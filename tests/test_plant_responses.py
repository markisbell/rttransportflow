"""Per-kind model behavior: step responses, hydro NMP, battery FFR/GFM,
electrolyzer shed, LFSM-O, start sequences, fuel meters, catalog validity."""

from __future__ import annotations

import numpy as np
import pytest

from rttransportflow.dynamics import F0, US, s_to_us
from rttransportflow.dynamics.events import Event
from rttransportflow.dynamics.fleet import ONLINE, STARTING, make_fleet
from rttransportflow.dynamics.integrator import Integrator, IslandState
from rttransportflow.dynamics.plant_types import (
    CatalogError,
    load_catalog,
    sync_spec,
)

CATALOG = load_catalog()["kinds"]


def hold_f(fleet, f_hz: float, seconds: float, dt_us: int = 10_000):
    """Drive fleet ticks at a FIXED frequency (no swing) and return y traces."""
    f = np.array([f_hz])
    n = int(seconds * US) // dt_us
    trace = []
    for _ in range(n):
        fleet.tick(dt_us, f, 1)
        trace.append(fleet.y.copy() if fleet.n_sync else None)
    return trace


# --- catalog -----------------------------------------------------------


def test_catalog_loads_and_requires_rationales(tmp_path) -> None:
    import json
    from pathlib import Path

    doc = load_catalog()
    assert set(doc["kinds"]) >= {"nuclear", "coal", "lignite", "gas_ccgt",
                                 "gas_ocgt", "hydro_ps", "wind_onshore",
                                 "wind_offshore", "solar_pv", "battery",
                                 "battery_gfm", "electrolyzer"}
    broken = json.loads(Path("data/catalogs/plant_types.json").read_text())
    del broken["kinds"]["coal"]["rationale"]
    p = tmp_path / "broken.json"
    p.write_text(json.dumps(broken))
    with pytest.raises(CatalogError, match="rationale"):
        load_catalog(p)


# --- turbine step responses (regression pins per kind) ------------------


def step_response(kind: str, seconds: float = 30.0) -> np.ndarray:
    """+100 MW dispatch step on a 1000 MW unit at t=0; y(t) at 10 ms."""
    spec = sync_spec(kind, CATALOG[kind], device_id="u", island=0,
                     p_max_mw=1000.0, p_min_mw=0.0, p_set_mw=500.0)
    spec["ramp_mw_s"] = np.inf  # isolate the turbine dynamics
    fleet = make_fleet([spec])
    fleet.init_steady_state()
    fleet.p_set[:] = 600.0
    return np.array([t[0] for t in hold_f(fleet, F0, seconds)])


def test_ocgt_is_the_fast_thermal_responder() -> None:
    y = step_response("gas_ocgt", 10.0)
    t90 = 0.01 * (np.argmax(y >= 590.0) + 1)
    assert t90 < 3.0  # 90 % of the step within 3 s


def test_ccgt_fast_then_breathes() -> None:
    y = step_response("gas_ccgt", 400.0)
    y5 = y[int(5 / 0.01)]
    # GT (2/3 of the step) arrives within seconds; the steam tail takes minutes.
    assert 555.0 < y5 < 580.0
    assert y[-1] > 597.0
    t90 = 0.01 * (np.argmax(y >= 590.0) + 1)
    assert 60.0 < t90 < 400.0  # the tail breathes over ~2 min


def test_coal_reheat_is_slow() -> None:
    y = step_response("coal", 60.0)
    y2 = y[int(2 / 0.01)]
    assert y2 < 550.0  # < half the step after 2 s (reheat lag)
    assert y[-1] > 595.0
    t90_coal = 0.01 * (np.argmax(y >= 590.0) + 1)
    y_ocgt = step_response("gas_ocgt", 60.0)
    t90_ocgt = 0.01 * (np.argmax(y_ocgt >= 590.0) + 1)
    assert t90_coal > 5.0 * t90_ocgt


def test_hydro_nonminimum_phase_kick() -> None:
    """PHYSICS §6.4: an upward step first moves output the WRONG way."""
    y = step_response("hydro_ps", 180.0)
    early = y[: int(0.5 / 0.01)]
    assert early.min() < 499.0  # dips below the starting point
    # Transient droop: ~(1 − e^{−t/60 s}) of the step — deliberately sluggish.
    y30 = y[int(30 / 0.01)]
    assert y30 == pytest.approx(500.0 + 100.0 * (1 - np.exp(-30 / 60)), abs=8.0)
    assert y[-1] > 590.0  # converges by ~3 lag constants


