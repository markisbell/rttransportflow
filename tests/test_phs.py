"""P8 PHS pump mode (PARAMETERS §1.10): reservoir SoC, pump-as-load,
energy bounds, the 49.7 Hz automatic pump shed, and the wire path."""

from __future__ import annotations

import numpy as np
import pytest

from rttransportflow.dynamics import F0, s_to_us
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator
from rttransportflow.dynamics.plant_types import load_catalog, sync_spec

from tests.helpers.dyn import make_island, pin_mode


def phs_island(pump_mw: float = 0.0, soc_frac: float = 0.5,
               p_l0: float = 1000.0):
    catalog = load_catalog("data/catalogs/plant_types.json")["kinds"]
    specs = [
        sync_spec("gas_ccgt", catalog["gas_ccgt"], device_id="g", island=0,
                  p_max_mw=2000.0, p_min_mw=0.0, p_set_mw=p_l0 + pump_mw),
        sync_spec("hydro_ps", catalog["hydro_ps"], device_id="phs", island=0,
                  p_max_mw=300.0, p_min_mw=0.0, p_set_mw=0.0),
    ]
    specs[1]["soc_frac"] = soc_frac
    fleet = make_fleet(specs)
    fleet.init_steady_state()
    fleet.hy_pump_set[1] = pump_mw
    integ = pin_mode(Integrator(fleet, make_island(p_l0)))
    return fleet, integ


def test_pumping_charges_the_reservoir_at_eta():
    fleet, integ = phs_island(pump_mw=300.0)
    soc0 = float(fleet.hy_soc_mwh[1])
    integ.advance(s_to_us(1800.0), interrupt_on_event=False)
    stored = float(fleet.hy_soc_mwh[1]) - soc0
    # the pump ramps in at the unit's 1.5 MW/s (motor start ~3.3 min):
    # ∫pump dt = 300*1800 − 300*200/2 = 141.7 MWh drawn, ×0.88 stored
    assert float(fleet.pump_energy_mwh[1]) == pytest.approx(141.7, rel=0.03)
    assert stored == pytest.approx(141.7 * 0.88, rel=0.03)


def test_generation_drains_at_eta_and_stops_empty():
    fleet, integ = phs_island(soc_frac=0.02)  # 48 MWh in a 2400 MWh pond
    fleet.p_set[1] = 300.0
    fleet.p_set[0] = 700.0  # gas covers the rest of the 1000 MW load
    integ.advance(s_to_us(1800.0), interrupt_on_event=False)
    # 48 MWh * 0.90 = 43.2 MWh of delivery, then the pond is dry
    assert float(fleet.hy_soc_mwh[1]) == pytest.approx(0.0, abs=1.0)
    assert float(fleet.y[1]) == pytest.approx(0.0, abs=1.0)


def test_pump_is_island_load():
    fleet, integ = phs_island(pump_mw=300.0)
    res = integ.advance(s_to_us(400.0), interrupt_on_event=False)
    # after the ~200 s motor ramp: gas p_set 1300 balances load 1000 + pump
    assert abs(float(res.f_end[0]) - F0) < 0.1
    assert float(fleet.hy_pump_p[1]) == pytest.approx(300.0, rel=0.02)


def test_pump_shed_at_49_7():
    fleet, integ = phs_island(pump_mw=300.0)
    integ.defense_enabled = True
    integ.advance(s_to_us(300.0), interrupt_on_event=False)  # pump fully in
    # drop 800 MW of generation: the island sags through 49.7
    from rttransportflow.dynamics.events import Event
    integ.queue.schedule(Event(integ.t_us + s_to_us(1.0), "load_step", "shock",
                               {"island": 0, "delta_mw": 800.0}))
    res = integ.advance(s_to_us(30.0), interrupt_on_event=False)
    shed = [e for e in res.events if e.kind == "pump_shed"]
    assert shed and shed[0].data["shed_mw"] > 250.0
    assert float(fleet.hy_pump_set[1]) == 0.0
    assert bool(integ.defense.pump_latched[0])
    # dispatcher re-commands are overridden while latched
    fleet.hy_pump_set[1] = 300.0
    integ.advance(s_to_us(5.0), interrupt_on_event=False)
    assert float(fleet.hy_pump_set[1]) == 0.0
