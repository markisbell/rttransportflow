"""Frequency-dynamics engine (authority: docs/PHYSICS.md).

Time is integer MICROSECONDS throughout this package. Every state update
happens on absolute-time boundaries (mode tick grid, PF/sample schedules,
event instants — all multiples of the 10 ms base quantum), which is what
makes trajectories independent of how callers slice time (bit-exact).
"""

QUANTUM_US = 10_000  # 10 ms — the base grid; every boundary is a multiple
F0 = 50.0

US = 1_000_000  # microseconds per second


def s_to_us(seconds: float) -> int:
    """Quantize a wall/wire duration to the base grid (round to nearest)."""
    return round(seconds * US / QUANTUM_US) * QUANTUM_US
