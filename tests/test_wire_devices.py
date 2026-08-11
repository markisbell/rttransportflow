"""P7 wire devices over the gamebridge: battery/grid_forming FFR, the H2
chain (electrolyzer → store → converted plant), HVDC paired injection
(embedded trip ≈ frequency-neutral) and the offshore hub (§1.16 losses,
trip = infeed loss)."""

from __future__ import annotations

import copy

import pytest
from fastapi.testclient import TestClient

from rttransportflow.api.runtime import create_app
from rttransportflow.config import Settings
from rttransportflow.dynamics.hvdc import path_loss_frac

from test_gamebridge import NATIVE, boundary_for_step, reset_doc

HUB_LOSS = path_loss_frac(300.0)  # 2 GW hub 300 km out delivers ≈ 97.1 %


def devices_full() -> list[dict]:
    return [
        {"id": "bat_paris", "kind": "battery", "node": "paris",
         "params": {"p_max_mw": 600.0, "e_mwh": 2400.0, "soc": 0.55}},
        {"id": "gfm_berlin", "kind": "grid_forming", "node": "berlin",
         "params": {"p_max_mw": 400.0, "e_mwh": 1600.0, "h_v_s": 6.0}},
        {"id": "cavern_north", "kind": "h2_store",
         "params": {"capacity_kg": 4_000_000.0, "level_kg": 2_000_000.0}},
        {"id": "ely_hamburg", "kind": "electrolyzer", "node": "frankfurt",
         "params": {"p_max_mw": 500.0, "h2_store_id": "cavern_north"}},
        {"id": "hvdc_suedlink_n", "kind": "hvdc", "node": "frankfurt",
         "params": {"link_id": "suedlink", "p_max_mw": 2000.0, "length_km": 700.0}},
        {"id": "hvdc_suedlink_s", "kind": "hvdc", "node": "milan",
         "params": {"link_id": "suedlink", "p_max_mw": 2000.0, "length_km": 700.0}},
        {"id": "hub_dogger", "kind": "offshore_hub", "node": "copenhagen",
         "params": {"p_max_mw": 2000.0, "platform_mw": 2000.0, "cable_km": 300.0}},
    ]


def reset_with_devices(extra_devices: list[dict] | None = None) -> dict:
    doc = reset_doc()
    doc["devices"] = extra_devices if extra_devices is not None else devices_full()
    return doc


@pytest.fixture()
def client():
    app = create_app(Settings(external_clock=True, autostart=False))
    with TestClient(app) as c:
        yield c


def _reset(client, doc: dict) -> dict:
    response = client.post("/gb/net/reset", json=doc)
    assert response.status_code == 200, response.text
    return response.json()


def _step(client, t: int, dt_s: float = 30.0, **extra) -> dict:
    body = {"t": t, "dt_s": dt_s, "interrupt_on_event": False,
            **boundary_for_step(0)}
    for key, value in extra.items():
        if key in ("zone_demand", "avail_mw", "device_commands"):
            body[key] = {**body.get(key, {}), **value}  # merge, don't clobber
        else:
            body[key] = value
    response = client.post("/gb/step", json=body)
    assert response.status_code == 200, response.text
    return response.json()


# --- reset validation ----------------------------------------------------


def test_reset_accepts_full_device_set(client) -> None:
    out = _reset(client, reset_with_devices())
    assert out["status"] == "ok"


def test_model_hash_covers_devices(client) -> None:
    bare = _reset(client, reset_doc())["model_hash"]
    with_devices = _reset(client, reset_with_devices())["model_hash"]
    assert bare != with_devices


def test_unknown_kind_rejected(client) -> None:
    doc = reset_with_devices([{"id": "x", "kind": "flux_capacitor", "node": "paris",
                               "params": {}}])
    assert client.post("/gb/net/reset", json=doc).status_code == 400


def test_unknown_node_rejected(client) -> None:
    doc = reset_with_devices([{"id": "b1", "kind": "battery", "node": "atlantis",
                               "params": {"p_max_mw": 100.0, "e_mwh": 400.0}}])
    assert client.post("/gb/net/reset", json=doc).status_code == 400


def test_dangling_h2_store_rejected(client) -> None:
    doc = reset_with_devices([{"id": "e1", "kind": "electrolyzer", "node": "paris",
                               "params": {"p_max_mw": 100.0,
                                          "h2_store_id": "nowhere"}}])
    assert client.post("/gb/net/reset", json=doc).status_code == 400


def test_half_hvdc_link_rejected(client) -> None:
    doc = reset_with_devices([{"id": "t1", "kind": "hvdc", "node": "paris",
                               "params": {"link_id": "lonely", "p_max_mw": 1000.0}}])
    assert client.post("/gb/net/reset", json=doc).status_code == 400


# --- battery -------------------------------------------------------------


