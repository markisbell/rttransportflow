"""Master integration loop (PHYSICS §1.2) + ALERT/CALM mode controller (§1.3).

Determinism/slicing rules implemented here:

- Time is integer µs; every stopping boundary is ABSOLUTE: the mode tick grid
  (k·dt_mode), PF instants (k·pf_interval), sample instants (k·sample_dt),
  and event times (grid-quantized at insertion). A step target never stops
  integration mid-boundary — `advance()` stops ON the last boundary within
  the request, so a sliced run walks the identical boundary sequence as an
  unsliced one → bit-identical trajectories.
- Consequence (documented deviation from the draft contract): `dt_done` is
  boundary-quantized; if the request is shorter than the next boundary the
  engine advances one boundary anyway (`dt_done` may exceed `dt_s` by up to
  one CALM tick — 250 ms). The wire `t`/idempotency story is unaffected.
- Mode transitions read only sim state; schedules are recomputed as the next
  absolute multiples after a transition (deterministic in absolute time).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np

from . import F0, QUANTUM_US, SNAP_MARK_US, US
from .events import Event, EventQueue
from .fleet import Fleet
from .telemetry import FineRing, TrajectoryBuffer

INF_US = 1 << 62


@dataclass
class ModeConfig:
    dt_alert_us: int = 10_000
    dt_calm_us: int = 250_000
    pf_alert_us: int = 1_000_000
    pf_calm_us: int = 30_000_000
    sample_alert_us: int = 20_000
    sample_calm_us: int = 1_000_000
    alert_df_hz: float = 0.050
    alert_rocof_hz_s: float = 0.025
    calm_df_hz: float = 0.030
    calm_rocof_hz_s: float = 0.010
    calm_hold_us: int = 30_000_000
    event_horizon_us: int = 5_000_000
    # AGC / aFRR (PHYSICS §2.8, ledger 19)
    agc_k_p: float = 0.1
    agc_k_i: float = 1.0 / 120.0

    @classmethod
    def from_settings(cls, settings) -> "ModeConfig":
        """Build from the service Settings (env-overridable knobs — the
        ledger-5 hysteresis revisit surface). Every default env produces a
        config BIT-EQUAL to ModeConfig(): the unit conversions here are
        exact for the default values, so wiring this changed nothing until
        someone actually sets an RTTRANSPORTFLOW_DT_* variable — at which
        point the bit-exact-pinned smokes on that machine no longer compare
        to the recorded numbers (deliberate: the knobs exist to experiment)."""
        return cls(
            dt_alert_us=int(round(settings.dt_alert * US)),
            dt_calm_us=int(round(settings.dt_calm * US)),
            pf_alert_us=int(round(settings.pf_interval_alert * US)),
            pf_calm_us=int(round(settings.pf_interval_calm * US)),
            alert_df_hz=settings.alert_df_mhz / 1000.0,
            alert_rocof_hz_s=settings.alert_rocof_mhz_s / 1000.0,
            calm_df_hz=settings.calm_df_mhz / 1000.0,
            calm_rocof_hz_s=settings.calm_rocof_mhz_s / 1000.0,
            calm_hold_us=int(round(settings.calm_hold_s * US)),
        )


@dataclass
class IslandState:
    """Vectorized per-island swing state (PHYSICS §2.3)."""

    f: np.ndarray  # Hz
    e_k: np.ndarray  # MJ (recomputed on fleet changes)
    p_l0: np.ndarray  # zone-demand ledger sum [MW], sample-and-hold
    w: np.ndarray  # surviving load fraction (UFLS sheds it, restoration raises)
    p_loss: np.ndarray  # network losses [MW], sample-and-hold from PF
    d_pu: float  # load damping, per-unit
    # extra f-insensitive net load [MW]: tripped embedded DG (PARAMETERS §2.2
    # RoCoF rows) raises island net load; restored with load restoration
    p_extra: np.ndarray = None

    def __post_init__(self) -> None:
        if self.p_extra is None:
            self.p_extra = np.zeros_like(self.f)

    @property
    def n(self) -> int:
        return len(self.f)

    def p_load(self, f: np.ndarray | None = None) -> np.ndarray:
        f_eval = self.f if f is None else f
        return (self.p_l0 * self.w * (1.0 + self.d_pu * (f_eval - F0) / F0)
                + self.p_extra)

    def swing_update(self, dt_us: int, p_inj: np.ndarray) -> np.ndarray:
        """Semi-implicit update; returns the new f (also stored).

        An island with E_k = 0 (every source gone) is BLACKED OUT: its
        frequency freezes (never NaN on the wire — found when a collapsing
        auto-built grid nulled f_min and crashed the game client)."""
        dt_s = dt_us / US
        alive = self.e_k > 0.0
        k_f = np.where(alive, dt_s * F0 / (2.0 * np.maximum(self.e_k, 1e-9)), 0.0)
        numer = self.f + k_f * (p_inj - self.p_loss - self.p_extra
                                - self.p_l0 * self.w * (1.0 - self.d_pu))
        denom = 1.0 + k_f * self.p_l0 * self.w * self.d_pu / F0
        self.f = np.where(alive, numer / denom, self.f)
        return self.f

    def blackout(self) -> np.ndarray:
        return self.e_k <= 0.0


@dataclass
class AdvanceResult:
    dt_done_us: int
    t_end_us: int
    mode: str
    events: list[Event]
    early_return: bool
    f_end: np.ndarray
    f_min: np.ndarray
    f_max: np.ndarray
    rocof_max: np.ndarray  # max |windowed RoCoF| per island over the window
    trajectory: dict
    balance_err: float


class Integrator:
    # 1-D per-island state gathered by parent on every island reshape.
    # Ledger 37 is the bug shape this prevents: a forgotten hand-remap
    # compiles, runs fine on single-island worlds, and corrupts on the
    # first mid-batch split. DECLARE new arrays here — replace_islands
    # gathers everything listed; only genuinely special state (fresh
    # FineRings, the energy-ledger restart, f_start) is remapped by hand.
    PER_ISLAND = ("_rocof_inst", "agc_mw", "agc_int")

    def __init__(
        self,
        fleet: Fleet,
        islands: IslandState,
        cfg: ModeConfig | None = None,
        pf_hook: Callable[[str], None] | None = None,
        trajectory_max_samples: int = 512,
        protection_seed: int = 0,
        fwindow=None,  # FWindowConfig | None — catalog frequency_protection
    ) -> None:
        from .protection import DefensePlan, FrequencyWindowRelays

        self.fleet = fleet
        self.islands = islands
        self.cfg = cfg or ModeConfig()
        self.pf_hook = pf_hook  # called with reason "scheduled"|"event"; updates p_loss
        self.trajectory_max_samples = trajectory_max_samples
        self.relays = FrequencyWindowRelays(fleet, fwindow)
        self.defense = DefensePlan(islands.n, protection_seed)
        # sim-layer topology callback: line_trip/line_close events land here
        # (the integrator knows nothing about pandapower); returns follow-up
        # (kind, element, data) events — island_split/island_merge
        self.topology_hook: Callable[[str, str], list] | None = None
        # rolling-ring capture (ledger 23): called at 5 s sim marks — which
        # already lie ON the tick grid (250 ms and 10 ms both divide 5 s),
        # so arming it never changes the boundary sequence (slicing identity)
        self.snapshot_hook: Callable[[int], None] | None = None
        # analytic fixtures pin the bare swing+FCR path (PHYSICS §6 runs
        # "with clamps disabled" — the defense layer counts as one)
        self.defense_enabled = True
        # secondary control (aFRR): the §6 droop-only QSS pins run with it
        # OFF — with AGC the frequency returns to 50 Hz by construction
        self.agc_enabled = True
        self.agc_mw = np.zeros(islands.n)  # commanded secondary correction
        self.agc_int = np.zeros(islands.n)  # PI integral state [MW·? ]

        self.t_us = 0
        self.mode = "calm"
        self.quiet_us = 0
        # wire `watch` list: (label, block in {sync,inv,bat,ely}, row)
        self.watch_specs: list[tuple[str, str, int]] = []
        self.queue = EventQueue()
        self._pending_topology_events: list[Event] = []
        self._batch_was_alive: np.ndarray | None = None
        self.rings = {i: FineRing() for i in range(islands.n)}
        self._rocof_inst = np.zeros(islands.n)
        self.energy_in_mj = 0.0  # ∫(P_inj − P_load − P_loss) dt
        self.energy_load_mj = 0.0  # ∫ P_load dt (throughput, for the balance test)
        self.f_start = islands.f.copy()  # for the energy-balance identity

        self.refresh_e_k()

    # ------------------------------------------------------------------

    def refresh_e_k(self) -> None:
        self.islands.e_k = self.fleet.e_k_per_island(self.islands.n)

    def replace_islands(self, islands: IslandState,
                        parent_of_new: list[int]) -> None:
        """Adopt a re-topologized island set (split/merge). Per-island state
        inherits from the parent island; fresh rings start empty (windowed
        RoCoF rebuilds within ~one ALERT sample). The energy-balance ledger
        restarts — the identity is only meaningful within one topology."""
        idx = np.array(parent_of_new, dtype=np.int64)
        if self._batch_was_alive is not None:
            # carry an in-flight event batch's alive-mask through the reshape
            self._batch_was_alive = self._batch_was_alive[idx].copy()
        self.islands = islands
        self.rings = {i: FineRing() for i in range(islands.n)}
        # declared per-island state: control areas re-form with the islands
        # (inherit the parent's secondary state rather than kicking every
        # unit at the split)
        for name in self.PER_ISLAND:
            setattr(self, name, getattr(self, name)[idx].copy())
        self.f_start = islands.f.copy()
        self.energy_in_mj = 0.0
        self.energy_load_mj = 0.0
        self.defense.remap(parent_of_new)
        self.refresh_e_k()

    @property
    def _dt_mode(self) -> int:
        return self.cfg.dt_alert_us if self.mode == "alert" else self.cfg.dt_calm_us

    @property
    def _pf_interval(self) -> int:
        return self.cfg.pf_alert_us if self.mode == "alert" else self.cfg.pf_calm_us

    @property
    def _sample_interval(self) -> int:
        return self.cfg.sample_alert_us if self.mode == "alert" else self.cfg.sample_calm_us

    @staticmethod
    def _next_multiple(t_us: int, interval_us: int) -> int:
        return (t_us // interval_us + 1) * interval_us

    def enter_alert(self) -> None:
        self.mode = "alert"
        self.quiet_us = 0

    def _mode_update(self, dt_us: int) -> None:
        df_max = float(np.max(np.abs(self.islands.f - F0)))
        rocof_max = float(np.max(np.abs(self._rocof_inst)))
        if self.mode == "calm":
            if df_max > self.cfg.alert_df_hz or rocof_max > self.cfg.alert_rocof_hz_s:
                self.enter_alert()
            return
        quiet = (
            df_max < self.cfg.calm_df_hz
            and rocof_max < self.cfg.calm_rocof_hz_s
            and not self.queue.has_event_within(self.t_us, self.cfg.event_horizon_us)
        )
        self.quiet_us = self.quiet_us + dt_us if quiet else 0
        if self.quiet_us >= self.cfg.calm_hold_us:
            self.mode = "calm"

    # ------------------------------------------------------------------

    def _agc_update(self, dt_s: float) -> None:
        """Secondary control per island (PHYSICS §2.8): ACE = ΔP_tie + B·Δf
        with the textbook bias B = ΣK_i + D·P_L0/f0 (ledger 19); one
        synchronous area means no tie flows. PI with anti-windup at the
        participating headroom; the command reaches units through their own
        dispatch slew, so restoration is only as fast as the fleet allows."""
        islands = self.islands
        alive = ~islands.blackout()
        df = islands.f - F0
        k_sum = np.zeros(islands.n)
        online = self.fleet.online
        if self.fleet.n_sync and online.any():
            np.add.at(k_sum, self.fleet.island_of[online],
                      self.fleet.k_droop[online])
        bias = k_sum + islands.d_pu * islands.p_l0 * islands.w / F0
        ace = bias * df  # MW: negative when the island is short
        up, down = self.fleet.agc_headroom(islands.n)

        integral = self.agc_int + ace * dt_s
        command = -(self.cfg.agc_k_p * ace + self.cfg.agc_k_i * integral)
        clamped = np.clip(command, -down, up)
        # anti-windup: only integrate where the command is not railed
        self.agc_int = np.where((command == clamped) & alive,
                                integral, self.agc_int)
        self.agc_mw = np.where(alive, clamped, 0.0)

    def _tick(self, dt_us: int) -> None:
        """Tick order per PHYSICS §2.6."""
        if self.agc_enabled:
            self._agc_update(dt_us / US)
        p_mech, p_inv = self.fleet.tick(
            dt_us, self.islands.f, self.islands.n, self._rocof_inst,
            self.agc_mw if self.agc_enabled else None
        )
        p_inj = p_mech + p_inv
        f_prev = self.islands.f
        f_new = self.islands.swing_update(dt_us, p_inj)
        self._rocof_inst = (f_new - f_prev) / (dt_us / US)
        # Energy meters (damping term at f⁺ — the semi-implicit exact pairing).
        p_load = self.islands.p_load(f_new)
        dt_s = dt_us / US
        self.energy_in_mj += float(np.sum(p_inj - self.islands.p_loss - p_load)) * dt_s
        self.energy_load_mj += float(np.sum(p_load)) * dt_s

    def _apply_events(self, events: list[Event]) -> None:
        # A line event inside THIS batch can re-topologize mid-loop, so the
        # alive-mask lives on the instance and `replace_islands` remaps it by
        # parent island. (A raw comparison crashed on a 2->3 split; the 1->2
        # case had been masked by numpy broadcasting.)
        self._batch_was_alive = ~self.islands.blackout()
        for event in events:
            if event.kind == "trip":
                try:
                    self.fleet.trip(event.element, self.t_us)
                except KeyError:
                    # a trip on an id the reset never registered (e.g. a
                    # dropped hub) must NOT crash the loop — never-crash rule
                    event.data["unknown_device"] = True
                    continue
                self.refresh_e_k()
            elif event.kind == "load_step":
                island = int(event.data.get("island", 0))
                self.islands.p_l0[island] += float(event.data["delta_mw"])
            elif event.kind in ("line_trip", "line_close"):
                if self.topology_hook is not None:
                    for kind, element, data in self.topology_hook(
                            event.kind, event.element):
                        self._pending_topology_events.append(
                            Event(self.t_us, kind, element, data,
                                  significant=True))
            elif event.kind == "start_complete":
                pass  # informational (commitment already applied)
            else:
                raise ValueError(f"unknown event kind {event.kind!r}")
        # a COLLAPSE disconnects everything: a newly-dead island loses its
        # load (w -> 0) so a later black start faces an unloaded system and
        # the game re-picks demand up in restore_load blocks (PHYSICS §2.7)
        # An island BORN dead by a split counts as newly black too: the mask
        # was remapped through the split, so it carries its parent's state.
        was_alive = self._batch_was_alive
        self._batch_was_alive = None
        newly_black = was_alive & self.islands.blackout()
        for island in np.nonzero(newly_black)[0]:
            self.islands.w[island] = 0.0
            self.islands.p_extra[island] = 0.0
            self.defense.restore_target_w[island] = 0.0
            self._pending_topology_events.append(
                Event(self.t_us, "blackout", f"island:{island}", {},
                      significant=True))

    def balance_err(self) -> float:
        """|∫(P_inj−P_load−P_loss)dt − (2/f0)·Σ E_k·Δf| / ∫P_load dt."""
        kinetic = float(np.sum(2.0 / F0 * self.islands.e_k * (self.islands.f - self.f_start)))
        if self.energy_load_mj <= 0:
            return 0.0
        return abs(self.energy_in_mj - kinetic) / self.energy_load_mj

    # ------------------------------------------------------------------

    def advance(self, dt_us: int, interrupt_on_event: bool = True) -> AdvanceResult:
        start = self.t_us
        target = start + max(dt_us, 0)
        buffer = TrajectoryBuffer()
        fired: list[Event] = []
        early = False
        f_min = self.islands.f.copy()
        f_max = self.islands.f.copy()
        rocof_max = np.zeros(self.islands.n)

        next_pf = self._next_multiple(self.t_us, self._pf_interval)
        next_sample = self._next_multiple(self.t_us, self._sample_interval)
        did_any = False

        while True:
            candidates = [
                self._next_multiple(self.t_us, self._dt_mode),
                next_pf,
                next_sample,
            ]
            ev_t = self.queue.peek_time()
            if ev_t is not None:
                candidates.append(max(ev_t, self.t_us + QUANTUM_US))
            boundary = min(candidates)

            if boundary > target and did_any:
                break  # stop ON the last boundary within the request

            dt = boundary - self.t_us
            self._tick(dt)
            self.t_us = boundary
            did_any = True

            np.minimum(f_min, self.islands.f, out=f_min)
            np.maximum(f_max, self.islands.f, out=f_max)

            # engine notices from the tick (H2 starvation etc.)
            if self.fleet.notices:
                for kind, device_id in self.fleet.notices:
                    fired.append(Event(self.t_us, kind, device_id,
                                       significant=(kind == "fuel_starved")))
                    buffer.mark_event(self.t_us)
                    if kind == "fuel_starved":
                        self.enter_alert()
                significant_notice = any(k == "fuel_starved" for k, _ in self.fleet.notices)
                self.fleet.notices.clear()
                if interrupt_on_event and significant_notice:
                    early = True
                    break

            # commitment completions (informational events)
            was_black = self.islands.blackout().copy()
            completions = self.fleet.poll_commitment(
                self.t_us, self.islands.f, self.islands.blackout())
            for device_id in completions:
                self.refresh_e_k()
                completed = Event(self.t_us, "start_complete", device_id,
                                  significant=False)
                fired.append(completed)
            if completions:
                # a black start into a dead island RE-ENERGIZES it: the
                # first machine sets the reference frequency (PHYSICS §2.7
                # scripted-restoration hook)
                revived = was_black & ~self.islands.blackout()
                for island in np.nonzero(revived)[0]:
                    self.islands.f[island] = F0
                    fired.append(Event(self.t_us, "black_start",
                                       f"island:{island}", {},
                                       significant=True))
                    buffer.mark_event(self.t_us)
                    self.enter_alert()

            # f-window self-protection: relay pickups become trip events NOW
            for device_id in self.relays.check(self.fleet, self.islands.f, dt):
                self.queue.schedule(Event(self.t_us, "trip", device_id,
                                          {"cause": "f_window"}))

            # defense plan (UFLS / interruptible tier / RoCoF table /
            # restoration ramp): trips are scheduled, sheds are applied
            def_trips: list = []
            def_events: list = []
            if self.defense_enabled:
                win_rocof = np.array([self.rings[i].rocof_window(self.t_us)
                                      for i in range(self.islands.n)])
                def_trips, def_events = self.defense.tick(
                    self.fleet, self.islands, self.t_us, dt, win_rocof)
            for device_id, trip_data in def_trips:
                self.queue.schedule(Event(self.t_us, "trip", device_id,
                                          trip_data))
            defense_early = False
            for kind, element, data in def_events:
                if kind == "trip":
                    continue  # the scheduled trip event carries the cause
                significant = kind in ("ufls_stage", "rocof_dg_trip")
                fired.append(Event(self.t_us, kind, element, data,
                                   significant=significant))
                if significant:
                    buffer.mark_event(self.t_us)
                    self.enter_alert()
                    defense_early = True

            due = self.queue.pop_due(self.t_us)
            if due:
                self._apply_events(due)
                fired.extend(due)
                if self._pending_topology_events:
                    fired.extend(self._pending_topology_events)
                    self._pending_topology_events.clear()
                buffer.mark_event(self.t_us)
                self._sample(buffer)
                if self.pf_hook is not None:
                    self.pf_hook("event")
                self.enter_alert()
                next_pf = self._next_multiple(self.t_us, self._pf_interval)
                next_sample = self._next_multiple(self.t_us, self._sample_interval)
                if interrupt_on_event and any(e.significant for e in due):
                    early = True
                    break
            if interrupt_on_event and defense_early:
                early = True
                break

            # a topology event may have re-shaped the island set mid-advance:
            # the per-step min/max window restarts at the new topology
            if len(f_min) != self.islands.n:
                f_min = self.islands.f.copy()
                f_max = self.islands.f.copy()
                rocof_max = np.zeros(self.islands.n)

            if self.t_us == next_pf:
                if self.pf_hook is not None:
                    self.pf_hook("scheduled")
                next_pf = self._next_multiple(self.t_us, self._pf_interval)

            if self.t_us == next_sample:
                self._sample(buffer)
                next_sample = self._next_multiple(self.t_us, self._sample_interval)

            mode_before = self.mode
            self._mode_update(dt)
            if self.mode != mode_before:
                next_pf = self._next_multiple(self.t_us, self._pf_interval)
                next_sample = self._next_multiple(self.t_us, self._sample_interval)

            if self.snapshot_hook is not None and self.t_us % SNAP_MARK_US == 0:
                self.snapshot_hook(self.t_us)

            for island in range(self.islands.n):
                rocof_max[island] = max(
                    rocof_max[island], abs(self.rings[island].rocof_window(self.t_us))
                )

            if self.t_us >= target:
                break

        return AdvanceResult(
            dt_done_us=self.t_us - start,
            t_end_us=self.t_us,
            mode=self.mode,
            events=fired,
            early_return=early,
            f_end=self.islands.f.copy(),
            f_min=f_min,
            f_max=f_max,
            rocof_max=rocof_max,
            trajectory=buffer.emit(start, self.trajectory_max_samples),
            balance_err=self.balance_err(),
        )

    def _sample(self, buffer: TrajectoryBuffer) -> None:
        watched = None
        if self.watch_specs:
            arrays = {"sync": self.fleet.y, "inv": self.fleet.inv_p,
                      "bat": self.fleet.bat_p, "ely": self.fleet.ely_p}
            watched = {label: float(arrays[block][row])
                       for label, block, row in self.watch_specs}
        buffer.sample(self.t_us, self.islands.f, watched)
        for island in range(self.islands.n):
            self.rings[island].append(self.t_us, float(self.islands.f[island]))

    # ------------------------------------------------------------------

    def state_dict(self) -> dict[str, Any]:
        return {
            "version": 1,
            "t_us": self.t_us,
            "mode": self.mode,
            "quiet_us": self.quiet_us,
            "f": [repr(float(v)) for v in self.islands.f],
            "p_l0": [repr(float(v)) for v in self.islands.p_l0],
            "w": [repr(float(v)) for v in self.islands.w],
            "p_loss": [repr(float(v)) for v in self.islands.p_loss],
            "rocof_inst": [repr(float(v)) for v in self._rocof_inst],
            "agc_mw": [repr(float(v)) for v in self.agc_mw],
            "agc_int": [repr(float(v)) for v in self.agc_int],
            "energy_in_mj": repr(self.energy_in_mj),
            "energy_load_mj": repr(self.energy_load_mj),
            "f_start": [repr(float(v)) for v in self.f_start],
            "fleet": self.fleet.state_dict(),
            # attachment state is FLEET-owned; spliced at the same top-level
            # keys so the snapshot layout stays byte-identical (each new
            # attachment used to mean editing the Integrator in two places)
            **self.fleet.attachments_state(),
            "p_extra": [repr(float(v)) for v in self.islands.p_extra],
            "defense": self.defense.state_dict(),
            "relays": self.relays.state_dict(),
            "events": self.queue.snapshot(),
        }

    def restore_state(self, state: dict[str, Any]) -> None:
        if state.get("version") != 1:
            raise ValueError(f"unsupported snapshot version {state.get('version')!r}")
        self.t_us = int(state["t_us"])
        self.mode = state["mode"]
        self.quiet_us = int(state["quiet_us"])
        self.islands.f = np.array([float(v) for v in state["f"]])
        self.islands.p_l0 = np.array([float(v) for v in state["p_l0"]])
        self.islands.w = np.array([float(v) for v in state["w"]])
        self.islands.p_loss = np.array([float(v) for v in state["p_loss"]])
        self._rocof_inst = np.array([float(v) for v in state["rocof_inst"]])
        if "agc_mw" in state:
            self.agc_mw = np.array([float(v) for v in state["agc_mw"]])
            self.agc_int = np.array([float(v) for v in state["agc_int"]])
        self.energy_in_mj = float(state["energy_in_mj"])
        self.energy_load_mj = float(state["energy_load_mj"])
        self.f_start = np.array([float(v) for v in state["f_start"]])
        self.fleet.restore_state(state["fleet"])
        self.fleet.restore_attachments(state)
        if state.get("p_extra") is not None:
            self.islands.p_extra = np.array([float(v) for v in state["p_extra"]])
        if state.get("defense") is not None:
            self.defense.restore_state(state["defense"])
        self.relays.restore_state(state["relays"])
        self.queue.restore(state["events"])
        self.refresh_e_k()
        self.rings = {i: FineRing() for i in range(self.islands.n)}
