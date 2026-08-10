"""StateStore: latest result + bounded history + WebSocket fan-out (family shape)."""

from __future__ import annotations

import asyncio
from collections import deque
from typing import Any

from .simulator import StepResult


class StateStore:
    def __init__(self, history_size: int) -> None:
        self._latest: StepResult | None = None
        self._history: deque[StepResult] = deque(maxlen=history_size)
        self._subscribers: set[asyncio.Queue[dict[str, Any]]] = set()

    @property
    def latest(self) -> StepResult | None:
        return self._latest

    def history(self, limit: int | None = None) -> list[StepResult]:
        items = list(self._history)
        if limit is not None and limit >= 0:
            items = items[-limit:]
        return items

    async def publish(self, result: StepResult) -> None:
        self._latest = result
        self._history.append(result)
        wire = result.to_wire()
        for queue in list(self._subscribers):
            # Slow consumers drop frames, they never stall the loop.
            try:
                queue.put_nowait(wire)
            except asyncio.QueueFull:
                pass

    def subscribe(self) -> asyncio.Queue[dict[str, Any]]:
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=64)
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue[dict[str, Any]]) -> None:
        self._subscribers.discard(queue)

    def reset(self) -> None:
        self._latest = None
        self._history.clear()
