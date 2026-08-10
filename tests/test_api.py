from __future__ import annotations

from fastapi.testclient import TestClient

from rttransportflow import APP_NAME, __version__


def test_health_identity(app) -> None:
    with TestClient(app) as client:
        body = client.get("/health").json()
    assert body == {"app": APP_NAME, "version": __version__}


def test_state_404_before_first_step(app) -> None:
    with TestClient(app) as client:
        assert client.get("/state").status_code == 404


def test_status_and_control_flow(app) -> None:
    with TestClient(app) as client:
        status = client.get("/status").json()
        assert status["running"] is False
        assert status["step"] == 0 and status["day"] == 0

        assert client.post("/control/start").json()["running"] is True
        assert client.post("/control/pause").json()["paused"] is True
        assert client.post("/control/resume").json()["paused"] is False

        # The tick loop produces results the surface can serve.
        deadline_attempts = 200
        state = None
        for _ in range(deadline_attempts):
            response = client.get("/state")
            if response.status_code == 200:
                state = response.json()
                break
        assert state is not None and state["converged"] is True
        assert isinstance(client.get("/history").json(), list)


def test_ws_streams_step_results(app) -> None:
    with TestClient(app) as client:
        client.post("/control/start")
        with client.websocket_connect("/ws") as ws:
            frame = ws.receive_json()
    assert frame["converged"] is True
    assert "step" in frame and "day" in frame
