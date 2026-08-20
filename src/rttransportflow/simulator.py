"""Simulation core.

`PFSimulator` (P1): apply profile columns -> retry-ladder AC solve ->
collect, one StepResult per step. Non-convergence is DATA (a degraded
frame), never an exception out of `run_step` — one poisoned step must not
kill the loop, and the next step self-heals from a cold start.

StepResult is the single wire format (family §6 pattern) — REST /state,
/history, the WS stream, and the recorder all serve projections of it.
`NullSimulator` remains for scaffold tests.
"""

from __future__ import annotations

import time
from typing import Any

from .dynamics import SNAP_MARK_US
from .simulator_commands import CommandsMixin
from .simulator_report import ReportingMixin
from .simulator_topology import (
    DUTY_ARM_PCT,
    DUTY_CLEAR_PCT,
    DUTY_DECAY_PCT_S,
    DUTY_TRIP_PCT_S,
    OVERLOAD_INSTANT_PCT,
    RESYNC_MAX_DF_HZ,
    TopologyMixin,
)
from .wire import StepResult, _as_int, _r, failed_step_result, time_of_day
from .wire_devices import WireDeviceError, _parse_wire_devices

# state_blob format version (v2: engine + line states + duty). The reset
# guard in gamebridge imports THIS — the P8 v1→v2 bump had to edit two files
# in lockstep, and a mismatch silently downgrades every restore to
# refused_snapshot (which smokes read as a cold start, not an error).
SIM_SNAPSHOT_VERSION = 2


def pf_solver_tiers(warm_start: bool, last_converged: bool) -> list[dict[str, Any]]:
    """The ONE retry ladder: warm NR -> cold NR -> iwamoto (it had already
    drifted once between its two copies)."""
    tiers: list[dict[str, Any]] = []
    if warm_start and last_converged:
        tiers.append({"init": "results"})
    tiers.append({"init": "dc"})
    tiers.append({"algorithm": "iwamoto_nr", "init": "dc", "max_iteration": 30})
    return tiers


def run_pf_ladder(net, tiers: list[dict[str, Any]]) -> Exception | None:
    """None on success; the failure exception otherwise (the caller decides
    whether that raises — PFSimulator — or degrades — DynSimulator)."""
    import pandapower as pp

    last_exc: Exception | None = None
    for tier in tiers:
        try:
            pp.runpp(net, enforce_q_lims=True, **tier)
            return None
        except Exception as exc:  # noqa: BLE001 — every tier may fail
            last_exc = exc
    return last_exc if last_exc is not None else RuntimeError("no solver tier ran")


class NullSimulator:
    """Placeholder solver: instant, always converged, deterministic."""

    def __init__(self, steps_per_day: int) -> None:
        self.steps_per_day = steps_per_day

    def run_step(self, step: int, day: int) -> StepResult:
        t0 = time.perf_counter()
        return StepResult(
            step=step,
            day=day,
            time_of_day=time_of_day(step, self.steps_per_day),
            converged=True,
            solve_ms=(time.perf_counter() - t0) * 1e3,
            timestamp=time.time(),
            summary={"simulator": "null"},
        )