def test_battery_dispatch_and_soc(client) -> None:
    _reset(client, reset_with_devices())
    r0 = _step(client, 0, dt_s=60.0,
               device_commands={"bat_paris": {"dispatch_mw": 300.0}})
    bat = r0["devices"]["bat_paris"]
    assert bat["state"] == "online"
    # the quiet-time SoC-restoration term (±recharge_frac·P_n = 60 MW) leans
    # against sustained discharge — the DELIVERED band is p_set − recharge
    assert 220.0 < bat["p_mw"] <= 305.0
    soc0 = bat["soc"]
    r1 = _step(client, 1, dt_s=600.0,
               device_commands={"bat_paris": {"dispatch_mw": 300.0}})
    assert r1["devices"]["bat_paris"]["soc"] < soc0  # discharging drains it


def test_battery_ffr_on_trip(client) -> None:
    _reset(client, reset_with_devices())
    _step(client, 0, dt_s=30.0)
    res = _step(client, 1, dt_s=60.0,
                scheduled_events=[{"at_s_rel": 5.0, "kind": "trip",
                                   "element": "nuc_lyon"}])
    assert res["islands"]["0"]["f_min"] < 49.99  # the event bit
    assert res["devices"]["bat_paris"]["p_mw"] > 10.0  # FFR discharging
    assert res["devices"]["bat_paris"]["soc"] < 0.55


# --- H2 chain ------------------------------------------------------------


def test_electrolyzer_fills_store(client) -> None:
    _reset(client, reset_with_devices())
    res = _step(client, 0, dt_s=900.0,
                device_commands={"ely_hamburg": {"dispatch_mw": 400.0}})
    ely = res["devices"]["ely_hamburg"]
    store = res["devices"]["cavern_north"]
    # slight under-frequency sheds a few % of flexible load (shed ramp
    # db 10 mHz → full at 200 mHz) — the command lands minus that shed
    assert -401.0 <= ely["p_mw"] < -360.0  # a load: negative injection
    assert store["injected_kg_step"] > 1000.0
    assert store["h2_kg"] > 2_000_000.0


def test_h2_plant_draws_store(client) -> None:
    native = copy.deepcopy(NATIVE)
    for plant in native["plants"]["plants"]:
        if plant["id"] == "ccgt_brussels":
            plant["fuel"] = "h2"
            plant["h2_store_id"] = "cavern_north"
    doc = reset_doc(native)
    doc["devices"] = devices_full()
    _reset(client, doc)
    res = _step(client, 0, dt_s=900.0)
    store = res["devices"]["cavern_north"]
    # the 4 000 t cavern withdraws at most 45 t/h — over 900 s that is
    # 11.25 t, which feeds ≈ 900 MW of CCGT: the plant DERATES to the store
    assert store["withdrawn_kg_step"] == pytest.approx(11_250.0, rel=0.05)
    plant = res["devices"]["ccgt_brussels"]
    assert 700.0 < plant["p_mw"] < 1000.0  # burning, capped by withdrawal


def test_h2_plant_without_store_rejected(client) -> None:
    native = copy.deepcopy(NATIVE)
    native["plants"]["plants"][1]["fuel"] = "h2"  # no h2_store_id
    doc = reset_doc(native)
    assert client.post("/gb/net/reset", json=doc).status_code == 400


# --- HVDC link -----------------------------------------------------------


def test_hvdc_paired_injection_frequency_neutral(client) -> None:
    _reset(client, reset_with_devices())
    _step(client, 0, dt_s=30.0)
    res = _step(client, 1, dt_s=60.0,
                device_commands={"hvdc_suedlink_n": {"dispatch_mw": 1500.0}})
    north = res["devices"]["hvdc_suedlink_n"]
    south = res["devices"]["hvdc_suedlink_s"]
    loss = path_loss_frac(700.0)
    assert north["p_mw"] == pytest.approx(-1500.0, abs=10.0)  # sending end draws
    assert south["p_mw"] == pytest.approx(1500.0 * (1.0 - loss), abs=10.0)
    # embedded link: the ±P pair cancels in the COI ledger — f barely moves
    assert abs(res["islands"]["0"]["f_min"] - 50.0) < 0.15
    assert abs(res["islands"]["0"]["f_max"] - 50.0) < 0.15


def test_hvdc_trip_is_not_an_infeed_loss(client) -> None:
    _reset(client, reset_with_devices())
    _step(client, 0, dt_s=30.0,
          device_commands={"hvdc_suedlink_n": {"dispatch_mw": 1500.0}})
    res = _step(client, 1, dt_s=60.0,
                scheduled_events=[{"at_s_rel": 5.0, "kind": "trip",
                                   "element": "hvdc_suedlink_n"}])
    assert res["devices"]["hvdc_suedlink_n"]["state"] == "tripped"
    assert res["devices"]["hvdc_suedlink_n"]["p_mw"] == 0.0
    assert res["devices"]["hvdc_suedlink_s"]["p_mw"] == 0.0
    # ledger change ≈ losses (tens of MW) — nothing like a 1.5 GW infeed loss
    assert abs(res["islands"]["0"]["f_min"] - 50.0) < 0.10


