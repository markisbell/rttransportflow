from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from rttransportflow.data_loader import BundleError, input_data_from_dicts, load_bundle

BUNDLE_DIR = Path(__file__).resolve().parent.parent / "data" / "grids" / "europe_mini"


@pytest.fixture(scope="module")
def docs() -> dict[str, dict]:
    return {
        name: json.loads((BUNDLE_DIR / f"{name}.json").read_text())
        for name in ("grid", "lines", "plants", "load_centers", "scenario")
    }


def test_shipped_bundle_is_valid(docs) -> None:
    data = load_bundle(BUNDLE_DIR)
    assert data.scenario.name == "europe_mini"
    assert len(data.grid.buses) == 11
    assert data.load_centers.steps == data.scenario.steps_per_day == 96


@pytest.mark.parametrize(
    "mutate, message",
    [
        (lambda d: d["grid"].update(reference_bus="nowhere"), "reference_bus"),
        (lambda d: d["grid"]["zones"].append({"id": "x", "bus": "nowhere"}), "unknown bus"),
        (lambda d: d["lines"]["lines"][0].update(to_bus="nowhere"), "unknown bus"),
        (lambda d: d["lines"]["lines"].append(dict(d["lines"]["lines"][0])), "duplicate line"),
        (lambda d: d["plants"]["plants"][0].update(bus="nowhere"), "unknown bus"),
        (lambda d: d["plants"]["plants"][0]["profile_p_mw"].pop(), "profile length"),
        (lambda d: d["load_centers"]["items"][0]["p_mw"].pop(), "p_mw length"),
        (lambda d: d["load_centers"].update(steps=95), None),  # two rules can fire
        (lambda d: d["scenario"].update(steps_per_day=48), "steps"),
    ],
)
def test_cross_validation_rejects(docs, mutate, message) -> None:
    broken = copy.deepcopy(docs)
    mutate(broken)
    with pytest.raises(BundleError) as exc:
        input_data_from_dicts(
            broken["grid"], broken["lines"], broken["plants"],
            broken["load_centers"], broken["scenario"],
        )
    if message:
        assert message in str(exc.value)


def test_profile_above_p_max_rejected(docs) -> None:
    broken = copy.deepcopy(docs)
    plant = broken["plants"]["plants"][0]
    plant["profile_p_mw"][0] = plant["p_max_mw"] * 2
    with pytest.raises(BundleError, match="exceeds p_max"):
        input_data_from_dicts(
            broken["grid"], broken["lines"], broken["plants"],
            broken["load_centers"], broken["scenario"],
        )


def test_missing_file_reported(tmp_path) -> None:
    with pytest.raises(BundleError, match="missing bundle file"):
        load_bundle(tmp_path)
