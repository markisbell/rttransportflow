"""Contract suite: spawns the REAL backend on port 8032 — the wire is the
authority; in-process fakes never are (family rule)."""

from __future__ import annotations

import os
import subprocess
import sys
import time

import httpx
import pytest

PORT = 8032  # family scheme: never 8000-8002 / 8010-8016 / 8020-8029
BASE = f"http://127.0.0.1:{PORT}"


@pytest.fixture(scope="session")
def backend():
    env = os.environ.copy()
    env.update(
        RTTRANSPORTFLOW_PORT=str(PORT),
        RTTRANSPORTFLOW_EXTERNAL_CLOCK="true",
        RTTRANSPORTFLOW_AUTOSTART="false",
        RTTRANSPORTFLOW_LOG_LEVEL="warning",
    )
    proc = subprocess.Popen(
        [sys.executable, "-m", "rttransportflow.main"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(100):
            try:
                r = httpx.get(f"{BASE}/health", timeout=1.0)
                if r.status_code == 200 and r.json().get("app") == "rttransportflow":
                    break
            except httpx.HTTPError:
                pass
            time.sleep(0.2)
        else:
            raise RuntimeError("backend on 8032 did not become healthy")
        yield BASE
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