# --- battery ------------------------------------------------------------


def battery_fixture(extra_batteries=None, h: float = 5.0):
    from tests.test_dynamics_analytic import make_fixture  # reuse the P2 fixture

    integ = make_fixture(h=h)
    if extra_batteries:
        # Rebuild with batteries attached (same sync fixture).
        sync = [
            {
                "id": f"g{i}", "island": 0, "s_n": 2500.0, "h": h, "r": 0.05,
                "db": 0.0, "fcr_band": np.inf, "p_max": np.inf, "p_min": 0.0,
                "t_g": 0.2, "t_ch": 0.4, "t_rh": 8.0, "f_hp": 1.0,
                "ramp_mw_s": np.inf, "p_set": 2000.0,
            }
            for i in range(4)
        ]
        fleet = make_fleet(sync, batteries=extra_batteries)
        fleet.init_steady_state()
        islands = IslandState(f=np.array([F0]), e_k=np.zeros(1),
                              p_l0=np.array([8000.0]), w=np.ones(1),
                              p_loss=np.zeros(1), d_pu=1.0)
        integ = Integrator(fleet, islands)
        integ.defense_enabled = False  # pinned pre-defense dynamics
        integ.agc_enabled = False  # droop-only pins (PHYSICS §6)
    return integ


def test_battery_ffr_shallows_the_nadir() -> None:
    """PHYSICS §6.3: +500 MW battery => strictly shallower nadir; battery
    crosses 50 % of its final response within 300 ms of the trip."""
    base = battery_fixture()
    base.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
    base.advance(s_to_us(30.0), interrupt_on_event=False)
    nadir_base = None
    t, f = base.rings[0]._ordered()
    nadir_base = f.min()

    bat = [{"id": "b0", "island": 0, "p_max": 500.0, "e_mwh": 500.0,
            "ffr_full_hz": 0.2, "db": 0.010, "t_b": 0.1, "soc_frac": 0.55}]
    with_bat = battery_fixture(extra_batteries=bat)
    with_bat.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
    soc0 = float(with_bat.fleet.bat_soc[0])
    # step tick-by-tick shortly after the trip to watch the battery output
    with_bat.advance(s_to_us(1.0), interrupt_on_event=False)
    p_at_300ms = None
    for k in range(3000):
        with_bat.advance(10_000, interrupt_on_event=False)
        if p_at_300ms is None and with_bat.t_us >= s_to_us(1.3):
            p_at_300ms = float(with_bat.fleet.bat_p[0])
    t2, f2 = with_bat.rings[0]._ordered()
    nadir_bat = f2.min()
    p_final = float(with_bat.fleet.bat_p[0])

    assert nadir_bat > nadir_base + 0.05  # visibly shallower
    assert p_at_300ms > 0.5 * p_final  # FFR arrives within 300 ms
    assert float(with_bat.fleet.bat_soc[0]) < soc0  # SoC visibly draining


def test_gfm_battery_adds_inertia_and_lowers_rocof() -> None:
    bat_gfl = [{"id": "b", "island": 0, "p_max": 1000.0, "e_mwh": 1000.0,
                "h_v": 0.0, "db": 0.010}]
    bat_gfm = [{"id": "b", "island": 0, "p_max": 1000.0, "e_mwh": 1000.0,
                "h_v": 4.0, "db": 0.0, "ffr_full_hz": 1.0, "t_b": 0.05}]

    rocofs = {}
    for name, batteries in (("gfl", bat_gfl), ("gfm", bat_gfm)):
        integ = battery_fixture(extra_batteries=batteries, h=2.0)
        assert integ.islands.e_k[0] == pytest.approx(
            2.0 * 4 * 2500.0 + (4000.0 if name == "gfm" else 0.0))
        integ.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
        integ.advance(s_to_us(1.0), interrupt_on_event=False)
        f0 = float(integ.islands.f[0])
        integ.advance(10_000, interrupt_on_event=False)
        rocofs[name] = abs(float(integ.islands.f[0]) - f0) / 0.010
    # Virtual inertia is the ONLY converter effect that lowers RoCoF.
    assert rocofs["gfm"] < 0.85 * rocofs["gfl"]


