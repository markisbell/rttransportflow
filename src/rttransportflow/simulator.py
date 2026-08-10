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
                 catalog_path: str = "data/catalogs/plant_types.json") -> None:
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

        self.fleet = make_fleet(sync_specs, inv_specs)
        d_pu = d_load_pct_per_hz * F0 / 100.0
        islands = IslandState(
            f=np.array([F0]),
            e_k=np.zeros(1),
            p_l0=np.array([float(built.load_p[:, 0].sum())]),
            w=np.ones(1),
            p_loss=np.zeros(1),
            d_pu=d_pu,
        )
        self.integrator = Integrator(self.fleet, islands, pf_hook=self._run_pf)

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
            net.sgen.loc[b.sgen_idx, "p_mw"] = self.fleet.inv_p
            net.sgen.loc[b.sgen_idx, "q_mvar"] = self.fleet.inv_p * 0.25

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
        self.fleet.inv_avail[:] = b.sgen_p[:, step]
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
            row = self._inv_row.get(plant_id)
            if row is None:
                notes.append(f"avail_mw: unknown converter plant {plant_id!r}")
                continue
            self.fleet.inv_avail[row] = float(value)

        for device_id, cmd in (device_commands or {}).items():
            sync_row = self._sync_row.get(device_id)
            inv_row = self._inv_row.get(device_id)
            if sync_row is None and inv_row is None:
                notes.append(f"device_commands: unknown device {device_id!r}")
                continue
            if "dispatch_mw" in cmd and cmd["dispatch_mw"] is not None:
                if sync_row is not None:
                    self.fleet.p_set[sync_row] = float(cmd["dispatch_mw"])
                else:
                    notes.append(f"{device_id}: dispatch_mw on a converter plant")
            if "curtail_to_mw" in cmd and cmd["curtail_to_mw"] is not None:
                if inv_row is not None:
                    self.fleet.inv_curtail[inv_row] = float(cmd["curtail_to_mw"])
                else:
                    notes.append(f"{device_id}: curtail_to_mw on a synchronous plant")
            breaker = cmd.get("breaker")
            if breaker == "open" and sync_row is not None:
                self.fleet.command_stop(device_id, self.integrator.t_us)
                self.integrator.refresh_e_k()
            elif breaker == "close" and sync_row is not None:
                try:
                    self.fleet.command_start(device_id, self.integrator.t_us)
                except RuntimeError as exc:
                    notes.append(str(exc))
        return notes

    def set_watch(self, watch: list[str]) -> list[str]:
        specs: list[tuple[str, str, int]] = []
        notes: list[str] = []
        for device_id in watch:
            if device_id in self._sync_row:
                specs.append((device_id, "sync", self._sync_row[device_id]))
            elif device_id in self._inv_row:
                specs.append((device_id, "inv", self._inv_row[device_id]))
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
