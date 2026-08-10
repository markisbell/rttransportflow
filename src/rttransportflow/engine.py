"""RealtimeEngine (family shape, netzsim lineage).

Two clock modes over one shared per-tick body `_advance_once()`:

- internal accelerated tick (standalone): one sim step per
  `step_interval_seconds` of wall time, solve off-loop via asyncio.to_thread;
- puppet mode (`external_clock`): the loop is off and the game drives
  `external_step()` — which REFUSES while the internal clock runs (the
  two-clock guard; a test pins N-step identity between the modes).

After `steps_per_day` steps the step counter wraps to 0 and the day
increments.
"""

from __future__ import annotations

import asyncio
import time

from .simulator import StepResult
from .state import StateStore


class ExternalClockConflict(RuntimeError):
    """external_step() was called while the internal clock is running."""


class RealtimeEngine:
    def __init__(
        self,
        simulator,
        store: StateStore,
        *,
        step_interval_seconds: float,
        steps_per_day: int,
    ) -> None:
        self.simulator = simulator
        self.store = store
        self.step_interval_seconds = step_interval_seconds
        self.steps_per_day = steps_per_day

        self.step = 0
        self.day = 0

        self._task: asyncio.Task | None = None
        self._running = False
        self._resumed = asyncio.Event()
        self._resumed.set()  # set = not paused
        self._ext_lock = asyncio.Lock()
        self._in_flight: asyncio.Future | None = None

    # --- shared per-tick body -------------------------------------------

    async def _advance_once(self) -> StepResult:
        result = await asyncio.to_thread(self.simulator.run_step, self.step, self.day)
        await self.store.publish(result)
        self.step += 1
        if self.step >= self.steps_per_day:
            self.step = 0
            self.day += 1
        return result

    # --- internal accelerated clock -------------------------------------

    @property
    def running(self) -> bool:
        return self._running

    @property
    def paused(self) -> bool:
        return self._running and not self._resumed.is_set()

    async def start(self) -> None:
        if self._running:
            return
        self._running = True
        self._resumed.set()
        self._task = asyncio.create_task(self._loop(), name="rttransportflow-engine")

    async def stop(self) -> None:
        """Stop the loop, draining any in-flight step first (family rule)."""
        self._running = False
        self._resumed.set()
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None

    def pause(self) -> None:
        self._resumed.clear()

    def resume(self) -> None:
        self._resumed.set()

    async def _loop(self) -> None:
        while self._running:
            await self._resumed.wait()
            if not self._running:
                break
            t0 = time.perf_counter()
            try:
                await self._advance_once()
            except Exception:  # noqa: BLE001 — never let one step kill the loop
                pass
            elapsed = time.perf_counter() - t0
            await asyncio.sleep(max(0.0, self.step_interval_seconds - elapsed))

    # --- puppet mode -----------------------------------------------------

    async def external_step(self) -> StepResult:
        if self._running:
            raise ExternalClockConflict(
                "external_step refused: the internal clock is running "
                "(set RTTRANSPORTFLOW_EXTERNAL_CLOCK=true)"
            )
        async with self._ext_lock:  # strictly sequential external steps
            return await self._advance_once()
