"""Frequency-window self-protection (P3 subset of PHYSICS §2.7).

Synchronous machines and converter plants trip outside [47.5, 51.5] Hz after
a 100 ms pickup delay (PARAMETERS §2.2). UFLS, RoCoF effects, overload duty,
and islanding arrive in P8. Timers are absolute-dt accumulations — fully
deterministic and snapshot-covered.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class FWindowConfig:
    low_hz: float = 47.5
    high_hz: float = 51.5
    delay_us: int = 100_000


class FrequencyWindowRelays:
    def __init__(self, fleet, cfg: FWindowConfig | None = None) -> None:
        self.cfg = cfg or FWindowConfig()
        self.sync_timer_us = np.zeros(fleet.n_sync, dtype=np.int64)
        self.inv_timer_us = np.zeros(len(fleet.inv_ids), dtype=np.int64)

    def check(self, fleet, f_island: np.ndarray, dt_us: int) -> list[str]:
        """Advance relay timers against the post-tick frequency; return the
        ids whose pickup delay elapsed (to be tripped via events)."""
        trips: list[str] = []
        low, high, delay = self.cfg.low_hz, self.cfg.high_hz, self.cfg.delay_us

        if fleet.n_sync:
            f_dev = f_island[fleet.island_of]
            out = ((f_dev < low) | (f_dev > high)) & fleet.online
            self.sync_timer_us = np.where(out, self.sync_timer_us + dt_us, 0)
            for row in np.nonzero(self.sync_timer_us > delay)[0]:
                trips.append(fleet.ids[row])
                self.sync_timer_us[row] = 0

        if len(fleet.inv_ids):
            f_dev = f_island[fleet.inv_island]
            out = ((f_dev < low) | (f_dev > high)) & fleet.inv_online
            self.inv_timer_us = np.where(out, self.inv_timer_us + dt_us, 0)
            for row in np.nonzero(self.inv_timer_us > delay)[0]:
                trips.append(fleet.inv_ids[row])
                self.inv_timer_us[row] = 0

        return trips

    def state_dict(self) -> dict:
        return {
            "sync_timer_us": self.sync_timer_us.tolist(),
            "inv_timer_us": self.inv_timer_us.tolist(),
        }

    def restore_state(self, state: dict) -> None:
        self.sync_timer_us[:] = np.array(state["sync_timer_us"], dtype=np.int64)
        self.inv_timer_us[:] = np.array(state["inv_timer_us"], dtype=np.int64)


# ---------------------------------------------------------------------------
# P8 defense plan (PARAMETERS §2.2, mechanics PHYSICS §2.7)

UFLS_STAGES: list[tuple[float, float]] = [
    (49.0, 0.075), (48.8, 0.075), (48.6, 0.075),
    (48.4, 0.075), (48.2, 0.075), (48.0, 0.075),
]
UFLS_PICKUP_US = 150_000
PUMP_SHED_HZ = 49.7  # all PHS pumping trips (automatic load relief)
ELY_SHED_HZ = 49.6  # interruptible tier (proportional shed is already full)
RESTORE_F_OK_HZ = 49.8
RESTORE_F_OK_US = 300_000_000  # 5 min above 49.8 before restoration may ramp
RESTORE_RAMP_PER_S = 0.001  # 1 % of original load per 10 s
RESTORE_BLOCK = 0.10  # one restore_load command = one 10 % block
EMBEDDED_DG_FRAC = 0.15  # of current island load (netted embedded generation)
ROCOF_DG_ROWS: list[tuple[float, float]] = [(0.5, 0.02), (1.0, 0.05)]
POLE_SLIP_ROCOF = 2.0
POLE_SLIP_P = 0.2
ROCOF_REARM_FACTOR = 0.5  # a row re-arms once |RoCoF| falls below half its pick-up


class DefensePlan:
    """UFLS + interruptible-tier shedding + restoration ramp + the RoCoF feel
    table. All latches/timers are absolute-dt accumulations, the pole-slip
    draws come from the scenario `protection_seed` PRNG in event order —
    fully deterministic and snapshot-covered."""

    def __init__(self, n_islands: int, protection_seed: int = 0) -> None:
        n = n_islands
        k = len(UFLS_STAGES)
        self.stage_armed = np.ones((k, n), dtype=bool)
        self.stage_timer_us = np.zeros((k, n), dtype=np.int64)
        self.ely_latched = np.zeros(n, dtype=bool)
        self.pump_latched = np.zeros(n, dtype=bool)
        self.rocof_armed = np.ones((len(ROCOF_DG_ROWS), n), dtype=bool)
        self.pole_armed = np.ones(n, dtype=bool)
        self.restore_target_w = np.ones(n)
        self.f_ok_since_us = np.full(n, -1, dtype=np.int64)
        self.rng = np.random.default_rng(protection_seed)

    def request_restore(self, island: int, fraction: float) -> None:
        """One game `restore_load` command = one block toward w = 1."""
        self.restore_target_w[island] = float(np.clip(
            self.restore_target_w[island] + fraction, 0.0, 1.0))

    def tick(self, fleet, islands, t_us: int, dt_us: int,
             rocof_windowed: np.ndarray
             ) -> tuple[list[tuple[str, dict]], list[tuple[str, str, dict]]]:
        """Returns (device_trips as (id, data), events as (kind, element,
        data)) — the trip data carries the CAUSE onto the wire event."""
        trips: list[tuple[str, dict]] = []
        events: list[tuple[str, str, dict]] = []
        f = islands.f
        alive = ~islands.blackout()
        dt_s = dt_us / 1e6

        # --- automatic load relief: PHS pumping trips at 49.7 -------------
        for island in np.nonzero((f < PUMP_SHED_HZ) & alive
                                 & ~self.pump_latched)[0]:
            self.pump_latched[island] = True
            rows = np.nonzero(fleet.is_hydro & (fleet.island_of == island)
                              & (fleet.hy_pump_set > 0.0))[0]
            shed_mw = float(fleet.hy_pump_p[rows].sum()) if len(rows) else 0.0
            fleet.hy_pump_set[fleet.island_of == island] = 0.0
            events.append(("pump_shed", f"island:{island}",
                           {"f_hz": float(f[island]), "shed_mw": shed_mw}))
        # while latched, dispatcher re-commands are overridden every tick
        for island in np.nonzero(self.pump_latched)[0]:
            fleet.hy_pump_set[fleet.island_of == island] = 0.0

        # --- interruptible tier: electrolyzers latch off at 49.6 ----------
        for island in np.nonzero((f < ELY_SHED_HZ) & alive & ~self.ely_latched)[0]:
            self.ely_latched[island] = True
            if len(fleet.ely_ids):
                rows = np.nonzero((fleet.ely_island == island) & fleet.ely_online)[0]
                for row in rows:
                    trips.append((fleet.ely_ids[row], {"cause": "interruptible"}))
            events.append(("ely_shed", f"island:{island}", {"f_hz": float(f[island])}))

        # --- UFLS stages: 150 ms pickup, latch once per event -------------
        for k, (thr, shed) in enumerate(UFLS_STAGES):
            mask = self.stage_armed[k] & alive & (f < thr)
            self.stage_timer_us[k] = np.where(mask, self.stage_timer_us[k] + dt_us, 0)
            for island in np.nonzero(self.stage_timer_us[k] > UFLS_PICKUP_US)[0]:
                self.stage_armed[k, island] = False
                self.stage_timer_us[k, island] = 0
                islands.w[island] = max(islands.w[island] - shed, 1.0 - 0.45)
                self.restore_target_w[island] = islands.w[island]
                events.append(("ufls_stage", f"island:{island}",
                               {"stage": k + 1, "shed_frac": shed,
                                "w": float(islands.w[island])}))

        # --- RoCoF feel table (500 ms windowed) ---------------------------
        aro = np.abs(rocof_windowed)
        for r, (thr, dg_frac) in enumerate(ROCOF_DG_ROWS):
            fired = np.nonzero(self.rocof_armed[r] & alive & (aro >= thr))[0]
            for island in fired:
                self.rocof_armed[r, island] = False
                dg_mw = dg_frac * EMBEDDED_DG_FRAC * float(
                    islands.p_l0[island] * islands.w[island])
                islands.p_extra[island] += dg_mw
                events.append(("rocof_dg_trip", f"island:{island}",
                               {"rocof_hz_s": float(rocof_windowed[island]),
                                "dg_mw": dg_mw}))
            self.rocof_armed[r] |= aro < thr * ROCOF_REARM_FACTOR
        # pole-slip risk: each ONLINE sync unit trips with 20 % probability,
        # drawn in row order from the seeded PRNG (deterministic per event)
        for island in np.nonzero(self.pole_armed & alive & (aro >= POLE_SLIP_ROCOF))[0]:
            self.pole_armed[island] = False
            rows = np.nonzero((fleet.island_of == island) & fleet.online)[0]
            draws = self.rng.random(len(rows))
            for row, draw in zip(rows, draws):
                if draw < POLE_SLIP_P:
                    trips.append((fleet.ids[row],
                                  {"cause": "pole_slip",
                                   "rocof_hz_s": float(rocof_windowed[island])}))
        self.pole_armed |= aro < POLE_SLIP_ROCOF * ROCOF_REARM_FACTOR

        # --- restoration: ramp w toward the requested target --------------
        f_ok = (f > RESTORE_F_OK_HZ) & alive
        self.f_ok_since_us = np.where(
            f_ok, np.where(self.f_ok_since_us < 0, t_us, self.f_ok_since_us), -1)
        held = f_ok & (self.f_ok_since_us >= 0) \
            & (t_us - self.f_ok_since_us >= RESTORE_F_OK_US)
        for island in np.nonzero(held & (self.restore_target_w > islands.w))[0]:
            step = RESTORE_RAMP_PER_S * dt_s
            islands.w[island] = min(islands.w[island] + step,
                                    self.restore_target_w[island])
            if islands.w[island] >= 0.9995:
                islands.w[island] = 1.0
                # full restoration re-arms the event latches (§2.2)
                self.stage_armed[:, island] = True
                self.ely_latched[island] = False
                self.pump_latched[island] = False
                islands.p_extra[island] = 0.0
                if len(fleet.ely_ids):
                    rows = np.nonzero(fleet.ely_island == island)[0]
                    fleet.ely_online[rows] = True
                events.append(("load_restored", f"island:{island}", {}))

        return trips, events

    def remap(self, parent_of_new: list[int]) -> None:
        """Re-shape all per-island latches after an island split/merge: each
        NEW island inherits its parent's defense state (COI approximation —
        same rule as the frequency itself)."""
        idx = np.array(parent_of_new, dtype=np.int64)
        self.stage_armed = self.stage_armed[:, idx].copy()
        self.stage_timer_us = self.stage_timer_us[:, idx].copy()
        self.ely_latched = self.ely_latched[idx].copy()
        self.pump_latched = self.pump_latched[idx].copy()
        self.rocof_armed = self.rocof_armed[:, idx].copy()
        self.pole_armed = self.pole_armed[idx].copy()
        self.restore_target_w = self.restore_target_w[idx].copy()
        self.f_ok_since_us = self.f_ok_since_us[idx].copy()

    def state_dict(self) -> dict:
        return {
            "stage_armed": self.stage_armed.tolist(),
            "stage_timer_us": self.stage_timer_us.tolist(),
            "ely_latched": self.ely_latched.tolist(),
            "pump_latched": self.pump_latched.tolist(),
            "rocof_armed": self.rocof_armed.tolist(),
            "pole_armed": self.pole_armed.tolist(),
            "restore_target_w": [repr(float(v)) for v in self.restore_target_w],
            "f_ok_since_us": self.f_ok_since_us.tolist(),
            "rng": self.rng.bit_generator.state,
        }

    def restore_state(self, state: dict) -> None:
        self.stage_armed[:] = np.array(state["stage_armed"], dtype=bool)
        self.stage_timer_us[:] = np.array(state["stage_timer_us"], dtype=np.int64)
        self.ely_latched[:] = np.array(state["ely_latched"], dtype=bool)
        self.pump_latched[:] = np.array(
            state.get("pump_latched", self.pump_latched.tolist()), dtype=bool)
        self.rocof_armed[:] = np.array(state["rocof_armed"], dtype=bool)
        self.pole_armed[:] = np.array(state["pole_armed"], dtype=bool)
        self.restore_target_w[:] = np.array(
            [float(v) for v in state["restore_target_w"]])
        self.f_ok_since_us[:] = np.array(state["f_ok_since_us"], dtype=np.int64)
        self.rng.bit_generator.state = state["rng"]
