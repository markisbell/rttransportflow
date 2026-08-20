from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from rttransportflow.api.runtime import create_app
from rttransportflow.config import Settings


@pytest.fixture()
def client():
    """External-clock gamebridge client — shared by the gamebridge, wire-device
    and replay suites (previously three identical module-level copies)."""
    app = create_app(Settings(external_clock=True, autostart=False))
    with TestClient(app) as c:
        yield c


@pytest.fixture
def settings() -> Settings:
    # Fast ticks, no autostart, null simulator: scaffold tests drive the
    # clock explicitly and don't pay the PF warmup.
    return Settings(
        autostart=False,
        simulator="null",
        step_interval_seconds=0.005,
        steps_per_day=96,
        history_size=32,
    )


@pytest.fixture
def app(settings: Settings):
    return create_app(settings)
