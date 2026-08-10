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

from . import F0, QUANTUM_US, US
from .events import Event, EventQueue
from .fleet import Fleet
from ..telemetry import FineRing, TrajectoryBuffer

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


@dataclass
class IslandState:
    """Vectorized per-island swing state (PHYSICS §2.3)."""

    f: np.ndarray  # Hz
    e_k: np.ndarray  # MJ (recomputed on fleet changes)
    p_l0: np.ndarray  # zone-demand ledger sum [MW], sample-and-hold
    w: np.ndarray  # surviving load fraction (UFLS, P8) — 1.0 in P2
    p_loss: np.ndarray  # network losses [MW], sample-and-hold from PF
    d_pu: float  # load damping, per-unit

    @property
    def n(self) -> int:
        return len(self.f)

    def p_load(self, f: np.ndarray | None = None) -> np.ndarray:
        f_eval = self.f if f is None else f
        return self.p_l0 * self.w * (1.0 + self.d_pu * (f_eval - F0) / F0)

    def swing_update(self, dt_us: int, p_inj: np.ndarray) -> np.ndarray:
        """Semi-implicit update; returns the new f (also stored)."""
        dt_s = dt_us / US
        k_f = dt_s * F0 / (2.0 * self.e_k)
        numer = self.f + k_f * (p_inj - self.p_loss - self.p_l0 * self.w * (1.0 - self.d_pu))
        denom = 1.0 + k_f * self.p_l0 * self.w * self.d_pu / F0
        self.f = numer / denom
        return self.f


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
    def __init__(
        self,
        fleet: Fleet,
        islands: IslandState,
        cfg: ModeConfig | None = None,
        pf_hook: Callable[[str], None] | None = None,
        trajectory_max_samples: int = 512,
    ) -> None:
        from .protection import FrequencyWindowRelays

        self.fleet = fleet
        self.islands = islands
        self.cfg = cfg or ModeConfig()
        self.pf_hook = pf_hook  # called with reason "scheduled"|"event"; updates p_loss
        self.trajectory_max_samples = trajectory_max_samples
        self.relays = FrequencyWindowRelays(fleet)

        self.t_us = 0
        self.mode = "calm"
        self.quiet_us = 0
        # wire `watch` list: (label, block in {sync,inv,bat,ely}, row)
        self.watch_specs: list[tuple[str, str, int]] = []
        self.queue = EventQueue()
        self.rings = {i: FineRing() for i in range(islands.n)}
        self._rocof_inst = np.zeros(islands.n)
        self.energy_in_mj = 0.0  # ∫(P_inj − P_load − P_loss) dt
        self.energy_load_mj = 0.0  # ∫ P_load dt (throughput, for the balance test)
        self.f_start = islands.f.copy()  # for the energy-balance identity

        self.refresh_e_k()

    # ------------------------------------------------------------------

    def refresh_e_k(self) -> None:
        self.islands.e_k = self.fleet.e_k_per_island(self.islands.n)

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

    def _tick(self, dt_us: int) -> None:
        """Tick order per PHYSICS §2.6 (H2 chain arrives in P7)."""
        p_mech, p_inv = self.fleet.tick(
            dt_us, self.islands.f, self.islands.n, self._rocof_inst
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
        for event in events:
            if event.kind == "trip":
                self.fleet.trip(event.element, self.t_us)
                self.refresh_e_k()
            elif event.kind == "load_step":
                island = int(event.data.get("island", 0))
                self.islands.p_l0[island] += float(event.data["delta_mw"])
            elif event.kind == "start_complete":
                pass  # informational (commitment already applied)
            else:
                raise ValueError(f"unknown event kind {event.kind!r}")

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

            # commitment completions (informational events)
            for device_id in self.fleet.poll_commitment(self.t_us):
                self.refresh_e_k()
                completed = Event(self.t_us, "start_complete", device_id,
                                  significant=False)
                fired.append(completed)

            # f-window self-protection: relay pickups become trip events NOW
            for device_id in self.relays.check(self.fleet, self.islands.f, dt):
                self.queue.schedule(Event(self.t_us, "trip", device_id,
                                          {"cause": "f_window"}))

            due = self.queue.pop_due(self.t_us)
            if due:
                self._apply_events(due)
                fired.extend(due)
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
            "energy_in_mj": repr(self.energy_in_mj),
            "energy_load_mj": repr(self.energy_load_mj),
            "f_start": [repr(float(v)) for v in self.f_start],
            "fleet": self.fleet.state_dict(),
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
        self.energy_in_mj = float(state["energy_in_mj"])
        self.energy_load_mj = float(state["energy_load_mj"])
        self.f_start = np.array([float(v) for v in state["f_start"]])
        self.fleet.restore_state(state["fleet"])
        self.relays.restore_state(state["relays"])
        self.queue.restore(state["events"])
        self.refresh_e_k()
        self.rings = {i: FineRing() for i in range(self.islands.n)}
