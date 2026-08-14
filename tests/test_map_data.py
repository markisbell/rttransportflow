"""Validate the shipped Europe map (ledger 38: europe_v3, 5 km grid)."""

from __future__ import annotations

import hashlib

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
MAP_PATH = ROOT / "data" / "map" / "europe_v3.json"
QUANTIZE = ROOT / "tools" / "map_authoring" / "quantize.py"

# GAME_DESIGN §2.1 table: id -> (peak MW, season)
EXPECTED_CENTERS = {
    "london": (15000.0, "winter"), "paris": (12000.0, "winter"),
    "ruhr": (11000.0, "flat"), "milan": (9000.0, "summer"),
    "rome": (7000.0, "summer"), "madrid": (6000.0, "summer"),
    "barcelona": (6000.0, "summer"), "silesia": (6000.0, "flat"),
    "munich": (6000.0, "winter"), "randstad": (6000.0, "winter"),
    "brussels": (5000.0, "winter"), "frankfurt": (5000.0, "flat"),
    "stuttgart": (5000.0, "flat"), "warsaw": (5000.0, "winter"),
    "lyon": (5000.0, "winter"), "berlin": (4000.0, "winter"),
    "hamburg": (4000.0, "winter"), "prague": (4000.0, "winter"),
    "vienna": (4000.0, "winter"), "zurich": (4000.0, "winter"),
    "copenhagen": (4000.0, "winter"), "stockholm": (4000.0, "winter"),
    "athens": (4000.0, "summer"), "lisbon": (4000.0, "flat"),
    "oslo": (3000.0, "winter"),
}

LAND = set("chpm")
BUILDABLE_LAND = set("phc")


@pytest.fixture(scope="module")
def doc() -> dict:
    return json.loads(MAP_PATH.read_text())


