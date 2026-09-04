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


def test_case9_angle_model_internals() -> None:
    """Pin the pandapower internals the per-machine angle observer's classical
    Kron reduction depends on (the phasor arc, ledger 56) — so a library
    upgrade that moves the Ybus / lookups / result columns fails loudly here,
    not silently inside the engine's reduced-network build."""
    import numpy as np
    import pandapower as pp
    import pandapower.networks as nw

    net = nw.case9()
    pp.runpp(net)
    # the admittance matrix is exposed on the solved ppc as a square sparse Ybus
    ybus = net._ppc["internal"]["Ybus"]
    assert ybus.shape == (len(net.bus), len(net.bus))
    assert hasattr(ybus, "todense")  # scipy sparse
    # the net-bus -> ppc-bus lookup the reduction maps machine buses through
    b_lookup = net._pd2ppc_lookups["bus"]
    assert int(b_lookup[int(net.gen.at[net.gen.index[0], "bus"])]) >= 0
    # the per-machine operating point the internal EMF E' is initialised from
    for col in ("p_mw", "q_mvar", "va_degree"):
        assert col in net.res_gen.columns
    assert "va_degree" in net.res_bus.columns
    # the classic WSCC 3-machine, 9-bus shape (1 ext_grid + 2 gens = 3 machines)
    assert len(net.ext_grid) + len(net.gen) == 3
    assert not np.isnan(net.res_bus.va_degree.values).any()


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
