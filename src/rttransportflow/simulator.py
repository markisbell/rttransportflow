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
