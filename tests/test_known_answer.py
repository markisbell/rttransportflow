"""Known-answer test: exact PF numbers for the shipped europe_mini bundle.

Regenerating the bundle or touching the builder/simulator must reproduce
these values (rtheatflow known-answer rule). Baseline captured 2026-08-10
from pandapower 3.5.4.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from rttransportflow.simulator import build_pf_simulator

BUNDLE_DIR = Path(__file__).resolve().parent.parent / "data" / "grids" / "europe_mini"
REL = 1e-4


@pytest.fixture(scope="module")
def sim():
    simulator = build_pf_simulator(BUNDLE_DIR, 96)
    simulator.warmup()
    return simulator


def test_step0_night_valley(sim) -> None:
    r = sim.run_step(0, 0)
    assert r.converged
    s = r.summary
    assert s["load_mw"] == pytest.approx(33480.0, rel=REL)
    assert s["gen_mw"] == pytest.approx(32819.7, rel=1e-3)
    assert s["sgen_mw"] == pytest.approx(1162.9, rel=1e-3)
    assert s["slack_mw"] == pytest.approx(-305.87, rel=1e-3)
    assert s["loss_mw"] == pytest.approx(196.73, rel=1e-3)
    assert s["max_loading_pct"] == pytest.approx(64.63, rel=1e-3)
    assert abs(s["balance_err_mw"]) < 0.01


def test_step74_evening_peak(sim) -> None:
    r = sim.run_step(74, 0)
    assert r.converged
    s = r.summary
    assert s["load_mw"] == pytest.approx(54996.1, rel=REL)
    assert s["slack_mw"] == pytest.approx(-621.45, rel=1e-3)
    assert s["loss_mw"] == pytest.approx(203.45, rel=1e-3)
    assert s["max_loading_pct"] == pytest.approx(69.94, rel=1e-3)
    assert r.lines["lyon-milan"]["loading_percent"] == pytest.approx(69.94, rel=1e-3)
    # Every bus holds its 1.02 setpoint (fully PV-covered fleet at P1).
    assert all(abs(b["vm_pu"] - 1.02) < 1e-6 for b in r.buses.values())


def test_full_day_converges_with_sane_envelope(sim) -> None:
    slack, loading = [], []
    for step in range(96):
        r = sim.run_step(step, 0)
        assert r.converged, f"step {step} diverged: {r.error}"
        slack.append(r.summary["slack_mw"])
        loading.append(r.summary["max_loading_pct"])
    # Authored dispatch keeps the slack small and corridors inside limits —
    # window properties, not instants (family smoke rule).
    assert max(abs(v) for v in slack) < 800.0
    assert max(loading) < 75.0
