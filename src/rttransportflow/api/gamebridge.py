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
from ..dynamics.integrator import ModeConfig
from ..simulator import (
    SIM_SNAPSHOT_VERSION,
    DynSimulator,
    WireDeviceError,
    _as_int,
    _r,
)
from ..snapshot import model_hash

CONTRACT = "2.0"
NETWORK_KIND = "transmission"
# dt_s bounds are CONTRACT numbers (schema: minimum 0.05, maximum 900) —
# not operator knobs; the schema, this pair and the error message agree.
MIN_DT_S = 0.05
MAX_DT_S = 900.0
# a replay window longer than ring retention is a guaranteed window_expired
REPLAY_WINDOW_MAX_S = DynSimulator.RING_RETAIN_US / US

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
        # reset ingredients — /gb/replay rebuilds a THROWAWAY sim from these
        self.data: Any = None
        self.wire_devices: list[dict] = []
        self.protection_seed: int = 0
        self.sim_kwargs: dict[str, Any] = {}


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

    # ONE kwargs source for the live build AND the replay reconstruction —
    # the split constructor was exactly the drift that produces a replay
    # running with different sim options than the live run, silently
    # (replay pins only compare replay-vs-replay).
    protection_seed = _as_int(body.get("protection_seed", 0.0))
    sim_kwargs = {
        "steps_per_day": data.scenario.steps_per_day,
        "d_load_pct_per_hz": container.settings.d_load_pct_per_hz,
        "warm_start": container.settings.warm_start,
        "catalog_path": container.settings.catalog_path,
        "mode_cfg": ModeConfig.from_settings(container.settings),
    }

    def build() -> DynSimulator:
        sim = DynSimulator(
            data, build_network(data),
            wire_devices=wire_devices,
            protection_seed=protection_seed,
            **sim_kwargs,
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
                and snapshot_blob.get("version") == SIM_SNAPSHOT_VERSION):
            sim.restore_blob(snapshot_blob["blob"])
        else:
            status = "refused_snapshot"  # applied WITHOUT it — game cold-starts

    gb = GbState(sim, body.get("name", "unnamed"), hash_)
    gb.data = data
    gb.wire_devices = wire_devices
    gb.protection_seed = protection_seed
    gb.sim_kwargs = sim_kwargs
    sim.enable_snapshot_ring()
    request.app.state.gb = gb
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
            # add/remove_device were planned for P5/P7 and deliberately never
            # landed: every topology edit goes through the full debounced
            # reset instead (P5 §6). Rejected loudly, never ignored.
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
    if not (MIN_DT_S <= dt_s <= MAX_DT_S):
        return None, {"error": f"dt_s {dt_s} outside [{MIN_DT_S}, {MAX_DT_S:g}]"}
    interrupt = bool(body.get("interrupt_on_event", True))

    sim = gb.sim
    t0 = time.perf_counter()
    # From here on, ANY exception is DATA (family never-crash rule, ledger
    # 36): a raised step used to kill the WS handler while /health stayed
    # green — the game then froze forever against a live-but-deaf backend.
    # The guard covers the BOUNDARY PROLOGUE too: its old start line was an
    # accident of where _step_body was cut, so a prologue exception 500ed
    # over HTTP and produced a third, undocumented error shape over WS. A
    # failed frame after a partially applied boundary is the documented
    # semantic — engine exceptions leave applied boundary state as well,
    # and sample-and-hold covers the next step.
    try:
        notes = sim.apply_wire_boundary(
            body.get("zone_demand"), body.get("avail_mw"), body.get("device_commands"))
        for zone_id, zcmd in (body.get("zone_commands") or {}).items():
            restore = zcmd.get("restore_load")
            if restore is not None:
                bus = sim._zone_bus.get(zone_id)
                if bus is None:
                    notes.append(f"zone_commands: unknown zone {zone_id!r}")
                    continue
                # route to the zone's ACTUAL island (a stale pre-P8 comment
                # used to guard a hardcoded island 0 — restore_load on a
                # split island silently ramped island 0's defense plan)
                island = sim._bus_island[sim.built.bus_index[bus]]
                sim.integrator.defense.request_restore(island, float(restore))
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
        return _step_body(gb, body, t, dt_s, interrupt, notes, line_events, t0)
    except Exception as exc:  # noqa: BLE001 — the loop must survive anything
        result = _failed_frame(t, sim, exc)
        gb.last_t = t
        gb.last_result = result
        return result, None


def _failed_frame(t: int, sim, exc: Exception) -> dict:
    """The contract 'failed' frame — kept skeleton-key-identical to
    _step_body's result (a new top-level key must appear in BOTH)."""
    import traceback
    return _r({
        "t": t, "status": "failed", "solve_ms": 0.0,
        "dt_done_s": 0.0, "t_sim_end": sim.integrator.t_us / US,
        "mode": sim.integrator.mode,
        "islands": {}, "trajectory": {"t_rel_s": [], "islands": {}, "watched": {}},
        "pf": {"latest": {}, "window_extremes": {}},
        "devices": {}, "zones": {}, "events": [],
        "violations": [{"element": "engine", "kind": "exception",
                        "severity": "critical",
                        "value": f"{type(exc).__name__}: {exc}"}],
        "summary": {"balance_err": 0.0,
                    "traceback": traceback.format_exc()[-2000:]},
    })


