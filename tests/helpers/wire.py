"""Shared gamebridge wire fixtures.

Previously module-level in test_gamebridge / test_wire_devices / test_replay
and imported across test modules two different ways — importing a helper
executed another test file's module-level side effects, and the drifted step
helpers meant a copied test could silently send different wire bodies than
intended. One home, one merge rule.
"""

from __future__ import annotations

import json
from pathlib import Path

from rttransportflow.models import SYNC_KINDS

BUNDLE_DIR = (
    Path(__file__).resolve().parent.parent.parent / "data" / "grids" / "europe_mini"
)


def load_native() -> dict:
    return {
        name: json.loads((BUNDLE_DIR / f"{name}.json").read_text())
        for name in ("grid", "lines", "plants", "load_centers", "scenario")
    }


NATIVE = load_native()


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


def do_reset(client, doc: dict | None = None) -> dict:
    response = client.post("/gb/net/reset", json=doc or reset_doc())
    assert response.status_code == 200, response.text
    return response.json()


def do_step(client, t: int, dt_s: float = 900.0, *,
            boundary_step: int | None = None, **extra) -> dict:
    """The ONE step helper. Boundary defaults to the per-t profile column
    (min(t, 95)); pass boundary_step=0 for the fixed-boundary device suites.
    Boundary-key extras MERGE into the profile boundary — never clobber it.
    """
    step = min(t, 95) if boundary_step is None else boundary_step
    body = {"t": t, "dt_s": dt_s, "interrupt_on_event": False,
            **boundary_for_step(step)}
    for key, value in extra.items():
        if key in ("zone_demand", "avail_mw", "device_commands"):
            body[key] = {**body.get(key, {}), **value}  # merge, don't clobber
        else:
            body[key] = value
    response = client.post("/gb/step", json=body)
    assert response.status_code == 200, response.text
    return response.json()
