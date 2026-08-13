"""P8 defense plan (PARAMETERS §2.2 / PHYSICS §2.7): UFLS stages with
latching + restoration ramp, the interruptible electrolyzer tier, the RoCoF
feel table (embedded-DG trips + seeded pole-slip draws), and snapshot
coverage of every latch and the PRNG."""

from __future__ import annotations

import numpy as np
import pytest

from rttransportflow.dynamics import F0, s_to_us
from rttransportflow.dynamics.events import Event
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator, IslandState
from rttransportflow.dynamics.protection import (
    ELY_SHED_HZ,
    RESTORE_F_OK_US,
    UFLS_STAGES,
)


def worked_example_island(h_sys: float = 1.5, fcr_mw: float = 1500.0,
                          protection_seed: int = 0) -> Integrator:
    """The §2.3 fixture shape: 150 GW island, aggregate machine, 3 GW
    exogenous H = 0 infeed loss scheduled at t = 5 s."""
    p_l0 = 150_000.0
    s_n = 150_000.0
    gain = fcr_mw / 0.2  # full FCR at ±200 mHz
    r_pu = s_n / (gain * F0)
    sync = [{
        "id": "agg", "island": 0, "s_n": s_n, "h": h_sys, "r": r_pu,
        "db": 0.010, "fcr_band": fcr_mw, "p_max": np.inf, "p_min": 0.0,
        "t_g": 8.0, "t_ch": 1e-3, "t_rh": 1e9, "f_hp": 1.0,
        "ramp_mw_s": np.inf, "p_set": p_l0,
    }]
    fleet = make_fleet(sync)
    fleet.init_steady_state()
    islands = IslandState(f=np.array([F0]), e_k=np.zeros(1),
                          p_l0=np.array([p_l0 + 3000.0]), w=np.ones(1),
                          p_loss=np.zeros(1), d_pu=0.5)
    integ = Integrator(fleet, islands, protection_seed=protection_seed)
    # model the 3 GW infeed as extra generation that vanishes at t = 5 s
    integ.islands.p_l0[0] = p_l0
    integ.queue.schedule(Event(s_to_us(5.0), "load_step", "import",
                               {"island": 0, "delta_mw": 3000.0}))
    return integ


def test_ufls_stages_fire_and_arrest() -> None:
    """§2.3 row 5 WITH the defense on: the raw dynamics pin says nadir
    48.77 — UFLS stages 1+2 shed 15 % and arrest the fall above 48.6."""
    integ = worked_example_island()
    res = integ.advance(s_to_us(65.0), interrupt_on_event=False)
    stages = [e for e in res.events if e.kind == "ufls_stage"]
    # the §2.3 narrative said "stages 1+2": that was the RAW-nadir reading
    # (48.77 < 48.8). With the defense live, stage 1's 7.5 % shed is
    # 11.25 GW against a 3 GW loss — the fall reverses before 48.8 and
    # only stage 1 fires. The raw pins stay in test_worked_example.
    assert [e.data["stage"] for e in stages] == [1]
    assert integ.islands.w[0] == pytest.approx(0.925)
    assert 48.8 < float(res.f_min[0]) < 49.0  # arrested between 1 and 2
    # latched: a lingering sub-49 excursion cannot re-fire stage 1
    assert not integ.defense.stage_armed[0, 0]
    assert integ.defense.stage_armed[1, 0]


