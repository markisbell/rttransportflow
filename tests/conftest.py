from __future__ import annotations

import pytest

from rttransportflow.api.runtime import create_app
from rttransportflow.config import Settings


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
