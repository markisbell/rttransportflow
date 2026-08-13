"""DeviceFleet: struct-of-arrays over all devices; no Python objects in the loop.

Device blocks (PHYSICS §2.4, constants from data/catalogs/plant_types.json):

- SYNCHRONOUS machines share one governor pipeline (dispatch slew → droop
  with soft deadband + FCR-band/envelope clamps) feeding one of two turbine
  realizations, all per-stage exact-exponential:
    * unified 3-stage chain covering steam / CCGT / OCGT via coefficients:
      x_g ← c_in·u (T_a), x_1 ← x_g (T_b), x_2 ← c_2·x_1 (T_c),
      y = w_a·x_g + w_b·x_1 + w_c·x_2
      steam: c_in=1, c_2=1, w=(0, F_HP, 1−F_HP), T=(T_SM, T_CH, T_RH)
      ccgt:  c_in=2/3, c_2=0.5, w=(0, 1, 1),     T=(T1, T2, T_ST)
      ocgt:  c_in=1,   w=(0, 1, 0),              T=(T1, T2, ·)
    * hydro: transient-droop lead-lag → rate-limited servo → non-minimum-
      phase water column, y = 3·x_h − 2·g (the wrong-way kick).
  Plus unit commitment (offline/starting/online with hot/warm/cold lead
  times and trip lockout) and energy/fuel meters.
- BATTERIES: FFR/droop through a converter lag + SoC bookkeeping with
  efficiency and band clamps; grid-forming units add virtual inertia H_v to
  the island pool and debit inertial energy from SoC.
- ELECTROLYZERS: controllable load shedding on under-frequency.
- INVERTER plants (wind/PV): availability/curtailment following with
  asymmetric up/down lags and LFSM-O above 50.2 Hz.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import F0, US

# commitment states
OFFLINE, STARTING, ONLINE = 0, 1, 2

# LFSM-O (RfG, PHYSICS §2.7): above 50.2 Hz ALL generation curtails at 5 %
# droop — 40 % of current P per Hz over — BEFORE any 51.5 trip, so
# over-frequency never becomes a mass-disconnection cliff. The inverter
# block carries its own catalog-driven variant; this pair is the sync-side.
LFSM_O_FROM_HZ = 50.2
LFSM_O_GAIN_PER_HZ = 0.40


@dataclass
class SyncParams:
    """Generic defaults (used when a spec omits keys; analytic fixtures)."""

    h_s: float = 4.0
    r_pu: float = 0.05
    db_hz: float = 0.010
    fcr_band_frac: float = 0.05  # of S_n; np.inf disables
    t_g: float = 0.2
    t_ch: float = 0.3
    t_rh: float = 8.0
    f_hp: float = 0.3
    ramp_frac_per_min: float = 4.0


def _soft_db(df: np.ndarray, db: np.ndarray) -> np.ndarray:
    return np.sign(df) * np.maximum(np.abs(df) - db, 0.0)


@dataclass
class Fleet:
    # --- synchronous machines ---
    ids: list[str]
    island_of: np.ndarray
    s_n: np.ndarray
    p_max: np.ndarray  # envelope (device-level, game-set)
    p_min: np.ndarray
    h: np.ndarray
    k_droop: np.ndarray  # MW/Hz
    db: np.ndarray
    fcr_band: np.ndarray
    ramp_mw_s: np.ndarray
    # chain coefficients
    t_a: np.ndarray
    t_b: np.ndarray
    t_c: np.ndarray
    c_in: np.ndarray
    c_2: np.ndarray
    w_a: np.ndarray
    w_b: np.ndarray
    w_c: np.ndarray
    is_hydro: np.ndarray  # bool
    # hydro extras (full-length arrays; used where is_hydro)
    hy_t_lag: np.ndarray  # (r_t/R)·T_r
    hy_k_lead: np.ndarray  # T_r / t_lag
    hy_t_srv: np.ndarray
    hy_rate_mw_s: np.ndarray
    hy_t_w2: np.ndarray  # 0.5·T_w
    # PHS reservoir + pump mode (PARAMETERS §1.10; e_mwh 0 = unmodeled)
    hy_e_mwh: np.ndarray
    hy_eta_ch: np.ndarray
    hy_eta_dis: np.ndarray
    # commitment
    status: np.ndarray  # int8: OFFLINE/STARTING/ONLINE
    start_done_us: np.ndarray  # int64
    off_since_us: np.ndarray  # int64
    tripped_at_us: np.ndarray  # int64, -1 = never
    start_hot_s: np.ndarray
    start_warm_s: np.ndarray
    start_cold_s: np.ndarray
    warm_after_s: np.ndarray
    cold_after_s: np.ndarray
    trip_lockout_s: np.ndarray
    # meters
    eta_full: np.ndarray
    eta_min: np.ndarray
    energy_mwh: np.ndarray
    fuel_mwh_th: np.ndarray
    # states
    p_set: np.ndarray
    p_disp: np.ndarray
    x_g: np.ndarray
    x_1: np.ndarray
    x_2: np.ndarray
    hy_xc: np.ndarray
    hy_g: np.ndarray
    hy_xh: np.ndarray
    y: np.ndarray
    hy_soc_mwh: np.ndarray
    hy_pump_set: np.ndarray  # commanded pumping draw [MW, >= 0]
    hy_pump_p: np.ndarray  # actual pumping draw (slewed)
    pump_energy_mwh: np.ndarray

    # --- inverter plants (wind/PV) ---
    inv_ids: list[str]
    inv_island: np.ndarray
    inv_p_rated: np.ndarray
    inv_t_up: np.ndarray
    inv_t_down: np.ndarray
    inv_lfsm_from: np.ndarray
    inv_lfsm_gain: np.ndarray  # 1/(droop·f0) per unit of current P, per Hz
    inv_avail: np.ndarray  # availability TARGET [MW] (wire, sample-and-hold)
    inv_curtail: np.ndarray  # curtailment cap [MW]
    inv_p: np.ndarray
    inv_online: np.ndarray
    inv_energy_mwh: np.ndarray
    inv_aux_mw: np.ndarray  # no-load station service while energized (hubs)
    # weather does not STEP: the 15-min wire cadence is a sampling artifact,
    # so the effective availability slews toward the target at a physical
    # rate (default inf = instant, keeps every pre-slew pin). A GW-scale
    # avail step relayed out a small island twice (P6/P7 smoke hunts).
    inv_slew_mw_s: np.ndarray
    inv_avail_eff: np.ndarray

    # --- batteries ---
    bat_ids: list[str]
    bat_island: np.ndarray
    bat_p_max: np.ndarray
    bat_e_mwh: np.ndarray
    bat_k_f: np.ndarray  # MW/Hz
    bat_db: np.ndarray
    bat_t: np.ndarray
    bat_eta_ch: np.ndarray
    bat_eta_dis: np.ndarray
    bat_soc_min: np.ndarray  # MWh
    bat_soc_max: np.ndarray
    bat_soc_target: np.ndarray
    bat_recharge_p: np.ndarray
    bat_quiet_hz: np.ndarray
    bat_h_v: np.ndarray  # virtual inertia [s] (grid-forming), 0 = GFL
    bat_p_set: np.ndarray
    bat_p: np.ndarray  # signed, + = discharge
    bat_soc: np.ndarray  # MWh
    bat_online: np.ndarray
    bat_clamped: np.ndarray  # bool, energy/power clamp active last tick

    # --- electrolyzers ---
    ely_ids: list[str]
    ely_island: np.ndarray
    ely_p_max: np.ndarray
    ely_t: np.ndarray
    ely_db: np.ndarray
    ely_shed_full: np.ndarray
    ely_p_set: np.ndarray
    ely_p: np.ndarray  # consumption, positive
    ely_online: np.ndarray
    ely_energy_mwh: np.ndarray
    # H2 chain (attach_h2 wires these; PHYSICS §2.8) — defaulted fields last
    fuel_is_h2: np.ndarray = None
    h2_store_row: np.ndarray = None
    h2_starved: np.ndarray = None
    ely_store_row: np.ndarray = None
    h2: object = None  # H2Stores (attach_h2)
    hvdc: object = None  # HVDCLinks (attach_hvdc)
    notices: list = None  # (kind, device_id) engine notices, polled per tick
    # rows whose pending start is a BLACK START (bypasses the sick-island
    # hold; the integrator re-energizes a dead island on completion)
    black_start_rows: set = None

    _coeff_cache: dict[int, dict[str, np.ndarray]] = field(default_factory=dict, repr=False)

    # ------------------------------------------------------------------

    @property
    def n_sync(self) -> int:
        return len(self.ids)

    @property
    def online(self) -> np.ndarray:
        return self.status == ONLINE

    def invalidate_coeffs(self) -> None:
        self._coeff_cache.clear()

    def _coeffs(self, dt_us: int) -> dict[str, np.ndarray]:
        cached = self._coeff_cache.get(dt_us)
        if cached is None:
            dt = dt_us / US
            with np.errstate(divide="ignore"):
                cached = {
                    "a": np.exp(-dt / self.t_a),
                    "b": np.exp(-dt / self.t_b),
                    "c": np.exp(-dt / self.t_c),
                    "hl": np.exp(-dt / self.hy_t_lag),
                    "hs": np.exp(-dt / self.hy_t_srv),
                    "hw": np.exp(-dt / self.hy_t_w2),
                    "bt": np.exp(-dt / self.bat_t) if len(self.bat_ids) else np.zeros(0),
                    "et": np.exp(-dt / self.ely_t) if len(self.ely_ids) else np.zeros(0),
                    "iu": np.exp(-dt / self.inv_t_up) if len(self.inv_ids) else np.zeros(0),
                    "id": np.exp(-dt / self.inv_t_down) if len(self.inv_ids) else np.zeros(0),
                }
            if len(self._coeff_cache) > 64:
                self._coeff_cache.clear()
            self._coeff_cache[dt_us] = cached
        return cached

    # ------------------------------------------------------------------

    def e_k_per_island(self, n_islands: int) -> np.ndarray:
        """Kinetic constant [MJ]: online sync H·S_n + grid-forming H_v·P_max."""
        e = np.zeros(n_islands)
        mask = self.online
        np.add.at(e, self.island_of[mask], (self.h * self.s_n)[mask])
        if len(self.bat_ids):
            gfm = self.bat_online & (self.bat_h_v > 0)
            np.add.at(e, self.bat_island[gfm], (self.bat_h_v * self.bat_p_max)[gfm])
        return e

    def s_online_per_island(self, n_islands: int) -> np.ndarray:
        s = np.zeros(n_islands)
        mask = self.online
        np.add.at(s, self.island_of[mask], self.s_n[mask])
        if len(self.bat_ids):
            gfm = self.bat_online & (self.bat_h_v > 0)
            np.add.at(s, self.bat_island[gfm], self.bat_p_max[gfm])
        return s

    # ------------------------------------------------------------------

    def trip(self, device_id: str, t_us: int = 0) -> None:
        if device_id in self.ids:
            row = self.ids.index(device_id)
            self.status[row] = OFFLINE
            self.off_since_us[row] = t_us
            self.tripped_at_us[row] = t_us
            self.p_disp[row] = self.x_g[row] = self.x_1[row] = self.x_2[row] = 0.0
            self.hy_xc[row] = self.hy_g[row] = self.hy_xh[row] = 0.0
            self.p_set[row] = 0.0
            self.y[row] = 0.0
        elif device_id in self.inv_ids:
            row = self.inv_ids.index(device_id)
            self.inv_online[row] = False
            self.inv_p[row] = 0.0
        elif device_id in self.bat_ids:
            row = self.bat_ids.index(device_id)
            self.bat_online[row] = False
            self.bat_p[row] = 0.0
        elif device_id in self.ely_ids:
            row = self.ely_ids.index(device_id)
            self.ely_online[row] = False
            self.ely_p[row] = 0.0
        elif self.hvdc is not None and self.hvdc.has(device_id):
            self.hvdc.trip(device_id)
        else:
            raise KeyError(device_id)

    def command_start(self, device_id: str, t_us: int) -> float:
        """Begin a start sequence; returns the lead time [s]. Raises if locked out."""
        row = self.ids.index(device_id)
        if self.status[row] != OFFLINE:
            return 0.0
        if self.tripped_at_us[row] >= 0:
            lockout_us = int(self.trip_lockout_s[row] * US)
            if t_us - self.tripped_at_us[row] < lockout_us:
                raise RuntimeError(
                    f"{device_id}: start locked out for another "
                    f"{(lockout_us - (t_us - self.tripped_at_us[row])) / US:.0f} s (post-trip)"
                )
        off_s = (t_us - self.off_since_us[row]) / US
        if off_s < self.warm_after_s[row]:
            lead = self.start_hot_s[row]
        elif off_s < self.cold_after_s[row]:
            lead = self.start_warm_s[row]
        else:
            lead = self.start_cold_s[row]
        self.status[row] = STARTING
        self.start_done_us[row] = t_us + int(lead * US)
        return float(lead)

    def command_stop(self, device_id: str, t_us: int) -> None:
        row = self.ids.index(device_id)
        if self.status[row] == ONLINE:
            self.status[row] = OFFLINE
            self.off_since_us[row] = t_us
            self.p_disp[row] = self.x_g[row] = self.x_1[row] = self.x_2[row] = 0.0
            self.hy_xc[row] = self.hy_g[row] = self.hy_xh[row] = 0.0
            self.y[row] = 0.0

    def poll_commitment(self, t_us: int, f_island: np.ndarray | None = None,
                        blackout: np.ndarray | None = None) -> list[str]:
        """Complete due start sequences; sync at P_min. Returns completed ids.

        A unit cannot synchronize to a collapsed or dying island: while the
        island is blacked out or |f − f0| > 1 Hz the completion is HELD
        (re-checked every 30 s). Without this, dispatcher auto-restarts into
        a sagging island fed a death spiral that integrated f to −27 Hz
        (found by calm_week). Proper black-start restoration is P8."""
        done: list[str] = []
        rows = np.nonzero((self.status == STARTING) & (self.start_done_us <= t_us))[0]
        for row in rows:
            if f_island is not None \
                    and row not in (self.black_start_rows or ()):
                island = int(self.island_of[row])
                sick = abs(float(f_island[island]) - F0) > 1.0
                if blackout is not None:
                    sick = sick or bool(blackout[island])
                if sick:
                    self.start_done_us[row] = t_us + int(30.0 * US)
                    continue
            self.status[row] = ONLINE
            self.tripped_at_us[row] = -1
            p0 = self.p_min[row]
            self.p_disp[row] = p0
            self.x_g[row] = self.c_in[row] * p0
            self.x_1[row] = self.x_g[row]
            self.x_2[row] = self.c_2[row] * self.x_1[row]
            self.hy_xc[row] = self.hy_g[row] = self.hy_xh[row] = p0
            self.p_set[row] = max(self.p_set[row], p0)
            if self.black_start_rows:
                self.black_start_rows.discard(int(row))
            done.append(self.ids[row])
        return done

    def init_steady_state(self) -> None:
        self.p_disp[:] = self.p_set
        self.x_g[:] = self.c_in * self.p_set
        self.x_1[:] = self.x_g
        self.x_2[:] = self.c_2 * self.x_1
        self.hy_xc[:] = self.p_set
        self.hy_g[:] = self.p_set
        self.hy_xh[:] = self.p_set
        self.y[:] = np.where(self.online, self.p_set, 0.0)
        self.inv_avail_eff[:] = self.inv_avail
        self.inv_p[:] = np.minimum(self.inv_avail, self.inv_curtail)
        self.bat_p[:] = 0.0
        self.ely_p[:] = self.ely_p_set

    def attach_h2(self, stores, sync_store_ids: dict, ely_store_ids: dict) -> None:
        """Wire the H2 chain: `stores` is an H2Stores; the dicts map device
        id -> store id for H2-fired plants and electrolyzers."""
        self.h2 = stores
        self.fuel_is_h2 = np.zeros(self.n_sync, dtype=bool)
        self.h2_store_row = np.full(self.n_sync, -1, dtype=np.int64)
        self.h2_starved = np.zeros(self.n_sync, dtype=bool)
        self.ely_store_row = np.full(len(self.ely_ids), -1, dtype=np.int64)
        self.notices = []
        for pid, store_id in sync_store_ids.items():
            row = self.ids.index(pid)
            self.fuel_is_h2[row] = True
            self.h2_store_row[row] = stores.row(store_id)
        for pid, store_id in ely_store_ids.items():
            self.ely_store_row[self.ely_ids.index(pid)] = stores.row(store_id)

    def attach_hvdc(self, links) -> None:
        """Wire the HVDC block (HVDCLinks); its per-island injection joins
        p_inv each tick. H = 0 — never enters e_k."""
        self.hvdc = links
        if self.notices is None:
            self.notices = []

    # ------------------------------------------------------------------

    def tick(self, dt_us: int, f_island: np.ndarray, n_islands: int,
             rocof_island: np.ndarray | None = None):
        """One tick. Returns (p_mech, p_inv) per island; p_inv includes
        wind/PV + battery discharge − electrolyzer consumption."""
        dt_s = dt_us / US
        cf = self._coeffs(dt_us)
        online = self.online

        # --- synchronous governor pipeline -----------------------------
        df = f_island[self.island_of] - F0
        prim = np.clip(-self.k_droop * _soft_db(df, self.db), -self.fcr_band, self.fcr_band)
        self.fcr_used = np.zeros(n_islands)
        np.add.at(self.fcr_used, self.island_of[online], np.abs(prim[online]))
        self.p_disp += np.clip(self.p_set - self.p_disp,
                               -self.ramp_mw_s * dt_s, self.ramp_mw_s * dt_s)
        u = np.clip(self.p_disp + prim, self.p_min, self.p_max)
        u = np.where(online, u, 0.0)

        # PHS pump mode: a pumping unit spins as a motor (inertia stays in
        # the pool via ONLINE status) with the turbine path idle
        pumping = self.is_hydro & (np.maximum(self.hy_pump_set,
                                              self.hy_pump_p) > 0.0)
        if pumping.any():
            u = np.where(pumping, 0.0, u)
            self.hy_pump_p += np.clip(self.hy_pump_set - self.hy_pump_p,
                                      -self.ramp_mw_s * dt_s,
                                      self.ramp_mw_s * dt_s)
            self.hy_pump_p = np.where(online, self.hy_pump_p, 0.0)
            has_res = self.hy_e_mwh > 0.0
            ch_cap = np.where(
                has_res,
                (self.hy_e_mwh - self.hy_soc_mwh) / np.maximum(self.hy_eta_ch, 1e-9)
                * (3600.0 / max(dt_s, 1e-9)),
                np.inf)
            self.hy_pump_p = np.minimum(self.hy_pump_p, np.maximum(ch_cap, 0.0))

        # unified chain (steam / ccgt / ocgt)
        self.x_g += (1.0 - cf["a"]) * (self.c_in * u - self.x_g)
        self.x_1 += (1.0 - cf["b"]) * (self.x_g - self.x_1)
        self.x_2 += (1.0 - cf["c"]) * (self.c_2 * self.x_1 - self.x_2)
        y_chain = self.w_a * self.x_g + self.w_b * self.x_1 + self.w_c * self.x_2

        # hydro: lead-lag compensator -> rate-limited servo -> water column
        if self.is_hydro.any():
            self.hy_xc += (1.0 - cf["hl"]) * (u - self.hy_xc)
            v = self.hy_k_lead * u + (1.0 - self.hy_k_lead) * self.hy_xc
            g_tgt = v + (self.hy_g - v) * cf["hs"]
            self.hy_g += np.clip(g_tgt - self.hy_g,
                                 -self.hy_rate_mw_s * dt_s, self.hy_rate_mw_s * dt_s)
            self.hy_xh += (1.0 - cf["hw"]) * (self.hy_g - self.hy_xh)
            y_hydro = 3.0 * self.hy_xh - 2.0 * self.hy_g
        else:
            y_hydro = y_chain

        y = np.where(self.is_hydro, y_hydro, y_chain)
        y = np.where(online, y, 0.0)

        # PHS reservoir: pumped inflow, turbine outflow, hard energy bounds
        res_rows = self.is_hydro & (self.hy_e_mwh > 0.0)
        if res_rows.any():
            dis_cap = self.hy_soc_mwh * self.hy_eta_dis * (3600.0 / max(dt_s, 1e-9))
            y = np.where(res_rows, np.minimum(y, np.maximum(dis_cap, 0.0)), y)
            dt_h = dt_s / 3600.0
            self.hy_soc_mwh += np.where(
                res_rows,
                self.hy_pump_p * self.hy_eta_ch * dt_h
                - y / np.maximum(self.hy_eta_dis, 1e-9) * dt_h, 0.0)
            np.clip(self.hy_soc_mwh, 0.0, np.maximum(self.hy_e_mwh, 0.0),
                    out=self.hy_soc_mwh)
            self.pump_energy_mwh += self.hy_pump_p * dt_h

        # sync-side LFSM-O: continuous over-frequency curtailment (§2.7)
        over = np.maximum(df - (LFSM_O_FROM_HZ - F0), 0.0)
        if over.any():
            y = y * np.clip(1.0 - LFSM_O_GAIN_PER_HZ * over, 0.0, 1.0)

        # H2 fuel gating (PHYSICS §2.8): a store at its cushion floor derates
        # its plants to the withdrawal limit, then starves them. Deviation
        # (documented): starvation cuts at the physical withdrawal limit
        # rather than a cosmetic 10 s purge ramp.
        if self.h2 is not None and self.fuel_is_h2.any():
            rows = np.nonzero(self.fuel_is_h2)[0]
            span = np.maximum(self.p_max[rows] - self.p_min[rows], 1e-9)
            frac = np.clip((y[rows] - self.p_min[rows]) / span, 0.0, 1.0)
            eta = self.eta_min[rows] + (self.eta_full[rows] - self.eta_min[rows]) * frac
            # a STARVED plant draws nothing until recovery — otherwise it eats
            # every freshly injected kg and the level never clears the floor
            request = np.where(self.h2_starved[rows], 0.0, y[rows])
            allowed = self.h2.draw_for_plants(
                self.h2_store_row[rows], request, eta, dt_us / US)
            floor = self.h2.floor_kg()
            for i, row in enumerate(rows):
                store = self.h2_store_row[row]
                level = self.h2.level_kg[store]
                if allowed[i] < request[i] - 1e-6 and level <= floor[store] + 1e-6:
                    if not self.h2_starved[row]:
                        self.h2_starved[row] = True
                        self.notices.append(("fuel_starved", self.ids[row]))
                elif self.h2_starved[row] \
                        and level > 0.07 * self.h2.capacity_kg[store]:
                    self.h2_starved[row] = False
                    self.notices.append(("fuel_recovered", self.ids[row]))
            y[rows] = allowed
        self.y = y

        # meters: energy + fuel through the part-load efficiency line
        if dt_s > 0:
            e_step = y * (dt_s / 3600.0)
            self.energy_mwh += e_step
            span = np.maximum(self.p_max - self.p_min, 1e-9)
            frac = np.clip((y - self.p_min) / span, 0.0, 1.0)
            eta = self.eta_min + (self.eta_full - self.eta_min) * frac
            fueled = self.eta_full > 0
            self.fuel_mwh_th[fueled] += (e_step[fueled] / np.maximum(eta[fueled], 1e-9))

        p_mech = np.zeros(n_islands)
        np.add.at(p_mech, self.island_of, y - self.hy_pump_p)
        p_inv = np.zeros(n_islands)

        # --- inverter plants (wind/PV): lags + LFSM-O -------------------
        if len(self.inv_ids):
            slew = self.inv_slew_mw_s * dt_s
            self.inv_avail_eff += np.clip(self.inv_avail - self.inv_avail_eff,
                                          -slew, slew)
            target = np.minimum(self.inv_avail_eff, self.inv_curtail)
            df_i = f_island[self.inv_island] - F0
            over = np.maximum(df_i - (self.inv_lfsm_from - F0), 0.0)
            target = np.maximum(target - self.inv_p * over * self.inv_lfsm_gain, 0.0)
            a_i = np.where(target < self.inv_p, cf["id"], cf["iu"])
            self.inv_p += (1.0 - a_i) * (target - self.inv_p)
            self.inv_p = np.where(self.inv_online, self.inv_p, 0.0)
            self.inv_energy_mwh += self.inv_p * (dt_s / 3600.0)
            aux = np.where(self.inv_online, self.inv_aux_mw, 0.0)
            np.add.at(p_inv, self.inv_island, self.inv_p - aux)

        # --- batteries: FFR + SoC -------------------------------------
        if len(self.bat_ids):
            df_b = f_island[self.bat_island] - F0
            ffr = np.clip(-self.bat_k_f * _soft_db(df_b, self.bat_db),
                          -self.bat_p_max, self.bat_p_max)
            quiet = np.abs(df_b) <= self.bat_quiet_hz
            recharge = np.clip((self.bat_soc - self.bat_soc_target)
                               / np.maximum(self.bat_e_mwh, 1e-9) * 5.0 * self.bat_p_max,
                               -self.bat_recharge_p, self.bat_recharge_p)
            np.add.at(self.fcr_used, self.bat_island[self.bat_online],
                      np.abs(ffr[self.bat_online]))
            p_cmd = self.bat_p_set + ffr + np.where(quiet, recharge, 0.0)
            p_cmd = np.clip(p_cmd, -self.bat_p_max, self.bat_p_max)
            self.bat_p += (1.0 - cf["bt"]) * (p_cmd - self.bat_p)
            # energy-bound clamps over this tick
            dis_cap = np.maximum(self.bat_soc - self.bat_soc_min, 0.0) \
                * self.bat_eta_dis * (3600.0 / max(dt_s, 1e-9))
            ch_cap = np.maximum(self.bat_soc_max - self.bat_soc, 0.0) \
                / self.bat_eta_ch * (3600.0 / max(dt_s, 1e-9))
            clamped = (self.bat_p > dis_cap) | (self.bat_p < -ch_cap)
            self.bat_p = np.clip(self.bat_p, -ch_cap, dis_cap)
            self.bat_p = np.where(self.bat_online, self.bat_p, 0.0)
            self.bat_clamped = clamped & self.bat_online
            # SoC integration (+ grid-forming inertial energy debit)
            dis = np.maximum(self.bat_p, 0.0)
            ch = np.maximum(-self.bat_p, 0.0)
            self.bat_soc += (-dis / self.bat_eta_dis + ch * self.bat_eta_ch) * (dt_s / 3600.0)
            if rocof_island is not None:
                gfm = self.bat_h_v > 0
                if gfm.any():
                    p_inertial = (2.0 * self.bat_h_v * self.bat_p_max / F0) \
                        * rocof_island[self.bat_island]
                    self.bat_soc[gfm] += (p_inertial[gfm] * (dt_s / 3600.0))
            np.clip(self.bat_soc, 0.0, self.bat_e_mwh, out=self.bat_soc)
            np.add.at(p_inv, self.bat_island, self.bat_p)

        # --- electrolyzers: sheddable load ----------------------------
        if len(self.ely_ids):
            df_e = f_island[self.ely_island] - F0
            shed = np.clip((-df_e - self.ely_db)
                           / np.maximum(self.ely_shed_full - self.ely_db, 1e-9), 0.0, 1.0)
            p_cmd = self.ely_p_set * (1.0 - shed)
            self.ely_p += (1.0 - cf["et"]) * (p_cmd - self.ely_p)
            self.ely_p = np.where(self.ely_online, self.ely_p, 0.0)
            self.ely_energy_mwh += self.ely_p * (dt_s / 3600.0)
            np.add.at(p_inv, self.ely_island, -self.ely_p)
            if self.h2 is not None and self.ely_store_row is not None \
                    and (self.ely_store_row >= 0).any():
                aux = self.h2.inject_from_electrolyzers(
                    self.ely_store_row, self.ely_p, self.ely_p_max,
                    dt_s, n_islands)
                p_inv -= aux  # compressor consumes on the store's island

        # --- HVDC links: paired ±P, embedded links net ≈ −losses ------
        if self.hvdc is not None:
            p_inv += self.hvdc.tick(dt_us, n_islands)

        return p_mech, p_inv

    # ------------------------------------------------------------------

    def state_dict(self) -> dict:
        def rf(a):
            return [repr(float(v)) for v in a]

        return {
            "status": self.status.tolist(),
            "start_done_us": self.start_done_us.tolist(),
            "off_since_us": self.off_since_us.tolist(),
            "tripped_at_us": self.tripped_at_us.tolist(),
            "p_set": rf(self.p_set), "p_disp": rf(self.p_disp),
            "x_g": rf(self.x_g), "x_1": rf(self.x_1), "x_2": rf(self.x_2),
            "hy_xc": rf(self.hy_xc), "hy_g": rf(self.hy_g), "hy_xh": rf(self.hy_xh),
            "y": rf(self.y),
            "hy_soc_mwh": rf(self.hy_soc_mwh),
            "hy_pump_set": rf(self.hy_pump_set), "hy_pump_p": rf(self.hy_pump_p),
            "pump_energy_mwh": rf(self.pump_energy_mwh),
            "energy_mwh": rf(self.energy_mwh), "fuel_mwh_th": rf(self.fuel_mwh_th),
            "inv_online": self.inv_online.tolist(),
            "inv_avail": rf(self.inv_avail), "inv_avail_eff": rf(self.inv_avail_eff),
            "inv_curtail": rf(self.inv_curtail),
            "inv_p": rf(self.inv_p), "inv_energy_mwh": rf(self.inv_energy_mwh),
            "bat_online": self.bat_online.tolist(),
            "bat_p_set": rf(self.bat_p_set), "bat_p": rf(self.bat_p),
            "bat_soc": rf(self.bat_soc),
            "ely_online": self.ely_online.tolist(),
            "ely_p_set": rf(self.ely_p_set), "ely_p": rf(self.ely_p),
            "ely_energy_mwh": rf(self.ely_energy_mwh),
            "black_start_rows": sorted(self.black_start_rows or []),
        }

    def restore_state(self, state: dict) -> None:
        self.status[:] = np.array(state["status"], dtype=np.int8)
        self.start_done_us[:] = np.array(state["start_done_us"], dtype=np.int64)
        self.off_since_us[:] = np.array(state["off_since_us"], dtype=np.int64)
        self.tripped_at_us[:] = np.array(state["tripped_at_us"], dtype=np.int64)
        self.inv_online[:] = np.array(state["inv_online"], dtype=bool)
        self.bat_online[:] = np.array(state["bat_online"], dtype=bool)
        self.ely_online[:] = np.array(state["ely_online"], dtype=bool)
        for name in ("p_set", "p_disp", "x_g", "x_1", "x_2", "hy_xc", "hy_g",
                     "hy_xh", "y", "energy_mwh", "fuel_mwh_th", "inv_avail",
                     "inv_curtail", "inv_p", "inv_energy_mwh", "bat_p_set",
                     "bat_p", "bat_soc", "ely_p_set", "ely_p", "ely_energy_mwh"):
            getattr(self, name)[:] = np.array([float(v) for v in state[name]])
        # pre-slew snapshots lack the field: converged fallback
        self.inv_avail_eff[:] = np.array(
            [float(v) for v in state.get("inv_avail_eff", state["inv_avail"])])
        self.black_start_rows = set(state.get("black_start_rows", []))
        for name in ("hy_soc_mwh", "hy_pump_set", "hy_pump_p", "pump_energy_mwh"):
            if name in state:
                getattr(self, name)[:] = np.array(
                    [float(v) for v in state[name]])


def make_fleet(
    sync: list[dict],
    inverters: list[dict] | None = None,
    batteries: list[dict] | None = None,
    electrolyzers: list[dict] | None = None,
    defaults: SyncParams | None = None,
) -> Fleet:
    """Build a fleet from device spec dicts.

    sync: {id, island, s_n, p_max, p_set, [model: steam|ccgt|ocgt|hydro,
      p_min, h, r, db, fcr_band, ramp_mw_s, t_g/t_ch/t_rh/f_hp (steam-style,
      also the generic default), t_fuel/t_gt/t_st (ccgt/ocgt),
      t_r/r_t/t_servo/gate_rate_pu_s/t_w (hydro), start_hot_s/…,
      eta_full/eta_min, offline: bool]}
    inverters: {id, island, p_rated, [avail, curtail, t_up, t_down,
      lfsm_from, lfsm_droop, aux_mw, avail_slew_mw_s]}
    batteries: {id, island, p_max, e_mwh, [soc_frac, p_set, k_f, db, t_b,
      eta_ch, eta_dis, soc_min/max/target_frac, recharge_frac, quiet_hz, h_v]}
    electrolyzers: {id, island, p_max, [p_set, t_e, db, shed_full_hz]}
    """
    d = defaults or SyncParams()
    inverters = inverters or []
    batteries = batteries or []
    electrolyzers = electrolyzers or []
    n = len(sync)

    def col(key, fallback):
        return np.array([float(s.get(key, fallback(s))) for s in sync]) if n else np.zeros(0)

    models = [s.get("model", "steam") for s in sync]
    t_a = np.zeros(n)
    t_b = np.zeros(n)
    t_c = np.zeros(n)
    c_in = np.ones(n)
    c_2 = np.ones(n)
    w_a = np.zeros(n)
    w_b = np.zeros(n)
    w_c = np.zeros(n)
    is_hydro = np.zeros(n, dtype=bool)
    hy_t_lag = np.full(n, 1.0)
    hy_k_lead = np.zeros(n)
    hy_t_srv = np.full(n, 1.0)
    hy_rate = np.full(n, np.inf)
    hy_t_w2 = np.full(n, 1.0)

    for i, spec in enumerate(sync):
        model = models[i]
        if model == "steam":
            t_a[i] = spec.get("t_g", d.t_g)
            t_b[i] = spec.get("t_ch", d.t_ch)
            t_c[i] = spec.get("t_rh", d.t_rh)
            f_hp = spec.get("f_hp", d.f_hp)
            w_b[i], w_c[i] = f_hp, 1.0 - f_hp
        elif model == "ccgt":
            t_a[i] = spec.get("t_fuel", 0.4)
            t_b[i] = spec.get("t_gt", 1.0)
            t_c[i] = spec.get("t_st", 120.0)
            c_in[i], c_2[i] = 2.0 / 3.0, 0.5
            w_b[i] = w_c[i] = 1.0
        elif model == "ocgt":
            t_a[i] = spec.get("t_fuel", 0.3)
            t_b[i] = spec.get("t_gt", 0.8)
            t_c[i] = 1e9  # unused stage, weight 0
            w_b[i] = 1.0
        elif model == "hydro":
            is_hydro[i] = True
            t_a[i] = t_b[i] = t_c[i] = 1e9  # chain unused
            t_r = spec.get("t_r", 6.0)
            r_t = spec.get("r_t", 0.4)
            r_pu = spec.get("r", 0.04)
            hy_t_lag[i] = (r_t / r_pu) * t_r
            hy_k_lead[i] = t_r / hy_t_lag[i]
            hy_t_srv[i] = spec.get("t_servo", 0.5)
            p_max_i = float(spec.get("p_max", spec["s_n"] * 0.9))
            hy_rate[i] = spec.get("gate_rate_pu_s", 0.1) * p_max_i
            hy_t_w2[i] = 0.5 * spec.get("t_w", 1.5)
        else:
            raise ValueError(f"unknown sync model {model!r}")

    status = np.array(
        [OFFLINE if s.get("offline") else ONLINE for s in sync], dtype=np.int8
    ) if n else np.zeros(0, dtype=np.int8)

    fleet = Fleet(
        ids=[s["id"] for s in sync],
        island_of=np.array([int(s.get("island", 0)) for s in sync], dtype=np.int64)
        if n else np.zeros(0, dtype=np.int64),
        s_n=col("s_n", lambda s: 0.0),
        p_max=col("p_max", lambda s: s["s_n"] * 0.9),
        p_min=col("p_min", lambda s: 0.0),
        h=col("h", lambda s: d.h_s),
        k_droop=np.array([float(s["s_n"]) / (float(s.get("r", d.r_pu)) * F0) for s in sync])
        if n else np.zeros(0),
        db=col("db", lambda s: d.db_hz),
        fcr_band=np.array(
            [float(s.get("fcr_band", d.fcr_band_frac * float(s["s_n"]))) for s in sync]
        ) if n else np.zeros(0),
        ramp_mw_s=np.array(
            [float(s.get("ramp_mw_s",
                         d.ramp_frac_per_min / 100.0
                         * float(s.get("p_max", s["s_n"] * 0.9)) / 60.0))
             for s in sync]
        ) if n else np.zeros(0),
        t_a=t_a, t_b=t_b, t_c=t_c, c_in=c_in, c_2=c_2,
        w_a=w_a, w_b=w_b, w_c=w_c, is_hydro=is_hydro,
        hy_t_lag=hy_t_lag, hy_k_lead=hy_k_lead, hy_t_srv=hy_t_srv,
        hy_rate_mw_s=hy_rate, hy_t_w2=hy_t_w2,
        hy_e_mwh=col("e_mwh", lambda s: 0.0),
        hy_eta_ch=col("eta_pump", lambda s: 0.88),
        hy_eta_dis=col("eta_turbine", lambda s: 0.90),
        status=status,
        start_done_us=np.zeros(n, dtype=np.int64),
        off_since_us=np.zeros(n, dtype=np.int64),
        tripped_at_us=np.full(n, -1, dtype=np.int64),
        start_hot_s=col("start_hot_s", lambda s: 900.0),
        start_warm_s=col("start_warm_s", lambda s: s.get("start_hot_s", 900.0)),
        start_cold_s=col("start_cold_s", lambda s: s.get("start_hot_s", 900.0)),
        warm_after_s=col("warm_after_s", lambda s: 28800.0),
        cold_after_s=col("cold_after_s", lambda s: 172800.0),
        trip_lockout_s=col("trip_lockout_s", lambda s: 0.0),
        eta_full=col("eta_full", lambda s: 0.0),
        eta_min=col("eta_min", lambda s: s.get("eta_full", 0.0)),
        energy_mwh=np.zeros(n),
        fuel_mwh_th=np.zeros(n),
        p_set=col("p_set", lambda s: 0.0),
        p_disp=np.zeros(n), x_g=np.zeros(n), x_1=np.zeros(n), x_2=np.zeros(n),
        hy_xc=np.zeros(n), hy_g=np.zeros(n), hy_xh=np.zeros(n), y=np.zeros(n),
        hy_soc_mwh=np.array([float(s.get("soc_frac", 0.5))
                             * float(s.get("e_mwh", 0.0)) for s in sync])
        if n else np.zeros(0),
        hy_pump_set=np.zeros(n), hy_pump_p=np.zeros(n),
        pump_energy_mwh=np.zeros(n),
        inv_ids=[i["id"] for i in inverters],
        inv_island=np.array([int(i.get("island", 0)) for i in inverters], dtype=np.int64),
        inv_p_rated=np.array([float(i.get("p_rated", i.get("p_target", 0.0))) for i in inverters]),
        inv_t_up=np.array([float(i.get("t_up", 2.0)) for i in inverters]),
        inv_t_down=np.array([float(i.get("t_down", 0.2)) for i in inverters]),
        inv_lfsm_from=np.array([float(i.get("lfsm_from", 50.2)) for i in inverters]),
        inv_lfsm_gain=np.array(
            [1.0 / (float(i.get("lfsm_droop", 0.05)) * F0) for i in inverters]
        ),
        inv_avail=np.array([float(i.get("avail", i.get("p_target", 0.0))) for i in inverters]),
        inv_curtail=np.array([float(i.get("curtail", np.inf)) for i in inverters]),
        inv_p=np.zeros(len(inverters)),
        inv_online=np.ones(len(inverters), dtype=bool),
        inv_energy_mwh=np.zeros(len(inverters)),
        inv_aux_mw=np.array([float(i.get("aux_mw", 0.0)) for i in inverters]),
        inv_slew_mw_s=np.array([float(i.get("avail_slew_mw_s", np.inf))
                                for i in inverters]),
        inv_avail_eff=np.array([float(i.get("avail", i.get("p_target", 0.0)))
                                for i in inverters]),
        bat_ids=[b["id"] for b in batteries],
        bat_island=np.array([int(b.get("island", 0)) for b in batteries], dtype=np.int64),
        bat_p_max=np.array([float(b["p_max"]) for b in batteries]),
        bat_e_mwh=np.array([float(b["e_mwh"]) for b in batteries]),
        bat_k_f=np.array(
            [float(b.get("k_f", float(b["p_max"]) / float(b.get("ffr_full_hz", 0.2))))
             for b in batteries]
        ),
        bat_db=np.array([float(b.get("db", 0.010)) for b in batteries]),
        bat_t=np.array([float(b.get("t_b", 0.1)) for b in batteries]),
        bat_eta_ch=np.array([float(b.get("eta_ch", 0.94)) for b in batteries]),
        bat_eta_dis=np.array([float(b.get("eta_dis", 0.94)) for b in batteries]),
        bat_soc_min=np.array(
            [float(b.get("soc_min_frac", 0.05)) * float(b["e_mwh"]) for b in batteries]
        ),
        bat_soc_max=np.array(
            [float(b.get("soc_max_frac", 0.95)) * float(b["e_mwh"]) for b in batteries]
        ),
        bat_soc_target=np.array(
            [float(b.get("soc_target_frac", 0.55)) * float(b["e_mwh"]) for b in batteries]
        ),
        bat_recharge_p=np.array(
            [float(b.get("recharge_frac", 0.1)) * float(b["p_max"]) for b in batteries]
        ),
        bat_quiet_hz=np.array([float(b.get("quiet_hz", 0.05)) for b in batteries]),
        bat_h_v=np.array([float(b.get("h_v", 0.0)) for b in batteries]),
        bat_p_set=np.array([float(b.get("p_set", 0.0)) for b in batteries]),
        bat_p=np.zeros(len(batteries)),
        bat_soc=np.array(
            [float(b.get("soc_frac", 0.55)) * float(b["e_mwh"]) for b in batteries]
        ),
        bat_online=np.ones(len(batteries), dtype=bool),
        bat_clamped=np.zeros(len(batteries), dtype=bool),
        ely_ids=[e["id"] for e in electrolyzers],
        ely_island=np.array([int(e.get("island", 0)) for e in electrolyzers], dtype=np.int64),
        ely_p_max=np.array([float(e["p_max"]) for e in electrolyzers]),
        ely_t=np.array([float(e.get("t_e", 0.3)) for e in electrolyzers]),
        ely_db=np.array([float(e.get("db", 0.010)) for e in electrolyzers]),
        ely_shed_full=np.array([float(e.get("shed_full_hz", 0.2)) for e in electrolyzers]),
        ely_p_set=np.array([float(e.get("p_set", 0.0)) for e in electrolyzers]),
        ely_p=np.zeros(len(electrolyzers)),
        ely_online=np.ones(len(electrolyzers), dtype=bool),
        ely_energy_mwh=np.zeros(len(electrolyzers)),
    )
    return fleet
