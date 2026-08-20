"""Canonical wire-format helpers (family §6 pattern).

`_r`/`_as_int` are the package-wide wire API — engine.py, state.py and
gamebridge all depend on them (previously as module-privates of the
simulator file). StepResult is the single wire format: REST /state,
/history, the WS stream, and the recorder all serve projections of it.
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


# public names (the underscore spellings stay for the existing importers)
round_wire = _r
as_int = _as_int


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


def failed_step_result(step: int, day: int, steps_per_day: int,
                       t0: float, exc: Exception) -> StepResult:
    """The never-crash frame both simulators emit on an escaped exception."""
    return StepResult(
        step=step, day=day,
        time_of_day=time_of_day(step, steps_per_day),
        converged=False, solve_ms=(time.perf_counter() - t0) * 1e3,
        timestamp=time.time(), error=f"{type(exc).__name__}: {exc}",
    )
