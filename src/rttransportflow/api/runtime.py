"""App container singleton + FastAPI factory (family api/runtime.py pattern)."""

from __future__ import annotations

from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from ..config import Settings
from ..engine import RealtimeEngine
from ..simulator import NullSimulator
from ..state import StateStore


@dataclass
class App:
    """Everything the routers need, in one place."""

    settings: Settings
    store: StateStore
    engine: RealtimeEngine


def build_container(settings: Settings | None = None) -> App:
    settings = settings or Settings()
    store = StateStore(history_size=settings.history_size)
    simulator = NullSimulator(steps_per_day=settings.steps_per_day)
    engine = RealtimeEngine(
        simulator,
        store,
        step_interval_seconds=settings.step_interval_seconds,
        steps_per_day=settings.steps_per_day,
    )
    return App(settings=settings, store=store, engine=engine)


def create_app(settings: Settings | None = None) -> FastAPI:
    container = build_container(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if container.settings.autostart and not container.settings.external_clock:
            await container.engine.start()
        yield
        await container.engine.stop()

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