def _events_wire(res) -> list[dict]:
    """AdvanceResult events -> wire shape (shared by _step_body and replay —
    'physics exactly once' now covers the wire assembly around it too)."""
    return [{"t_sim": e.t_us / US, "kind": e.kind,
             "element": e.element, "data": e.data} for e in res.events]


def _step_body(gb: GbState, body: dict, t: int, dt_s: float, interrupt: bool,
               notes: list, line_events: list,
               t0: float) -> tuple[dict | None, dict | None]:
    """Frame assembly only: the state projection lives ON the simulator
    (ReportingMixin) — this layer keeps _r(), the idempotency cache, and the
    request-scoped notes. Result key order is contract-observable (goldens
    compare serialized frames): keep it."""
    sim = gb.sim

    meters = sim.begin_step()
    res = sim.integrator.advance(s_to_us(dt_s), interrupt_on_event=interrupt)

    devices = sim.device_report(meters)
    zones = sim.zone_report()
    violations = sim.pf_violations()
    for note in notes:
        violations.append({"element": "request", "kind": "tolerated",
                           "severity": "info", "value": note})
    pf_latest, pf_window = sim.pf_report()

    result = _r({
        "t": t,
        "status": "converged" if sim._pf_ok else "degraded",
        "solve_ms": (time.perf_counter() - t0) * 1e3,
        "dt_done_s": res.dt_done_us / US,
        "t_sim_end": sim.integrator.t_us / US,
        "mode": res.mode,
        "islands": sim.islands_report(res),
        "trajectory": res.trajectory,
        "pf": {
            "latest": pf_latest,
            "window_extremes": pf_window,
        },
        "devices": devices,
        "zones": zones,
        "events": ([{"t_sim": sim.integrator.t_us / US, "kind": k,
                     "element": el, "data": d} for k, el, d in line_events]
                   + _events_wire(res)),
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
            try:
                async with gb.lock:
                    result, error = await asyncio.to_thread(_handle_step, gb, body)
            except Exception as exc:  # noqa: BLE001 — a raise must not deafen the WS
                result, error = None, {"error": "step_failed",
                                       "detail": f"{type(exc).__name__}: {exc}"}
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
        "version": SIM_SNAPSHOT_VERSION,
        "blob": gb.sim.state_blob(),  # repr floats — bit-exact (v2: + topology)
    }


@router.post("/replay")
async def replay(request: Request) -> dict:
    """Counterfactual re-run of an event window (contract v2, ledger 23):
    restore the newest ring snapshot at or before `t_sim`, apply overrides,
    integrate forward on a THROWAWAY sim — the live state is never touched
    and the physics runs exactly once (same engine code). The PF hook stays
    off: losses ride sample-and-hold from the snapshot (documented). The ring
    entry AT an event instant is captured post-application — a replay
    anchored on the event t_sim replays the AFTERMATH, which is what the
    ghost traces compare (GAME_DESIGN §4.5)."""
    gb = _gb(request)
    body = await request.json()
    if "t_sim" not in body:
        # wire events carry no ids — the game addresses windows by t_sim
        raise HTTPException(status_code=400, detail="t_sim required")
    t_sim = float(body["t_sim"])
    window_s = min(float(body.get("window_s", 65.0)), REPLAY_WINDOW_MAX_S)
    hit = gb.sim.ring_lookup(s_to_us(t_sim))
    if hit is None:
        return {"status": "window_expired"}
    t0_us, blob = hit
    overrides = body.get("overrides") or {}

    def run():
        from ..network_builder import build_network

        sim = DynSimulator(gb.data, build_network(gb.data),
                           wire_devices=gb.wire_devices,
                           protection_seed=gb.protection_seed,
                           **gb.sim_kwargs)
        sim.integrator.pf_hook = None  # replay: swing only, losses frozen
        sim.restore_blob(blob)
        notes: list[str] = []
        for device_id in overrides.get("remove_devices", []) or []:
            try:
                sim.fleet.trip(str(device_id), sim.integrator.t_us)
                sim.integrator.refresh_e_k()
            except KeyError:
                notes.append(f"remove_devices: unknown {device_id!r}")
        for device_id, params in (overrides.get("set_params") or {}).items():
            notes += sim.apply_wire_boundary(None, None, {device_id: params})
        if overrides.get("add_devices"):
            notes.append("add_devices: unsupported in replay")
        horizon_us = s_to_us(t_sim + window_s) - sim.integrator.t_us
        res = sim.integrator.advance(max(horizon_us, QUANTUM_US),
                                     interrupt_on_event=False)
        return sim, res, notes

    sim2, res, notes = await asyncio.to_thread(run)
    islands2 = sim2.integrator.islands
    return _r({
        "status": "ok",
        "t_start": t0_us / US,
        "t_end": sim2.integrator.t_us / US,
        "trajectory": res.trajectory,
        "islands": {str(i): {"f_hz": float(islands2.f[i]),
                             "f_min": float(res.f_min[i]) if i < len(res.f_min)
                             else float(islands2.f[i]),
                             "blackout": bool(islands2.blackout()[i]),
                             "w": float(islands2.w[i])}
                    for i in range(islands2.n)},
        "events": _events_wire(res),
        "notes": notes,
    })


@router.get("/telemetry/ring")
def telemetry_ring(request: Request,
                   window_s: float = REPLAY_WINDOW_MAX_S) -> dict:
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
