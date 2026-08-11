"""Telemetry: fine ring (120 s of samples) + per-advance trajectory buffer.

The fine ring backs RoCoF windowing and (later) /gb/telemetry/ring and the
replay UI. The trajectory buffer collects the samples of one advance() call
and emits a stride-decimated array (<= max_samples, event instants kept).
The coarse 24 h ring and the rolling snapshot ring join in P4/P8.
"""

from __future__ import annotations

import numpy as np

from .dynamics import US


class FineRing:
    """Per-island ring of (t_us, f) samples, capacity ~120 s."""

    def __init__(self, capacity: int = 12_000) -> None:
        self.capacity = capacity
        self.t_us = np.zeros(capacity, dtype=np.int64)
        self.f = np.zeros(capacity)
        self.n = 0  # total samples ever written

    def append(self, t_us: int, f: float) -> None:
        idx = self.n % self.capacity
        self.t_us[idx] = t_us
        self.f[idx] = f
        self.n += 1

    def _ordered(self) -> tuple[np.ndarray, np.ndarray]:
        if self.n <= self.capacity:
            return self.t_us[: self.n], self.f[: self.n]
        cut = self.n % self.capacity
        return (
            np.concatenate([self.t_us[cut:], self.t_us[:cut]]),
            np.concatenate([self.f[cut:], self.f[:cut]]),
        )

    def rocof_window(self, t_us: int, window_us: int = 500_000) -> float:
        """Windowed mean RoCoF [Hz/s]: (f(t) - f(t-w)) / actual span."""
        t, f = self._ordered()
        if len(t) < 2:
            return 0.0
        i_now = int(np.searchsorted(t, t_us, side="right")) - 1
        if i_now <= 0:
            return 0.0
        i_then = int(np.searchsorted(t, t_us - window_us, side="left"))
        i_then = min(i_then, i_now - 1)
        span_us = t[i_now] - t[i_then]
        if span_us <= 0:
            return 0.0
        return float((f[i_now] - f[i_then]) / (span_us / US))


class TrajectoryBuffer:
    def __init__(self) -> None:
        self.t_us: list[int] = []
        self.f: dict[int, list[float]] = {}
        self.watched: dict[str, list[float]] = {}
        self.event_t_us: set[int] = set()

    def sample(self, t_us: int, f_by_island: np.ndarray,
               watched: dict[str, float] | None = None) -> None:
        self.t_us.append(t_us)
        for island, value in enumerate(f_by_island):
            self.f.setdefault(island, []).append(float(value))
        if watched:
            for label, value in watched.items():
                self.watched.setdefault(label, []).append(float(value))

    def mark_event(self, t_us: int) -> None:
        self.event_t_us.add(t_us)

    def emit(self, t0_us: int, max_samples: int) -> dict:
        n = len(self.t_us)
        # an island born mid-step (split/merge) has a shorter series: pad
        # the pre-birth stretch with nulls (wire-legal; the game reads
        # trajectory numerics null-tolerantly)
        for island, values in self.f.items():
            if len(values) < n:
                self.f[island] = [None] * (n - len(values)) + values
        if n == 0:
            return {"t_rel_s": [], "islands": {}, "watched": {}}
        keep = list(range(n))
        if n > max_samples:
            stride = -(-n // max_samples)
            kept = set(range(0, n, stride))
            kept.add(n - 1)
            for i, t in enumerate(self.t_us):  # event instants always included
                if t in self.event_t_us:
                    kept.add(i)
            keep = sorted(kept)
        return {
            "t_rel_s": [(self.t_us[i] - t0_us) / US for i in keep],
            "islands": {
                str(island): {"f": [values[i] for i in keep]}
                for island, values in self.f.items()
            },
            "watched": {
                label: {"p": [values[i] for i in keep]}
                for label, values in self.watched.items()
            },
        }
