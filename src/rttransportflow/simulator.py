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

import math
import time
from dataclasses import asdict, dataclass, field
from typing import Any


def _r(x: Any) -> Any:
    """Canonical wire rounding: floats to 6 digits, non-finite -> None.

    Every float that leaves the process goes through here — browsers'
    JSON.parse rejects literal NaN/Infinity (family gotcha). The sole
    exemption is the snapshot blob (repr floats, bit-exact restore).
    """
    if isinstance(x, float):
        if not math.isfinite(x):
            return None
        return round(x, 6)
    if isinstance(x, dict):
        return {k: _r(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [_r(v) for v in x]
    return x


def _as_int(x: Any) -> int:
    """Tolerate integer-valued floats (Godot serializes 96 as 96.0)."""
    if isinstance(x, bool):
        raise ValueError(f"expected integer, got bool {x!r}")
    if isinstance(x, int):
        return x
    if isinstance(x, float) and x.is_integer():
        return int(x)
    raise ValueError(f"expected integer, got {x!r}")


def time_of_day(step: int, steps_per_day: int) -> str:
    minutes = int(round(step * 24 * 60 / steps_per_day)) % (24 * 60)
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


@dataclass
class StepResult:
    step: int
    day: int
    time_of_day: str
    converged: bool
    solve_ms: float
    timestamp: float
    summary: dict[str, Any] = field(default_factory=dict)
    buses: dict[str, Any] = field(default_factory=dict)
    lines: dict[str, Any] = field(default_factory=dict)
    freq: dict[str, Any] | None = None  # frequency block (dyn simulator, P2+)
    error: str | None = None

    def to_wire(self) -> dict[str, Any]:
        return _r(asdict(self))


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
        """Retry ladder: warm NR -> cold NR -> iwamoto. Raises on total failure."""
        import pandapower as pp

        tiers: list[dict[str, Any]] = []
        if self.warm_start and self._last_converged:
            tiers.append({"init": "results"})
        tiers.append({"init": "dc"})
        tiers.append({"algorithm": "iwamoto_nr", "init": "dc", "max_iteration": 30})

        last_exc: Exception | None = None
        for tier in tiers:
            try:
                pp.runpp(self.built.net, enforce_q_lims=True, **tier)
                return
            except Exception as exc:  # noqa: BLE001 — every tier may fail
                last_exc = exc
        raise last_exc if last_exc else RuntimeError("no solver tier ran")

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
            return StepResult(
                step=step,
                day=day,
                time_of_day=time_of_day(step, self.steps_per_day),
                converged=False,
                solve_ms=(time.perf_counter() - t0) * 1e3,
                timestamp=time.time(),
                summary={},
                error=f"{type(exc).__name__}: {exc}",
            )
        self._last_converged = True
        return self._collect(step, day, (time.perf_counter() - t0) * 1e3)

    def warmup(self) -> float:
        """One throwaway solve so numba JIT never lands on a live step."""
        t0 = time.perf_counter()
        self.run_step(0, 0)
        self._last_converged = False  # the warmup is not part of the run
        return (time.perf_counter() - t0) * 1e3


def build_pf_simulator(data_dir: str, steps_per_day: int, warm_start: bool = True) -> PFSimulator:
    from .data_loader import load_bundle
    from .network_builder import build_network

    data = load_bundle(data_dir)
    if data.scenario.steps_per_day != steps_per_day:
        raise ValueError(
            f"scenario steps_per_day ({data.scenario.steps_per_day}) != configured ({steps_per_day})"
        )
    return PFSimulator(build_network(data), steps_per_day=steps_per_day, warm_start=warm_start)


class WireDeviceError(ValueError):
    """Invalid reset `devices` entry — surfaces as HTTP 400, never a crash."""


def _parse_wire_devices(devices: list[dict], catalog: dict, bus_index: dict) -> dict:
    """Partition contract-v2 reset devices into fleet spec lists.

    Kinds: battery | grid_forming | electrolyzer | h2_store | hvdc |
    offshore_hub (sync_plant/wind/pv travel in the native bundle — the game's
    topology builder owns them)."""
    from .dynamics.hvdc import NO_LOAD_AUX_FRAC, path_loss_frac
    from .dynamics.plant_types import battery_spec, electrolyzer_spec

    out: dict = {"bat": [], "ely": [], "stores": [], "hubs": [], "pairs": [],
                 "ely_store": {}, "nodes": {}}
    hvdc_groups: dict[str, list[dict]] = {}
    seen: set[str] = set()
    for dev in devices:
        did = dev.get("id")
        kind = dev.get("kind")
        node = dev.get("node")
        params = dev.get("params") or {}
        if not did or did in seen:
            raise WireDeviceError(f"device id missing or duplicate: {did!r}")
        seen.add(did)
        try:
            if kind != "h2_store":  # stores are ledger entities, not bus elements
                if node not in bus_index:
                    raise WireDeviceError(f"{did}: unknown node {node!r}")
                out["nodes"][did] = node
            if kind in ("battery", "grid_forming"):
                cat = catalog["battery_gfm" if kind == "grid_forming" else "battery"]
                spec = battery_spec(kind, cat, device_id=did, island=0,
                                    p_max_mw=float(params["p_max_mw"]),
                                    e_mwh=float(params["e_mwh"]),
                                    soc_frac=float(params.get("soc", 0.55)))
                ffr = params.get("ffr") or {}
                if ffr.get("enabled") is False:
                    spec["k_f"] = 0.0
                if "full_at_hz" in ffr:
                    spec["ffr_full_hz"] = float(ffr["full_at_hz"])
                if "deadband_hz" in ffr:
                    spec["db"] = float(ffr["deadband_hz"])
                if kind == "grid_forming":
                    spec["h_v"] = float(params.get("h_v_s", cat["h_v_s"]))
                out["bat"].append(spec)
            elif kind == "electrolyzer":
                store_id = params.get("h2_store_id")
                if not store_id:
                    raise WireDeviceError(f"{did}: electrolyzer needs h2_store_id")
                out["ely"].append(electrolyzer_spec(
                    kind, catalog["electrolyzer"], device_id=did, island=0,
                    p_max_mw=float(params["p_max_mw"]), p_set_mw=0.0))
                out["ely_store"][did] = str(store_id)
            elif kind == "h2_store":
                spec = {"id": did, "island": 0,
                        "capacity_kg": float(params["capacity_kg"])}
                for key in ("level_kg", "inject_max_kgph", "withdraw_max_kgph"):
                    if key in params and params[key] is not None:
                        spec[key] = float(params[key])
                out["stores"].append(spec)
            elif kind == "offshore_hub":
                p_max = float(params["p_max_mw"])
                out["hubs"].append({
                    "id": did, "island": 0, "p_rated": p_max, "avail": 0.0,
                    "t_up": 0.1, "t_down": 0.1,
                    "avail_slew_mw_s": 0.20 * p_max / 60.0,  # front-crossing rate
                    "lfsm_from": 50.2, "lfsm_droop": 0.05,
                    "aux_mw": NO_LOAD_AUX_FRAC * p_max,
                    # extra keys (ignored by make_fleet), kept for the sim maps
                    "loss_frac": path_loss_frac(float(params.get("cable_km", 0.0))),
                    "p_max": p_max,
                })
            elif kind == "hvdc":
                link_id = str(params.get("link_id") or "")
                if not link_id:
                    raise WireDeviceError(f"{did}: hvdc terminal needs link_id")
                hvdc_groups.setdefault(link_id, []).append(dev)
            else:
                raise WireDeviceError(f"{did}: unsupported device kind {kind!r}")
        except KeyError as exc:
            raise WireDeviceError(f"{did}: missing param {exc}") from None
    for link_id, terms in hvdc_groups.items():
        if len(terms) != 2:
            raise WireDeviceError(
                f"hvdc link {link_id!r}: needs exactly 2 terminals, got {len(terms)}")
        p_max = max(float((t.get("params") or {}).get("p_max_mw", 0.0)) for t in terms)
        if p_max <= 0:
            raise WireDeviceError(f"hvdc link {link_id!r}: p_max_mw missing")
        length = max(float((t.get("params") or {}).get("length_km", 0.0)) for t in terms)
        out["pairs"].append({
            "link_id": link_id, "p_max_mw": p_max, "length_km": length,
            "terminals": [{"id": t["id"], "island": 0} for t in terms],
        })
    return out


class DynSimulator:
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
                 protection_seed: int = 0) -> None:
        import numpy as np

        from .dynamics import F0
        from .dynamics.fleet import make_fleet
        from .dynamics.integrator import Integrator, IslandState
        from .dynamics.plant_types import inverter_spec, load_catalog, sync_spec
        from .models import CONVERTER_KINDS, SYNC_KINDS

        self.built = built
        self.data = data
        self.steps_per_day = steps_per_day
        self.step_seconds = 24 * 3600 / steps_per_day
        self.warm_start = warm_start
        self._last_converged = False
        self._np = np
        self._f0 = F0

        catalog = load_catalog(catalog_path)["kinds"]
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

        # wire-device row maps + hub loss model (PARAMETERS §1.16)
        self._bat_row = {pid: i for i, pid in enumerate(self.fleet.bat_ids)}
        self._ely_row = {pid: i for i, pid in enumerate(self.fleet.ely_ids)}
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
        self.integrator = Integrator(self.fleet, islands, pf_hook=self._run_pf,
                                     protection_seed=protection_seed)

        self._load_p_col = built.load_p[:, 0].copy()
        self._load_q_col = built.load_q[:, 0].copy()
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
        self._sync_row = {pid: i for i, pid in enumerate(self.fleet.ids)}
        self._inv_row = {pid: i for i, pid in enumerate(self.fleet.inv_ids)}

    # -- PF hook (called by the integrator at mode cadence + on events) ---

    def _run_pf(self, reason: str) -> None:
        import pandapower as pp

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
        damping_factor = float(
            island.w[0] * (1.0 + island.d_pu * (island.f[0] - self._f0) / self._f0)
        )
        if b.load_idx:
            net.load.loc[b.load_idx, "p_mw"] = self._load_p_col * damping_factor
            net.load.loc[b.load_idx, "q_mvar"] = self._load_q_col * damping_factor
        if b.gen_idx:
            net.gen.loc[b.gen_idx, "p_mw"] = self.fleet.y
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

        tiers: list[dict[str, Any]] = []
        if self.warm_start and self._last_converged:
            tiers.append({"init": "results"})
        tiers.append({"init": "dc"})
        tiers.append({"algorithm": "iwamoto_nr", "init": "dc", "max_iteration": 30})
        for tier in tiers:
            try:
                pp.runpp(net, enforce_q_lims=True, **tier)
                break
            except Exception:  # noqa: BLE001
                continue
        else:
            self._last_converged = False
            self._pf_ok = False
            self._pf_fail_count += 1
            return  # sample-and-hold: keep previous p_loss and flows

        self._last_converged = True
        self._pf_ok = True
        self._pf_count += 1
        for line_id, idx in zip(b.line_ids, b.line_idx):
            loading = float(net.res_line.loading_percent.at[idx])
            if loading > self._pf_window_max.get(line_id, 0.0):
                self._pf_window_max[line_id] = loading
        island.p_loss[0] = float(net.res_line.pl_mw.sum())
        self._latest_pf = {
            "buses": {
                name: {"vm_pu": float(net.res_bus.vm_pu.at[idx]),
                       "va_degree": float(net.res_bus.va_degree.at[idx])}
                for name, idx in b.bus_index.items()
            },
            "lines": {
                line_id: {"loading_percent": float(net.res_line.loading_percent.at[idx]),
                          "p_from_mw": float(net.res_line.p_from_mw.at[idx]),
                          "pl_mw": float(net.res_line.pl_mw.at[idx])}
                for line_id, idx in zip(b.line_ids, b.line_idx)
            },
            "slack_mw": float(net.res_ext_grid.p_mw.sum()),
            "loss_mw": float(net.res_line.pl_mw.sum()),
            "max_loading_pct": float(net.res_line.loading_percent.max()),
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
        self.integrator.islands.p_l0[0] = float(self._load_p_col.sum())

    def warmup(self) -> float:
        import time as _time

        t0 = _time.perf_counter()
        self._set_boundary(0)
        self.fleet.init_steady_state()
        self.integrator.refresh_e_k()
        self._run_pf("warmup")
        self._initialized = True
        return (_time.perf_counter() - t0) * 1e3

    # -- gamebridge wire boundary (sample-and-hold per field) -------------

    def apply_wire_boundary(self, zone_demand: dict | None, avail_mw: dict | None,
                            device_commands: dict | None) -> list[str]:
        """Apply a step request's boundary; returns per-entry problem notes
        (tolerant: unknown ids are reported, never fatal)."""
        from .network_builder import DEFAULT_Q_FACTOR

        notes: list[str] = []
        for zone_id, payload in (zone_demand or {}).items():
            rows = self._zone_rows.get(zone_id)
            if rows is None:
                notes.append(f"zone_demand: unknown zone {zone_id!r}")
                continue
            value = float(payload["value_mw"]) if isinstance(payload, dict) else float(payload)
            share = value / len(rows)
            for row in rows:
                self._load_p_col[row] = share
                self._load_q_col[row] = share * DEFAULT_Q_FACTOR
        self.integrator.islands.p_l0[0] = float(self._load_p_col.sum())

        for plant_id, value in (avail_mw or {}).items():
            hub_row = self._hub_row.get(plant_id)
            if hub_row is not None:
                # hub availability arrives farm-aggregated; the backend owns
                # the §1.16 path losses (2 stations + cable) and the rating clamp
                p_max = self._hub_p_max[plant_id]
                delivered = min(float(value), p_max) * (1.0 - self._hub_loss[plant_id])
                self.fleet.inv_avail[hub_row] = max(delivered, 0.0)
                continue
            row = self._inv_row.get(plant_id)
            if row is None:
                notes.append(f"avail_mw: unknown converter plant {plant_id!r}")
                continue
            self.fleet.inv_avail[row] = float(value)

        for device_id, cmd in (device_commands or {}).items():
            if device_id in self._sync_row:
                notes += self._cmd_sync(device_id, cmd)
            elif device_id in self._hub_row:
                notes += self._cmd_hub(device_id, cmd)
            elif device_id in self._inv_row:
                notes += self._cmd_inv(device_id, cmd)
            elif device_id in self._bat_row:
                notes += self._cmd_battery(device_id, cmd)
            elif device_id in self._ely_row:
                notes += self._cmd_electrolyzer(device_id, cmd)
            elif device_id in self._term_row:
                notes += self._cmd_hvdc_term(device_id, cmd)
            else:
                notes.append(f"device_commands: unknown device {device_id!r}")
        return notes

    # -- per-class command handlers (tolerant: bad fields note, never raise) --

    def _cmd_sync(self, device_id: str, cmd: dict) -> list[str]:
        notes: list[str] = []
        row = self._sync_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            self.fleet.p_set[row] = float(cmd["dispatch_mw"])
        if cmd.get("curtail_to_mw") is not None:
            notes.append(f"{device_id}: curtail_to_mw on a synchronous plant")
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.command_stop(device_id, self.integrator.t_us)
            self.integrator.refresh_e_k()
        elif breaker == "close":
            try:
                self.fleet.command_start(device_id, self.integrator.t_us)
            except RuntimeError as exc:
                notes.append(str(exc))
        return notes

    def _cmd_inv(self, device_id: str, cmd: dict) -> list[str]:
        notes: list[str] = []
        row = self._inv_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            notes.append(f"{device_id}: dispatch_mw on a converter plant")
        if cmd.get("curtail_to_mw") is not None:
            self.fleet.inv_curtail[row] = float(cmd["curtail_to_mw"])
        return notes

    def _cmd_hub(self, device_id: str, cmd: dict) -> list[str]:
        notes: list[str] = []
        row = self._inv_row[device_id]
        if cmd.get("curtail_to_mw") is not None:
            self.fleet.inv_curtail[row] = float(cmd["curtail_to_mw"])
        if cmd.get("q_mvar") is not None:
            band = 0.40 * self._hub_p_max[device_id]  # STATCOM at any P (§1.16)
            hub_i = row - self._n_native_inv
            self._hub_q[hub_i] = float(self._np.clip(float(cmd["q_mvar"]), -band, band))
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.inv_online[row] = False
            self.fleet.inv_p[row] = 0.0
        elif breaker == "close":
            self.fleet.inv_online[row] = True
        return notes

    def _cmd_battery(self, device_id: str, cmd: dict) -> list[str]:
        row = self._bat_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            p_max = float(self.fleet.bat_p_max[row])
            self.fleet.bat_p_set[row] = float(
                self._np.clip(float(cmd["dispatch_mw"]), -p_max, p_max))
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.bat_online[row] = False
            self.fleet.bat_p[row] = 0.0
            self.integrator.refresh_e_k()  # grid-forming H_v leaves the ledger
        elif breaker == "close":
            self.fleet.bat_online[row] = True
            self.integrator.refresh_e_k()
        return []

    def _cmd_electrolyzer(self, device_id: str, cmd: dict) -> list[str]:
        row = self._ely_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            self.fleet.ely_p_set[row] = float(self._np.clip(
                float(cmd["dispatch_mw"]), 0.0, float(self.fleet.ely_p_max[row])))
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.ely_online[row] = False
            self.fleet.ely_p[row] = 0.0
        elif breaker == "close":
            self.fleet.ely_online[row] = True
        return []

    def _cmd_hvdc_term(self, device_id: str, cmd: dict) -> list[str]:
        links = self.fleet.hvdc
        if cmd.get("dispatch_mw") is not None:
            links.command(device_id, float(cmd["dispatch_mw"]))
        if cmd.get("q_mvar") is not None:
            links.command_q(device_id, float(cmd["q_mvar"]))
        breaker = cmd.get("breaker")
        if breaker == "open":
            links.trip(device_id)
        elif breaker == "close":
            links.close(device_id)
        return []

    def set_watch(self, watch: list[str]) -> list[str]:
        specs: list[tuple[str, str, int]] = []
        notes: list[str] = []
        for device_id in watch:
            if device_id in self._sync_row:
                specs.append((device_id, "sync", self._sync_row[device_id]))
            elif device_id in self._inv_row:
                specs.append((device_id, "inv", self._inv_row[device_id]))
            elif device_id in self._bat_row:
                specs.append((device_id, "bat", self._bat_row[device_id]))
            elif device_id in self._ely_row:
                specs.append((device_id, "ely", self._ely_row[device_id]))
            else:
                notes.append(f"watch: unknown device {device_id!r}")
        self.integrator.watch_specs = specs
        return notes

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
            return StepResult(
                step=step, day=day,
                time_of_day=time_of_day(step, self.steps_per_day),
                converged=False, solve_ms=(time.perf_counter() - t0) * 1e3,
                timestamp=time.time(), error=f"{type(exc).__name__}: {exc}",
            )

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
                        catalog_path: str = "data/catalogs/plant_types.json") -> DynSimulator:
    from .data_loader import load_bundle
    from .network_builder import build_network

    data = load_bundle(data_dir)
    if data.scenario.steps_per_day != steps_per_day:
        raise ValueError(
            f"scenario steps_per_day ({data.scenario.steps_per_day}) != configured ({steps_per_day})"
        )
    return DynSimulator(data, build_network(data), steps_per_day=steps_per_day,
                        d_load_pct_per_hz=d_load_pct_per_hz, warm_start=warm_start,
                        catalog_path=catalog_path)
