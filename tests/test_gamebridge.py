"""Gamebridge v2 semantics, in-process (the wire authority is tests/contract/)."""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from rttransportflow.api.runtime import create_app
from rttransportflow.config import Settings

BUNDLE_DIR = Path(__file__).resolve().parent.parent / "data" / "grids" / "europe_mini"


def load_native() -> dict:
    return {
        name: json.loads((BUNDLE_DIR / f"{name}.json").read_text())
        for name in ("grid", "lines", "plants", "load_centers", "scenario")
    }


NATIVE = load_native()
SYNC_KINDS = {"nuclear", "coal", "lignite", "gas_ccgt", "gas_ocgt", "hydro_ps"}


def reset_doc(native: dict | None = None) -> dict:
    native = native or NATIVE
    return {
        "contract": "2.0",
        "network_kind": "transmission",
        "name": "europe_mini",
        "native": native,
        "zones": [{"id": z["id"], "node": z["bus"]} for z in native["grid"]["zones"]],
        "devices": [],
    }


def boundary_for_step(step: int, native: dict | None = None) -> dict:
    native = native or NATIVE
    zone_demand = {
        item["zone"]: {"value_mw": item["p_mw"][step]}
        for item in native["load_centers"]["items"]
    }
    avail, commands = {}, {}
    for plant in native["plants"]["plants"]:
        if plant["kind"] in SYNC_KINDS:
            commands[plant["id"]] = {"dispatch_mw": plant["profile_p_mw"][step]}
        else:
            avail[plant["id"]] = plant["profile_p_mw"][step]
    return {"zone_demand": zone_demand, "avail_mw": avail, "device_commands": commands}


@pytest.fixture()
def client():
    app = create_app(Settings(external_clock=True, autostart=False))
    with TestClient(app) as c:
        yield c


def do_reset(client, doc: dict | None = None) -> dict:
    response = client.post("/gb/net/reset", json=doc or reset_doc())
    assert response.status_code == 200, response.text
    return response.json()


def do_step(client, t: int, dt_s: float = 900.0, **extra) -> dict:
    body = {"t": t, "dt_s": dt_s, "interrupt_on_event": False,
            **boundary_for_step(min(t, 95)), **extra}
    response = client.post("/gb/step", json=body)
    assert response.status_code == 200, response.text
    return response.json()


def test_version_handshake(client) -> None:
    v = client.get("/gb/version").json()
    assert v["contract"] == "2.0"
    assert v["backend"] == "rttransportflow"
    assert v["units"] == {"power": "MW"}
    assert v["external_clock"] is True
    assert v["solver"]["pf"].startswith("pandapower")


def test_step_before_reset_is_409(client) -> None:
    assert client.post("/gb/step", json={"t": 0, "dt_s": 1.0}).status_code == 409


def test_reset_step_and_result_shape(client) -> None:
    r = do_reset(client)
    assert r["status"] == "ok"
    assert r["warmup_solve_ms"] > 0
    res = do_step(client, 0)
    assert res["status"] in ("converged", "degraded")
    assert res["dt_done_s"] == pytest.approx(900.0)
    isl = res["islands"]["0"]
    assert 49.5 < isl["f_hz"] < 50.5
    assert isl["h_sys_s"] > 3.0
    assert res["trajectory"]["t_rel_s"]
    assert res["zones"]["london"]["supplied"] == 1.0
    assert res["devices"]["nuc_paris"]["state"] == "online"
    assert res["pf"]["latest"]["buses"]["paris"]["vm_pu"] == pytest.approx(1.02, abs=1e-3)


def test_idempotent_resend_no_double_integration(client) -> None:
    do_reset(client)
    first = do_step(client, 0)
    t_sim_after = client.get("/gb/snapshot").json()["t_sim"]
    again = do_step(client, 0)  # re-send of last t
    assert again == first  # cached result, byte-identical
    assert client.get("/gb/snapshot").json()["t_sim"] == t_sim_after  # no state applied


def test_out_of_order_409(client) -> None:
    do_reset(client)
    do_step(client, 0)
    response = client.post("/gb/step", json={"t": 5, "dt_s": 1.0})
    assert response.status_code == 409
    body = response.json()  # FLAT body, identical to the WS frame shape
    assert body["error"] == "out_of_order"
    assert body["expected"] == [0, 1]


def test_any_t_accepted_after_reset(client) -> None:
    """The game clock continues across resets: reset clears last_t and the
    FIRST step afterwards may carry any t (found by game-shell integration)."""
    do_reset(client)
    do_step(client, 0)
    do_step(client, 1)
    do_reset(client)
    res = do_step(client, 7)  # arbitrary continuation of the game's sequence
    assert res["t"] == 7
    res2 = do_step(client, 8)
    assert res2["t"] == 8


