"""Generate the authored europe_mini scenario bundle (deterministic).

11 buses / 8 countries, 380 kV double-circuit corridors, mixed fleet, one
winter-workday of 96 x 15-min profiles. Dispatch is authored by a per-bus
balancing pass (must-take renewables + flat nuclear; dispatchables track the
local residual; the global residual is spread over remaining headroom) so
the slack carries only losses + a small exchange — a physically realistic
operating point (P0 lesson: degenerate points break solvers).

Committed output lives in data/grids/europe_mini/ — regenerate with:

    .venv/bin/python scripts/gen_europe_mini.py
"""

from __future__ import annotations

import json
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "data" / "grids" / "europe_mini"
STEPS = 96

# name, lat, lon, zone peak MW
BUSES = [
    ("london", 51.5, -0.1, 8000.0),
    ("paris", 48.9, 2.3, 9000.0),
    ("lyon", 45.8, 4.8, 4000.0),
    ("madrid", 40.4, -3.7, 5000.0),
    ("brussels", 50.8, 4.4, 3000.0),
    ("frankfurt", 50.1, 8.7, 6000.0),
    ("berlin", 52.5, 13.4, 4000.0),
    ("milan", 45.5, 9.2, 6000.0),
    ("vienna", 48.2, 16.4, 3000.0),
    ("warsaw", 52.2, 21.0, 4000.0),
    ("copenhagen", 55.7, 12.6, 2000.0),
]

# from, to, km — stylized 380 kV double-circuit corridors (kept <= ~550 km;
# longer hauls go via intermediate buses, as real AC corridors do)
CORRIDORS = [
    ("madrid", "lyon", 550),
    ("lyon", "paris", 400),
    ("lyon", "milan", 320),
    ("paris", "london", 340),
    ("paris", "brussels", 260),
    ("paris", "frankfurt", 480),
    ("brussels", "frankfurt", 320),
    ("frankfurt", "berlin", 420),
    ("frankfurt", "vienna", 550),
    ("berlin", "warsaw", 520),
    ("berlin", "copenhagen", 360),
    ("vienna", "milan", 550),
]

# id, bus, kind, p_max_mw — dispatchable fleet sized for the 54 GW evening
# peak (nuclear 11 + wind ~1.6 + 0.92 x 50 GW dispatchable ≈ 58.6 GW).
PLANTS = [
    ("nuc_paris", "paris", "nuclear", 9000.0),
    ("ccgt_london", "london", "gas_ccgt", 9500.0),
    ("nuc_lyon", "lyon", "nuclear", 3500.0),
    ("pv_madrid", "madrid", "solar_pv", 3000.0),
    ("ccgt_madrid", "madrid", "gas_ccgt", 6000.0),
    ("ccgt_brussels", "brussels", "gas_ccgt", 3500.0),
    ("coal_frankfurt", "frankfurt", "coal", 4000.0),
    ("ccgt_frankfurt", "frankfurt", "gas_ccgt", 4000.0),
    ("lignite_berlin", "berlin", "lignite", 4500.0),
    ("ccgt_milan", "milan", "gas_ccgt", 7500.0),
    ("phs_vienna", "vienna", "hydro_ps", 2500.0),
    ("ccgt_vienna", "vienna", "gas_ccgt", 3500.0),
    ("coal_warsaw", "warsaw", "coal", 5000.0),
    ("wind_copenhagen", "copenhagen", "wind_offshore", 2500.0),
    ("ccgt_copenhagen", "copenhagen", "gas_ccgt", 1500.0),
]

DISPATCHABLE = {"gas_ccgt", "coal", "lignite", "hydro_ps"}
CAP = 0.92  # dispatchable headroom ceiling


def load_shape(step: int) -> float:
    """Winter workday: night valley 0.62, morning ramp, evening peak 1.0 at 18:30."""
    h = step / 4.0
    base = 0.62
    morning = 0.22 * math.exp(-((h - 9.5) ** 2) / 8.0)
    midday = 0.16 * math.exp(-((h - 13.0) ** 2) / 14.0)
    evening = 0.38 * math.exp(-((h - 18.5) ** 2) / 5.0)
    return base + morning + midday + evening


def solar_shape(step: int) -> float:
    h = step / 4.0
    if h < 8.0 or h > 18.0:
        return 0.0
    return max(0.0, math.sin(math.pi * (h - 8.0) / 10.0)) ** 1.4


