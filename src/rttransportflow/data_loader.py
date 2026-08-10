"""Load + cross-validate a scenario bundle (family pattern).

`load_bundle(dir)` reads the JSON docs; `input_data_from_dicts` builds from
in-memory dicts (the later gamebridge path). Every referential and shape rule
is checked here so the builder/simulator can trust their inputs.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .models import (
    GridDoc,
    LinesDoc,
    LoadCentersDoc,
    PlantsDoc,
    ScenarioDoc,
)


class BundleError(ValueError):
    """A scenario bundle failed validation."""


@dataclass
class InputData:
    grid: GridDoc
    lines: LinesDoc
    plants: PlantsDoc
    load_centers: LoadCentersDoc
    scenario: ScenarioDoc


def _read(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        raise BundleError(f"missing bundle file: {path.name}") from None
    except json.JSONDecodeError as exc:
        raise BundleError(f"{path.name}: invalid JSON: {exc}") from None


def input_data_from_dicts(
    grid: dict,
    lines: dict,
    plants: dict,
    load_centers: dict,
    scenario: dict,
) -> InputData:
    data = InputData(
        grid=GridDoc.model_validate(grid),
        lines=LinesDoc.model_validate(lines),
        plants=PlantsDoc.model_validate(plants),
        load_centers=LoadCentersDoc.model_validate(load_centers),
        scenario=ScenarioDoc.model_validate(scenario),
    )
    _cross_validate(data)
    return data


def load_bundle(directory: str | Path) -> InputData:
    d = Path(directory)
    return input_data_from_dicts(
        grid=_read(d / "grid.json"),
        lines=_read(d / "lines.json"),
        plants=_read(d / "plants.json"),
        load_centers=_read(d / "load_centers.json"),
        scenario=_read(d / "scenario.json"),
    )


def _cross_validate(data: InputData) -> None:
    bus_names = [b.name for b in data.grid.buses]
    buses = set(bus_names)
    if len(buses) != len(bus_names):
        raise BundleError("grid.json: duplicate bus names")
    if data.grid.reference_bus not in buses:
        raise BundleError(f"grid.json: reference_bus {data.grid.reference_bus!r} is not a bus")

    zone_ids = [z.id for z in data.grid.zones]
    if len(set(zone_ids)) != len(zone_ids):
        raise BundleError("grid.json: duplicate zone ids")
    for z in data.grid.zones:
        if z.bus not in buses:
            raise BundleError(f"grid.json: zone {z.id!r} references unknown bus {z.bus!r}")

    line_ids = [ln.id for ln in data.lines.lines]
    if len(set(line_ids)) != len(line_ids):
        raise BundleError("lines.json: duplicate line ids")
    for ln in data.lines.lines:
        for end in (ln.from_bus, ln.to_bus):
            if end not in buses:
                raise BundleError(f"lines.json: line {ln.id!r} references unknown bus {end!r}")
        if ln.std_type is None and None in (
            ln.r_ohm_per_km, ln.x_ohm_per_km, ln.c_nf_per_km, ln.max_i_ka
        ):
            raise BundleError(f"lines.json: line {ln.id!r} needs std_type or full explicit params")

    steps = data.load_centers.steps
    if steps != data.scenario.steps_per_day:
        raise BundleError(
            f"load_centers.json steps ({steps}) != scenario.steps_per_day "
            f"({data.scenario.steps_per_day})"
        )
    if data.load_centers.resolution_minutes * steps != 24 * 60:
        raise BundleError("load_centers.json: resolution_minutes * steps must cover 24 h")

    zone_set = set(zone_ids)
    for item in data.load_centers.items:
        if item.zone not in zone_set:
            raise BundleError(f"load_centers.json: item {item.name!r} references unknown zone {item.zone!r}")
        if len(item.p_mw) != steps:
            raise BundleError(f"load_centers.json: item {item.name!r} p_mw length != steps")
        if item.q_mvar is not None and len(item.q_mvar) != steps:
            raise BundleError(f"load_centers.json: item {item.name!r} q_mvar length != steps")

    plant_ids = [p.id for p in data.plants.plants]
    if len(set(plant_ids)) != len(plant_ids):
        raise BundleError("plants.json: duplicate plant ids")
    for p in data.plants.plants:
        if p.bus not in buses:
            raise BundleError(f"plants.json: plant {p.id!r} references unknown bus {p.bus!r}")
        if len(p.profile_p_mw) != steps:
            raise BundleError(f"plants.json: plant {p.id!r} profile length != steps")
        if max(p.profile_p_mw) > p.p_max_mw * 1.0001:
            raise BundleError(f"plants.json: plant {p.id!r} profile exceeds p_max_mw")
