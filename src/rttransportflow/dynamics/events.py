"""Event queue: heap by sim time, FIFO tiebreak by insertion seq (determinism)."""

from __future__ import annotations

import heapq
from dataclasses import dataclass, field
from typing import Any

from . import QUANTUM_US


@dataclass(frozen=True)
class Event:
    t_us: int
    kind: str  # "trip" | "load_step" (P2); grows per contract
    element: str
    data: dict[str, Any] = field(default_factory=dict)
    significant: bool = True


class EventQueue:
    def __init__(self) -> None:
        self._heap: list[tuple[int, int, Event]] = []
        self._seq = 0

    def schedule(self, event: Event) -> Event:
        # Quantize to the base grid (ceil) so events land on tick boundaries.
        t = -(-event.t_us // QUANTUM_US) * QUANTUM_US
        if t != event.t_us:
            event = Event(t, event.kind, event.element, event.data, event.significant)
        heapq.heappush(self._heap, (event.t_us, self._seq, event))
        self._seq += 1
        return event

    def peek_time(self) -> int | None:
        return self._heap[0][0] if self._heap else None

    def pop_due(self, t_us: int) -> list[Event]:
        due: list[Event] = []
        while self._heap and self._heap[0][0] <= t_us:
            due.append(heapq.heappop(self._heap)[2])
        return due

    def has_event_within(self, t_us: int, horizon_us: int) -> bool:
        nxt = self.peek_time()
        return nxt is not None and nxt <= t_us + horizon_us

    def snapshot(self) -> list[dict]:
        return [
            {"t_us": e.t_us, "kind": e.kind, "element": e.element,
             "data": e.data, "significant": e.significant}
            for _, _, e in sorted(self._heap)
        ]

    def restore(self, items: list[dict]) -> None:
        self._heap = []
        self._seq = 0
        for item in items:
            self.schedule(Event(item["t_us"], item["kind"], item["element"],
                                dict(item["data"]), item["significant"]))
