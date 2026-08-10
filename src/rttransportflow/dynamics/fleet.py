"""DeviceFleet: struct-of-arrays over all devices; no Python objects in the loop.

Synchronous machines carry the generic governor/turbine realization
(PHYSICS §2.4): dispatch slew -> droop with soft deadband + FCR-band/envelope
clamps -> T_g governor lag -> T_CH/T_RH reheat cascade with F_HP split, all
per-stage exact-exponential updates. Converter devices (wind/PV) are instant
injections at P2 (their lags arrive with the per-kind models in P3).

P2 uses ONE generic parameter set for every synchronous kind; P3 loads the
per-kind catalog.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import F0, US


@dataclass
class SyncParams:
    """Generic P2 defaults (PHYSICS §2.4 table, coal-ish middle ground)."""

    h_s: float = 4.0
    r_pu: float = 0.05
    db_hz: float = 0.010
    fcr_band_frac: float = 0.05  # of S_n; np.inf disables (analytic fixture)
    t_g: float = 0.2
    t_ch: float = 0.3
    t_rh: float = 8.0
    f_hp: float = 0.3
    ramp_frac_per_min: float = 4.0  # % of p_max per minute (dispatch slew)


@dataclass
class Fleet:
    # --- synchronous machines (parallel arrays, row = device) ---
    ids: list[str]
    island_of: np.ndarray  # int64
    s_n: np.ndarray
    p_max: np.ndarray
    p_min: np.ndarray
    h: np.ndarray
    k_droop: np.ndarray  # MW/Hz = s_n / (r * f0)
    db: np.ndarray  # Hz
    fcr_band: np.ndarray  # MW (np.inf = disabled)
    t_g: np.ndarray
    t_ch: np.ndarray
    t_rh: np.ndarray
    f_hp: np.ndarray
    ramp_mw_s: np.ndarray
    online: np.ndarray  # bool
    # states
    p_set: np.ndarray  # commanded dispatch target
    p_disp: np.ndarray  # slewed dispatch
    x_g: np.ndarray
    x_1: np.ndarray
    x_2: np.ndarray
    y: np.ndarray  # last turbine output per machine (read by the PF hook)
    # --- converter devices ---
    inv_ids: list[str]
    inv_island: np.ndarray
    inv_p: np.ndarray
    inv_target: np.ndarray
    inv_online: np.ndarray

    _coeff_cache: dict[int, tuple[np.ndarray, np.ndarray, np.ndarray]] = field(
        default_factory=dict, repr=False
    )

    # ------------------------------------------------------------------

    @property
    def n_sync(self) -> int:
        return len(self.ids)

    def invalidate_coeffs(self) -> None:
        self._coeff_cache.clear()

    def _coeffs(self, dt_us: int):
        cached = self._coeff_cache.get(dt_us)
        if cached is None:
            dt = dt_us / US
            cached = (
                np.exp(-dt / self.t_g),
                np.exp(-dt / self.t_ch),
                np.exp(-dt / self.t_rh),
            )
            if len(self._coeff_cache) > 64:  # boundary-shortened ticks recur; bound it
                self._coeff_cache.clear()
            self._coeff_cache[dt_us] = cached
        return cached

    def e_k_per_island(self, n_islands: int) -> np.ndarray:
        """Kinetic constant per island [MJ] over ONLINE synchronous machines."""
        e = np.zeros(n_islands)
        np.add.at(e, self.island_of[self.online], (self.h * self.s_n)[self.online])
        return e

    def s_online_per_island(self, n_islands: int) -> np.ndarray:
        s = np.zeros(n_islands)
        np.add.at(s, self.island_of[self.online], self.s_n[self.online])
        return s

    def trip(self, device_id: str) -> None:
        if device_id in self.ids:
            row = self.ids.index(device_id)
            self.online[row] = False
            self.p_disp[row] = self.x_g[row] = self.x_1[row] = self.x_2[row] = 0.0
            self.p_set[row] = 0.0
        elif device_id in self.inv_ids:
            row = self.inv_ids.index(device_id)
            self.inv_online[row] = False
            self.inv_p[row] = self.inv_target[row] = 0.0
        else:
            raise KeyError(device_id)

    def init_steady_state(self) -> None:
        """Start every lag state at its dispatch point (no artificial transient)."""
        self.p_disp[:] = self.p_set
        self.x_g[:] = self.p_set
        self.x_1[:] = self.p_set
        self.x_2[:] = self.p_set
        self.y[:] = self.p_set
        self.inv_p[:] = self.inv_target

    # ------------------------------------------------------------------

    def tick(self, dt_us: int, f_island: np.ndarray, n_islands: int):
        """One integration tick. Returns (p_mech, p_inv) sums per island [MW]."""
        dt_s = dt_us / US
        a_g, a_1, a_2 = self._coeffs(dt_us)

        df = f_island[self.island_of] - F0
        e = np.sign(df) * np.maximum(np.abs(df) - self.db, 0.0)
        prim = np.clip(-self.k_droop * e, -self.fcr_band, self.fcr_band)

        move = np.clip(self.p_set - self.p_disp, -self.ramp_mw_s * dt_s, self.ramp_mw_s * dt_s)
        self.p_disp += move

        u = np.clip(self.p_disp + prim, self.p_min, self.p_max)
        u = np.where(self.online, u, 0.0)

        self.x_g += (1.0 - a_g) * (u - self.x_g)
        self.x_1 += (1.0 - a_1) * (self.x_g - self.x_1)
        self.x_2 += (1.0 - a_2) * (self.x_1 - self.x_2)
        y = np.where(self.online, self.f_hp * self.x_1 + (1.0 - self.f_hp) * self.x_2, 0.0)
        self.y = y

        self.inv_p[:] = np.where(self.inv_online, self.inv_target, 0.0)

        p_mech = np.zeros(n_islands)
        np.add.at(p_mech, self.island_of, y)
        p_inv = np.zeros(n_islands)
        np.add.at(p_inv, self.inv_island, self.inv_p)
        return p_mech, p_inv

    # ------------------------------------------------------------------

    def state_dict(self) -> dict:
        return {
            "online": self.online.tolist(),
            "inv_online": self.inv_online.tolist(),
            "p_set": [repr(float(v)) for v in self.p_set],
            "p_disp": [repr(float(v)) for v in self.p_disp],
            "x_g": [repr(float(v)) for v in self.x_g],
            "x_1": [repr(float(v)) for v in self.x_1],
            "x_2": [repr(float(v)) for v in self.x_2],
            "inv_p": [repr(float(v)) for v in self.inv_p],
            "inv_target": [repr(float(v)) for v in self.inv_target],
        }

    def restore_state(self, state: dict) -> None:
        self.online[:] = np.array(state["online"], dtype=bool)
        self.inv_online[:] = np.array(state["inv_online"], dtype=bool)
        for name in ("p_set", "p_disp", "x_g", "x_1", "x_2", "inv_p", "inv_target"):
            getattr(self, name)[:] = np.array([float(v) for v in state[name]])


def make_fleet(
    sync: list[dict],
    inverters: list[dict] | None = None,
    defaults: SyncParams | None = None,
) -> Fleet:
    """Build a fleet from device dicts.

    sync entries: {id, island, s_n, p_max, p_set, [p_min, h, r, db, fcr_band,
    t_g, t_ch, t_rh, f_hp, ramp_mw_s]} — omitted keys fall to `defaults`.
    inverter entries: {id, island, p_target}.
    """
    d = defaults or SyncParams()
    inverters = inverters or []

    def arr(key: str, fallback) -> np.ndarray:
        return np.array([float(s.get(key, fallback(s))) for s in sync])

    n = len(sync)
    s_n = np.array([float(s["s_n"]) for s in sync])
    fleet = Fleet(
        ids=[s["id"] for s in sync],
        island_of=np.array([int(s.get("island", 0)) for s in sync], dtype=np.int64),
        s_n=s_n,
        p_max=arr("p_max", lambda s: s["s_n"] * 0.9),
        p_min=arr("p_min", lambda s: 0.0),
        h=arr("h", lambda s: d.h_s),
        k_droop=np.array(
            [float(s["s_n"]) / (float(s.get("r", d.r_pu)) * F0) for s in sync]
        ),
        db=arr("db", lambda s: d.db_hz),
        fcr_band=np.array(
            [float(s.get("fcr_band", d.fcr_band_frac * float(s["s_n"]))) for s in sync]
        ),
        t_g=arr("t_g", lambda s: d.t_g),
        t_ch=arr("t_ch", lambda s: d.t_ch),
        t_rh=arr("t_rh", lambda s: d.t_rh),
        f_hp=arr("f_hp", lambda s: d.f_hp),
        ramp_mw_s=np.array(
            [
                float(s.get("ramp_mw_s", d.ramp_frac_per_min / 100.0 * float(s.get("p_max", s["s_n"] * 0.9)) / 60.0))
                for s in sync
            ]
        ),
        online=np.ones(n, dtype=bool),
        p_set=arr("p_set", lambda s: 0.0),
        p_disp=np.zeros(n),
        x_g=np.zeros(n),
        x_1=np.zeros(n),
        x_2=np.zeros(n),
        y=np.zeros(n),
        inv_ids=[i["id"] for i in inverters],
        inv_island=np.array([int(i.get("island", 0)) for i in inverters], dtype=np.int64),
        inv_p=np.zeros(len(inverters)),
        inv_target=np.array([float(i.get("p_target", 0.0)) for i in inverters]),
        inv_online=np.ones(len(inverters), dtype=bool),
    )
    return fleet
