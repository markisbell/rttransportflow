"""/gb/replay (ledger 23): rolling-ring state source, throwaway-sim
counterfactuals, and the isolation guarantee (replay NEVER moves live state)."""

from __future__ import annotations

from tests.helpers.wire import do_step, reset_doc, reset_with_devices


def _step(client, t, dt_s=30.0, **extra):
    return do_step(client, t, dt_s, boundary_step=0, **extra)


def test_ring_fills_at_5s_cadence(client) -> None:
    client.post("/gb/net/reset", json=reset_doc())
    _step(client, 0, dt_s=21.0)
    app_gb = client.app.state.gb
    marks = [t for t, _ in app_gb.sim._snap_ring]
    assert marks and all(t % 5_000_000 == 0 for t in marks)
    assert len(marks) >= 4  # 5/10/15/20 s


def test_window_expired(client) -> None:
    client.post("/gb/net/reset", json=reset_doc())
    _step(client, 0, dt_s=10.0)
    out = client.post("/gb/replay", json={"t_sim": -50.0}).json()
    assert out["status"] == "window_expired"


def test_replay_reproduces_and_never_touches_live_state(client) -> None:
    client.post("/gb/net/reset", json=reset_doc())
    _step(client, 0, dt_s=30.0)
    res = _step(client, 1, dt_s=60.0,
                scheduled_events=[{"at_s_rel": 5.0, "kind": "trip",
                                   "element": "nuc_lyon"}])
    t_event = next(e["t_sim"] for e in res["events"] if e["kind"] == "trip")

    live_before = client.get("/gb/snapshot").json()["blob"]
    replay_a = client.post("/gb/replay", json={"t_sim": t_event,
                                               "window_s": 20.0}).json()
    replay_b = client.post("/gb/replay", json={"t_sim": t_event,
                                               "window_s": 20.0}).json()
    live_after = client.get("/gb/snapshot").json()["blob"]

    assert replay_a["status"] == "ok"
    assert replay_a == replay_b  # deterministic re-run, same engine code
    assert live_before == live_after  # READ-ONLY: bit-identical live state
    # the ring entry AT the event instant carries the trip already applied —
    # the window replays the AFTERMATH (ghost traces compare aftermaths,
    # GAME_DESIGN §4.5), so the dip must be visible in the replay window
    assert replay_a["islands"]["0"]["f_min"] < 49.9
    assert replay_a["t_start"] <= t_event


def test_counterfactual_remove_battery_deepens_the_dip(client) -> None:
    client.post("/gb/net/reset", json=reset_with_devices())
    _step(client, 0, dt_s=30.0)
    res = _step(client, 1, dt_s=60.0,
                scheduled_events=[{"at_s_rel": 5.0, "kind": "trip",
                                   "element": "nuc_lyon"}])
    t_event = next(e["t_sim"] for e in res["events"] if e["kind"] == "trip")

    with_bat = client.post("/gb/replay", json={
        "t_sim": t_event, "window_s": 20.0}).json()
    without_bat = client.post("/gb/replay", json={
        "t_sim": t_event, "window_s": 20.0,
        "overrides": {"remove_devices": ["bat_paris", "gfm_berlin"]}}).json()
    assert with_bat["status"] == "ok" and without_bat["status"] == "ok"
    # the ghost trace: no battery fleet => deeper nadir (GAME_DESIGN §4.5)
    assert without_bat["islands"]["0"]["f_min"] \
        < with_bat["islands"]["0"]["f_min"] - 0.02
