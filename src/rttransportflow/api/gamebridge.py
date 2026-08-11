"""Gamebridge v2 — the game-owns-time wire (authority: docs/contract/v2.md).

Ground rules implemented here: HTTP control plane + WS step channel (one
frame in → one out, strictly sequential; POST /gb/step identical fallback);
divergence is DATA at HTTP 200; idempotent last-`t` cache returned BEFORE any
state application; any other `t` → 409/`out_of_order`; sample-and-hold;
warmup PF at every reset; reset clears the idempotency cache; `_as_int`
tolerance for Godot's float-ints; `_r()` on every wire float (snapshot blob
exempt: repr floats).
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect

from .. import APP_NAME, __version__
from ..dynamics import QUANTUM_US, US, s_to_us
from ..dynamics.events import Event
from ..simulator import DynSimulator, WireDeviceError, _as_int, _r
from ..snapshot import model_hash

CONTRACT = "2.0"
NETWORK_KIND = "transmission"
MIN_DT_S = 0.05
SNAPSHOT_VERSION = 2

router = APIRouter(prefix="/gb")


class GbState:
    """Per-reset gamebridge session state (family: rebuilt on every reset)."""

    def __init__(self, sim: DynSimulator, name: str, hash_: str) -> None:
        self.sim = sim
        self.name = name
        self.model_hash = hash_
        self.last_t: int | None = None
        self.last_result: dict[str, Any] | None = None
        self.lock = asyncio.Lock()  # strictly sequential step channel


def _gb(request_or_ws) -> GbState:
    gb = getattr(request_or_ws.app.state, "gb", None)
    if gb is None:
        raise HTTPException(status_code=409, detail="no network loaded — POST /gb/net/reset first")
    return gb


@router.get("/version")
def version(request: Request) -> dict:
    container = request.app.state.container
    import pandapower

    return {
        "contract": CONTRACT,
        "backend": APP_NAME,
        "api": __version__,
        "solver": {"pf": f"pandapower {pandapower.__version__}", "dyn": "rttf-dyn/1"},
        "external_clock": container.settings.external_clock,
        "units": {"power": "MW"},
    }


@router.post("/net/reset")
async def net_reset(request: Request) -> dict:
    body = await request.json()
    container = request.app.state.container

    if body.get("contract", "").split(".")[0] != CONTRACT.split(".")[0]:
        raise HTTPException(status_code=409, detail=f"contract major mismatch (backend {CONTRACT})")
    if body.get("network_kind") != NETWORK_KIND:
        raise HTTPException(status_code=400, detail=f"network_kind must be {NETWORK_KIND!r}")
    native = body.get("native")
    if not isinstance(native, dict):
        raise HTTPException(status_code=400, detail="native bundle missing")

    from ..data_loader import BundleError, input_data_from_dicts
    from ..network_builder import build_network

    try:
        data = input_data_from_dicts(
            grid=native["grid"], lines=native["lines"], plants=native["plants"],
            load_centers=native["load_centers"], scenario=native["scenario"],
        )
    except (KeyError, BundleError) as exc:
        raise HTTPException(status_code=400, detail=f"invalid native bundle: {exc}") from None

    wire_devices = body.get("devices", [])
    allowed_kinds = {"battery", "grid_forming", "electrolyzer", "h2_store",
                     "hvdc", "offshore_hub"}
    unsupported = sorted({str(d.get("kind")) for d in wire_devices
                          if d.get("kind") not in allowed_kinds})
    if unsupported:
        # sync_plant/wind/pv travel in the native bundle; reject loudly, never ignore.
        raise HTTPException(status_code=400,
                            detail=f"unsupported reset device kinds: {unsupported}")

    def build() -> DynSimulator:
        sim = DynSimulator(
            data, build_network(data),
            steps_per_day=data.scenario.steps_per_day,
            d_load_pct_per_hz=container.settings.d_load_pct_per_hz,
            warm_start=container.settings.warm_start,
            catalog_path=container.settings.catalog_path,
            wire_devices=wire_devices,
            protection_seed=_as_int(body.get("protection_seed", 0.0)),
        )
        sim.warmup()
        return sim

    t0 = time.perf_counter()
    try:
        sim = await asyncio.to_thread(build)
    except WireDeviceError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    warmup_ms = (time.perf_counter() - t0) * 1e3

    hash_ = model_hash(sim.fleet)
    status = "ok"
    snapshot_blob = body.get("snapshot")
    if snapshot_blob is not None:
        if (snapshot_blob.get("model_hash") == hash_
                and snapshot_blob.get("version") == SNAPSHOT_VERSION):
            sim.restore_blob(snapshot_blob["blob"])
        else:
            status = "refused_snapshot"  # applied WITHOUT it — game cold-starts

    request.app.state.gb = GbState(sim, body.get("name", "unnamed"), hash_)
    island = sim.integrator.islands
    return _r({
        "status": status,
        "warmup_solve_ms": warmup_ms,
        "model_hash": hash_,
        "islands": {"0": {"f_hz": float(island.f[0]),
                          "e_k_mj": float(island.e_k[0])}},
    })


@router.post("/net/patch")
async def net_patch(request: Request) -> dict:
    gb = _gb(request)
    body = await request.json()
    results = []
    for op in body.get("ops", []):
        kind = op.get("op")
        if kind == "set_device":
            notes = gb.sim.apply_wire_boundary(None, None,
                                               {op["id"]: op.get("params", {})})
            results.append({"applied": not notes, "error": "; ".join(notes) or None})
        else:
            # add/remove_device land in P5/P7 — rejected loudly, never ignored.
            results.append({"applied": False, "error": f"unsupported op {kind!r} in P4"})
    return {"results": results}


def _step_error(expected: list[int]) -> dict:
    return {"error": "out_of_order", "expected": expected}


def _handle_step(gb: GbState, body: dict) -> tuple[dict | None, dict | None]:
    """Returns (result, error). Idempotent cache checked BEFORE any state
    application (family rule — never double-integrates)."""
    try:
        t = _as_int(body["t"])
    except (KeyError, ValueError) as exc:
        return None, {"error": f"bad t: {exc}"}

    if gb.last_t is not None and t == gb.last_t:
        return gb.last_result, None
    # After a reset (last_t is None) ANY t is legal as the first step — the
    # game clock continues across resets (v1 rule carried into v2; found by
    # the game-shell integration).
    if gb.last_t is not None and t != gb.last_t + 1:
        return None, _step_error([gb.last_t, gb.last_t + 1])

    dt_s = float(body.get("dt_s", 0.1))
    if not (MIN_DT_S <= dt_s <= 900.0):
        return None, {"error": f"dt_s {dt_s} outside [0.05, 900]"}
    interrupt = bool(body.get("interrupt_on_event", True))

    sim = gb.sim
    t0 = time.perf_counter()
    notes = sim.apply_wire_boundary(
        body.get("zone_demand"), body.get("avail_mw"), body.get("device_commands"))
    for zone_id, zcmd in (body.get("zone_commands") or {}).items():
        restore = zcmd.get("restore_load")
        if restore is not None:
            # zones map onto island 0 until the split/merge layer lands
            sim.integrator.defense.request_restore(0, float(restore))
    notes += sim.set_watch(body.get("watch", []))
    line_events = sim.apply_line_commands(body.get("line_commands"))
    for ev in body.get("scheduled_events", []):
        kind = ev.get("kind")
        if kind not in ("trip", "load_step", "line_trip", "line_close"):
            notes.append(f"scheduled_events: unsupported kind {kind!r}")
            continue
        at_us = sim.integrator.t_us + s_to_us(float(ev.get("at_s_rel", 0.0)))
        data = {"island": 0, "delta_mw": float(ev.get("delta_mw", 0.0))} \
            if kind == "load_step" else {}
        sim.integrator.queue.schedule(Event(max(at_us, sim.integrator.t_us + QUANTUM_US),
                                            kind, ev.get("element", ""), data))

    # meters before, for per-step deltas
    e_before = sim.fleet.energy_mwh.copy()
    fuel_before = sim.fleet.fuel_mwh_th.copy()
    inv_e_before = sim.fleet.inv_energy_mwh.copy()
    ely_e_before = sim.fleet.ely_energy_mwh.copy()
    h2 = sim.fleet.h2
    h2_wd_before = h2.withdrawn_kg.copy() if h2 is not None else None
    h2_in_before = h2.injected_kg.copy() if h2 is not None else None
    sim._pf_window_max = {}

    res = sim.integrator.advance(s_to_us(dt_s), interrupt_on_event=interrupt)

    island = sim.integrator.islands
    n_islands = island.n
    s_online_arr = sim.fleet.s_online_per_island(n_islands)
    fcr_arr = getattr(sim.fleet, "fcr_used", None)

    devices: dict[str, Any] = {}
    status_names = {0: "offline", 1: "starting", 2: "online"}
    for pid, row in sim._sync_row.items():
        state = status_names[int(sim.fleet.status[row])]
        if state == "offline" and sim.fleet.tripped_at_us[row] >= 0:
            state = "tripped"
        if state == "online" and sim.fleet.h2_starved is not None \
                and bool(sim.fleet.h2_starved[row]):
            state = "starved"
        devices[pid] = {
            "p_mw": float(sim.fleet.y[row]),
            "state": state,
            "headroom_mw": max(0.0, float(sim.fleet.p_max[row] - sim.fleet.y[row])),
            "energy_mwh_step": float(sim.fleet.energy_mwh[row] - e_before[row]),
            "fuel_mwh_th_step": float(sim.fleet.fuel_mwh_th[row] - fuel_before[row]),
        }
    for pid, row in sim._inv_row.items():
        devices[pid] = {
            "p_mw": float(sim.fleet.inv_p[row]),
            "state": "online" if sim.fleet.inv_online[row] else "tripped",
            "avail_mw": float(sim.fleet.inv_avail[row]),
            "energy_mwh_step": float(sim.fleet.inv_energy_mwh[row] - inv_e_before[row]),
        }
    for pid, row in sim._bat_row.items():
        e_cap = float(sim.fleet.bat_e_mwh[row])
        devices[pid] = {
            "p_mw": float(sim.fleet.bat_p[row]),
            "state": "online" if sim.fleet.bat_online[row] else "tripped",
            "soc": float(sim.fleet.bat_soc[row]) / e_cap if e_cap > 0 else 0.0,
            "soc_mwh": float(sim.fleet.bat_soc[row]),
            "clamped": bool(sim.fleet.bat_clamped[row]),
        }
    for pid, row in sim._ely_row.items():
        devices[pid] = {
            "p_mw": -float(sim.fleet.ely_p[row]),  # a load: negative injection
            "state": "online" if sim.fleet.ely_online[row] else "tripped",
            "energy_mwh_step": float(sim.fleet.ely_energy_mwh[row] - ely_e_before[row]),
        }
    for sid, row in sim._store_row.items():
        devices[sid] = {
            "h2_kg": float(h2.level_kg[row]),
            "capacity_kg": float(h2.capacity_kg[row]),
            "injected_kg_step": float(h2.injected_kg[row] - h2_in_before[row]),
            "withdrawn_kg_step": float(h2.withdrawn_kg[row] - h2_wd_before[row]),
            "state": "online",
        }
    if sim.fleet.hvdc is not None:
        term_p = sim.fleet.hvdc.term_p()
        for tid, i in sim._term_row.items():
            link = int(sim.fleet.hvdc.term_link[i])
            devices[tid] = {
                "p_mw": float(term_p[i]),
                "q_mvar": float(sim.fleet.hvdc.term_q[i]),
                "state": "online" if sim.fleet.hvdc.online[link] else "tripped",
                "link_id": sim.fleet.hvdc.link_ids[link],
            }

    pf = sim._latest_pf
    zones = {}
    blackout = sim.integrator.islands.blackout()
    for zone_id, bus in sim._zone_bus.items():
        zone_island = sim._bus_island[sim.built.bus_index[bus]]
        detail = {}
        if pf.get("buses", {}).get(bus):
            detail["v_pu"] = pf["buses"][bus]["vm_pu"]
        zones[zone_id] = {"supplied": (0.0 if blackout[zone_island]
                                       else float(island.w[zone_island])),
                          "detail": detail}

    violations: list[dict[str, Any]] = []
    for line_id, vals in pf.get("lines", {}).items():
        loading = vals["loading_percent"]
        if loading > 120.0:
            violations.append({"element": line_id, "kind": "loading",
                               "severity": "critical", "value": loading})
        elif loading > 100.0:
            violations.append({"element": line_id, "kind": "loading",
                               "severity": "warning", "value": loading})
    for bus, vals in pf.get("buses", {}).items():
        vm = vals["vm_pu"]
        if vm < 0.90 or vm > 1.10:
            violations.append({"element": bus, "kind": "voltage",
                               "severity": "critical", "value": vm})
        elif vm < 0.95 or vm > 1.05:
            violations.append({"element": bus, "kind": "voltage",
                               "severity": "warning", "value": vm})
    for note in notes:
        violations.append({"element": "request", "kind": "tolerated",
                           "severity": "info", "value": note})

    result = _r({
        "t": t,
        "status": "converged" if sim._pf_ok else "degraded",
        "solve_ms": (time.perf_counter() - t0) * 1e3,
        "dt_done_s": res.dt_done_us / US,
        "t_sim_end": sim.integrator.t_us / US,
        "mode": res.mode,
        "islands": {str(i): {
            "f_hz": float(res.f_end[i]) if i < len(res.f_end) else float(island.f[i]),
            "rocof_hz_s": float(sim.integrator.rings[i].rocof_window(sim.integrator.t_us)),
            "f_min": float(res.f_min[i]) if i < len(res.f_min) else float(island.f[i]),
            "f_max": float(res.f_max[i]) if i < len(res.f_max) else float(island.f[i]),
            "rocof_max": float(res.rocof_max[i]) if i < len(res.rocof_max) else 0.0,
            "e_k_mj": float(island.e_k[i]),
            "s_online_mva": float(s_online_arr[i]),
            "h_sys_s": (float(island.e_k[i] / s_online_arr[i])
                        if s_online_arr[i] > 0 else 0.0),
            "blackout": bool(island.blackout()[i]),
            "fcr_used_mw": (float(fcr_arr[i])
                            if fcr_arr is not None and i < len(fcr_arr) else 0.0),
            "afrr_used_mw": 0.0,
            "w": float(island.w[i]),
        } for i in range(n_islands)},
        "trajectory": res.trajectory,
        "pf": {
            "latest": {k: v for k, v in pf.items()},
            "window_extremes": dict(sim._pf_window_max),
        },
        "devices": devices,
        "zones": zones,
        "events": ([{"t_sim": sim.integrator.t_us / US, "kind": k,
                     "element": el, "data": d} for k, el, d in line_events]
                   + [{"t_sim": e.t_us / US, "kind": e.kind,
                       "element": e.element, "data": e.data}
                      for e in res.events]),
        "violations": violations,
        "summary": {"balance_err": res.balance_err,
                    "pf_failures": sim._pf_fail_count},
    })
    gb.last_t = t
    gb.last_result = result
    return result, None


@router.post("/step")
async def step_http(request: Request):
    from fastapi.responses import JSONResponse

    gb = _gb(request)
    body = await request.json()
    async with gb.lock:
        result, error = await asyncio.to_thread(_handle_step, gb, body)
    if error is not None:
        # Flat body, identical to the WS out_of_order frame (contract shape).
        status = 409 if error.get("error") == "out_of_order" else 400
        return JSONResponse(status_code=status, content=error)
    return result


@router.websocket("/ws")
async def step_ws(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        while True:
            body = await websocket.receive_json()
            gb = getattr(websocket.app.state, "gb", None)
            if gb is None:
                await websocket.send_json({"error": "no_network"})
                continue
            async with gb.lock:
                result, error = await asyncio.to_thread(_handle_step, gb, body)
            await websocket.send_json(error if error is not None else result)
    except (WebSocketDisconnect, asyncio.CancelledError):
        pass


@router.get("/result/latest")
def result_latest(request: Request) -> dict:
    gb = _gb(request)
    if gb.last_result is None:
        raise HTTPException(status_code=404, detail="no step taken yet")
    return gb.last_result


@router.get("/snapshot")
def snapshot(request: Request) -> dict:
    gb = _gb(request)
    return {
        "t": gb.last_t,
        "t_sim": gb.sim.integrator.t_us / US,
        "model_hash": gb.model_hash,
        "version": SNAPSHOT_VERSION,
        "blob": gb.sim.state_blob(),  # repr floats — bit-exact (v2: + topology)
    }


@router.get("/telemetry/ring")
def telemetry_ring(request: Request, window_s: float = 120.0) -> dict:
    gb = _gb(request)
    ring = gb.sim.integrator.rings[0]
    t, f = ring._ordered()
    t_now = gb.sim.integrator.t_us
    cut = t_now - int(window_s * US)
    keep = t >= cut
    return _r({
        "t_sim": [float(v) / US for v in t[keep]],
        "f": [float(v) for v in f[keep]],
    })