def test_battery_soc_energy_clamp() -> None:
    bat = [{"id": "b", "island": 0, "p_max": 100.0, "e_mwh": 1.0,
            "soc_frac": 0.06, "db": 0.010}]  # nearly empty
    fleet = make_fleet([], batteries=bat)
    fleet.init_steady_state()
    fleet.bat_p_set[:] = 100.0  # try to discharge hard
    f = np.array([F0])
    for _ in range(400):  # 4 s
        fleet.tick(10_000, f, 1)
    # SoC floor holds; the battery is clamped, not overdrawn.
    assert float(fleet.bat_soc[0]) >= 0.05 * 1.0 - 1e-9
    assert bool(fleet.bat_clamped[0]) is True


# --- electrolyzer / LFSM-O ---------------------------------------------


def test_electrolyzer_sheds_on_underfrequency() -> None:
    ely = [{"id": "e", "island": 0, "p_max": 100.0, "p_set": 100.0}]
    fleet = make_fleet([], electrolyzers=ely)
    fleet.init_steady_state()
    f = np.array([49.85])  # df = -0.15 => shed (0.15-0.01)/0.19 = 73.7 %
    for _ in range(500):
        fleet.tick(10_000, f, 1)
    assert float(fleet.ely_p[0]) == pytest.approx(100.0 * (1 - 0.14 / 0.19), rel=0.02)
    f = np.array([49.79])  # beyond full-shed threshold
    for _ in range(500):
        fleet.tick(10_000, f, 1)
    assert float(fleet.ely_p[0]) < 1.0


def test_wind_lfsm_o_curtails_over_frequency() -> None:
    inv = [{"id": "w", "island": 0, "p_rated": 1000.0, "avail": 1000.0,
            "t_up": 2.0, "t_down": 0.2, "lfsm_from": 50.2, "lfsm_droop": 0.05}]
    fleet = make_fleet([], inverters=inv)
    fleet.init_steady_state()
    f = np.array([50.4])  # 0.2 Hz over the LFSM-O knee
    for _ in range(2000):
        fleet.tick(10_000, f, 1)
    # steady state: p = avail - p*(0.2)*0.4  =>  p = 1000/1.08
    assert float(fleet.inv_p[0]) == pytest.approx(1000.0 / 1.08, rel=0.01)
    f = np.array([F0])
    for _ in range(3000):
        fleet.tick(10_000, f, 1)
    assert float(fleet.inv_p[0]) == pytest.approx(1000.0, rel=0.01)


# --- start sequences ----------------------------------------------------


def test_cold_nuclear_start_delivers_no_power_for_hours() -> None:
    spec = sync_spec("nuclear", CATALOG["nuclear"], device_id="n", island=0,
                     p_max_mw=1600.0, p_min_mw=800.0, p_set_mw=0.0, offline=True)
    fleet = make_fleet([spec])
    fleet.off_since_us[0] = -(int(CATALOG["nuclear"]["cold_after_s"] * US) + US)
    lead = fleet.command_start("n", t_us=0)
    assert lead == CATALOG["nuclear"]["start_cold_s"] == 172800  # 48 h
    assert fleet.status[0] == STARTING

    # Hours in: still zero output, zero inertia contribution.
    f = np.array([F0])
    for _ in range(100):
        fleet.tick(36_000, f, 1)
    assert fleet.poll_commitment(s_to_us(3600.0)) == []
    assert float(fleet.y[0]) == 0.0
    assert fleet.e_k_per_island(1)[0] == 0.0

    # One quantum before completion: nothing; at completion: online at P_min.
    assert fleet.poll_commitment(s_to_us(172800.0) - 10_000) == []
    assert fleet.poll_commitment(s_to_us(172800.0)) == ["n"]
    assert fleet.status[0] == ONLINE
    assert float(fleet.p_disp[0]) == 800.0


