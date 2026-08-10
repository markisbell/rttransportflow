"""Simulation core.

P0 ships a NullSimulator so the engine/API scaffold runs end to end; the
pandapower simulator replaces it in P1 (ROADMAP P1). StepResult is the single
wire format (family §6 pattern) — REST /state, /history, the WS stream, and
later the recorder all serve projections of it.
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