class PFSimulator:
    """Time-series AC power flow over a build-once pandapower net."""

    def __init__(self, built, steps_per_day: int, warm_start: bool = True) -> None:
        self.built = built
        self.steps_per_day = steps_per_day
        self.warm_start = warm_start
        self._last_converged = False

    # -- per-step body ---------------------------------------------------

    def _apply_step(self, step: int) -> None:
        b = self.built
        net = b.net
        if b.load_idx:
            net.load.loc[b.load_idx, "p_mw"] = b.load_p[:, step]
            net.load.loc[b.load_idx, "q_mvar"] = b.load_q[:, step]
        if b.gen_idx:
            net.gen.loc[b.gen_idx, "p_mw"] = b.gen_p[:, step]
        if b.sgen_idx:
            net.sgen.loc[b.sgen_idx, "p_mw"] = b.sgen_p[:, step]
            net.sgen.loc[b.sgen_idx, "q_mvar"] = b.sgen_q[:, step]

    def _solve(self) -> None:
        """Retry ladder (shared): raises on total failure."""
        exc = run_pf_ladder(self.built.net,
                            pf_solver_tiers(self.warm_start, self._last_converged))
        if exc is not None:
            raise exc

    def _collect(self, step: int, day: int, solve_ms: float) -> StepResult:
        b = self.built
        net = b.net

        buses = {
            name: {
                "vm_pu": float(net.res_bus.vm_pu.at[idx]),
                "va_degree": float(net.res_bus.va_degree.at[idx]),
            }
            for name, idx in b.bus_index.items()
        }
        lines = {
            line_id: {
                "loading_percent": float(net.res_line.loading_percent.at[idx]),
                "p_from_mw": float(net.res_line.p_from_mw.at[idx]),
                "pl_mw": float(net.res_line.pl_mw.at[idx]),
            }
            for line_id, idx in zip(b.line_ids, b.line_idx)
        }

        load_mw = float(net.res_load.p_mw.sum())
        gen_mw = float(net.res_gen.p_mw.sum()) if len(net.gen) else 0.0
        sgen_mw = float(net.res_sgen.p_mw.sum()) if len(net.sgen) else 0.0
        slack_mw = float(net.res_ext_grid.p_mw.sum())
        loss_mw = float(net.res_line.pl_mw.sum())

        summary = {
            "load_mw": load_mw,
            "gen_mw": gen_mw,
            "sgen_mw": sgen_mw,
            "slack_mw": slack_mw,
            "loss_mw": loss_mw,
            "balance_err_mw": gen_mw + sgen_mw + slack_mw - load_mw - loss_mw,
            "max_loading_pct": float(net.res_line.loading_percent.max()),
            "min_vm_pu": float(net.res_bus.vm_pu.min()),
            "max_vm_pu": float(net.res_bus.vm_pu.max()),
        }
        return StepResult(
            step=step,
            day=day,
            time_of_day=time_of_day(step, self.steps_per_day),
            converged=True,
            solve_ms=solve_ms,
            timestamp=time.time(),
            summary=summary,
            buses=buses,
            lines=lines,
        )

    def run_step(self, step: int, day: int) -> StepResult:
        t0 = time.perf_counter()
        try:
            self._apply_step(step)
            self._solve()
        except Exception as exc:  # noqa: BLE001 — divergence is data, never a crash
            self._last_converged = False  # cold-start the next step
            return failed_step_result(step, day, self.steps_per_day, t0, exc)
        self._last_converged = True
        return self._collect(step, day, (time.perf_counter() - t0) * 1e3)

    def warmup(self) -> float:
        """One throwaway solve so numba JIT never lands on a live step."""
        t0 = time.perf_counter()
        self.run_step(0, 0)
        self._last_converged = False  # the warmup is not part of the run
        return (time.perf_counter() - t0) * 1e3


def build_pf_simulator(data_dir: str, steps_per_day: int, warm_start: bool = True,
                       data=None) -> PFSimulator:
    from .data_loader import load_bundle
    from .network_builder import build_network

    data = data if data is not None else load_bundle(data_dir)
    if data.scenario.steps_per_day != steps_per_day:
        raise ValueError(
            f"scenario steps_per_day ({data.scenario.steps_per_day}) != configured ({steps_per_day})"
        )
    return PFSimulator(build_network(data), steps_per_day=steps_per_day, warm_start=warm_start)


