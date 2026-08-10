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
