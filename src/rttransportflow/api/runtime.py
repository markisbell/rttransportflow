"""App container singleton + FastAPI factory (family api/runtime.py pattern)."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from ..config import Settings
from ..engine import RealtimeEngine
from ..recorder import Recorder
from ..simulator import NullSimulator, build_pf_simulator
from ..state import StateStore


@dataclass
class App:
    """Everything the routers need, in one place."""

    settings: Settings
    store: StateStore
    engine: RealtimeEngine
    network_meta: dict[str, Any] | None = None
    warmup_solve_ms: float | None = None
    recorder: Recorder | None = field(default=None, repr=False)


def _network_meta(data) -> dict[str, Any]:
    return {
        "name": data.scenario.name,
        "steps_per_day": data.scenario.steps_per_day,
        "buses": [
            {
                "name": b.name,
                "vn_kv": b.vn_kv,
                "geo": {"lat": b.geo.lat, "lon": b.geo.lon} if b.geo else None,
            }
            for b in data.grid.buses
        ],
        "lines": [
            {"id": ln.id, "from_bus": ln.from_bus, "to_bus": ln.to_bus,
             "length_km": ln.length_km, "parallel": ln.parallel}
            for ln in data.lines.lines
        ],
        "plants": [
            {"id": p.id, "bus": p.bus, "kind": p.kind, "p_max_mw": p.p_max_mw}
            for p in data.plants.plants
        ],
        "zones": [{"id": z.id, "bus": z.bus} for z in data.grid.zones],
    }


def build_container(settings: Settings | None = None) -> App:
    settings = settings or Settings()
    store = StateStore(history_size=settings.history_size)

    network_meta = None
    if settings.simulator == "dyn":
        from ..data_loader import load_bundle
        from ..simulator import build_dyn_simulator

        simulator = build_dyn_simulator(
            settings.data_dir, settings.steps_per_day,
            d_load_pct_per_hz=settings.d_load_pct_per_hz,
            warm_start=settings.warm_start,
            catalog_path=settings.catalog_path,
        )
        network_meta = _network_meta(load_bundle(settings.data_dir))
    elif settings.simulator == "pf":
        from ..data_loader import load_bundle

        simulator = build_pf_simulator(
            settings.data_dir, settings.steps_per_day, warm_start=settings.warm_start
        )
        network_meta = _network_meta(load_bundle(settings.data_dir))
    else:
        simulator = NullSimulator(steps_per_day=settings.steps_per_day)

    engine = RealtimeEngine(
        simulator,
        store,
        step_interval_seconds=settings.step_interval_seconds,
        steps_per_day=settings.steps_per_day,
    )
    return App(settings=settings, store=store, engine=engine, network_meta=network_meta)


def create_app(settings: Settings | None = None) -> FastAPI:
    container = build_container(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        simulator = container.engine.simulator
        if hasattr(simulator, "warmup"):
            # JIT never lands on a live step (family rule).
            container.warmup_solve_ms = await asyncio.to_thread(simulator.warmup)
        if container.settings.record:
            container.recorder = Recorder(container.settings.record_dir)
            container.store.sink = container.recorder.record
        if container.settings.autostart and not container.settings.external_clock:
            await container.engine.start()
        yield
        await container.engine.stop()
        if container.recorder is not None:
            container.recorder.close()

    app = FastAPI(title="rttransportflow", lifespan=lifespan)
    app.state.container = container

    if container.settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=container.settings.cors_origins,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    from . import control, core

    app.include_router(core.router)
    app.include_router(control.router)
    return app
