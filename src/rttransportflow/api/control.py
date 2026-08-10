"""Clock control for standalone mode: /control/start|pause|resume."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Request

router = APIRouter(prefix="/control")


def _container(request: Request):
    return request.app.state.container


@router.post("/start")
async def start(request: Request) -> dict:
    c = _container(request)
    if c.settings.external_clock:
        raise HTTPException(status_code=409, detail="external clock owns time")
    await c.engine.start()
    return {"running": c.engine.running}


@router.post("/pause")
def pause(request: Request) -> dict:
    c = _container(request)
    c.engine.pause()
    return {"paused": c.engine.paused}


@router.post("/resume")
def resume(request: Request) -> dict:
    c = _container(request)
    c.engine.resume()
    return {"paused": c.engine.paused}
