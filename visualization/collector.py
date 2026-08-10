"""Collector: poll the backend's REST /state and write to InfluxDB v2.

Stdlib only (urllib) — no dependencies beyond Python. Family split: the
collector reads REST (not the WS); day/step land as FIELDS, never tags
(family gotcha: tag cardinality).
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

API = os.environ.get("RTTF_API", "http://127.0.0.1:8003")
INFLUX_URL = os.environ.get("INFLUX_URL", "http://127.0.0.1:8089")
INFLUX_TOKEN = os.environ.get("INFLUX_TOKEN", "rttf-dev-token")
INFLUX_ORG = os.environ.get("INFLUX_ORG", "rttf")
INFLUX_BUCKET = os.environ.get("INFLUX_BUCKET", "rttf")
INTERVAL = float(os.environ.get("COLLECT_INTERVAL", "0.5"))


def fetch_state() -> dict | None:
    try:
        with urllib.request.urlopen(f"{API}/state", timeout=3) as resp:
            return json.load(resp)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
        return None


def esc_tag(value: str) -> str:
    return value.replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")


def to_lines(state: dict, ts_ns: int) -> str:
    lines: list[str] = []
    fields = [
        f"step={int(state['step'])}i",
        f"day={int(state['day'])}i",
        f"converged={1 if state.get('converged') else 0}i",
        f"solve_ms={state.get('solve_ms') or 0.0}",
    ]
    for key, value in (state.get("summary") or {}).items():
        if isinstance(value, (int, float)) and value is not True and value is not False:
            fields.append(f"{key}={float(value)}")
    lines.append(f"summary {','.join(fields)} {ts_ns}")

    for line_id, vals in (state.get("lines") or {}).items():
        parts = [
            f"{k}={float(v)}"
            for k, v in vals.items()
            if isinstance(v, (int, float))
        ]
        if parts:
            lines.append(f"line,id={esc_tag(line_id)} {','.join(parts)} {ts_ns}")

    for bus, vals in (state.get("buses") or {}).items():
        parts = [
            f"{k}={float(v)}"
            for k, v in vals.items()
            if isinstance(v, (int, float))
        ]
        if parts:
            lines.append(f"bus,name={esc_tag(bus)} {','.join(parts)} {ts_ns}")
    return "\n".join(lines)


def write_influx(body: str) -> bool:
    url = f"{INFLUX_URL}/api/v2/write?org={INFLUX_ORG}&bucket={INFLUX_BUCKET}&precision=ns"
    req = urllib.request.Request(
        url,
        data=body.encode(),
        headers={"Authorization": f"Token {INFLUX_TOKEN}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status in (204, 200)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
        return False


def main() -> None:
    print(f"collector: {API}/state -> {INFLUX_URL} ({INFLUX_ORG}/{INFLUX_BUCKET})", flush=True)
    last_key: tuple[int, int] | None = None
    while True:
        state = fetch_state()
        if state is not None:
            key = (int(state.get("day", -1)), int(state.get("step", -1)))
            if key != last_key:  # only new steps, never duplicates
                if write_influx(to_lines(state, time.time_ns())):
                    last_key = key
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
