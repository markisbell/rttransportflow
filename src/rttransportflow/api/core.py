"""Core surface: /, /health, /status, /state, /history, /ws."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse

from .. import APP_NAME, __version__

router = APIRouter()


def _container(request: Request):
    return request.app.state.container


@router.get("/", response_class=HTMLResponse)
def index() -> str:
    return (
        "<!doctype html><title>rttransportflow</title>"
        "<h1>rttransportflow</h1>"
        "<p>Realtime transmission-grid simulator. See <a href='/docs'>/docs</a>, "
        "<a href='/health'>/health</a>, <a href='/state'>/state</a>.</p>"
    )


@router.get("/health")
def health() -> dict:
    # Identity payload: lets port-sharing siblings be told apart (family rule).
    return {"app": APP_NAME, "version": __version__}


@router.get("/status")
def status(request: Request) -> dict:
    c = _container(request)
    return {
        "running": c.engine.running,
        "paused": c.engine.paused,
        "external_clock": c.settings.external_clock,
        "step": c.engine.step,
        "day": c.engine.day,
        "steps_per_day": c.settings.steps_per_day,
        "step_interval_seconds": c.settings.step_interval_seconds,
    }


@router.get("/state")
def state(request: Request) -> dict:
    c = _container(request)
    if c.store.latest is None:
        raise HTTPException(status_code=404, detail="no step solved yet")
    return c.store.latest.to_wire()


@router.get("/history")
def history(request: Request, limit: int = 100) -> list[dict]:
    c = _container(request)
    return [r.to_wire() for r in c.store.history(limit)]


@router.websocket("/ws")
async def ws(websocket: WebSocket) -> None:
    container = websocket.app.state.container
    await websocket.accept()
    queue = container.store.subscribe()
    try:
        while True:
            frame = await queue.get()
            await websocket.send_json(frame)
    except (WebSocketDisconnect, asyncio.CancelledError):
        pass
    finally:
        container.store.unsubscribe(queue)
