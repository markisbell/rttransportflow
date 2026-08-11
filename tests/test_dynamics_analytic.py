"""PHYSICS §6 analytic validation — the P2 gate.

Fixture: 4 machines × 2500 MVA, H = 5 s, R = 0.05 (machine base), T_g = 0.2,
T_CH = 0.4, no reheat stage (F_HP = 1), load 8000 MW, D = 1.0 pu (fixture
value = 2 %/Hz), no deadband, losses 0, AGC off, ALL CLAMPS DISABLED;
trip unit 1 (2000 MW) at t = 1 s. E_k in the RoCoF form is the POST-trip
fleet: 3 × 2500 × 5 = 37 500 MJ.
"""

from __future__ import annotations

import math

import numpy as np
import pytest

from rttransportflow.dynamics import F0, US, s_to_us
from rttransportflow.dynamics.events import Event
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator, IslandState


def make_fixture(h: float = 5.0, n_machines: int = 4, s_n: float = 2500.0,
                 load_mw: float = 8000.0, d_pu: float = 1.0) -> Integrator:
    p_each = load_mw / n_machines
    sync = [
        {
            "id": f"g{i}", "island": 0, "s_n": s_n, "h": h, "r": 0.05,
            "db": 0.0, "fcr_band": np.inf, "p_max": np.inf, "p_min": 0.0,
            "t_g": 0.2, "t_ch": 0.4, "t_rh": 8.0, "f_hp": 1.0,
            "ramp_mw_s": np.inf, "p_set": p_each,
        }
        for i in range(n_machines)
    ]
    fleet = make_fleet(sync)
    fleet.init_steady_state()
    islands = IslandState(
        f=np.array([F0]), e_k=np.zeros(1), p_l0=np.array([load_mw]),
        w=np.ones(1), p_loss=np.zeros(1), d_pu=d_pu,
    )
    integrator = Integrator(fleet, islands)
    # the §6 pins predate the P8 defense layer and run with it OFF (the
    # fixture family's "clamps disabled" rule)
    integrator.defense_enabled = False
    return integrator


def run_trip(integ: Integrator, until_s: float = 60.0) -> dict:
    """Trip g0 at t=1 s; integrate to `until_s`; return trace of (t, f)."""
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
    ts: list[float] = []
    fs: list[float] = []
    target = s_to_us(until_s)
    while integ.t_us < target:
        res = integ.advance(target - integ.t_us, interrupt_on_event=False)
        traj = res.trajectory
        base = (integ.t_us - res.dt_done_us) / US
        ts.extend(base + t for t in traj["t_rel_s"])
        fs.extend(traj["islands"]["0"]["f"])
    return {"t": np.array(ts), "f": np.array(fs), "integ": integ}


def test_rocof_first_tick_analytic() -> None:
    integ = make_fixture()
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
    integ.advance(s_to_us(1.0), interrupt_on_event=False)  # lands exactly on the trip
    f_before = float(integ.islands.f[0])
    assert f_before == pytest.approx(F0, abs=1e-9)  # steady until the trip
    integ.advance(10_000, interrupt_on_event=False)  # one ALERT tick
    rocof = (float(integ.islands.f[0]) - f_before) / 0.010
    analytic = -2000.0 * F0 / (2.0 * 37_500.0)  # post-trip E_k
    assert rocof == pytest.approx(analytic, rel=5e-3)  # tol 0.5 %
    assert rocof == pytest.approx(-1.3319, abs=2e-3)  # engine-design pin


def test_rocof_proportional_to_inverse_inertia() -> None:
    inv_ek, rocofs = [], []
    for scale in (0.5, 1.0, 2.0):
        integ = make_fixture(h=5.0 * scale)
        integ.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
        integ.advance(s_to_us(1.0), interrupt_on_event=False)
        f_before = float(integ.islands.f[0])
        integ.advance(10_000, interrupt_on_event=False)
        rocofs.append((float(integ.islands.f[0]) - f_before) / 0.010)
        inv_ek.append(1.0 / (3 * 2500.0 * 5.0 * scale))
    r = np.corrcoef(inv_ek, rocofs)[0, 1]
    assert r**2 > 0.999


