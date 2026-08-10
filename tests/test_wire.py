from __future__ import annotations

import math

import pytest

from rttransportflow.config import Settings
from rttransportflow.simulator import NullSimulator, StepResult, _as_int, _r


def test_r_rounds_and_nulls_nonfinite() -> None:
    assert _r(1.23456789) == 1.234568
    assert _r(float("nan")) is None
    assert _r(float("inf")) is None
    assert _r({"a": float("-inf"), "b": [1.0000004, 2]}) == {"a": None, "b": [1.0, 2]}
    assert _r("text") == "text"


def test_as_int_tolerates_godot_floats() -> None:
    assert _as_int(96) == 96
    assert _as_int(96.0) == 96
    with pytest.raises(ValueError):
        _as_int(96.5)
    with pytest.raises(ValueError):
        _as_int(True)


def test_step_result_wire_is_json_safe() -> None:
    result = StepResult(
        step=1,
        day=0,
        time_of_day="00:15",
        converged=True,
        solve_ms=float("nan"),
        timestamp=123.456789123,
        summary={"loss_mw": float("inf")},
    )
    wire = result.to_wire()
    assert wire["solve_ms"] is None
    assert wire["summary"]["loss_mw"] is None
    assert wire["timestamp"] == 123.456789


def test_null_simulator_deterministic_fields() -> None:
    sim = NullSimulator(steps_per_day=96)
    r = sim.run_step(4, 2)
    assert (r.step, r.day, r.time_of_day, r.converged) == (4, 2, "01:00", True)


def test_settings_env_override(monkeypatch) -> None:
    monkeypatch.setenv("RTTRANSPORTFLOW_PORT", "8099")
    monkeypatch.setenv("RTTRANSPORTFLOW_EXTERNAL_CLOCK", "true")
    s = Settings(_env_file=None)
    assert s.port == 8099
    assert s.external_clock is True
    assert s.host == "127.0.0.1"
