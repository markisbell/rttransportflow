"""Slicing identity, snapshot bit-replay, early return (PHYSICS §6.6–6.8)."""

from __future__ import annotations

import json

import numpy as np

from rttransportflow.dynamics import s_to_us
from rttransportflow.dynamics.events import Event
from tests.helpers.dyn import make_fixture


def capture(integ) -> dict:
    return integ.state_dict()


def through_json(snap: dict) -> dict:
    """The bit-exactness claim under test: repr-floats survive a JSON trip."""
    return json.loads(json.dumps(snap, separators=(",", ":"), sort_keys=True))


def run_sliced(chunks_s: list[float], total_s: float = 10.0):
    """Fresh fixture with a trip at 1 s; advance by the given slicing, then
    top up to exactly `total_s` (dt_done is boundary-quantized, so slices
    may under/over-shoot individually — the loop converges on the target)."""
    integ = make_fixture()
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
    target = s_to_us(total_s)
    for chunk in chunks_s:
        if integ.t_us >= target:
            break
        integ.advance(min(s_to_us(chunk), target - integ.t_us), interrupt_on_event=False)
    while integ.t_us < target:
        integ.advance(target - integ.t_us, interrupt_on_event=False)
    return integ


def test_slicing_identity_bit_exact() -> None:
    # One 10 s call vs ten 1 s calls vs awkward slices, with a CALM→ALERT
    # transition (the trip) inside the window.
    a = run_sliced([10.0])
    b = run_sliced([1.0] * 10)
    c = run_sliced([0.3, 4.7, 5.0])
    sa, sb, sc = capture(a), capture(b), capture(c)
    assert sa == sb == sc  # repr-exact state: bit-identical trajectories
    assert a.t_us == b.t_us == c.t_us == s_to_us(10.0)


def test_snapshot_bit_replay() -> None:
    total = 300.0
    # Uninterrupted run.
    ref = run_sliced([total], total_s=total)
    # Run to 150 s, snapshot through JSON, restore into a FRESH integrator,
    # continue to 300 s.
    half = run_sliced([150.0], total_s=150.0)
    snap = through_json(capture(half))
    fresh = make_fixture()
    fresh.restore_state(snap)
    while fresh.t_us < s_to_us(total):
        fresh.advance(s_to_us(total) - fresh.t_us, interrupt_on_event=False)
    assert capture(fresh) == capture(ref)


def test_early_return_on_event() -> None:
    integ = make_fixture()
    integ.queue.schedule(Event(s_to_us(400.0), "trip", "g0"))
    res = integ.advance(s_to_us(900.0), interrupt_on_event=True)
    assert res.early_return is True
    assert res.dt_done_us == s_to_us(400.0)
    assert [e.kind for e in res.events] == ["trip"]

    # Continuing reproduces the uninterrupted run exactly.
    integ.advance(s_to_us(500.0), interrupt_on_event=False)
    ref = make_fixture()
    ref.queue.schedule(Event(s_to_us(400.0), "trip", "g0"))
    ref.advance(s_to_us(900.0), interrupt_on_event=False)
    assert capture(integ) == capture(ref)


def test_dt_done_min_one_boundary_rule() -> None:
    """A request smaller than the next boundary still advances one boundary
    (documented deviation: dt_done may exceed dt_s by up to one CALM tick)."""
    integ = make_fixture()  # calm, tick 250 ms
    res = integ.advance(s_to_us(0.1), interrupt_on_event=False)
    assert res.dt_done_us == 250_000
    assert integ.t_us == 250_000


def test_trajectory_decimation_bounds() -> None:
    integ = make_fixture()
    integ.queue.schedule(Event(s_to_us(1.0), "trip", "g0"))
    res = integ.advance(s_to_us(120.0), interrupt_on_event=False)
    n = len(res.trajectory["t_rel_s"])
    assert 0 < n <= 512 + 2  # cap plus kept event/final samples
    assert len(res.trajectory["islands"]["0"]["f"]) == n
    assert res.f_min[0] < 49.2  # the dip is really in the buffer
    assert np.isclose(res.f_end[0], 50.0 - 0.63291, atol=2e-3)