@pytest.fixture(scope="module")
def quantize_module():
    spec = importlib.util.spec_from_file_location("quantize", QUANTIZE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def terrain(doc: dict, x: int, y: int) -> str:
    return doc["terrain_rows"][y][x]


def test_grid_shape_and_alphabet(doc) -> None:
    assert doc["version"] == 1
    # ledger 38: 5 km grid. Asserted against the projection rather than a
    # bare literal, so a future resolution change fails ONE pin, not five.
    assert doc["tile_km"] == 5
    assert doc["width"] * doc["tile_km"] == 4800  # same geographic span
    assert doc["height"] * doc["tile_km"] == 4020
    assert doc["width"] == 960 and doc["height"] == 804
    assert len(doc["terrain_rows"]) == doc["height"]
    for row in doc["terrain_rows"]:
        assert len(row) == doc["width"]
        assert set(row) <= set("Sscphm")


def test_all_load_centers_present_once(doc) -> None:
    seen = {}
    for center in doc["load_centers"]:
        seen[center["id"]] = center
    assert set(seen) == set(EXPECTED_CENTERS)
    for cid, (peak, season) in EXPECTED_CENTERS.items():
        assert seen[cid]["peak_mw_2025"] == peak, cid
        assert seen[cid]["season"] == season, cid
        assert seen[cid]["temp_coeff_pct_per_c"] > 0
        # Footprints are sized in KILOMETRES (ledger 38: 35 km core for a
        # >= 8 GW metro, 20 km otherwise) and keep only their land tiles, so
        # a coastal city legitimately has fewer.
        n = int(round((35.0 if peak >= 8000.0 else 20.0) / doc["tile_km"]))
        assert 0 < len(seen[cid]["tiles"]) <= n * n, cid


def test_footprints_on_buildable_land_and_disjoint(doc) -> None:
    taken: set[tuple[int, int]] = set()
    for center in doc["load_centers"]:
        for x, y in center["tiles"]:
            assert terrain(doc, x, y) in BUILDABLE_LAND, (center["id"], x, y)
            assert (x, y) not in taken, (center["id"], x, y)
            taken.add((x, y))


def test_resources_terrain_constraints(doc) -> None:
    kinds = {}
    for res in doc["resources"]:
        kinds.setdefault(res["kind"], []).append(res)

    assert len(kinds["phs_site"]) >= 12
    for site in kinds["phs_site"]:
        assert 20 <= site["max_gwh"] <= 60
        for x, y in site["tiles"]:
            assert terrain(doc, x, y) == "m", ("phs_site", x, y)

    for kind in ("salt_cavern", "coal_basin"):
        assert len(kinds[kind]) >= 4
        for res in kinds[kind]:
            assert res["tiles"], kind
            for x, y in res["tiles"]:
                assert terrain(doc, x, y) in LAND, (kind, x, y)

    # rivers come from Natural Earth now (ledger 38), so the count is
    # whatever crosses the window — pin the ones the game leans on instead
    assert "river" in kinds and len(kinds["river"]) >= 20
    named = {str(r.get("name", "")).lower() for r in kinds["river"]}
    for expected in ("rhine", "danube", "elbe", "rhone", "loire", "vistula"):
        assert expected in named, expected
    solar_bands = [r for r in kinds["solar_resource"]]
    assert any(r.get("band_lat") == [35, 44] for r in solar_bands)


def test_shelf_seas_exist(doc) -> None:
    shelf = sum(row.count("s") for row in doc["terrain_rows"])
    assert shelf >= 200


def test_geography_spot_checks(doc, quantize_module) -> None:
    q = quantize_module
    # Madrid, Oslo, Warsaw on land; mid-Atlantic deep sea; Adriatic is sea.
    for lon, lat in ((-3.7, 40.42), (10.75, 59.91), (21.0, 52.2)):
        x, y = q.tile_of(lon, lat)
        assert terrain(doc, x, y) in LAND, (lon, lat)
    x, y = q.tile_of(-16.0, 45.0)
    assert terrain(doc, x, y) == "S"
    x, y = q.tile_of(15.3, 42.8)  # mid-Adriatic
    assert terrain(doc, x, y) in ("s", "S")
    x, y = q.tile_of(19.5, 61.0)  # mid-Baltic
    assert terrain(doc, x, y) in ("s", "S")
    # The Channel separates Britain from France: London and Paris must lie
    # in DIFFERENT 4-connected land components (the real requirement — the
    # carve may be diagonal, which still breaks orthogonal connectivity).
    rows = doc["terrain_rows"]

    def component(start: tuple[int, int]) -> frozenset:
        seen = {start}
        stack = [start]
        while stack:
            cx, cy = stack.pop()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = cx + dx, cy + dy
                if (0 <= nx < 96 and 0 <= ny < 80 and (nx, ny) not in seen
                        and rows[ny][nx] in LAND):
                    seen.add((nx, ny))
                    stack.append((nx, ny))
        return frozenset(seen)

    london = tuple(next(c for c in doc["load_centers"] if c["id"] == "london")["tiles"][0])
    paris = tuple(next(c for c in doc["load_centers"] if c["id"] == "paris")["tiles"][0])
    assert paris not in component(london)


def test_regeneration_is_byte_identical(doc, quantize_module) -> None:
    """The shipped map must be exactly what the generator produces.

    Compare DIGESTS, not the strings: the map is ~4 MB and pytest's
    assertion rewriting tries to diff mismatching strings, which turned a
    35 s test into a hang.
    """
    regenerated, _shifts = quantize_module.build()
    fresh = json.dumps(regenerated, indent=1) + "\n"
    fresh_digest = hashlib.sha256(fresh.encode()).hexdigest()
    shipped_digest = hashlib.sha256(MAP_PATH.read_bytes()).hexdigest()
    assert fresh_digest == shipped_digest, (
        "regenerated map differs from the shipped one — rerun "
        "tools/map_authoring/quantize.py and commit the result")