def test_qss_analytic() -> None:
    out = run_trip(make_fixture(), until_s=60.0)
    f_end = float(out["integ"].islands.f[0])
    k_sum = 3 * 2500.0 / (0.05 * F0)  # surviving droop gain 3000 MW/Hz
    d_gain = 1.0 * 8000.0 / F0  # damping 160 MW/Hz
    analytic = F0 - 2000.0 / (k_sum + d_gain)
    assert f_end == pytest.approx(analytic, rel=1e-3)
    assert f_end - F0 == pytest.approx(-0.63291, abs=1e-3)  # engine-design pin


def test_nadir_regression_pin() -> None:
    out = run_trip(make_fixture(), until_s=12.0)
    idx = int(np.argmin(out["f"]))
    nadir = float(out["f"][idx])
    t_nadir = float(out["t"][idx])
    # Engine-design reference: 49.086 Hz at ~2.15 s (tol 10 mHz).
    assert nadir == pytest.approx(49.086, abs=0.010)
    assert t_nadir == pytest.approx(2.15, abs=0.25)


def test_nadir_inertia_sweep_monotone() -> None:
    nadirs, t_nadirs = [], []
    for h in (2.0, 3.0, 4.0, 5.0, 6.0, 8.0):
        out = run_trip(make_fixture(h=h), until_s=15.0)
        idx = int(np.argmin(out["f"]))
        nadirs.append(float(out["f"][idx]))
        t_nadirs.append(float(out["t"][idx]))
    # Lower inertia => strictly deeper nadir and earlier nadir time.
    assert all(a < b for a, b in zip(nadirs, nadirs[1:]))
    assert all(a <= b for a, b in zip(t_nadirs, t_nadirs[1:]))


def test_energy_balance_identity() -> None:
    out = run_trip(make_fixture(), until_s=30.0)
    err = out["integ"].balance_err()
    assert err <= 0.01  # PHYSICS §6.12 bound; semi-implicit pairing keeps it ~0
    assert err <= 1e-9  # our discretization satisfies the identity exactly


def test_exact_lag_recursion_pin() -> None:
    """Per-stage exponential update vs its own closed form (tol 1e-9)."""
    t_lag, dt, u, x0 = 0.4, 0.01, 1.0, 0.0
    a = math.exp(-dt / t_lag)
    x = x0
    for k in range(1, 301):
        x = u + (x - u) * a
        closed = u + (x0 - u) * math.exp(-k * dt / t_lag)
        assert abs(x - closed) < 1e-9
    # Stability at dt = 5 T: no overshoot, monotone approach.
    a5 = math.exp(-5.0)
    x, prev = x0, x0
    for _ in range(10):
        x = u + (x - u) * a5
        assert prev <= x <= u + 1e-12
        prev = x


def test_mode_controller_transitions() -> None:
    integ = make_fixture()
    assert integ.mode == "calm"
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
    integ.advance(s_to_us(2.0), interrupt_on_event=False)
    assert integ.mode == "alert"  # the trip forces ALERT
    # QSS offset (-0.63 Hz) far exceeds the calm threshold — stays ALERT.
    integ.advance(s_to_us(60.0), interrupt_on_event=False)
    assert integ.mode == "alert"


def test_total_source_loss_freezes_frequency_no_nan() -> None:
    """E_k = 0 (every source tripped) is a blackout: frequency FREEZES —
    the engine must never emit NaN (a collapsing player build nulled the
    wire and crashed the game client; found in P5)."""
    integ = make_fixture()
    for i in range(4):
        integ.queue.schedule(Event(s_to_us(1.0), "trip", f"g{i}"))
    integ.advance(s_to_us(30.0), interrupt_on_event=False)
    f_end = float(integ.islands.f[0])
    assert np.isfinite(f_end)
    assert integ.islands.e_k[0] == 0.0
    assert bool(integ.islands.blackout()[0]) is True
    f_frozen = float(integ.islands.f[0])
    integ.advance(s_to_us(30.0), interrupt_on_event=False)
    assert float(integ.islands.f[0]) == f_frozen  # frozen, still finite
