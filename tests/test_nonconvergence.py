"""Non-convergence is DATA: a degraded frame, an alive loop, never a 500."""

from __future__ import annotations

from pathlib import Path

import pandapower as pp
import pytest

from rttransportflow.simulator import build_pf_simulator

BUNDLE_DIR = Path(__file__).resolve().parent.parent / "data" / "grids" / "europe_mini"


@pytest.fixture(scope="module")
def sim():
    simulator = build_pf_simulator(BUNDLE_DIR, 96)
    simulator.warmup()
    return simulator


def test_forced_divergence_yields_degraded_frame_then_self_heals(sim, monkeypatch) -> None:
    calls = {"n": 0}

    def explode(*args, **kwargs):
        calls["n"] += 1
        raise pp.LoadflowNotConverged("forced by test")

    monkeypatch.setattr(pp, "runpp", explode)
    r = sim.run_step(5, 0)
    assert r.converged is False
    assert "forced by test" in r.error
    assert calls["n"] >= 2  # every retry tier was attempted
    assert r.summary == {}

    monkeypatch.undo()
    # Self-heal: next step cold-starts (no warm tier after a failure) and converges.
    r2 = sim.run_step(6, 0)
    assert r2.converged is True
    assert r2.summary["load_mw"] > 0


def test_degraded_frame_serves_over_rest(monkeypatch) -> None:
    """A non-converged frame is HTTP 200 on /state, never a 500."""
    import time

    from fastapi.testclient import TestClient

    from rttransportflow.api.runtime import create_app
    from rttransportflow.config import Settings
    from rttransportflow.simulator import StepResult

    app = create_app(
        Settings(autostart=False, simulator="null", steps_per_day=96,
                 step_interval_seconds=0.005)
    )
    with TestClient(app) as client:
        container = app.state.container

        def broken_run_step(step, day):
            return StepResult(
                step=step, day=day, time_of_day="00:00", converged=False,
                solve_ms=0.1, timestamp=time.time(),
                error="LoadflowNotConverged: forced",
            )

        monkeypatch.setattr(container.engine.simulator, "run_step", broken_run_step)

        assert client.post("/control/start").status_code == 200
        state = None
        for _ in range(200):
            got = client.get("/state")
            assert got.status_code in (200, 404)  # never a 500
            if got.status_code == 200:
                state = got.json()
                break
        assert state is not None
        assert state["converged"] is False
        assert "LoadflowNotConverged" in state["error"]
