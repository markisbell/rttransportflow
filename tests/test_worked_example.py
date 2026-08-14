"""PARAMETERS §2.3 worked example as a known-answer test (±2 % pins).

Setup: 150 GW island (rotating MVA ≈ load), 3 GW EXOGENOUS H = 0 infeed loss
(the surviving 150 GVA fleet is untouched — ledger 28), load damping
1500 MW/Hz (= 1 %/Hz), FCR 3000 MW with gain 15 GW/Hz through an aggregate
8 s turbine lag, deadband ±10 mHz. Battery variant: +1 GW GFL BESS
(K = 5 GW/Hz, T = 0.1 s, db ±10 mHz).
"""

from __future__ import annotations

import numpy as np
import pytest

from rttransportflow.dynamics import F0, US, s_to_us
from rttransportflow.dynamics.events import Event
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator, IslandState

S_SYS = 150_000.0  # MVA
LOAD = 150_000.0  # MW
TRIP = 3_000.0  # MW exogenous infeed


def build_case(h_sys: float, fcr_mw: float, battery_gw: float = 0.0) -> Integrator:
    sync = [{
        "id": "agg", "island": 0, "s_n": S_SYS, "h": h_sys,
        "r": S_SYS / (15_000.0 * F0),  # gain 15 GW/Hz on the 150 GVA base
        "db": 0.010, "fcr_band": fcr_mw,
        "p_max": np.inf, "p_min": 0.0, "ramp_mw_s": np.inf,
        # aggregate single 8 s turbine lag: instant servo, T_CH = 8, no reheat
        "t_g": 1e-6, "t_ch": 8.0, "t_rh": 8.0, "f_hp": 1.0,
        "p_set": LOAD - TRIP,
    }]
    inverters = [{"id": "infeed", "island": 0, "p_rated": TRIP, "avail": TRIP,
                  "t_up": 1e-6, "t_down": 1e-6}]
    batteries = []
    if battery_gw:
        batteries = [{"id": "bess", "island": 0, "p_max": battery_gw * 1000.0,
                      "e_mwh": 1e6, "k_f": 5_000.0, "db": 0.010, "t_b": 0.1,
                      "soc_frac": 0.55, "quiet_hz": 0.0}]  # recharge off
    fleet = make_fleet(sync, inverters=inverters, batteries=batteries)
    fleet.init_steady_state()
    islands = IslandState(
        f=np.array([F0]), e_k=np.zeros(1), p_l0=np.array([LOAD]),
        w=np.ones(1), p_loss=np.zeros(1),
        d_pu=0.5,  # 1 %/Hz on 150 GW = 1500 MW/Hz
    )
    integ = Integrator(fleet, islands)
    integ.defense_enabled = False  # §2.3 pins are PRE-shed numbers (fixture rule)
    integ.agc_enabled = False  # droop-only pins (PHYSICS §6)
    return integ


def run_case(h_sys: float, fcr_mw: float, battery_gw: float = 0.0) -> dict:
    integ = build_case(h_sys, fcr_mw, battery_gw)
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "infeed"))
    integ.advance(s_to_us(1.0), interrupt_on_event=False)
    f_before = float(integ.islands.f[0])
    integ.advance(10_000, interrupt_on_event=False)
    rocof = (float(integ.islands.f[0]) - f_before) / 0.010
    integ.advance(s_to_us(60.0) - integ.t_us + s_to_us(1.0), interrupt_on_event=False)
    while integ.t_us < s_to_us(61.0):
        integ.advance(s_to_us(61.0) - integ.t_us, interrupt_on_event=False)
    t, f = integ.rings[0]._ordered()
    idx = int(np.argmin(f))
    alarm = t[np.argmax(f < 49.8)] / US - 1.0 if (f < 49.8).any() else None
    return {
        "rocof": rocof,
        "nadir": float(f[idx]),
        "t_nadir": t[idx] / US - 1.0,  # relative to the trip
        "f60": float(f[np.searchsorted(t, s_to_us(61.0)) - 1]),
        "alarm_s": alarm,
    }


CASES = [
    # (h_sys, fcr, battery_gw, rocof_pin, nadir_pin, t_nadir_pin, f60_pin)
    (5.0, 3000.0, 0.0, -0.100, 49.50, 12.3, 49.80),
    (2.0, 3000.0, 0.0, -0.250, 49.22, 8.0, 49.81),
    (2.0, 3000.0, 1.0, -0.250, 49.57, 5.3, 49.85),
    (5.0, 3000.0, 1.0, -0.100, 49.72, 7.3, 49.85),
    (1.5, 1500.0, 0.0, -0.333, 48.77, 12.1, None),  # "renewable weekend"
]


@pytest.mark.parametrize("h_sys,fcr,bat,rocof_pin,nadir_pin,t_pin,f60_pin", CASES)
def test_worked_example_row(h_sys, fcr, bat, rocof_pin, nadir_pin, t_pin, f60_pin) -> None:
    out = run_case(h_sys, fcr, bat)
    # The documented ±2 % pins: RoCoF and nadir DEPTH.
    assert out["rocof"] == pytest.approx(rocof_pin, rel=0.02)
    assert (F0 - out["nadir"]) == pytest.approx(F0 - nadir_pin, rel=0.02)
    # Informational pins, held loosely.
    assert out["t_nadir"] == pytest.approx(t_pin, rel=0.15)
    if f60_pin is not None:
        assert out["f60"] == pytest.approx(f60_pin, abs=0.03)


def test_lessons_of_the_table() -> None:
    """The intended lessons hold as orderings (GAME_DESIGN §4 core)."""
    h5 = run_case(5.0, 3000.0)
    h2 = run_case(2.0, 3000.0)
    h2b = run_case(2.0, 3000.0, battery_gw=1.0)
    # Cutting inertia 5 s -> 2 s multiplies RoCoF x2.5 ...
    assert h2["rocof"] / h5["rocof"] == pytest.approx(2.5, rel=0.02)
    # ... and deepens the nadir; the battery recovers nadir WITHOUT touching RoCoF.
    assert h2["nadir"] < h5["nadir"]
    assert h2b["nadir"] > h2["nadir"] + 0.3
    assert h2b["rocof"] == pytest.approx(h2["rocof"], rel=0.02)
