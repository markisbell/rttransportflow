"""PF sanity (PHYSICS §6.9): library pins + PF↔dynamics coupling settling."""

from __future__ import annotations

from pathlib import Path

import pytest

BUNDLE_DIR = Path(__file__).resolve().parent.parent / "data" / "grids" / "europe_mini"

# Captured 2026-08-10 from pandapower 3.5.4 (case9, init="dc").
CASE9_VM_PU = [1.0, 1.0, 1.0, 0.98700685, 0.97547218, 1.00337544,
               0.98564488, 0.99618525, 0.95762104]
CASE9_LOSS_MW = 4.954702


def test_case9_pins() -> None:
    import pandapower as pp
    import pandapower.networks as nw

    net = nw.case9()
    pp.runpp(net, init="dc")
    for got, want in zip(net.res_bus.vm_pu, CASE9_VM_PU):
        assert got == pytest.approx(want, abs=1e-6)
    assert float(net.res_line.pl_mw.sum()) == pytest.approx(CASE9_LOSS_MW, abs=1e-4)


@pytest.fixture(scope="module")
def dyn():
    from rttransportflow.simulator import build_dyn_simulator

    sim = build_dyn_simulator(BUNDLE_DIR, 96)
    sim.warmup()
    return sim


def test_dyn_simulator_hour_of_europe_mini(dyn) -> None:
    """One hour of coupled dynamics: converged PF, frequency near nominal,
    freq block present, energy balance holds."""
    for step in range(4):
        r = dyn.run_step(step, 0)
        assert r.converged, f"step {step}: {r.error}"
        assert r.freq is not None
        assert abs(r.freq["f_hz"] - 50.0) < 0.1  # balanced dispatch => small offset
        assert r.freq["h_sys_s"] > 3.0  # the whole sync fleet is online
        assert r.freq["balance_err"] < 1e-6
        assert r.summary["pf_failures"] == 0


def test_loss_feedback_settles(dyn) -> None:
    """Constant boundary => the PF slack residual shrinks below 0.1 % of load
    after a few PF instants (the ledger's loss estimate self-corrects)."""
    r = dyn.run_step(4, 0)  # constant boundary within the step; >= 3 PF instants
    assert r.converged
    slack = abs(r.summary["slack_mw"])
    load = r.summary["load_mw"]
    assert slack < 0.001 * load, f"slack {slack:.1f} MW vs load {load:.0f} MW"