# --- offshore hub --------------------------------------------------------


def test_hub_delivery_minus_losses(client) -> None:
    _reset(client, reset_with_devices())
    # the hub SLEWS to its avail target (20 %/min front-crossing rate) —
    # and 1.8 GW would overload the copenhagen corridor and TRIP it (the
    # P8 duty layer; covered by test_hub_overload_islands_copenhagen), so
    # the delivery check runs at a corridor-safe 900 MW
    _step(client, 0, dt_s=300.0, avail_mw={"hub_dogger": 900.0})
    res = _step(client, 1, dt_s=120.0, avail_mw={"hub_dogger": 900.0})
    hub = res["devices"]["hub_dogger"]
    assert hub["p_mw"] == pytest.approx(900.0 * (1.0 - HUB_LOSS), rel=0.02)
    assert hub["avail_mw"] == pytest.approx(900.0 * (1.0 - HUB_LOSS), rel=1e-6)


def test_hub_overload_islands_copenhagen(client) -> None:
    """P8 cascade, zero special code: 1.75 GW of hub delivery overloads the
    copenhagen corridor -> duty/instant trip -> island_split; both islands
    keep solving (per-island slack election)."""
    _reset(client, reset_with_devices())
    _step(client, 0, dt_s=300.0, avail_mw={"hub_dogger": 1800.0})
    res = _step(client, 1, dt_s=300.0, avail_mw={"hub_dogger": 1800.0})
    events = res["events"] + _step(client, 2, dt_s=300.0,
                                   avail_mw={"hub_dogger": 1800.0})["events"]
    kinds = {e["kind"] for e in events}
    assert "line_trip" in kinds
    assert "island_split" in kinds
    final = _step(client, 3, dt_s=60.0, avail_mw={"hub_dogger": 1800.0})
    assert len(final["islands"]) >= 2
    # the islanded pocket carries a ~2 GW surplus: over-frequency outruns
    # LFSM-O, its only sync unit f-window-trips at 51.5, the pocket dies —
    # while the main island keeps solving with its own slack
    islands = final["islands"]
    assert not islands["0"]["blackout"]
    assert any(islands[i]["blackout"] for i in islands if i != "0")
    assert any(e["kind"] == "trip" and e["data"].get("cause") == "f_window"
               for e in events)
    assert final["zones"]["copenhagen"]["supplied"] == 0.0
    assert final["zones"]["paris"]["supplied"] == 1.0
    assert final["status"] == "converged"  # the surviving island still solves


def test_hub_rating_clamps_avail(client) -> None:
    _reset(client, reset_with_devices())
    res = _step(client, 0, dt_s=60.0, avail_mw={"hub_dogger": 5000.0})
    hub = res["devices"]["hub_dogger"]
    assert hub["avail_mw"] == pytest.approx(2000.0 * (1.0 - HUB_LOSS), rel=1e-6)


def test_hub_trip_is_an_infeed_loss(client) -> None:
    _reset(client, reset_with_devices())
    _step(client, 0, dt_s=300.0, avail_mw={"hub_dogger": 1800.0})
    res = _step(client, 1, dt_s=60.0, avail_mw={"hub_dogger": 1800.0},
                scheduled_events=[{"at_s_rel": 5.0, "kind": "trip",
                                   "element": "hub_dogger"}])
    assert res["devices"]["hub_dogger"]["state"] == "tripped"
    assert res["devices"]["hub_dogger"]["p_mw"] == 0.0
    # ~1.75 GW of delivery vanishes in one step: a genuine frequency event
    assert res["islands"]["0"]["f_min"] < 49.95


# --- snapshot round-trip -------------------------------------------------


def test_snapshot_roundtrip_carries_device_state(client) -> None:
    _reset(client, reset_with_devices())
    _step(client, 0, dt_s=300.0,
          device_commands={"bat_paris": {"dispatch_mw": 200.0},
                           "ely_hamburg": {"dispatch_mw": 300.0},
                           "hvdc_suedlink_n": {"dispatch_mw": 800.0}})
    snap = client.get("/gb/snapshot").json()
    ref = _step(client, 1, dt_s=60.0)

    doc = reset_with_devices()
    doc["snapshot"] = snap
    out = _reset(client, doc)
    assert out["status"] == "ok"  # hash matched — devices are IN the hash
    replay = _step(client, 1, dt_s=60.0)
    assert replay["islands"]["0"]["f_hz"] == ref["islands"]["0"]["f_hz"]
    assert replay["devices"]["bat_paris"]["soc_mwh"] == \
        ref["devices"]["bat_paris"]["soc_mwh"]
    assert replay["devices"]["cavern_north"]["h2_kg"] == \
        ref["devices"]["cavern_north"]["h2_kg"]
    assert replay["devices"]["hvdc_suedlink_s"]["p_mw"] == \
        ref["devices"]["hvdc_suedlink_s"]["p_mw"]