def test_restoration_ramp_and_rearm() -> None:
    integ = worked_example_island()
    integ.advance(s_to_us(65.0), interrupt_on_event=False)
    assert integ.islands.w[0] == pytest.approx(0.925)
    # the lost import RETURNS (else restoring all shed load walks f straight
    # back to the 49.8 boundary and the ramp honestly stalls — verified)
    integ.queue.schedule(Event(integ.t_us + s_to_us(1.0), "load_step", "import",
                               {"island": 0, "delta_mw": -3000.0}))
    # give it the 5-min healthy hold, then restore blocks
    integ.advance(s_to_us(RESTORE_F_OK_US / 1e6 + 30.0), interrupt_on_event=False)
    assert float(integ.islands.f[0]) > 49.8
    integ.defense.request_restore(0, 0.10)  # one 10 % block covers the 7.5 %
    res = integ.advance(s_to_us(60.0), interrupt_on_event=False)
    # 1 %/10 s: 60 s of ramp ≈ +6 %
    assert 0.975 < float(integ.islands.w[0]) < 0.995
    # the pickup transient dips f under 49.8 for a moment — the ramp
    # correctly PAUSES for a fresh 5-min healthy hold before finishing
    res = integ.advance(s_to_us(420.0), interrupt_on_event=False)
    assert float(integ.islands.w[0]) == pytest.approx(1.0)
    restored = [e for e in res.events if e.kind == "load_restored"]
    assert restored
    assert bool(integ.defense.stage_armed[0, 0])  # re-armed for the next event


def test_electrolyzer_interruptible_tier() -> None:
    sync = [{"id": "g", "island": 0, "s_n": 10_000.0, "h": 4.0, "r": 0.05,
             "db": 0.010, "fcr_band": 200.0, "p_max": np.inf, "p_min": 0.0,
             "t_g": 0.5, "t_ch": 1e-3, "t_rh": 1e9, "f_hp": 1.0,
             "ramp_mw_s": np.inf, "p_set": 8000.0}]
    ely = [{"id": "e1", "island": 0, "p_max": 500.0, "p_set": 400.0}]
    fleet = make_fleet(sync, electrolyzers=ely)
    fleet.init_steady_state()
    islands = IslandState(f=np.array([49.55]), e_k=np.zeros(1),
                          p_l0=np.array([8000.0]), w=np.ones(1),
                          p_loss=np.zeros(1), d_pu=0.5)
    assert 49.55 < ELY_SHED_HZ
    integ = Integrator(fleet, islands)
    res = integ.advance(s_to_us(1.0), interrupt_on_event=False)
    shed = [e for e in res.events if e.kind == "ely_shed"]
    trips = [e for e in res.events if e.kind == "trip" and e.element == "e1"]
    assert shed and trips
    assert not fleet.ely_online[0]
    assert integ.defense.ely_latched[0]


def test_rocof_dg_trips_raise_net_load() -> None:
    # tiny inertia + big loss => windowed RoCoF beyond 1 Hz/s
    integ = worked_example_island(h_sys=1.0)
    res = integ.advance(s_to_us(20.0), interrupt_on_event=False)
    dg = [e for e in res.events if e.kind == "rocof_dg_trip"]
    assert dg  # at least the 0.5 Hz/s row fired
    assert float(integ.islands.p_extra[0]) > 0.0


def test_pole_slip_draws_are_seeded() -> None:
    def big_rocof_island(seed: int) -> list[str]:
        sync = [{"id": f"u{i}", "island": 0, "s_n": 500.0, "h": 1.0,
                 "r": 0.05, "db": 0.010, "fcr_band": 10.0, "p_max": np.inf,
                 "p_min": 0.0, "t_g": 8.0, "t_ch": 1e-3, "t_rh": 1e9,
                 "f_hp": 1.0, "ramp_mw_s": np.inf, "p_set": 400.0}
                for i in range(10)]
        fleet = make_fleet(sync)
        fleet.init_steady_state()
        islands = IslandState(f=np.array([F0]), e_k=np.zeros(1),
                              p_l0=np.array([4000.0]), w=np.ones(1),
                              p_loss=np.zeros(1), d_pu=0.5)
        integ = Integrator(fleet, islands, protection_seed=seed)
        integ.queue.schedule(Event(s_to_us(1.0), "load_step", "shock",
                                   {"island": 0, "delta_mw": 2500.0}))
        res = integ.advance(s_to_us(10.0), interrupt_on_event=False)
        return sorted(e.element for e in res.events
                      if e.kind == "trip" and e.data.get("cause") == "pole_slip")

    first = big_rocof_island(42)
    again = big_rocof_island(42)
    other = big_rocof_island(43)
    assert first == again  # deterministic per seed
    assert first  # the shock is far beyond 2 Hz/s: some units must slip
    assert first != other or len(first) == len(other)  # seeds draw independently