class DynSimulator(TopologyMixin, CommandsMixin, ReportingMixin):
    """Couples the frequency-dynamics integrator with the AC power flow.

    Standalone mode: `run_step(step, day)` sets the step's boundary
    conditions (dispatch targets, converter availability, zone demand) and
    integrates one step-interval of real dynamics (PHYSICS §2.5 ledger
    coupling); the PF hook refreshes losses/flows at the mode cadence.
    P4's gamebridge drives `integrator.advance()` with variable dt directly.
    """

    def __init__(self, data, built, *, steps_per_day: int, d_load_pct_per_hz: float = 1.0,
                 warm_start: bool = True,
                 catalog_path: str = "data/catalogs/plant_types.json",
                 wire_devices: list[dict] | None = None,
                 protection_seed: int = 0,
                 mode_cfg=None) -> None:
        import numpy as np

        from .dynamics import F0
        from .dynamics.fleet import make_fleet
        from .dynamics.integrator import Integrator, IslandState
        from .dynamics.plant_types import inverter_spec, load_catalog, sync_spec
        from .dynamics.protection import FWindowConfig
        from .models import CONVERTER_KINDS, SYNC_KINDS

        self.built = built
        self.data = data
        self.steps_per_day = steps_per_day
        self.step_seconds = 24 * 3600 / steps_per_day
        self.warm_start = warm_start
        self._last_converged = False
        self._np = np
        self._f0 = F0

        catalog_doc = load_catalog(catalog_path)
        catalog = catalog_doc["kinds"]
        # the catalog's frequency_protection block is the trip-window
        # authority (it used to be dead data shadowed by FWindowConfig's
        # identical defaults — a knob wired to nothing)
        fp = catalog_doc.get("frequency_protection")
        fwindow = FWindowConfig(
            low_hz=float(fp["sync_trip_low_hz"]),
            high_hz=float(fp["sync_trip_high_hz"]),
            delay_us=int(round(float(fp["sync_trip_delay_s"]) * 1e6)),
        ) if fp is not None else None
        sync_specs, inv_specs = [], []
        for plant in data.plants.plants:
            params = catalog[plant.kind]
            if plant.kind in SYNC_KINDS:
                # Envelope p_min comes from the SCENARIO (device-level); the
                # catalog p_min_pct informs the dispatcher (P6), not the clamp.
                sync_specs.append(sync_spec(
                    plant.kind, params, device_id=plant.id, island=0,
                    p_max_mw=plant.p_max_mw, p_min_mw=plant.p_min_mw,
                    p_set_mw=plant.profile_p_mw[0],
                ))
            elif plant.kind in CONVERTER_KINDS:
                inv_specs.append(inverter_spec(
                    plant.kind, params, device_id=plant.id, island=0,
                    p_rated_mw=plant.p_max_mw, avail_mw=plant.profile_p_mw[0],
                ))

        wire = _parse_wire_devices(wire_devices or [], catalog, built.bus_index)
        self._n_native_inv = len(inv_specs)
        hub_specs = wire["hubs"]
        self.fleet = make_fleet(sync_specs, inv_specs + hub_specs,
                                wire["bat"], wire["ely"])

        # H2 chain: named stores + converted plants (native `fuel: h2`) +
        # electrolyzers. Dangling references are reset-time 400s, never NaNs.
        sync_store_ids = {}
        for plant in data.plants.plants:
            if plant.fuel == "h2":
                if not plant.h2_store_id:
                    raise WireDeviceError(f"{plant.id}: fuel h2 needs h2_store_id")
                sync_store_ids[plant.id] = plant.h2_store_id
        if wire["stores"] or sync_store_ids or wire["ely_store"]:
            from .dynamics.hydrogen import make_stores
            stores = make_stores(wire["stores"])
            for ref_map in (sync_store_ids, wire["ely_store"]):
                for device_id, store_id in ref_map.items():
                    if store_id not in stores.ids:
                        raise WireDeviceError(
                            f"{device_id}: unknown h2_store {store_id!r}")
            self.fleet.attach_h2(stores, sync_store_ids, wire["ely_store"])

        if wire["pairs"]:
            from .dynamics.hvdc import make_links
            self.fleet.attach_hvdc(make_links(wire["pairs"]))

        # wire-device row maps + hub loss model (PARAMETERS §1.16).
        # sync/inv/bat/ely maps are FLEET-owned (one copy, shared object)
        self._bat_row = self.fleet.bat_row
        self._ely_row = self.fleet.ely_row
        self._store_row = ({sid: i for i, sid in enumerate(self.fleet.h2.ids)}
                           if self.fleet.h2 is not None else {})
        self._term_row = ({tid: i for i, tid in enumerate(self.fleet.hvdc.term_ids)}
                          if self.fleet.hvdc is not None else {})
        self._hub_row: dict[str, int] = {}
        self._hub_loss: dict[str, float] = {}
        self._hub_p_max: dict[str, float] = {}
        for i, hub in enumerate(hub_specs):
            self._hub_row[hub["id"]] = self._n_native_inv + i
            self._hub_loss[hub["id"]] = float(hub["loss_frac"])
            self._hub_p_max[hub["id"]] = float(hub["p_max"])
        self._hub_q = np.zeros(len(hub_specs))

        # PF elements for the wire devices (appended to the built net; the
        # native gen/sgen/load rows keep their builder-order alignment)
        self._bat_sgen_idx: list[int] = []
        self._ely_load_idx: list[int] = []
        self._hub_sgen_idx: list[int] = []
        self._term_sgen_idx: list[int] = []
        if wire["bat"] or wire["ely"] or hub_specs or wire["pairs"]:
            import pandapower as pp
            bus_of = built.bus_index
            for spec in wire["bat"]:
                self._bat_sgen_idx.append(int(pp.create_sgen(
                    built.net, bus_of[wire["nodes"][spec["id"]]],
                    p_mw=0.0, q_mvar=0.0, name=spec["id"])))
            for spec in wire["ely"]:
                self._ely_load_idx.append(int(pp.create_load(
                    built.net, bus_of[wire["nodes"][spec["id"]]],
                    p_mw=0.0, q_mvar=0.0, name=spec["id"])))
            for hub in hub_specs:
                self._hub_sgen_idx.append(int(pp.create_sgen(
                    built.net, bus_of[wire["nodes"][hub["id"]]],
                    p_mw=0.0, q_mvar=0.0, name=hub["id"])))
            if self.fleet.hvdc is not None:
                for tid in self.fleet.hvdc.term_ids:
                    self._term_sgen_idx.append(int(pp.create_sgen(
                        built.net, bus_of[wire["nodes"][tid]],
                        p_mw=0.0, q_mvar=0.0, name=tid)))

        d_pu = d_load_pct_per_hz * F0 / 100.0
        islands = IslandState(
            f=np.array([F0]),
            e_k=np.zeros(1),
            p_l0=np.array([float(built.load_p[:, 0].sum())]),
            w=np.ones(1),
            p_loss=np.zeros(1),
            d_pu=d_pu,
        )
        self.integrator = Integrator(self.fleet, islands, cfg=mode_cfg,
                                     pf_hook=self._run_pf,
                                     protection_seed=protection_seed,
                                     fwindow=fwindow)
        self.integrator.topology_hook = self._on_line_event

        self._load_p_col = built.load_p[:, 0].copy()
        self._load_q_col = built.load_q[:, 0].copy()

        # --- topology layer (P8): bus graph, island mapping, overload duty
        net = built.net
        self._line_in_service = {lid: True for lid in built.line_ids}
        self._line_pp_idx = dict(zip(built.line_ids, built.line_idx))
        self._line_duty: dict[str, float] = {}
        self._trip_scheduled: set[str] = set()
        self._last_pf_t_us = 0
        self._gen_bus = [int(net.gen.bus.at[i]) for i in built.gen_idx]
        self._nsgen_bus = [int(net.sgen.bus.at[i]) for i in built.sgen_idx]
        self._load_bus = [int(net.load.bus.at[i]) for i in built.load_idx]
        self._bat_bus = [int(net.sgen.bus.at[i]) for i in self._bat_sgen_idx]
        self._ely_bus = [int(net.load.bus.at[i]) for i in self._ely_load_idx]
        self._hub_bus = [int(net.sgen.bus.at[i]) for i in self._hub_sgen_idx]
        self._term_bus = [int(net.sgen.bus.at[i]) for i in self._term_sgen_idx]
        self._bus_island: dict[int, int] = {int(b): 0 for b in net.bus.index}
        self._latest_pf: dict[str, Any] = {}
        self._pf_ok = False
        self._pf_fail_count = 0
        self._pf_count = 0
        self._pf_window_max: dict[str, float] = {}
        self._initialized = False

        # wire lookup maps (gamebridge boundary application)
        self._zone_rows: dict[str, list[int]] = {}
        for row, item in enumerate(data.load_centers.items):
            self._zone_rows.setdefault(item.zone, []).append(row)
        self._zone_bus = {z.id: z.bus for z in data.grid.zones}
        self._sync_row = self.fleet.sync_row
        self._inv_row = self.fleet.inv_row

    # -- PF hook (called by the integrator at mode cadence + on events) ---

    def _run_pf(self, reason: str) -> None:
        # A fully blacked-out system has no PF to solve (PHYSICS §2.5: no
        # slack candidate => skip). Without this, a dead grid burned ~30 ms
        # of futile retry-ladder per scheduled solve — 27 s per 900 s step.
        if bool(self._np.all(self.integrator.islands.blackout())):
            self._pf_ok = False
            self._pf_fail_count += 1
            return

        b = self.built
        net = b.net
        np = self._np

        island = self.integrator.islands
        row_island = self._np.array(
            [self._bus_island[bus] for bus in self._load_bus], dtype=self._np.int64)             if self._load_bus else self._np.zeros(0, dtype=self._np.int64)
        factors = island.w * (1.0 + island.d_pu * (island.f - self._f0) / self._f0)
        row_factor = factors[row_island] if len(row_island) else factors[:0]
        if b.load_idx:
            net.load.loc[b.load_idx, "p_mw"] = self._load_p_col * row_factor
            net.load.loc[b.load_idx, "q_mvar"] = self._load_q_col * row_factor
        if b.gen_idx:
            net.gen.loc[b.gen_idx, "p_mw"] = self.fleet.y - self.fleet.hy_pump_p
        if b.sgen_idx:
            native = self.fleet.inv_p[:self._n_native_inv]
            net.sgen.loc[b.sgen_idx, "p_mw"] = native
            net.sgen.loc[b.sgen_idx, "q_mvar"] = native * 0.25
        if self._bat_sgen_idx:
            net.sgen.loc[self._bat_sgen_idx, "p_mw"] = self.fleet.bat_p
        if self._ely_load_idx:
            net.load.loc[self._ely_load_idx, "p_mw"] = self.fleet.ely_p
        if self._hub_sgen_idx:
            net.sgen.loc[self._hub_sgen_idx, "p_mw"] = \
                self.fleet.inv_p[self._n_native_inv:]
            net.sgen.loc[self._hub_sgen_idx, "q_mvar"] = self._hub_q
        if self._term_sgen_idx:
            net.sgen.loc[self._term_sgen_idx, "p_mw"] = self.fleet.hvdc.term_p()
            net.sgen.loc[self._term_sgen_idx, "q_mvar"] = self.fleet.hvdc.term_q

        if run_pf_ladder(net, pf_solver_tiers(self.warm_start,
                                              self._last_converged)) is not None:
            self._last_converged = False
            self._pf_ok = False
            self._pf_fail_count += 1
            return  # sample-and-hold: keep previous p_loss and flows

        self._last_converged = True
        self._pf_ok = True
        self._pf_count += 1
        dt_pf = max((self.integrator.t_us - self._last_pf_t_us) / 1e6, 0.0)
        self._last_pf_t_us = self.integrator.t_us
        self._line_protection_scan(net, b, dt_pf, reason)
        # per-island losses: attribute each in-service line to its from-bus island
        loss = self._np.zeros(island.n)
        for line_id, idx in zip(b.line_ids, b.line_idx):
            if not self._line_in_service[line_id]:
                continue
            pl = float(net.res_line.pl_mw.at[idx])
            if self._np.isfinite(pl):
                loss[self._bus_island[int(net.line.from_bus.at[idx])]] += pl
        island.p_loss = loss
        self._latest_pf = {
            "buses": {
                name: {"vm_pu": float(net.res_bus.vm_pu.at[idx]),
                       "va_degree": float(net.res_bus.va_degree.at[idx])}
                for name, idx in b.bus_index.items()
            },
            "lines": {
                line_id: {"loading_percent": float(net.res_line.loading_percent.at[idx]),
                          "p_from_mw": float(net.res_line.p_from_mw.at[idx]),
                          "pl_mw": float(net.res_line.pl_mw.at[idx]),
                          "in_service": True}
                for line_id, idx in zip(b.line_ids, b.line_idx)
                if self._line_in_service[line_id]
            },
            "slack_mw": float(net.res_ext_grid.p_mw.fillna(0.0).sum()),
            "loss_mw": float(loss.sum()),
            "max_loading_pct": float(self._np.nanmax(
                net.res_line.loading_percent.values)) if len(net.res_line) else 0.0,
            "min_vm_pu": float(net.res_bus.vm_pu.min()),
            "max_vm_pu": float(net.res_bus.vm_pu.max()),
        }

    # -- standalone step ---------------------------------------------------

    def _set_boundary(self, step: int) -> None:
        # Fleet rows and builder gen/sgen rows both follow plants.json order,
        # so the profile arrays align by row.
        b = self.built
        self.fleet.p_set[:] = b.gen_p[:, step]
        self.fleet.inv_avail[:self._n_native_inv] = b.sgen_p[:, step]
        self._load_p_col = b.load_p[:, step].copy()
        self._load_q_col = b.load_q[:, step].copy()
        self._refresh_p_l0()

    def warmup(self) -> float:
        import time as _time

        t0 = _time.perf_counter()
        self._set_boundary(0)
        self.fleet.init_steady_state()
        self.integrator.refresh_e_k()
        self._run_pf("warmup")
        self._initialized = True
        return (_time.perf_counter() - t0) * 1e3

    # -- rolling snapshot ring (ledger 23): 5 s cadence, 120 s retention --
    # 24 marks at the SNAP_MARK_US cadence = the 120 s replay window; the
    # /gb/replay cap derives from this constant (a replay window longer than
    # retention is a guaranteed window_expired).

    RING_RETAIN_US = 24 * SNAP_MARK_US

    def enable_snapshot_ring(self) -> None:
        """Arm the /gb/replay state source (gamebridge mode only — the
        standalone Grafana mode has no replay UI and skips the capture cost)."""
        from collections import deque
        self._snap_ring: object = deque()
        self.integrator.snapshot_hook = self._ring_capture

    def _ring_capture(self, t_us: int) -> None:
        ring = self._snap_ring
        ring.append((t_us, self.state_blob()))
        while ring and ring[0][0] < t_us - self.RING_RETAIN_US:
            ring.popleft()

    def ring_lookup(self, t_us: int):
        """Newest ring entry at or before t_us, or None (window expired)."""
        ring = getattr(self, "_snap_ring", None)
        best = None
        for entry_t, blob in (ring or ()):
            if entry_t <= t_us:
                best = (entry_t, blob)
        return best

    # -- sim-level snapshot (v2): engine + topology state -----------------

    def state_blob(self) -> dict:
        return {
            "version": SIM_SNAPSHOT_VERSION,
            "engine": self.integrator.state_dict(),
            "line_in_service": {k: bool(v)
                                for k, v in self._line_in_service.items()},
            "line_duty": {k: repr(float(v)) for k, v in self._line_duty.items()},
        }

    def restore_blob(self, blob: dict) -> None:
        net = self.built.net
        for line_id, live in blob["line_in_service"].items():
            if line_id in self._line_in_service:
                self._line_in_service[line_id] = bool(live)
                net.line.at[self._line_pp_idx[line_id], "in_service"] = bool(live)
        self._line_duty = {k: float(v) for k, v in blob["line_duty"].items()}
        self._trip_scheduled = set()
        # islands must match the blob's shape BEFORE the engine restore
        self._retopologize()
        self.integrator.restore_state(blob["engine"])
        self._apply_pf_topology()

    def run_step(self, step: int, day: int) -> StepResult:
        from .dynamics import s_to_us

        t0 = time.perf_counter()
        try:
            if not self._initialized:
                self.warmup()
            self._set_boundary(step)
            res = self.integrator.advance(s_to_us(self.step_seconds),
                                          interrupt_on_event=False)
        except Exception as exc:  # noqa: BLE001 — never kill the loop
            return failed_step_result(step, day, self.steps_per_day, t0, exc)

        island = self.integrator.islands
        e_k = float(island.e_k[0])
        s_online = float(self.fleet.s_online_per_island(1)[0])
        freq = {
            "f_hz": float(res.f_end[0]),
            "f_min_hz": float(res.f_min[0]),
            "f_max_hz": float(res.f_max[0]),
            "rocof_max_hz_s": float(res.rocof_max[0]),
            "e_k_mj": e_k,
            "s_online_mva": s_online,
            "h_sys_s": e_k / s_online if s_online > 0 else 0.0,
            "mode": res.mode,
            "balance_err": res.balance_err,
        }
        summary = {
            "load_mw": float(island.p_load()[0]),
            "gen_mw": float(self.fleet.y.sum()),
            "sgen_mw": float(self.fleet.inv_p.sum()),
            "f_hz": freq["f_hz"],
            "pf_solves": self._pf_count,
            "pf_failures": self._pf_fail_count,
            **{k: v for k, v in self._latest_pf.items() if not isinstance(v, dict)},
        }
        return StepResult(
            step=step, day=day,
            time_of_day=time_of_day(step, self.steps_per_day),
            converged=self._pf_ok,
            solve_ms=(time.perf_counter() - t0) * 1e3,
            timestamp=time.time(),
            summary=summary,
            buses=self._latest_pf.get("buses", {}),
            lines=self._latest_pf.get("lines", {}),
            freq=freq,
        )


def build_dyn_simulator(data_dir: str, steps_per_day: int, *,
                        d_load_pct_per_hz: float = 1.0,
                        warm_start: bool = True,
                        catalog_path: str = "data/catalogs/plant_types.json",
                        mode_cfg=None, data=None) -> DynSimulator:
    from .data_loader import load_bundle
    from .network_builder import build_network

    data = data if data is not None else load_bundle(data_dir)
    if data.scenario.steps_per_day != steps_per_day:
        raise ValueError(
            f"scenario steps_per_day ({data.scenario.steps_per_day}) != configured ({steps_per_day})"
        )
    return DynSimulator(data, build_network(data), steps_per_day=steps_per_day,
                        d_load_pct_per_hz=d_load_pct_per_hz, warm_start=warm_start,
                        catalog_path=catalog_path, mode_cfg=mode_cfg)
