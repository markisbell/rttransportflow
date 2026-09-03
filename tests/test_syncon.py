"""C6/D4 — the synchronous condenser (PARAMETERS §1.15): spinning mass
and voltage support with no prime mover. Pins: inertia physics (RoCoF
improves, strictly, by the H·S_n the machine adds), governor silence
(zero droop output at any excursion), the station-service draw, the
catalog/schema contract, and snapshot round-trip."""

from __future__ import annotations

import numpy as np
import pytest

from rttransportflow.dynamics import F0, s_to_us
from rttransportflow.dynamics.events import Event
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator
from rttransportflow.dynamics.plant_types import (
    CatalogError,
    load_catalog,
    sync_spec,
)
from tests.helpers.dyn import make_island

GAS = {"id": "g1", "island": 0, "s_n": 10_000.0, "h": 4.0, "r": 0.05,
       "db": 0.010, "fcr_band": 200.0, "p_max": 9000.0, "p_min": 0.0,
       "t_g": 0.5, "t_ch": 1e-3, "t_rh": 1e9, "f_hp": 1.0,
       "ramp_mw_s": np.inf, "p_set": 5000.0}


def _syncon_spec(sn: float = 300.0) -> dict:
    cat = load_catalog()
    return sync_spec("syncon", cat["kinds"]["syncon"], device_id="sc1",
                     island=0, p_max_mw=0.0, p_min_mw=0.0, p_set_mw=0.0,
                     sn_mva=sn)


def test_catalog_spec_carries_the_115_numbers() -> None:
    spec = _syncon_spec(300.0)
    assert spec["s_n"] == 300.0
    assert spec["h"] == pytest.approx(3.0)
    assert spec["fcr_band"] == 0.0
    assert spec["p_max"] == 0.0
    assert spec["aux_mw"] == pytest.approx(3.0)  # 1 % S_n


def test_syncon_without_rating_is_refused() -> None:
    cat = load_catalog()
    with pytest.raises(CatalogError):
        sync_spec("syncon", cat["kinds"]["syncon"], device_id="sc1",
                  island=0, p_max_mw=0.0, p_min_mw=0.0, p_set_mw=0.0)


def _rocof_first_tick(with_syncon: bool) -> float:
    sync = [dict(GAS)]
    if with_syncon:
        sync.append(_syncon_spec(1000.0))
    fleet = make_fleet(sync)
    fleet.init_steady_state()
    islands = make_island(5000.0)
    integ = Integrator(fleet, islands)
    integ.queue.schedule(Event(s_to_us(0.01), "load_step", "loss",
                               {"island": 0, "delta_mw": 1000.0}))
    res = integ.advance(s_to_us(0.05), interrupt_on_event=False)
    return float(res.rocof_max[0])


def test_rocof_improves_by_the_added_inertia() -> None:
    without = _rocof_first_tick(False)
    with_sc = _rocof_first_tick(True)
    assert abs(with_sc) < abs(without)
    # RoCoF ∝ 1/E_k: gas 4·10000 = 40 GJ·s-class, syncon adds 3·1000
    ratio = abs(without) / abs(with_sc)
    expected = (4.0 * 10_000.0 + 3.0 * 1000.0) / (4.0 * 10_000.0)
    assert ratio == pytest.approx(expected, rel=0.05)


def test_governor_stays_silent_and_aux_draws() -> None:
    fleet = make_fleet([dict(GAS), _syncon_spec(300.0)])
    fleet.init_steady_state()
    islands = make_island(5000.0)
    integ = Integrator(fleet, islands)
    # a big off-nominal excursion drives every governor hard
    integ.queue.schedule(Event(s_to_us(0.01), "load_step", "loss",
                               {"island": 0, "delta_mw": 3000.0}))
    integ.advance(s_to_us(10.0), interrupt_on_event=False)
    assert float(integ.islands.f[0]) < 49.95  # the loss is felt
    # yet the syncon's chain never produced a watt — no prime mover
    assert float(fleet.y[1]) == pytest.approx(0.0, abs=1e-9)
    # the station load is in the ledger: the syncon row draws 3 MW (1 % S_n)
    assert float(fleet.sync_aux_mw[1]) == pytest.approx(3.0)


def test_syncon_snapshot_round_trip() -> None:
    fleet = make_fleet([dict(GAS), _syncon_spec(300.0)])
    fleet.init_steady_state()
    islands = make_island(5000.0)
    integ = Integrator(fleet, islands)
    integ.advance(s_to_us(5.0), interrupt_on_event=False)
    blob = integ.state_dict()
    fleet2 = make_fleet([dict(GAS), _syncon_spec(300.0)])
    fleet2.init_steady_state()
    integ2 = Integrator(fleet2, make_island(5000.0))
    integ2.restore_state(blob)
    integ.advance(s_to_us(5.0), interrupt_on_event=False)
    integ2.advance(s_to_us(5.0), interrupt_on_event=False)
    assert float(integ.islands.f[0]) == float(integ2.islands.f[0])


def test_e_k_tracks_syncon_online_state() -> None:
    fleet = make_fleet([dict(GAS), _syncon_spec(500.0)])
    fleet.init_steady_state()
    e_with = float(fleet.e_k_per_island(1)[0])
    fleet.trip("sc1", 0)
    e_without = float(fleet.e_k_per_island(1)[0])
    assert e_with - e_without == pytest.approx(3.0 * 500.0)  # H·S_n
