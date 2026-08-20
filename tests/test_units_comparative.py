"""PHYSICS §6.14 / ROADMAP P3 gate: the same 1 GW infeed loss against three
fleets — each plant mix *feels* different, pinned numerically.

Fleets serve a 40 GW island; a 1 GW exogenous H=0 infeed trips at t = 1 s.
(a) gas-heavy: 20×CCGT 1600 + 8×OCGT 1000 — fast governors, mid inertia
(b) nuclear-heavy: 25×nuclear 1600 — highest inertia, tiny FCR band, glacial reheat
(c) renewables+battery: 5×CCGT + 31 GW inverter wind/PV + 2 GW GFL BESS —
    lowest inertia (highest RoCoF) but the fastest-acting arrest
"""

from __future__ import annotations

import numpy as np
import pytest

from rttransportflow.dynamics import F0, US, s_to_us
from rttransportflow.dynamics.events import Event
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator
from rttransportflow.dynamics.plant_types import (
    battery_spec,
    inverter_spec,
    load_catalog,
    sync_spec,
)

from tests.helpers.dyn import make_island, pin_mode

CATALOG = load_catalog()["kinds"]
LOAD = 40_000.0
TRIP = 1_000.0


def _syncs(kind: str, n: int, p_max: float, p_set: float) -> list[dict]:
    return [
        sync_spec(kind, CATALOG[kind], device_id=f"{kind}{i}", island=0,
                  p_max_mw=p_max, p_min_mw=0.0, p_set_mw=p_set)
        for i in range(n)
    ]


def build_fleet(which: str):
    infeed = [{"id": "infeed", "island": 0, "p_rated": TRIP, "avail": TRIP,
               "t_up": 1e-6, "t_down": 1e-6}]
    if which == "gas":
        # 22 × 1600 CCGT @ 1450 + 8 × 1000 OCGT @ 887.5 = 39 000 MW — dispatch
        # leaves ≥ the FCR band as headroom (no envelope clamp on primary
        # response; head-roomless dispatch was a real found failure mode).
        sync = _syncs("gas_ccgt", 22, 1600.0, 1450.0) + _syncs("gas_ocgt", 8, 1000.0, 887.5)
        fleet = make_fleet(sync, inverters=infeed)
    elif which == "nuclear":
        sync = _syncs("nuclear", 25, 1600.0, 1560.0)
        fleet = make_fleet(sync, inverters=infeed)
    elif which == "renewables":
        sync = _syncs("gas_ccgt", 5, 1600.0, 1400.0)
        wind = inverter_spec("wind_offshore", CATALOG["wind_offshore"],
                             device_id="wind", island=0,
                             p_rated_mw=24_000.0, avail_mw=24_000.0)
        pv = inverter_spec("solar_pv", CATALOG["solar_pv"], device_id="pv",
                           island=0, p_rated_mw=8_000.0, avail_mw=8_000.0)
        bess = battery_spec("battery", CATALOG["battery"], device_id="bess",
                            island=0, p_max_mw=2_000.0, e_mwh=4_000.0)
        fleet = make_fleet(sync, inverters=[wind, pv] + infeed, batteries=[bess])
    else:
        raise ValueError(which)
    fleet.init_steady_state()
    return fleet


def run(which: str) -> dict:
    fleet = build_fleet(which)
    # comparative pins predate the defense layer: droop-only pin mode
    integ = pin_mode(Integrator(fleet, make_island(LOAD)))
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "infeed"))
    integ.advance(s_to_us(1.0), interrupt_on_event=False)
    f_before = float(integ.islands.f[0])
    soc0 = float(fleet.bat_soc[0]) if len(fleet.bat_ids) else None
    integ.advance(10_000, interrupt_on_event=False)
    rocof = (float(integ.islands.f[0]) - f_before) / 0.010
    while integ.t_us < s_to_us(61.0):
        integ.advance(s_to_us(61.0) - integ.t_us, interrupt_on_event=False)
    t, f = integ.rings[0]._ordered()
    idx = int(np.argmin(f))
    return {
        "e_k": float(integ.islands.e_k[0]),
        "rocof": rocof,
        "nadir": float(f[idx]),
        "t_nadir": t[idx] / US - 1.0,
        "f_end": float(integ.islands.f[0]),
        "soc_delta": (float(fleet.bat_soc[0]) - soc0) if soc0 is not None else None,
    }


@pytest.fixture(scope="module")
def results() -> dict[str, dict]:
    return {which: run(which) for which in ("gas", "nuclear", "renewables")}


def test_inertia_ordering_drives_rocof(results) -> None:
    r = results
    assert r["nuclear"]["e_k"] > r["gas"]["e_k"] > r["renewables"]["e_k"]
    assert abs(r["renewables"]["rocof"]) > abs(r["gas"]["rocof"]) > abs(r["nuclear"]["rocof"])
    # RoCoF matches the analytic identity per fleet (post-trip fleets unchanged).
    for which in ("gas", "nuclear", "renewables"):
        analytic = -TRIP * F0 / (2.0 * r[which]["e_k"])
        assert r[which]["rocof"] == pytest.approx(analytic, rel=0.03)


def test_gas_arrests_faster_than_nuclear(results) -> None:
    """(a) vs (b): the gas fleet's governors catch the fall sooner and
    shallower despite LESS inertia — response speed beats mass here."""
    assert results["gas"]["nadir"] > results["nuclear"]["nadir"]
    assert results["gas"]["t_nadir"] < results["nuclear"]["t_nadir"]
    assert results["gas"]["f_end"] > results["nuclear"]["f_end"]


def test_renewables_fleet_highest_rocof_fastest_arrest(results) -> None:
    """(c): worst RoCoF (5× the gas fleet), but the battery slams the fall
    shut fastest of all — and pays in SoC."""
    r = results["renewables"]
    assert abs(r["rocof"]) > 4.0 * abs(results["gas"]["rocof"])
    assert r["t_nadir"] < results["gas"]["t_nadir"]
    assert r["nadir"] > results["nuclear"]["nadir"]  # battery beats slow steam
    assert r["soc_delta"] < -1.0  # SoC visibly draining (MWh)


def test_comparative_regression_pins(results) -> None:
    """Numeric regression pins (captured 2026-08-10; abs 2 mHz / rel 1e-3)."""
    r = results
    pins = {
        "gas": {"rocof": -0.12329, "nadir": 49.86618},
        "nuclear": {"rocof": -0.09371, "nadir": 49.45234},
        "renewables": {"rocof": -0.62344, "nadir": 49.88327},
    }
    for which, pin in pins.items():
        assert r[which]["rocof"] == pytest.approx(pin["rocof"], abs=0.002)
        assert r[which]["nadir"] == pytest.approx(pin["nadir"], abs=0.002)
