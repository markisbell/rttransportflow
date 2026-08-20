"""Secondary control (PHYSICS §2.8, ledger 19): the PI restores frequency to
nominal after primary response has arrested it, distributes by participation
factor, respects the participating headroom (anti-windup), rides each unit's
own dispatch slew, and round-trips through the snapshot."""

from __future__ import annotations

import numpy as np
import pytest

from rttransportflow.dynamics import F0, s_to_us
from rttransportflow.dynamics.events import Event
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator

from tests.helpers.dyn import make_island


def island(participants: list[dict] | None = None, p_l0: float = 4000.0):
    """4 x 1500 MW units at 1000 MW each; aFRR bands as given."""
    specs = []
    for i in range(4):
        spec = {
            "id": f"g{i}", "island": 0, "s_n": 1667.0, "h": 5.0, "r": 0.05,
            "db": 0.010, "fcr_band": 75.0, "p_max": 1500.0, "p_min": 0.0,
            "t_g": 0.2, "t_ch": 0.4, "t_rh": 8.0, "f_hp": 0.3,
            "ramp_mw_s": 25.0, "p_set": p_l0 / 4.0,
        }
        if participants is not None:
            spec.update(participants[i])
        else:
            spec["afrr_band"] = 150.0
            spec["agc_part"] = 150.0
        specs.append(spec)
    fleet = make_fleet(specs)
    fleet.init_steady_state()
    integ = Integrator(fleet, make_island(p_l0))
    integ.defense_enabled = False  # isolate the control loop (AGC stays ON)
    return fleet, integ


def test_agc_restores_frequency_after_a_load_step():
    """Droop alone leaves a STANDING offset; secondary control walks it out.
    That difference is the whole point of the layer."""
    fleet, integ = island()
    integ.queue.schedule(Event(s_to_us(5.0), "load_step", "step",
                               {"island": 0, "delta_mw": 200.0}))
    integ.advance(s_to_us(30.0), interrupt_on_event=False)
    f_primary = float(integ.islands.f[0])
    assert f_primary < 49.99  # primary arrests, but below nominal
    integ.advance(s_to_us(600.0), interrupt_on_event=False)
    assert float(integ.islands.f[0]) == pytest.approx(F0, abs=0.005)

    # same disturbance, AGC off: the offset PERSISTS
    fleet2, integ2 = island()
    integ2.agc_enabled = False
    integ2.queue.schedule(Event(s_to_us(5.0), "load_step", "step",
                                {"island": 0, "delta_mw": 200.0}))
    integ2.advance(s_to_us(630.0), interrupt_on_event=False)
    assert float(integ2.islands.f[0]) < 49.99


def test_agc_splits_by_participation_factor():
    fleet, integ = island(participants=[
        {"afrr_band": 300.0, "agc_part": 300.0},  # carries 3/4
        {"afrr_band": 100.0, "agc_part": 100.0},  # carries 1/4
        {"afrr_band": 0.0, "agc_part": 0.0},      # contracted out
        {"afrr_band": 0.0, "agc_part": 0.0},
    ])
    p0 = fleet.p_disp.copy()
    integ.queue.schedule(Event(s_to_us(5.0), "load_step", "step",
                               {"island": 0, "delta_mw": 200.0}))
    integ.advance(s_to_us(600.0), interrupt_on_event=False)
    delta = fleet.p_disp - p0
    assert delta[0] > delta[1] > 1.0
    assert delta[0] == pytest.approx(3.0 * delta[1], rel=0.15)
    # non-participants stay on schedule (droop still moves y, not p_disp)
    assert delta[2] == pytest.approx(0.0, abs=1e-6)
    assert delta[3] == pytest.approx(0.0, abs=1e-6)


def test_agc_anti_windup_at_the_contracted_band():
    """A deficit larger than the whole aFRR stack must not wind the integral
    up forever — the command rails at the participating headroom."""
    fleet, integ = island(participants=[{"afrr_band": 50.0, "agc_part": 50.0}] * 4)
    integ.queue.schedule(Event(s_to_us(5.0), "load_step", "step",
                               {"island": 0, "delta_mw": 2000.0}))
    integ.advance(s_to_us(900.0), interrupt_on_event=False)
    assert float(integ.agc_mw[0]) <= 4 * 50.0 + 1e-6  # railed at the band
    integral_after = float(integ.agc_int[0])
    integ.advance(s_to_us(900.0), interrupt_on_event=False)
    assert float(integ.agc_int[0]) == pytest.approx(integral_after, rel=1e-9)


def test_agc_is_only_as_fast_as_the_fleet():
    """PHYSICS §2.8: the command rides each unit's dispatch slew, so a
    sluggish fleet restores visibly slower — a felt lesson, not a constant."""
    def restore_time(ramp_mw_s: float) -> float:
        fleet, integ = island(participants=[
            {"afrr_band": 400.0, "agc_part": 400.0, "ramp_mw_s": ramp_mw_s}] * 4)
        integ.queue.schedule(Event(s_to_us(5.0), "load_step", "step",
                                   {"island": 0, "delta_mw": 600.0}))
        integ.advance(s_to_us(15.0), interrupt_on_event=False)  # past the dip
        assert abs(float(integ.islands.f[0]) - F0) > 0.005
        for _ in range(600):
            integ.advance(s_to_us(2.0), interrupt_on_event=False)
            if abs(float(integ.islands.f[0]) - F0) < 0.005:
                return integ.t_us / 1e6
        return 1e9

    quick = restore_time(25.0)      # OCGT/hydro-class movers
    sluggish = restore_time(0.05)   # a fleet that can barely move
    assert quick < sluggish
    assert quick < 15 * 60.0  # CE design: full restoration within 15 min


def test_agc_state_round_trips():
    fleet, integ = island()
    integ.queue.schedule(Event(s_to_us(5.0), "load_step", "step",
                               {"island": 0, "delta_mw": 200.0}))
    integ.advance(s_to_us(120.0), interrupt_on_event=False)
    blob = integ.state_dict()
    assert abs(float(integ.agc_int[0])) > 0.0

    fleet2, twin = island()
    twin.restore_state(blob)
    assert float(twin.agc_int[0]) == float(integ.agc_int[0])
    assert float(twin.agc_mw[0]) == float(integ.agc_mw[0])
    a = integ.advance(s_to_us(60.0), interrupt_on_event=False)
    b = twin.advance(s_to_us(60.0), interrupt_on_event=False)
    assert float(a.f_end[0]) == float(b.f_end[0])


def test_blacked_out_island_takes_no_agc():
    fleet, integ = island()
    for i in range(4):
        integ.queue.schedule(Event(s_to_us(1.0 + 0.1 * i), "trip", f"g{i}"))
    integ.advance(s_to_us(60.0), interrupt_on_event=False)
    assert bool(integ.islands.blackout()[0])
    assert float(integ.agc_mw[0]) == 0.0
