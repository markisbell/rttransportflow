from __future__ import annotations

import asyncio

import pytest

from rttransportflow.engine import ExternalClockConflict, RealtimeEngine
from rttransportflow.simulator import NullSimulator
from rttransportflow.state import StateStore


def make_engine(steps_per_day: int = 4, interval: float = 0.001):
    store = StateStore(history_size=64)
    engine = RealtimeEngine(
        NullSimulator(steps_per_day=steps_per_day),
        store,
        step_interval_seconds=interval,
        steps_per_day=steps_per_day,
    )
    return engine, store


def test_external_step_advances_and_wraps() -> None:
    async def run() -> None:
        engine, store = make_engine(steps_per_day=4)
        seen = []
        for _ in range(6):
            result = await engine.external_step()
            seen.append((result.step, result.day))
        assert seen == [(0, 0), (1, 0), (2, 0), (3, 0), (0, 1), (1, 1)]
        assert len(store.history()) == 6

    asyncio.run(run())


def test_external_step_refuses_while_internal_clock_runs() -> None:
    async def run() -> None:
        engine, _ = make_engine()
        await engine.start()
        try:
            with pytest.raises(ExternalClockConflict):
                await engine.external_step()
        finally:
            await engine.stop()

    asyncio.run(run())


def test_internal_clock_ticks_and_pauses() -> None:
    async def run() -> None:
        engine, store = make_engine(interval=0.001)
        await engine.start()
        for _ in range(500):
            if len(store.history()) >= 3:
                break
            await asyncio.sleep(0.002)
        assert len(store.history()) >= 3

        engine.pause()
        await asyncio.sleep(0.01)
        frozen = len(store.history())
        await asyncio.sleep(0.02)
        assert len(store.history()) == frozen

        engine.resume()
        for _ in range(500):
            if len(store.history()) > frozen:
                break
            await asyncio.sleep(0.002)
        assert len(store.history()) > frozen
        await engine.stop()

    asyncio.run(run())


def test_clock_mode_equivalence() -> None:
    """Internal and puppet clocks produce the identical step/day sequence."""

    async def run() -> None:
        n = 10

        engine_ext, store_ext = make_engine(steps_per_day=4)
        for _ in range(n):
            await engine_ext.external_step()

        engine_int, store_int = make_engine(steps_per_day=4, interval=0.0)
        await engine_int.start()
        for _ in range(2000):
            if len(store_int.history()) >= n:
                break
            await asyncio.sleep(0.001)
        await engine_int.stop()

        seq_ext = [(r.step, r.day) for r in store_ext.history()]
        seq_int = [(r.step, r.day) for r in store_int.history()][:n]
        assert seq_int == seq_ext

    asyncio.run(run())