def test_godot_float_ints_tolerated(client) -> None:
    do_reset(client)
    body = {"t": 0.0, "dt_s": 900, "interrupt_on_event": False, **boundary_for_step(0)}
    assert client.post("/gb/step", json=body).status_code == 200


def test_reset_clears_idempotency_cache(client) -> None:
    do_reset(client)
    do_step(client, 0)
    do_reset(client)
    # After reset any t is legal as the first step (v1 rule carried over: the
    # game clock continues across resets — expected_next is 0 here by spec,
    # so t=0 must be accepted freshly, not served from the old cache).
    res = do_step(client, 0)
    assert res["t_sim_end"] == pytest.approx(900.0)


def test_early_return_on_scheduled_trip(client) -> None:
    do_reset(client)
    do_step(client, 0)
    body = {"t": 1, "dt_s": 900.0, "interrupt_on_event": True,
            **boundary_for_step(1),
            "scheduled_events": [{"at_s_rel": 100.0, "kind": "trip",
                                  "element": "lignite_berlin"}]}
    res = client.post("/gb/step", json=body).json()
    assert res["dt_done_s"] == pytest.approx(100.0, abs=0.3)
    assert [e["kind"] for e in res["events"]] == ["trip"]
    assert res["mode"] == "alert"
    # devices reflect the trip
    assert res["devices"]["lignite_berlin"]["state"] == "tripped"
    # The dive happens in the FOLLOW-UP window (early return fires right at
    # the event — the game slows down and then watches the frequency fall).
    res2 = do_step(client, 2, dt_s=60.0)
    assert res2["islands"]["0"]["f_min"] < 49.95
    assert res2["islands"]["0"]["f_hz"] < 50.0
    assert res2["islands"]["0"]["fcr_used_mw"] > 100.0


def test_watch_devices_sampled(client) -> None:
    do_reset(client)
    res = do_step(client, 0, watch=["ccgt_london", "wind_copenhagen"])
    watched = res["trajectory"]["watched"]
    assert set(watched) == {"ccgt_london", "wind_copenhagen"}
    assert len(watched["ccgt_london"]["p"]) == len(res["trajectory"]["t_rel_s"])


def test_snapshot_roundtrip_restores_t_sim(client) -> None:
    do_reset(client)
    do_step(client, 0)
    do_step(client, 1)
    snap = client.get("/gb/snapshot").json()
    assert snap["t_sim"] == pytest.approx(1800.0)

    doc = reset_doc()
    doc["snapshot"] = snap
    r = do_reset(client, doc)
    assert r["status"] == "ok"
    assert client.get("/gb/snapshot").json()["t_sim"] == pytest.approx(1800.0)
    do_step(client, 0, dt_s=60.0)  # stepping continues after restore


def test_snapshot_refused_on_model_mismatch(client) -> None:
    do_reset(client)
    do_step(client, 0)
    snap = client.get("/gb/snapshot").json()

    native = copy.deepcopy(NATIVE)
    native["plants"]["plants"][0]["p_max_mw"] += 500.0  # different model hash
    doc = reset_doc(native)
    doc["snapshot"] = snap
    r = do_reset(client, doc)
    assert r["status"] == "refused_snapshot"  # applied WITHOUT the snapshot
    assert client.get("/gb/snapshot").json()["t_sim"] == 0.0


def test_ws_step_channel(client) -> None:
    do_reset(client)
    with client.websocket_connect("/gb/ws") as ws:
        ws.send_json({"t": 0, "dt_s": 60.0, "interrupt_on_event": False,
                      **boundary_for_step(0)})
        res = ws.receive_json()
        assert res["t"] == 0
        assert res["dt_done_s"] == pytest.approx(60.0)
        ws.send_json({"t": 7, "dt_s": 60.0})
        err = ws.receive_json()
        assert err["error"] == "out_of_order"
        assert err["expected"] == [0, 1]


def test_external_clock_equivalence() -> None:
    """Puppet stepping with profile boundaries ≡ standalone run_step —
    the two clock modes produce the identical frequency trajectory."""
    from rttransportflow.simulator import build_dyn_simulator

    standalone = build_dyn_simulator(BUNDLE_DIR, 96)
    standalone.warmup()
    for step in range(8):
        standalone.run_step(step, 0)
    f_standalone = float(standalone.integrator.islands.f[0])
    t_standalone = standalone.integrator.t_us

    app = create_app(Settings(external_clock=True, autostart=False))
    with TestClient(app) as client:
        do_reset(client)
        for step in range(8):
            do_step(client, step)
        snap = client.get("/gb/snapshot").json()
        f_wire = float(snap["blob"]["f"][0])
        t_wire = snap["t_sim"]

    assert t_wire == pytest.approx(t_standalone / 1e6)
    assert f_wire == f_standalone  # bit-identical