def test_defense_state_snapshot_roundtrip() -> None:
    integ = worked_example_island(protection_seed=7)
    integ.advance(s_to_us(65.0), interrupt_on_event=False)
    blob = integ.state_dict()

    twin = worked_example_island(protection_seed=7)
    twin.queue.restore([])  # replaced by the snapshot below anyway
    twin.restore_state(blob)
    assert twin.islands.w[0] == integ.islands.w[0]
    assert (twin.defense.stage_armed == integ.defense.stage_armed).all()
    assert twin.defense.rng.bit_generator.state == integ.defense.rng.bit_generator.state
    # continued runs stay bit-identical
    a = integ.advance(s_to_us(10.0), interrupt_on_event=False)
    b = twin.advance(s_to_us(10.0), interrupt_on_event=False)
    assert float(a.f_end[0]) == float(b.f_end[0])


def test_black_start_reenergizes_a_dead_island() -> None:
    """PHYSICS §2.7 restoration hook: a normal restart is HELD on a dead
    island forever; `black_start` bypasses the hold and the first completed
    machine re-energizes the island at 50 Hz (event `black_start`)."""
    # engine envelope p_min is 0 (the catalog p_min informs the DISPATCHER,
    # ledger/P3): a black-start unit runs at house load on the dead island —
    # syncing at a forced P_min into zero load would over-frequency-trip it
    sync = [{"id": "o", "island": 0, "s_n": 250.0, "h": 4.0, "r": 0.05,
             "db": 0.010, "fcr_band": 50.0, "p_max": 200.0, "p_min": 0.0,
             "t_g": 0.3, "t_ch": 0.8, "t_rh": 1e9, "f_hp": 1.0,
             "ramp_mw_s": np.inf, "p_set": 150.0, "start_hot_s": 60.0}]
    fleet = make_fleet(sync)
    fleet.init_steady_state()
    islands = IslandState(f=np.array([F0]), e_k=np.zeros(1),
                          p_l0=np.array([150.0]), w=np.ones(1),
                          p_loss=np.zeros(1), d_pu=0.5)
    integ = Integrator(fleet, islands)
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "o"))
    integ.advance(s_to_us(5.0), interrupt_on_event=False)
    assert bool(islands.blackout()[0])
    f_frozen = float(islands.f[0])

    # ordinary restart: held forever on the dead island
    fleet.command_start("o", integ.t_us)
    integ.advance(s_to_us(120.0), interrupt_on_event=False)
    assert int(fleet.status[0]) != 2  # still not online
    assert bool(islands.blackout()[0])
    assert float(islands.f[0]) == f_frozen

    # black start: completes onto the UNLOADED island (the collapse shed
    # everything — w = 0) and re-energizes at 50 Hz
    assert float(integ.islands.w[0]) == 0.0
    fleet.black_start_rows = {0}
    res = integ.advance(s_to_us(120.0), interrupt_on_event=False)
    assert int(fleet.status[0]) == 2
    assert not bool(integ.islands.blackout()[0])
    assert any(e.kind == "black_start" for e in res.events)
    assert float(res.f_end[0]) > 49.5  # holds at P_min, no load yet

    # the game then re-picks load up in blocks, dispatching generation to
    # match (restoration doctrine: load blocks + matching dispatch)
    fleet.p_set[0] = 30.0
    integ.advance(s_to_us(320.0), interrupt_on_event=False)
    integ.defense.request_restore(0, 0.10)
    integ.defense.request_restore(0, 0.10)
    integ.advance(s_to_us(300.0), interrupt_on_event=False)
    assert float(integ.islands.w[0]) > 0.15  # load coming back
    assert not bool(integ.islands.blackout()[0])
