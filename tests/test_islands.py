from __future__ import annotations

from rttransportflow.dynamics.islands import connected_components


def test_single_component() -> None:
    buses = ["a", "b", "c"]
    edges = [("a", "b", True), ("b", "c", True)]
    comp = connected_components(buses, edges)
    assert len(set(comp.values())) == 1


def test_split_on_out_of_service_line() -> None:
    buses = ["a", "b", "c", "d"]
    edges = [("a", "b", True), ("b", "c", False), ("c", "d", True)]
    comp = connected_components(buses, edges)
    assert comp["a"] == comp["b"]
    assert comp["c"] == comp["d"]
    assert comp["a"] != comp["c"]


def test_europe_mini_is_one_island() -> None:
    from pathlib import Path

    from rttransportflow.data_loader import load_bundle

    data = load_bundle(Path(__file__).resolve().parent.parent / "data" / "grids" / "europe_mini")
    comp = connected_components(
        [b.name for b in data.grid.buses],
        [(ln.from_bus, ln.to_bus, True) for ln in data.lines.lines],
    )
    assert len(set(comp.values())) == 1