def test_xenon_lockout_blocks_restart_after_trip() -> None:
    spec = sync_spec("nuclear", CATALOG["nuclear"], device_id="n", island=0,
                     p_max_mw=1600.0, p_min_mw=800.0, p_set_mw=1400.0)
    fleet = make_fleet([spec])
    fleet.init_steady_state()
    fleet.trip("n", t_us=s_to_us(100.0))
    with pytest.raises(RuntimeError, match="locked out"):
        fleet.command_start("n", t_us=s_to_us(200.0))
    # After the 48 h lockout the (cold) start is allowed.
    lead = fleet.command_start("n", t_us=s_to_us(100.0 + 172800.0))
    assert lead == 172800


def test_ocgt_quick_start_cycle() -> None:
    spec = sync_spec("gas_ocgt", CATALOG["gas_ocgt"], device_id="o", island=0,
                     p_max_mw=200.0, p_min_mw=40.0, p_set_mw=0.0, offline=True)
    fleet = make_fleet([spec])
    fleet.command_start("o", t_us=0)
    assert fleet.poll_commitment(s_to_us(900.0)) == ["o"]  # 15 min, any state


def test_start_completion_held_on_sick_island():
    """A unit cannot sync to a collapsed island: completion is HELD while
    |f - f0| > 1 Hz or the island is blacked out, and lands normally once
    the frequency recovers (the calm_week death-spiral fix)."""
    import numpy as np

    from rttransportflow.dynamics import s_to_us
    from rttransportflow.dynamics.fleet import make_fleet
    from rttransportflow.dynamics.plant_types import load_catalog, sync_spec

    catalog = load_catalog("data/catalogs/plant_types.json")["kinds"]
    fleet = make_fleet([sync_spec("gas_ocgt", catalog["gas_ocgt"], device_id="o",
                                  island=0, p_max_mw=200.0, p_min_mw=40.0,
                                  p_set_mw=0.0, offline=True)])
    fleet.off_since_us[0] = 0
    fleet.command_start("o", 0)
    due = int(fleet.start_done_us[0])
    # island deeply sagged: held, re-armed 30 s out
    assert fleet.poll_commitment(due, np.array([47.0]), np.array([False])) == []
    assert int(fleet.start_done_us[0]) == due + s_to_us(30.0)
    # island blacked out: held too
    assert fleet.poll_commitment(due + s_to_us(30.0), np.array([50.0]),
                                 np.array([True])) == []
    # island healthy again: completes
    assert fleet.poll_commitment(due + s_to_us(60.0), np.array([49.9]),
                                 np.array([False])) == ["o"]
    fleet.command_stop("o", t_us=s_to_us(1000.0))
    assert float(fleet.y[0]) == 0.0


# --- meters -------------------------------------------------------------


def test_energy_and_fuel_meters() -> None:
    spec = sync_spec("gas_ccgt", CATALOG["gas_ccgt"], device_id="c", island=0,
                     p_max_mw=600.0, p_min_mw=0.0, p_set_mw=600.0)
    fleet = make_fleet([spec])
    fleet.init_steady_state()
    f = np.array([F0])
    for _ in range(3600):  # one hour at 1 s ticks
        fleet.tick(1_000_000, f, 1)
    assert float(fleet.energy_mwh[0]) == pytest.approx(600.0, rel=1e-3)
    # Full load => eta_full = 0.59
    assert float(fleet.fuel_mwh_th[0]) == pytest.approx(600.0 / 0.59, rel=1e-3)


