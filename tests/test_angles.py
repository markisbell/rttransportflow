"""AngleObserver unit pins (phasor arc P1, ledger 56): the per-machine swing
integrates the classical inter-machine mode, projects to the COI f (< 1e-12),
and bounds a pole slip — all in isolation, on a synthetic reduced network."""
from __future__ import annotations

import types

import numpy as np

from rttransportflow.dynamics import F0
from rttransportflow.dynamics.angles import AngleObserver, IslandNet


def _two_machine_net(x=0.5, e=1.1, sn_base=100.0, h=5.0, sn=1000.0, pm=50.0):
    """A 2-machine island tied by reactance x (pu). Machine 0 generates pm,
    machine 1 absorbs it; equilibrium angle from Pe = pm."""
    pmax = e * e * sn_base / x  # MW
    d0 = np.arcsin(pm / pmax)
    b_mw = sn_base * np.array([[-1.0 / x, 1.0 / x], [1.0 / x, -1.0 / x]])
    g_mw = np.zeros((2, 2))
    weight = np.full(2, 2.0 * h * sn)
    inv_m = np.full(2, F0 / (2.0 * h * sn))
    net = IslandNet(island=0, rows=np.array([0, 1]),
                    g_mw=g_mw, b_mw=b_mw, e_prime=np.full(2, e),
                    p_bias=np.zeros(2), inv_m=inv_m, weight=weight,
                    d_coeff=np.zeros(2))
    return net, d0, pmax


def _fleet(delta0, y):
    return types.SimpleNamespace(
        delta=np.array(delta0, float), omega=np.zeros(len(y)), y=np.array(y, float))


def _run(obs, fleet, f_island, dt=0.001, T=8.0):
    n = int(T / dt)
    trace = np.empty(n)
    for k in range(n):
        obs.step(int(dt * 1e6), fleet, f_island)
        trace[k] = fleet.delta[0] - fleet.delta[1]
    return trace


def test_inter_machine_mode_matches_analytic() -> None:
    net, d0, pmax = _two_machine_net()
    obs = AngleObserver(); obs.set_islands([net])
    fleet = _fleet([d0 + 0.02, 0.0], [50.0, -50.0])  # kick machine 0
    trace = _run(obs, fleet, np.array([F0]))
    sig = trace - trace.mean()
    up = np.where((sig[:-1] <= 0) & (sig[1:] > 0))[0]
    tc = np.array([(i + sig[i] / (sig[i] - sig[i + 1])) * 0.001 for i in up])
    f_num = 1.0 / np.mean(np.diff(tc))
    # closed form: wn^2 = 2pi K (inv_m1+inv_m2), K = pmax cos(d0) [MW/rad]
    k_mw = pmax * np.cos(d0)
    f_an = np.sqrt(2 * np.pi * k_mw * float(np.sum(net.inv_m))) / (2 * np.pi)
    assert abs(f_num - f_an) / f_an < 0.02


def test_coi_projection_holds_each_tick() -> None:
    net, d0, _ = _two_machine_net(h=4.0, sn=800.0)  # unequal weights vs another
    net2, _, _ = _two_machine_net()
    # one island, two machines of DIFFERENT inertia so the weighted mean bites
    net.weight = np.array([2 * 4.0 * 800.0, 2 * 6.0 * 1600.0])
    net.inv_m = np.array([F0 / net.weight[0], F0 / net.weight[1]])
    obs = AngleObserver(); obs.set_islands([net])
    fleet = _fleet([d0 + 0.05, -0.03], [50.0, -50.0])
    f_isl = np.array([F0 - 0.013])  # a non-zero island frequency deviation
    for _ in range(500):
        obs.step(10_000, fleet, f_isl)
        w = net.weight
        mean = float(np.sum(w * fleet.omega) / np.sum(w))
        assert abs(mean - (f_isl[0] - F0)) < 1e-12


def test_pole_slip_is_bounded() -> None:
    # a weak tie carrying a modest load, then an over-torque beyond the tie's
    # Pmax: machine 0 loses synchronism, but delta stays wrapped in (-pi, pi]
    # and omega clamped — never an unbounded float / NaN.
    net, d0, pmax = _two_machine_net(x=3.0, pm=10.0)  # Pmax ~40 MW, d0 valid
    obs = AngleObserver(); obs.set_islands([net])
    fleet = _fleet([d0, 0.0], [200.0, -50.0])  # p_m 200 >> Pmax -> slip
    _run(obs, fleet, np.array([F0]), T=10.0)
    assert np.all(np.isfinite(fleet.delta)) and np.all(np.isfinite(fleet.omega))
    assert np.all(np.abs(fleet.delta) <= np.pi + 1e-9)
    assert np.all(np.abs(fleet.omega - 0.0) <= 10.0 + 1e-9)


def test_disabled_observer_is_a_noop() -> None:
    obs = AngleObserver()  # no set_islands
    fleet = _fleet([0.1, -0.1], [10.0, -10.0])
    before = fleet.delta.copy()
    obs.step(10_000, fleet, np.array([F0]))
    assert np.array_equal(fleet.delta, before)
