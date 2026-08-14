"""Generate data/map/europe_v3.json — the 960x804 Europe tile map.

Geometry comes from NATURAL EARTH (public domain, see natural_earth.py):
real coastlines, real river courses, real named mountain ranges. The
hand-authored polygons below are kept only as the fallback when the NE
cache is unavailable — at 5 km per tile, hand-drawing Europe is neither
accurate enough nor worth the effort.

Deterministic (no RNG, no time): hand-authored lat/lon polygons are
rasterized onto the 50 km tile grid (GAME_DESIGN SS1.7 format). Regenerate:

    .venv/bin/python tools/map_authoring/quantize.py

Projection (documented, equirectangular at a fixed metric scale):
    1 deg lat = 111.32 km ; 1 deg lon = 111.32 * cos(52 deg) = 68.536 km
    tile = 5 km  ->  DLAT = 0.0449 deg/tile , DLON = 0.0730 deg/tile
    row 0 center sits at LAT0 = 71 N (North Cape clipped), col 0 at LON0=-20.
    Content spans Lisbon-Helsinki / Ireland-Athens with sea margins.

Resolution (ledger 38, user direction 2026-08-14): 15 km tiles over the same
geographic span — countries need enough tiles to HAVE a shape, and mountain
ranges/forests need room to be drawn into the terrain. The compressions below
were 50 km-scale artifacts; at 15 km most resolve on their own (the Dover
strait, the Oresund and small islands are all wider than a tile now).

Deliberate scale compressions (documented, not bugs):
- The Dover strait is carved as a one-tile sea channel (real width < 1 tile).
- Copenhagen and Malmoe fuse into one land tile pair across the Oresund —
  it represents the fixed link (the load center IS "Oresund CPH-Malmoe");
  Kattegat/Skagerrak keep Scandinavia otherwise sea-separated.
- Islands under ~2 tiles are dropped except Sicily/Sardinia/Corsica/Crete.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent.parent.parent / "data" / "map"
## physical sizes that must stay constant as the tile shrinks
FOOTHILL_KM = 50.0   # hill halo around a range
## Metro footprints. These are the tiles a city OCCUPIES (unbuildable, and
## rendered as city blocks) — not the full conurbation. At 5 km tiles a
## literal 60 km metro is a 12x12 slab that reads as a vast block grid and
## walls off a third of a country, so the footprint is the dense CORE and
## the surrounding demand is abstract.
METRO_BIG_KM = 35.0  # >= 8 GW metro core (7 tiles at 5 km)
METRO_KM = 20.0      # (4 tiles)
PREVIEW = Path(__file__).resolve().parent / "preview.txt"

WIDTH, HEIGHT, TILE_KM = 960, 804, 5
LAT0, LON0 = 71.0, -20.0
KM_PER_DEG_LAT = 111.32
KM_PER_DEG_LON = 111.32 * math.cos(math.radians(52.0))  # 68.536
DLAT = TILE_KM / KM_PER_DEG_LAT  # 0.44916 deg per tile
DLON = TILE_KM / KM_PER_DEG_LON  # 0.72954 deg per tile


def _value_noise(width: int, height: int, cells: int, seed: int
                 ) -> list[list[float]]:
    """Deterministic smooth noise in [0, 1]: a coarse hash lattice with
    cosine interpolation. No RNG state, no numpy — same map every run."""

    def lattice(ix: int, iy: int) -> float:
        h = (ix * 374761393 + iy * 668265263 + seed * 1442695040888963407) & 0xFFFFFFFF
        h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
        return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0

    step_x = width / float(cells)
    step_y = height / float(cells)
    out: list[list[float]] = []
    for y in range(height):
        gy = y / step_y
        iy, fy = int(gy), gy - int(gy)
        wy = (1.0 - math.cos(fy * math.pi)) * 0.5
        row: list[float] = []
        for x in range(width):
            gx = x / step_x
            ix, fx = int(gx), gx - int(gx)
            wx = (1.0 - math.cos(fx * math.pi)) * 0.5
            top = lattice(ix, iy) * (1 - wx) + lattice(ix + 1, iy) * wx
            bot = lattice(ix, iy + 1) * (1 - wx) + lattice(ix + 1, iy + 1) * wx
            row.append(top * (1 - wy) + bot * wy)
        out.append(row)
    return out


# --- Natural Earth sourcing (public domain; see natural_earth.py) --------
_NE_LAND_USED = False
_NE_RANGES: list[list[bool]] | None = None
_NE_RIVERS: dict[str, set[tuple[int, int]]] | None = None
BBOX = (LON0 - 1.0, LAT0 - HEIGHT * (TILE_KM / KM_PER_DEG_LAT) - 1.0,
        LON0 + WIDTH * (TILE_KM / KM_PER_DEG_LON) + 1.0, LAT0 + 1.0)


def _tile_of_float(lon: float, lat: float) -> tuple[float, float]:
    """Sub-tile position — the rasteriser needs fractions, not floor()."""
    return (lon - LON0) / DLON, (LAT0 - lat) / DLAT


def _natural_earth_land() -> list[list[bool]] | None:
    """Land mask, named ranges and rivers straight from Natural Earth.
    Returns None (and leaves the hand-authored fallback in charge) when the
    cache is missing and the download is unavailable."""
    global _NE_LAND_USED, _NE_RANGES, _NE_RIVERS
    try:
        import natural_earth as ne
    except ImportError:
        return None
    try:
        land_rings = ne.rings_in("land", BBOX)
        if not land_rings:
            return None
        mask = ne.rasterize(land_rings, _tile_of_float, WIDTH, HEIGHT)
        # lakes are cut back out of the land mask: at 5 km the Ladoga,
        # Vänern and the Alpine lakes are real features, not noise
        for row_index, row in enumerate(
                ne.rasterize(ne.rings_in("lakes", BBOX, min_size=0.02),
                             _tile_of_float, WIDTH, HEIGHT)):
            for x, wet in enumerate(row):
                if wet:
                    mask[row_index][x] = False
        _NE_RANGES = ne.rasterize(ne.rings_in("regions", BBOX,
                                              featurecla="Range/mtn"),
                                  _tile_of_float, WIDTH, HEIGHT)
        _NE_RIVERS = ne.river_tiles(BBOX, tile_of)
        _NE_LAND_USED = True
        print(f"  Natural Earth: {sum(sum(r) for r in mask)} land tiles, "
              f"{sum(sum(r) for r in _NE_RANGES)} range tiles, "
              f"{len(_NE_RIVERS)} rivers")
        return mask
    except Exception as exc:  # noqa: BLE001 — the fallback must always work
        print(f"  Natural Earth unavailable ({exc}); using hand polygons")
        return None


def tile_of(lon: float, lat: float) -> tuple[int, int]:
    return int((lon - LON0) / DLON), int((LAT0 - lat) / DLAT)


def center_of(x: int, y: int) -> tuple[float, float]:
    return LON0 + (x + 0.5) * DLON, LAT0 - (y + 0.5) * DLAT


# ---------------------------------------------------------------------------
# Landmass polygons (lon, lat) — stylized, hand-authored, iterated against
# the preview until recognizable at 50 km.
# ---------------------------------------------------------------------------

IBERIA = [
    (-9.3, 43.6), (-7.5, 43.7), (-5.5, 43.6), (-3.5, 43.5), (-1.8, 43.4),
    (0.0, 42.8), (3.2, 42.4),  # Pyrenees border overlap w/ France
    (2.9, 41.8), (2.2, 41.3), (0.6, 40.6), (0.1, 39.8), (-0.3, 39.3),
    (-0.6, 38.3), (-2.1, 36.8), (-4.4, 36.5), (-5.5, 36.0),
    (-6.3, 36.5), (-6.9, 37.2), (-7.5, 37.1), (-8.9, 37.0),
    (-8.8, 38.5), (-9.5, 38.7), (-9.4, 39.4), (-9.3, 41.1), (-9.0, 42.5),
]

FRANCE = [
    (-1.8, 43.3), (-1.3, 44.4), (-1.2, 45.6), (-2.0, 46.7), (-2.5, 47.2),
    (-4.4, 47.8), (-4.8, 48.4), (-3.5, 48.8), (-1.8, 48.7), (-1.7, 49.6),
    (-0.4, 49.4), (0.2, 49.5), (1.2, 50.1), (1.6, 51.0),
    (3.0, 50.6), (4.6, 50.0), (6.2, 49.5), (7.8, 49.0), (8.1, 48.6),
    (7.3, 47.5), (6.7, 46.5), (6.1, 46.2), (6.6, 45.1), (7.2, 44.3),
    (7.6, 43.8), (6.5, 43.2), (4.9, 43.3), (3.9, 43.5), (3.1, 42.6),
    (0.5, 42.6), (-1.6, 43.2),
]

BRITAIN = [
    (-5.6, 50.0), (-4.2, 50.3), (-2.5, 50.6), (-1.0, 50.7), (0.5, 50.8),
    (1.3, 51.2), (1.0, 51.6), (1.7, 52.2), (1.7, 52.9), (0.3, 53.4),
    (0.0, 53.8), (-1.1, 54.2), (-1.4, 55.0), (-1.9, 55.7), (-2.5, 56.1),
    (-2.2, 56.7), (-1.9, 57.4), (-2.5, 57.9), (-3.5, 58.5), (-5.0, 58.6),
    (-5.8, 57.9), (-5.9, 57.0), (-5.5, 56.3), (-4.9, 55.7), (-4.7, 55.0),
    (-3.4, 54.7), (-3.2, 54.1), (-2.9, 53.6), (-3.6, 53.4), (-4.6, 53.3),
    (-4.4, 52.8), (-4.9, 52.3), (-5.3, 51.9), (-4.3, 51.7), (-3.2, 51.5),
    (-3.9, 51.2), (-4.7, 50.9), (-5.5, 50.4),
]

IRELAND = [
    (-6.1, 55.2), (-5.9, 54.6), (-6.1, 53.9), (-6.1, 53.4), (-6.3, 52.8),
    (-6.5, 52.2), (-7.6, 51.9), (-8.8, 51.5), (-10.2, 51.7), (-9.9, 52.5),
    (-9.5, 53.1), (-10.0, 53.6), (-9.9, 54.3), (-8.6, 54.6), (-8.4, 55.2),
    (-7.2, 55.4),
]

SCANDINAVIA = [
    (5.6, 58.7), (5.2, 59.6), (5.0, 60.6), (5.5, 61.5), (6.5, 62.5),
    (8.0, 63.4), (9.8, 64.0), (11.0, 64.9), (12.5, 65.8), (14.0, 66.8),
    (16.0, 68.0), (18.0, 68.9), (20.5, 69.8), (23.0, 70.5), (26.0, 70.8),
    (29.0, 70.5), (51.0, 70.2),  # continues off-map into Russia (Kola)
    (51.0, 59.6), (30.2, 59.95),  # overlaps CENTRAL east of St Petersburg
    (28.2, 60.4), (26.5, 60.3), (24.9, 60.1), (23.2, 60.0),
    (22.4, 60.4),  # SW Finland
    (21.2, 61.2), (21.3, 62.3), (21.4, 63.2), (22.5, 64.0), (24.4, 64.9),
    (25.3, 65.6),  # top of the Gulf of Bothnia
    (23.8, 65.8), (22.2, 65.4), (21.0, 64.7), (20.0, 63.7), (18.5, 62.8),
    (17.5, 61.8), (17.2, 60.7), (18.2, 59.4), (17.3, 58.7), (16.7, 57.9),
    (16.4, 56.9), (15.8, 56.1), (14.2, 55.9), (13.1, 55.5), (12.9, 55.4),
    (12.9, 56.2), (12.2, 57.2), (11.9, 57.7), (11.2, 58.5), (10.7, 59.2),
    (10.6, 59.9),  # Oslo fjord head
    (9.8, 59.4), (8.8, 58.6), (7.5, 58.1), (6.4, 58.3),
]

DENMARK = [
    (8.1, 55.3), (8.1, 56.2), (8.3, 57.0), (9.6, 57.7), (10.6, 57.2),
    (10.8, 56.4), (12.6, 56.0), (12.7, 55.6), (12.3, 55.0), (11.0, 54.7),
    (9.8, 54.8), (8.6, 54.9),
]

CENTRAL = [  # Benelux -> Germany -> Poland -> Baltics -> east edge -> Balkans border
    (1.6, 51.0), (2.6, 51.2), (3.6, 51.5), (4.7, 52.5), (5.2, 53.0),
    (6.5, 53.5), (8.2, 53.7), (8.6, 54.2), (8.5, 54.9),  # Danish border west
    (9.9, 54.6), (11.0, 54.3), (12.2, 54.3), (13.9, 54.1), (14.9, 54.1),
    (16.5, 54.5), (18.4, 54.7), (19.6, 54.5), (20.9, 55.2), (21.1, 56.1),
    (22.6, 56.6), (24.1, 57.2), (24.4, 58.4), (24.8, 59.5), (27.0, 59.6),
    (29.0, 59.8), (30.2, 59.85),  # St Petersburg
    (51.0, 59.7), (51.0, 47.0),  # continues off-map into Russia/Ukraine
    (30.9, 46.4), (29.7, 45.2),  # Odessa -> Danube delta
    (28.5, 43.9), (27.9, 43.3), (27.5, 42.6),  # Black Sea west coast
    (26.5, 42.6), (25.0, 43.6), (23.0, 43.8), (22.4, 44.7),  # Danube line
    (20.5, 45.1), (19.0, 45.7), (17.4, 45.9), (16.2, 46.4), (14.8, 46.6),
    (13.4, 46.6), (12.2, 46.8), (10.4, 46.6), (9.0, 46.1), (8.1, 46.2),
    (7.1, 46.0), (6.3, 46.3), (6.6, 46.9), (7.2, 47.6), (7.7, 48.6),
    (8.0, 49.0), (6.4, 49.6), (5.0, 50.1), (3.2, 50.6),
]

ITALY = [
    (7.5, 43.8), (8.8, 44.3), (10.1, 43.9), (10.9, 43.0), (11.7, 42.3),
    (12.7, 41.5), (13.9, 40.9), (14.9, 40.4), (15.6, 39.9), (16.0, 38.9),
    (15.9, 38.2), (16.3, 38.0),  # toe
    (16.6, 38.7), (17.1, 39.2), (16.9, 39.9), (17.2, 40.4),  # Taranto gulf
    (18.4, 39.9), (18.6, 40.3), (17.6, 40.9), (16.6, 41.2), (15.9, 41.9),
    (16.1, 42.0), (14.8, 42.2), (14.0, 42.7), (13.5, 43.6), (12.7, 44.1),
    (12.4, 44.7), (12.3, 45.2), (13.0, 45.6), (13.7, 45.7),  # Trieste
    (13.6, 46.4), (12.5, 46.6), (11.0, 46.6), (9.6, 46.2), (8.4, 46.0),
    (7.5, 45.5), (7.0, 44.8), (7.4, 44.1),
]

SICILY = [(12.4, 38.0), (13.4, 38.3), (15.0, 38.2), (15.3, 37.6),
          (15.1, 36.8), (14.2, 36.9), (12.5, 37.5)]
TURKEY = [  # north-Anatolia strip framing the Black Sea's south shore
    (26.6, 40.4), (29.2, 41.0), (32.0, 41.6), (36.0, 41.9), (41.5, 41.3),
    (51.0, 41.2), (51.0, 39.3), (36.0, 39.4), (29.0, 39.8), (26.9, 39.5),
]
CRIMEA = [(32.5, 45.4), (34.5, 46.0), (36.4, 45.4), (34.9, 44.4), (33.5, 44.5)]
SARDINIA = [(8.2, 41.2), (9.6, 41.2), (9.7, 39.9), (9.5, 39.1), (8.4, 38.9),
            (8.3, 40.0)]
CORSICA = [(8.6, 43.0), (9.5, 43.0), (9.4, 41.5), (8.7, 41.5)]
CRETE = [(23.5, 35.5), (26.2, 35.4), (26.1, 35.0), (23.6, 35.1)]

BALKANS = [  # ex-Yugoslavia + Albania + Greece + Bulgaria, overlapping CENTRAL
    (13.8, 45.6), (14.9, 45.0), (15.6, 44.4), (16.5, 43.5), (17.6, 43.0),
    (18.4, 42.5), (19.2, 41.9), (19.4, 40.9), (19.8, 40.1), (20.5, 39.2),
    (21.1, 38.6), (21.4, 38.2),  # Gulf of Patras
    (21.3, 37.6), (21.7, 36.9), (22.4, 36.5), (23.0, 36.6), (23.2, 37.3),
    (23.7, 37.9),  # Athens
    (24.1, 38.5), (23.5, 38.9), (23.2, 39.4), (22.7, 40.0), (22.9, 40.5),
    (24.0, 40.7), (25.3, 40.9), (26.2, 40.6), (28.2, 40.9), (29.2, 41.1),
    (29.1, 41.6), (28.1, 42.0), (27.6, 42.7),  # Burgas overlap
    (26.8, 43.2), (25.5, 43.7), (24.0, 43.9), (22.6, 44.4), (21.6, 44.9),
    (20.3, 45.2), (18.8, 45.6), (17.2, 45.8), (15.8, 45.9), (14.4, 45.9),
]

LANDMASSES = [IBERIA, FRANCE, BRITAIN, IRELAND, SCANDINAVIA, DENMARK,
              CENTRAL, ITALY, SICILY, SARDINIA, CORSICA, CRETE, BALKANS,
              TURKEY, CRIMEA]

# Forced one-tile sea channels (paths sampled and set to sea AFTER land).
CARVES = [
    [(-4.5, 49.8), (-2.5, 50.0), (-0.5, 50.3), (1.0, 50.7), (2.0, 51.4),
     (2.8, 51.9)],  # the Channel + Dover strait
    [(15.35, 38.05), (15.55, 38.35)],  # Messina strait
    [(10.9, 57.9), (11.4, 57.2), (11.8, 56.6)],  # Kattegat mid-line
]

# Mountain cores (m); a one-tile hill halo is derived around them.
MOUNTAINS = [
    [(5.8, 44.0), (6.7, 45.4), (7.9, 46.3), (9.6, 46.9), (11.5, 47.2),
     (13.4, 47.5), (15.0, 47.6), (14.7, 46.7), (12.6, 46.2), (10.4, 45.9),
     (8.6, 45.6), (7.1, 44.7), (6.3, 43.8)],  # Alps (two tiles thick)
    [(-1.9, 43.0), (0.5, 42.9), (2.7, 42.7), (2.6, 42.3), (0.3, 42.4),
     (-1.7, 42.6)],  # Pyrenees
    [(17.1, 48.7), (19.3, 49.5), (21.6, 49.5), (23.6, 48.9), (25.0, 47.9),
     (25.7, 46.8), (25.9, 45.9), (24.6, 45.5), (23.0, 45.5), (24.3, 46.3),
     (24.7, 47.2), (23.4, 48.2), (21.0, 48.9), (18.6, 48.8), (17.2, 48.4)],  # Carpathians
    [(6.2, 58.9), (6.8, 60.2), (7.8, 61.5), (9.4, 62.6), (12.0, 64.2),
     (14.5, 66.0), (17.0, 67.6), (19.5, 68.8), (20.8, 69.5), (19.0, 67.9),
     (15.9, 66.1), (13.2, 64.4), (10.5, 62.9), (8.5, 61.2), (7.3, 59.6)],  # Scandes
    [(-5.4, 56.6), (-4.4, 57.4), (-4.8, 58.2), (-5.7, 57.6)],  # Highlands
    [(15.2, 45.2), (16.8, 44.2), (18.5, 43.2), (19.9, 42.2), (20.5, 41.3),
     (19.9, 41.0), (18.5, 42.4), (16.6, 43.7), (14.8, 44.8)],  # Dinarides
    [(9.4, 44.4), (11.6, 43.7), (13.2, 42.5), (14.6, 41.6), (15.4, 40.6),
     (16.0, 39.4), (15.3, 39.9), (13.9, 41.2), (12.4, 42.4), (10.6, 43.6),
     (8.8, 44.2)],  # Apennines
    [(2.4, 44.5), (4.1, 44.6), (4.3, 45.5), (2.7, 45.6)],  # Massif Central
    [(-6.6, 42.9), (-4.2, 43.1), (-4.3, 43.35), (-6.5, 43.2)],  # Cantabrian
    [(-3.6, 37.0), (-2.5, 37.2), (-2.6, 37.45), (-3.7, 37.25)],  # S. Nevada
]

# Additional hill regions (h) beyond the automatic halo.
HILLS = [
    [(-7.5, 39.5), (-3.0, 41.5), (-2.0, 40.5), (-4.0, 38.5), (-6.5, 38.0)],  # Meseta
    [(21.5, 41.3), (23.5, 41.8), (25.5, 42.2), (25.0, 41.4), (22.5, 40.8)],  # Rhodopes
    [(12.5, 50.3), (14.9, 50.9), (16.5, 50.4), (14.8, 49.6), (13.0, 49.5)],  # Bohemia rim
    [(-3.9, 51.9), (-3.2, 53.1), (-3.9, 52.9), (-4.4, 52.2)],  # Wales
    [(7.8, 47.9), (8.4, 48.6), (8.9, 48.3), (8.3, 47.7)],  # Black Forest
    [(22.0, 62.0), (26.0, 63.5), (29.0, 63.0), (26.0, 61.5)],  # Finnish lakes ridge
]

RIVERS = {
    "rhine": [(7.6, 47.6), (7.8, 48.6), (8.4, 49.5), (8.3, 50.0), (7.6, 50.5),
              (6.8, 51.2), (6.1, 51.9), (5.0, 51.9), (4.2, 51.95)],
    "rhone": [(6.1, 46.2), (4.9, 45.8), (4.8, 44.8), (4.7, 44.0), (4.6, 43.6)],
    "loire": [(3.9, 45.1), (3.1, 46.7), (2.3, 47.7), (0.7, 47.4), (-1.4, 47.25)],
    "danube": [(8.6, 48.1), (10.2, 48.5), (12.1, 48.8), (13.4, 48.6),
               (15.3, 48.3), (16.4, 48.2), (17.8, 47.9), (19.0, 47.6),
               (18.9, 46.2), (20.4, 45.3), (22.5, 44.7), (24.5, 43.9),
               (26.5, 44.0), (28.2, 44.5), (29.5, 45.1)],
    "elbe": [(14.4, 50.8), (13.7, 51.1), (12.7, 51.9), (11.9, 52.5),
             (10.9, 53.2), (9.9, 53.55), (8.9, 53.9)],
    "po": [(7.3, 44.9), (9.0, 45.1), (10.8, 45.05), (12.2, 44.95)],
    "vistula": [(19.1, 50.1), (21.1, 51.3), (21.05, 52.25), (19.7, 52.6),
                (18.7, 53.1), (18.8, 54.2)],
}

# id, name, lon, lat, peak MW, season, temp coeff (%/degC):
# winter 1.8 (paris 2.4), summer 1.5, flat 0.8 — GAME_DESIGN SS2.2 mapping.
LOAD_CENTERS = [
    ("london", "London & South-East England", -0.13, 51.51, 15000.0, "winter", 1.8),
    ("paris", "Île-de-France", 2.35, 48.86, 12000.0, "winter", 2.4),
    ("ruhr", "Rhine-Ruhr", 7.0, 51.45, 11000.0, "flat", 0.8),
    ("milan", "Po Valley (Milan–Turin)", 9.19, 45.46, 9000.0, "summer", 1.5),
    ("rome", "Rome–Naples", 12.5, 41.9, 7000.0, "summer", 1.5),
    ("madrid", "Madrid", -3.7, 40.42, 6000.0, "summer", 1.5),
    ("barcelona", "Catalonia–Valencia", 2.17, 41.39, 6000.0, "summer", 1.5),
    ("silesia", "Upper Silesia", 19.0, 50.26, 6000.0, "flat", 0.8),
    ("munich", "Bavaria", 11.58, 48.14, 6000.0, "winter", 1.8),
    ("randstad", "Randstad (NL)", 4.9, 52.37, 6000.0, "winter", 1.8),
    ("brussels", "Brussels–Antwerp", 4.35, 50.85, 5000.0, "winter", 1.8),
    ("frankfurt", "Rhine-Main", 8.68, 50.11, 5000.0, "flat", 0.8),
    ("stuttgart", "Baden-Württemberg", 9.18, 48.78, 5000.0, "flat", 0.8),
    ("warsaw", "Warsaw–Łódź", 21.01, 52.23, 5000.0, "winter", 1.8),
    ("lyon", "Rhône-Alpes", 4.84, 45.76, 5000.0, "winter", 1.8),
    ("berlin", "Berlin", 13.4, 52.52, 4000.0, "winter", 1.8),
    ("hamburg", "Hamburg", 9.99, 53.55, 4000.0, "winter", 1.8),
    ("prague", "Bohemia", 14.42, 50.09, 4000.0, "winter", 1.8),
    ("vienna", "Vienna", 16.37, 48.21, 4000.0, "winter", 1.8),
    ("zurich", "Swiss Plateau", 8.54, 47.37, 4000.0, "winter", 1.8),
    ("copenhagen", "Øresund (CPH–Malmö)", 12.57, 55.68, 4000.0, "winter", 1.8),
    ("stockholm", "Mälardalen", 18.07, 59.33, 4000.0, "winter", 1.8),
    ("athens", "Attica", 23.73, 37.98, 4000.0, "summer", 1.5),
    ("lisbon", "Lisbon–Porto", -9.14, 38.72, 4000.0, "flat", 0.8),
    ("oslo", "Oslo–Viken", 10.75, 59.91, 3000.0, "winter", 1.8),
]

PHS_SITES = [  # (lon, lat, max_gwh) — all must land on `m`
    (6.8, 45.3, 60), (8.6, 46.3, 55), (11.3, 46.9, 45), (13.3, 47.2, 40),
    (0.5, 42.7, 30), (2.0, 42.6, 25),
    (6.9, 60.0, 60), (7.9, 61.3, 55), (12.6, 64.6, 40),
    (-4.6, 57.2, 25),
    (19.6, 49.3, 30), (25.2, 47.4, 30),
    (17.5, 43.7, 25), (15.9, 44.6, 20),
]

SALT_CAVERNS = [  # region boxes (lon0, lat0, lon1, lat1)
    (7.2, 52.4, 9.8, 53.5),  # N-Germany
    (6.3, 52.7, 7.1, 53.3),  # NE-Netherlands
    (8.6, 55.3, 9.4, 56.5),  # Danish Jutland
    (-1.6, 54.4, -0.9, 54.9),  # Teesside
    (17.8, 51.9, 19.6, 52.5),  # central Poland
    (4.5, 43.8, 5.1, 45.0),  # Rhone valley
]

COAL_BASINS = [
    (6.4, 51.2, 7.7, 51.7),  # Ruhr
    (13.8, 51.3, 14.8, 51.8),  # Lusatia
    (18.4, 49.9, 19.5, 50.5),  # Upper Silesia
    (-6.6, 43.0, -5.4, 43.4),  # Asturias
]

SHALLOW_BOXES = [  # seas forced to shelf `s`
    (-4.5, 51.0, 9.0, 61.5),  # North Sea (+ Channel approaches)
    (9.0, 53.4, 30.8, 66.2),  # Baltic incl. Gulf of Bothnia
    (-6.8, 51.6, -2.6, 55.6),  # Irish Sea
    (12.0, 39.9, 20.0, 45.8),  # Adriatic
]


def point_in_poly(lon: float, lat: float, poly: list[tuple[float, float]]) -> bool:
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > lat) != (yj > lat):
            if lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                inside = not inside
        j = i
    return inside


def sample_path(path: list[tuple[float, float]], step_deg: float = 0.05):
    for (lon0, lat0), (lon1, lat1) in zip(path, path[1:]):
        dist = math.hypot(lon1 - lon0, lat1 - lat0)
        n = max(2, int(dist / step_deg))
        for k in range(n + 1):
            f = k / n
            yield lon0 + f * (lon1 - lon0), lat0 + f * (lat1 - lat0)


def build() -> dict:
    land = _natural_earth_land()
    if land is None:
        land = [[False] * WIDTH for _ in range(HEIGHT)]
    if _NE_LAND_USED:
        pass  # Natural Earth already filled the mask
    else:
        for y in range(HEIGHT):
            for x in range(WIDTH):
                lon, lat = center_of(x, y)
                if any(point_in_poly(lon, lat, poly) for poly in LANDMASSES):
                    land[y][x] = True

    for path in CARVES:  # forced sea channels
        for lon, lat in sample_path(path):
            x, y = tile_of(lon, lat)
            if 0 <= x < WIDTH and 0 <= y < HEIGHT:
                land[y][x] = False

    grid = [["S"] * WIDTH for _ in range(HEIGHT)]
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if land[y][x]:
                grid[y][x] = "p"

    def is_land(x: int, y: int) -> bool:
        return 0 <= x < WIDTH and 0 <= y < HEIGHT and land[y][x]

    def is_land_for_class(x: int, y: int) -> bool:
        # For coast/shelf classification the map edge counts as "more of the
        # same": land clipped by the grid boundary must not grow a fake coast.
        if not (0 <= x < WIDTH and 0 <= y < HEIGHT):
            return True
        return land[y][x]

    # mountains + hills
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if not land[y][x]:
                continue
            if _NE_RANGES is not None:
                if _NE_RANGES[y][x]:
                    grid[y][x] = "m"
                continue
            lon, lat = center_of(x, y)
            if any(point_in_poly(lon, lat, poly) for poly in MOUNTAINS):
                grid[y][x] = "m"
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if grid[y][x] != "p":
                continue
            lon, lat = center_of(x, y)
            reach = max(1, int(round(FOOTHILL_KM / TILE_KM)))
            halo = any(
                0 <= x + dx < WIDTH and 0 <= y + dy < HEIGHT
                and grid[y + dy][x + dx] == "m"
                for dx in range(-reach, reach + 1)
                for dy in range(-reach, reach + 1)
            )
            if halo or any(point_in_poly(lon, lat, poly) for poly in HILLS):
                grid[y][x] = "h"

    # Upland texture (ledger 38): the authored polygons carve the NAMED
    # ranges; a deterministic low-frequency noise field then lifts coherent
    # regions of plain into hill country, so 15 km tiles show the rolling
    # relief Europe actually has instead of one flat green sheet.
    upland = _value_noise(WIDTH, HEIGHT, cells=22, seed=7)
    ridge = _value_noise(WIDTH, HEIGHT, cells=34, seed=11)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if grid[y][x] != "p":
                continue
            if upland[y][x] > 0.62:
                grid[y][x] = "h"
    # ridge crests inside big hill masses become low mountains
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if grid[y][x] != "h":
                continue
            if upland[y][x] > 0.78 and ridge[y][x] > 0.72:
                grid[y][x] = "m"

    # coasts (4-neighbor; mountains keep their kind)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if land[y][x] and grid[y][x] in ("p", "h"):
                if any(not is_land_for_class(x + dx, y + dy)
                       for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    grid[y][x] = "c"

    # shelf seas: near-land ring + authored shallow boxes
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if land[y][x]:
                continue
            lon, lat = center_of(x, y)
            near_land = any(
                is_land(x + dx, y + dy)
                for dx in (-1, 0, 1) for dy in (-1, 0, 1)
            )
            in_box = any(b[0] <= lon <= b[2] and b[1] <= lat <= b[3]
                         for b in SHALLOW_BOXES)
            grid[y][x] = "s" if (near_land or in_box) else "S"

    # --- resources ------------------------------------------------------
    resources: list[dict] = []

    def box_tiles(box, want_land=True):
        tiles = []
        for y in range(HEIGHT):
            for x in range(WIDTH):
                lon, lat = center_of(x, y)
                if box[0] <= lon <= box[2] and box[1] <= lat <= box[3]:
                    if land[y][x] == want_land:
                        tiles.append([x, y])
        return tiles

    def box_tiles_nonempty(box):
        tiles = box_tiles(box)
        if tiles:
            return tiles
        # Small boxes can miss every tile center — snap to the nearest land
        # tile around the box midpoint (deterministic spiral).
        cx, cy = tile_of((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
        for r in range(0, 4):
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < WIDTH and 0 <= y < HEIGHT and land[y][x]:
                        return [[x, y]]
        raise SystemExit(f"resource box {box} found no land tile")

    for box in COAL_BASINS:
        resources.append({"kind": "coal_basin", "tiles": box_tiles_nonempty(box)})
    for box in SALT_CAVERNS:
        resources.append({"kind": "salt_cavern", "tiles": box_tiles_nonempty(box)})

    for lon, lat, gwh in PHS_SITES:
        x, y = tile_of(lon, lat)
        # Snap to the nearest upland tile. The radius is a DISTANCE (~40 km)
        # and mountains are preferred but hills accepted: Natural Earth's
        # named ranges do not cover every real PHS massif (the Scottish
        # Highlands are hill-classed here), and a pumped-storage site in
        # hill country is perfectly plausible.
        best = None
        reach = max(2, int(round(40.0 / TILE_KM)))
        for wanted in ("m", "h"):
            for r in range(0, reach + 1):
                for dy in range(-r, r + 1):
                    for dx in range(-r, r + 1):
                        xx, yy = x + dx, y + dy
                        if 0 <= xx < WIDTH and 0 <= yy < HEIGHT \
                                and grid[yy][xx] == wanted:
                            best = [xx, yy]
                            break
                    if best:
                        break
                if best:
                    break
            if best:
                break
        if best is None:
            raise SystemExit(f"phs_site at ({lon},{lat}) found no upland tile")
        resources.append({"kind": "phs_site", "tiles": [best], "max_gwh": gwh})

    wind_tiles_130, wind_tiles_125, wind_tiles_115 = [], [], []
    for y in range(HEIGHT):
        for x in range(WIDTH):
            lon, lat = center_of(x, y)
            if grid[y][x] == "s":
                wind_tiles_130.append([x, y])
            elif grid[y][x] == "c" and lat > 47.0:
                wind_tiles_125.append([x, y])
            elif grid[y][x] == "c" and lon < -6.0:
                wind_tiles_115.append([x, y])
    resources.append({"kind": "wind_resource", "tiles": wind_tiles_130, "factor": 1.3})
    resources.append({"kind": "wind_resource", "tiles": wind_tiles_125, "factor": 1.25})
    resources.append({"kind": "wind_resource", "tiles": wind_tiles_115, "factor": 1.15})
    resources.append({"kind": "solar_resource", "band_lat": [35, 44], "factor": 1.3})
    resources.append({"kind": "solar_resource", "band_lat": [44, 50], "factor": 1.1})

    if _NE_RIVERS:
        # real courses from Natural Earth: the Rhine actually bends at Basel
        # and the Danube reaches the delta. Only tiles that ended up on land
        # count — a course crossing an estuary must not paint the sea.
        for name, course in sorted(_NE_RIVERS.items()):
            tiles = [[x, y] for x, y in sorted(course) if is_land(x, y)]
            if len(tiles) < 3:
                continue
            resources.append({"kind": "river", "name": name.lower(),
                              "tiles": tiles})
    else:
        for name, path in RIVERS.items():
            tiles, seen = [], set()
            for lon, lat in sample_path(path):
                x, y = tile_of(lon, lat)
                if (x, y) not in seen and is_land(x, y):
                    seen.add((x, y))
                    tiles.append([x, y])
            resources.append({"kind": "river", "name": name, "tiles": tiles})

    # --- load centers ---------------------------------------------------
    def footprint_ok(x0, y0, n, taken):
        """A metro footprint must be mostly buildable land and unclaimed.

        Not ENTIRELY land: at 5 km a real coastal metro (Rome, Lisbon,
        Copenhagen, Athens) legitimately spans water, and demanding a solid
        square left them homeless."""
        buildable = 0
        for yy in range(y0, y0 + n):
            for xx in range(x0, x0 + n):
                if not (0 <= xx < WIDTH and 0 <= yy < HEIGHT):
                    return False
                if (xx, yy) in taken:
                    return False
                if grid[yy][xx] in ("p", "h", "c"):
                    buildable += 1
        return buildable >= int(0.7 * n * n)

    centers = []
    taken: set[tuple[int, int]] = set()
    shifts = []
    for cid, name, lon, lat, peak, season, coeff in LOAD_CENTERS:
        n = max(2, int(round(
            (METRO_BIG_KM if peak >= 8000.0 else METRO_KM) / TILE_KM)))
        cx, cy = tile_of(lon, lat)
        x0, y0 = cx - n // 2, cy - n // 2
        placed = None
        # the search radius is a DISTANCE (~150 km), not a tile count
        for r in range(0, max(4, int(round(150.0 / TILE_KM)))):
            candidates = sorted(
                ((x0 + dx, y0 + dy) for dx in range(-r, r + 1)
                 for dy in range(-r, r + 1)),
                key=lambda p: (abs(p[0] - x0) + abs(p[1] - y0), p),
            )
            for px, py in candidates:
                if footprint_ok(px, py, n, taken):
                    placed = (px, py)
                    break
            if placed:
                break
        if placed is None:
            raise SystemExit(f"load center {cid} found no land footprint")
        px, py = placed
        if (px, py) != (x0, y0):
            shifts.append((cid, abs(px - x0) + abs(py - y0)))
        tiles = [[px + dx, py + dy] for dy in range(n) for dx in range(n)
                 if grid[py + dy][px + dx] in ("p", "h", "c")]
        taken.update((t[0], t[1]) for t in tiles)
        centers.append({
            "id": cid, "name": name, "tiles": tiles,
            "peak_mw_2025": peak, "season": season,
            "temp_coeff_pct_per_c": coeff,
        })

    doc = {
        "version": 1,
        "tile_km": TILE_KM,
        "width": WIDTH,
        "height": HEIGHT,
        "projection": {
            "lon0": LON0, "lat0": LAT0,
            "deg_lon_per_tile": round(DLON, 6),
            "deg_lat_per_tile": round(DLAT, 6),
        },
        "terrain_rows": ["".join(row) for row in grid],
        "resources": resources,
        "load_centers": centers,
    }
    return doc, shifts


def render_preview(doc: dict) -> str:
    rows = [list(r) for r in doc["terrain_rows"]]
    plain = "\n".join("".join(r) for r in rows)
    for i, center in enumerate(doc["load_centers"]):
        marker = chr(ord("A") + i) if i < 26 else "#"
        for x, y in center["tiles"]:
            rows[y][x] = marker
    marked = "\n".join("".join(r) for r in rows)
    legend = "  ".join(
        f"{chr(ord('A') + i)}={c['id']}" for i, c in enumerate(doc["load_centers"])
    )
    return (
        "TERRAIN (S deep sea, s shelf, c coast, p plain, h hills, m mountain)\n"
        + plain + "\n\nLOAD CENTERS\n" + legend + "\n" + marked + "\n"
    )


def main() -> None:
    doc, shifts = build()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "europe_v3.json").write_text(json.dumps(doc, indent=1) + "\n")
    PREVIEW.write_text(render_preview(doc))
    counts: dict[str, int] = {}
    for row in doc["terrain_rows"]:
        for ch in row:
            counts[ch] = counts.get(ch, 0) + 1
    print("tile counts:", dict(sorted(counts.items())))
    if shifts:
        print("shifted load centers:", shifts)
    print(f"wrote {OUT_DIR / 'europe_v3.json'} and {PREVIEW}")


if __name__ == "__main__":
    main()