def test_h2_starvation_chain() -> None:
    """PHYSICS §6.13: an electrolyzer fills a cavern; an H2-CCGT drains it;
    at the cushion floor the plant is starved (event) and frequency feels
    it; refilling recovers the plant."""
    from rttransportflow.dynamics.hydrogen import make_stores
    from rttransportflow.dynamics.integrator import Integrator, IslandState
    from rttransportflow.dynamics.events import Event

    # Sized so the island SURVIVES the starvation (an early fixture lost
    # 400 MW against a 40 MW FCR band -> collapse -> frozen blackout ->
    # the UF-shed electrolyzer never refilled: coherent physics, wrong test).
    stores = make_stores([{"id": "cavern", "island": 0, "capacity_kg": 20_000.0,
                           "level_kg": 1_400.0,  # floor is 1 000 kg
                           "withdraw_max_kgph": 40_000.0,
                           "inject_max_kgph": 40_000.0}])
    h2_ccgt = sync_spec("gas_ccgt", CATALOG["gas_ccgt"], device_id="h2gt",
                        island=0, p_max_mw=200.0, p_min_mw=0.0, p_set_mw=200.0)
    # SIX units with real headroom: at 5×800 the island sat exactly at its
    # capacity ceiling and could never recover (droop had already maxed the
    # fleet; redispatch had nothing to give — measured).
    coal = [sync_spec("coal", CATALOG["coal"], device_id=f"coal{i}", island=0,
                      p_max_mw=800.0, p_min_mw=0.0, p_set_mw=633.3)
            for i in range(6)]
    ely = [{"id": "ely1", "island": 0, "p_max": 100.0, "p_set": 0.0}]
    fleet = make_fleet([h2_ccgt] + coal, electrolyzers=ely)
    fleet.attach_h2(stores, {"h2gt": "cavern"}, {"ely1": "cavern"})
    fleet.init_steady_state()
    islands = IslandState(f=np.array([F0]), e_k=np.zeros(1),
                          p_l0=np.array([4000.0]), w=np.ones(1),
                          p_loss=np.zeros(1), d_pu=0.5)
    integ = Integrator(fleet, islands)
    integ.defense_enabled = False  # pinned pre-defense dynamics
    integ.agc_enabled = False  # droop-only pins (PHYSICS §6)

    # Draw at 200 MW: ~10.2 t/h; the 400 kg above the floor lasts ~2.4 min
    # -> starvation, early return, ALERT; the coal FCR arrests the loss.
    res = integ.advance(s_to_us(300.0), interrupt_on_event=True)
    assert res.early_return is True
    kinds = [e.kind for e in res.events]
    assert "fuel_starved" in kinds
    assert bool(fleet.h2_starved[0]) is True
    assert float(stores.level_kg[0]) <= 1_000.0 + 1.0
    # the lost 200 MW is a real frequency event the coal fleet arrests
    # (assert past the ~10 s reheat transient — QSS ≈ −0.11 Hz)
    integ.advance(s_to_us(60.0), interrupt_on_event=False)
    assert 49.6 < float(islands.f[0]) < 49.99

    # The dispatcher's job (P6): redispatch the coal fleet to cover the lost
    # unit — frequency recovers, the UF-shed electrolyzer un-sheds and
    # refills at full power (without this, refill crawls at ~150 kg/h
    # because the electrolyzer keeps shedding at 49.81 Hz — measured).
    for i in range(6):
        fleet.p_set[1 + i] = 700.0
    fleet.ely_p_set[0] = 100.0
    seen_recovery = False
    for _ in range(40):  # ~1.1 h sim in 100 s chunks
        res = integ.advance(s_to_us(100.0), interrupt_on_event=False)
        if any(e.kind == "fuel_recovered" for e in res.events):
            seen_recovery = True
            break
    assert seen_recovery
    assert bool(fleet.h2_starved[0]) is False


def test_avail_slew_limits_wire_steps():
    """The 15-min wire sample-and-hold is a sampling artifact: with
    avail_slew set, a GW-scale avail step reaches the plant as a ramp at
    the physical rate; without it (default inf) the step is instant."""
    import numpy as np

    from rttransportflow.dynamics import s_to_us
    from rttransportflow.dynamics.fleet import make_fleet

    def build(slew):
        spec = {"id": "w", "island": 0, "p_rated": 1000.0, "avail": 1000.0,
                "t_up": 0.01, "t_down": 0.01}
        if slew is not None:
            spec["avail_slew_mw_s"] = slew
        fleet = make_fleet([], [spec])
        fleet.init_steady_state()
        return fleet

    f0 = np.array([50.0])
    # slewed: 1000 -> 0 target moves at 10 MW/s
    fleet = build(10.0)
    fleet.inv_avail[0] = 0.0
    fleet.tick(s_to_us(1.0), f0, 1)
    assert fleet.inv_avail_eff[0] == 990.0
    for _ in range(9):
        fleet.tick(s_to_us(1.0), f0, 1)
    assert fleet.inv_avail_eff[0] == 900.0
    assert 880.0 < fleet.inv_p[0] < 920.0  # follows the ramp, not the cliff
    # default: instant (every pre-slew pin unchanged)
    fleet = build(None)
    fleet.inv_avail[0] = 0.0
    fleet.tick(s_to_us(1.0), f0, 1)
    assert fleet.inv_avail_eff[0] == 0.0