def wind_shape(step: int) -> float:
    h = step / 4.0
    return 0.55 + 0.12 * math.sin(2 * math.pi * (h - 3.0) / 24.0)


def author_dispatch() -> dict[str, list[float]]:
    """Per-step, per-plant dispatch tracking zonal load; slack ends up small."""
    peaks = {n: peak for n, _, _, peak in BUSES}
    plants_at: dict[str, list[tuple[str, str, float]]] = {}
    for pid, bus, kind, p_max in PLANTS:
        plants_at.setdefault(bus, []).append((pid, kind, p_max))

    dispatch: dict[str, list[float]] = {pid: [] for pid, *_ in PLANTS}

    for s in range(STEPS):
        ls = load_shape(s)
        loads = {n: peaks[n] * ls for n in peaks}
        target_total = sum(loads.values()) * 1.015  # + ~1.5 % losses

        fixed: dict[str, float] = {}
        for pid, bus, kind, p_max in PLANTS:
            if kind == "nuclear":
                fixed[pid] = 0.88 * p_max
            elif kind == "solar_pv":
                fixed[pid] = solar_shape(s) * p_max
            elif kind == "wind_offshore":
                fixed[pid] = wind_shape(s) * p_max

        # Dispatchables fill toward their bus's residual load.
        values: dict[str, float] = dict(fixed)
        for bus, plist in plants_at.items():
            residual = loads[bus] - sum(values.get(pid, 0.0) for pid, _, _ in plist)
            caps = [(pid, p_max) for pid, kind, p_max in plist if kind in DISPATCHABLE]
            cap_sum = sum(p for _, p in caps)
            for pid, p_max in caps:
                share = residual * (p_max / cap_sum) if cap_sum else 0.0
                values[pid] = min(max(share, 0.0), CAP * p_max)

        # Spread the remaining global residual over dispatchable headroom.
        residual = target_total - sum(values.values())
        heads = {
            pid: (CAP * p_max - values[pid]) if residual > 0 else values[pid]
            for pid, bus, kind, p_max in PLANTS
            if kind in DISPATCHABLE
        }
        head_sum = sum(heads.values())
        if head_sum > 0:
            for pid, h in heads.items():
                values[pid] += residual * (h / head_sum)

        for pid, bus, kind, p_max in PLANTS:
            dispatch[pid].append(round(min(max(values[pid], 0.0), p_max), 1))

    return dispatch


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    dispatch = author_dispatch()

    grid = {
        "buses": [
            {"name": n, "vn_kv": 380.0, "geo": {"lat": lat, "lon": lon}, "area": "CE"}
            for n, lat, lon, _ in BUSES
        ],
        "reference_bus": "frankfurt",
        "zones": [{"id": n, "bus": n} for n, _, _, _ in BUSES],
    }

    lines = {
        "lines": [
            {
                "id": f"{a}-{b}",
                "from_bus": a,
                "to_bus": b,
                "length_km": float(km),
                "std_type": "490-AL1/64-ST1A 380.0",
                "parallel": 2,
            }
            for a, b, km in CORRIDORS
        ]
    }

    plants = {
        "plants": [
            {
                "id": pid,
                "name": pid.replace("_", " "),
                "bus": bus,
                "kind": kind,
                "p_max_mw": p_max,
                "p_min_mw": 0.0,
                "vm_pu": 1.02,
                "profile_p_mw": dispatch[pid],
            }
            for pid, bus, kind, p_max in PLANTS
        ]
    }

    load_centers = {
        "resolution_minutes": 15,
        "steps": STEPS,
        "items": [
            {
                "name": n,
                "zone": n,
                "p_mw": [round(peak * load_shape(s), 1) for s in range(STEPS)],
            }
            for n, _, _, peak in BUSES
        ],
    }

    scenario = {
        "name": "europe_mini",
        "steps_per_day": STEPS,
        "description": "11-bus, 8-country 380 kV teaching grid; one winter workday.",
    }

    for fname, doc in [
        ("grid.json", grid),
        ("lines.json", lines),
        ("plants.json", plants),
        ("load_centers.json", load_centers),
        ("scenario.json", scenario),
    ]:
        (OUT / fname).write_text(json.dumps(doc, indent=1) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
