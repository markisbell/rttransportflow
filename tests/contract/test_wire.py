"""Wire-level contract checks over a real socket (HTTP + WebSocket)."""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import jsonschema
import pytest

from tests.helpers.wire import boundary_for_step, reset_doc

SCHEMA_DIR = Path(__file__).resolve().parent.parent.parent / "docs" / "contract" / "schemas"


def _schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text())


def test_schemas_validate_the_live_wire(backend) -> None:
    """The P4 freeze artifact, finally ENFORCED: until this test the three
    schema files were referenced by nothing and free to rot. The bodies this
    suite sends and the frames the backend answers must satisfy the
    machine-readable contract. Corrections go INTO the schemas from the live
    wire, never the reverse (the wire is frozen at 2.0)."""
    reset_body = reset_doc()
    jsonschema.validate(reset_body, _schema("reset.schema.json"))
    r = httpx.post(f"{backend}/gb/net/reset", json=reset_body, timeout=60.0)
    assert r.status_code == 200

    body = {"t": 0, "dt_s": 60.0, "interrupt_on_event": False,
            **boundary_for_step(0)}
    jsonschema.validate(body, _schema("step-request.schema.json"))
    res = httpx.post(f"{backend}/gb/step", json=body, timeout=60.0)
    assert res.status_code == 200
    jsonschema.validate(res.json(), _schema("step-result.schema.json"))


def test_handshake_over_the_wire(backend) -> None:
    v = httpx.get(f"{backend}/gb/version", timeout=5.0).json()
    assert v["contract"] == "2.0"
    assert v["units"]["power"] == "MW"
    assert v["external_clock"] is True


def test_reset_step_sequence_and_ordering(backend) -> None:
    r = httpx.post(f"{backend}/gb/net/reset", json=reset_doc(), timeout=60.0)
    assert r.status_code == 200 and r.json()["status"] == "ok"

    body = {"t": 0, "dt_s": 60.0, "interrupt_on_event": False, **boundary_for_step(0)}
    res = httpx.post(f"{backend}/gb/step", json=body, timeout=60.0)
    assert res.status_code == 200
    assert res.json()["dt_done_s"] == pytest.approx(60.0)

    # Godot float-int coercion over the real wire.
    body2 = {"t": 1.0, "dt_s": 60, "interrupt_on_event": False, **boundary_for_step(0)}
    assert httpx.post(f"{backend}/gb/step", json=body2, timeout=60.0).status_code == 200

    # Out-of-order over the real wire: 409 with a FLAT body (= WS frame shape).
    bad = httpx.post(f"{backend}/gb/step", json={"t": 9, "dt_s": 1.0}, timeout=30.0)
    assert bad.status_code == 409
    assert bad.json()["error"] == "out_of_order"
    assert bad.json()["expected"] == [1, 2]

    # Idempotent re-send returns the cached frame byte-identically.
    again = httpx.post(f"{backend}/gb/step", json=body2, timeout=60.0)
    assert again.json() == res_json_of_t1(backend)


def res_json_of_t1(backend) -> dict:
    return httpx.get(f"{backend}/gb/result/latest", timeout=30.0).json()


def test_ws_step_channel_over_the_wire(backend) -> None:
    from websockets.sync.client import connect

    httpx.post(f"{backend}/gb/net/reset", json=reset_doc(), timeout=60.0)
    ws_url = backend.replace("http://", "ws://") + "/gb/ws"
    with connect(ws_url, close_timeout=5) as ws:
        ws.send(json.dumps({"t": 0, "dt_s": 30.0, "interrupt_on_event": False,
                            **boundary_for_step(0)}))
        res = json.loads(ws.recv(timeout=60))
        assert res["t"] == 0
        assert res["dt_done_s"] == pytest.approx(30.0)
        assert res["islands"]["0"]["f_hz"] > 49.5
        # the WS frame is the SAME shape as the HTTP result (contract rule)
        jsonschema.validate(res, _schema("step-result.schema.json"))

        ws.send(json.dumps({"t": 4, "dt_s": 1.0}))
        err = json.loads(ws.recv(timeout=30))
        assert err["error"] == "out_of_order"


def test_no_nan_in_wire_json(backend) -> None:
    httpx.post(f"{backend}/gb/net/reset", json=reset_doc(), timeout=60.0)
    body = {"t": 0, "dt_s": 60.0, "interrupt_on_event": False, **boundary_for_step(0)}
    raw = httpx.post(f"{backend}/gb/step", json=body, timeout=60.0).text
    assert "NaN" not in raw and "Infinity" not in raw  # browsers/Godot reject them
