"""Natural Earth geometry -> the Europe tile grid.

WHY Natural Earth and not OpenStreetMap: NE vector data is explicitly
**public domain** ("no permission needed... though credit is appreciated"),
so nothing about its licence propagates into this repository. OSM is ODbL —
usable, but share-alike obligations attach to derived databases, and the
map grid we ship IS a derived database. NE at 1:10 m resolves to roughly a
kilometre, which is finer than our 5 km tile, so it is also sufficient.

Downloaded once into tools/map_authoring/ne_cache/ (git-ignored) from the
nvkelso/natural-earth-vector GeoJSON mirror. Layers used:

    ne_10m_land                     coastlines (land polygons)
    ne_10m_lakes                    inland water
    ne_10m_rivers_lake_centerlines  river courses, with scale ranks
    ne_10m_geography_regions_polys  named mountain ranges (FEATURECLA Range/mtn)

Everything here is pure geometry over lon/lat; the tile projection lives in
quantize.py, which passes its own tile_of() in.
"""

from __future__ import annotations

import json
import urllib.request
from pathlib import Path
from typing import Callable, Iterable

CACHE = Path(__file__).resolve().parent / "ne_cache"
MIRROR = ("https://raw.githubusercontent.com/nvkelso/natural-earth-vector"
          "/master/geojson")
LAYERS = {
    "land": "ne_10m_land",
    "lakes": "ne_10m_lakes",
    "rivers": "ne_10m_rivers_lake_centerlines",
    "regions": "ne_10m_geography_regions_polys",
}


def fetch(layer: str) -> dict:
    """Load a layer from the cache, downloading it once if missing."""
    CACHE.mkdir(exist_ok=True)
    path = CACHE / f"{LAYERS[layer]}.geojson"
    if not path.exists():
        url = f"{MIRROR}/{LAYERS[layer]}.geojson"
        print(f"  downloading {LAYERS[layer]} ...")
        with urllib.request.urlopen(url, timeout=120) as response:
            path.write_bytes(response.read())
    return json.loads(path.read_text())


# --- geometry helpers ------------------------------------------------------

def _rings(geometry: dict) -> Iterable[list]:
    """Every exterior ring of a (Multi)Polygon, as [(lon, lat), ...]."""
    kind = geometry.get("type")
    coords = geometry.get("coordinates") or []
    if kind == "Polygon":
        yield coords[0]
    elif kind == "MultiPolygon":
        for polygon in coords:
            yield polygon[0]


def _lines(geometry: dict) -> Iterable[list]:
    kind = geometry.get("type")
    coords = geometry.get("coordinates") or []
    if kind == "LineString":
        yield coords
    elif kind == "MultiLineString":
        yield from coords


def _bbox_of(points: list) -> tuple[float, float, float, float]:
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    return min(lons), min(lats), max(lons), max(lats)


def _point_in_ring(lon: float, lat: float, ring: list) -> bool:
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > lat) != (yj > lat):
            x_cross = (xj - xi) * (lat - yi) / (yj - yi + 1e-18) + xi
            if lon < x_cross:
                inside = not inside
        j = i
    return inside


def rasterize(rings: list[list], tile_of: Callable[[float, float], tuple[float, float]],
              width: int, height: int) -> list[list[bool]]:
    """Scanline even-odd fill of lon/lat rings straight into a tile mask.

    Point-in-polygon per tile is hopeless here: Eurasia is a single ring of
    ~10 000 vertices and the grid holds ~772 000 tiles. Scanline fill costs
    O(edges x rows) instead of O(tiles x vertices) — seconds, not hours.
    """
    mask = [[False] * width for _ in range(height)]
    # edges in TILE space, as (y0, y1, x_at_y0, slope)
    edges: list[tuple[float, float, float, float]] = []
    for ring in rings:
        points = [tile_of(lon, lat) for lon, lat in ring]
        for i in range(len(points)):
            x0, y0 = points[i]
            x1, y1 = points[(i + 1) % len(points)]
            if y0 == y1:
                continue  # horizontal edges never cross a scanline centre
            if y0 > y1:
                x0, y0, x1, y1 = x1, y1, x0, y0
            edges.append((y0, y1, x0, (x1 - x0) / (y1 - y0)))
    if not edges:
        return mask
    edges.sort(key=lambda e: e[0])
    for row in range(height):
        scan = row + 0.5
        crossings = [
            x0 + (scan - y0) * slope
            for y0, y1, x0, slope in edges
            if y0 <= scan < y1
        ]
        if not crossings:
            continue
        crossings.sort()
        for i in range(0, len(crossings) - 1, 2):
            start = max(0, int(crossings[i] + 0.5))
            end = min(width - 1, int(crossings[i + 1] - 0.5))
            for x in range(start, end + 1):
                mask[row][x] = True
    return mask


class RingIndex:
    """Rings bucketed by a coarse lon/lat grid — a full point-in-polygon
    sweep over NE's land layer costs minutes per map otherwise."""

    def __init__(self, rings: list[list], cell: float = 2.0) -> None:
        self.cell = cell
        self.buckets: dict[tuple[int, int], list[list]] = {}
        for ring in rings:
            lon0, lat0, lon1, lat1 = _bbox_of(ring)
            for bx in range(int(lon0 // cell), int(lon1 // cell) + 1):
                for by in range(int(lat0 // cell), int(lat1 // cell) + 1):
                    self.buckets.setdefault((bx, by), []).append(ring)

    def contains(self, lon: float, lat: float) -> bool:
        key = (int(lon // self.cell), int(lat // self.cell))
        for ring in self.buckets.get(key, ()):
            if _point_in_ring(lon, lat, ring):
                return True
        return False


def rings_in(layer: str, bbox: tuple[float, float, float, float],
             min_size: float = 0.0, featurecla: str | None = None) -> list[list]:
    """Every exterior ring of `layer` overlapping the map window."""
    lon0, lat0, lon1, lat1 = bbox
    out: list[list] = []
    for feature in fetch(layer)["features"]:
        if featurecla is not None \
                and feature["properties"].get("FEATURECLA") != featurecla:
            continue
        for ring in _rings(feature["geometry"]):
            r_lon0, r_lat0, r_lon1, r_lat1 = _bbox_of(ring)
            if r_lon1 < lon0 or r_lon0 > lon1 or r_lat1 < lat0 or r_lat0 > lat1:
                continue
            if min_size > 0.0 \
                    and (r_lon1 - r_lon0) * (r_lat1 - r_lat0) < min_size:
                continue
            out.append(ring)
    return out


def land_index(bbox: tuple[float, float, float, float]) -> RingIndex:
    """Land rings overlapping the map window."""
    lon0, lat0, lon1, lat1 = bbox
    rings: list[list] = []
    for feature in fetch("land")["features"]:
        for ring in _rings(feature["geometry"]):
            r_lon0, r_lat0, r_lon1, r_lat1 = _bbox_of(ring)
            if r_lon1 < lon0 or r_lon0 > lon1 or r_lat1 < lat0 or r_lat0 > lat1:
                continue
            rings.append(ring)
    return RingIndex(rings)


def lake_index(bbox: tuple[float, float, float, float],
               min_size: float = 0.02) -> RingIndex:
    lon0, lat0, lon1, lat1 = bbox
    rings: list[list] = []
    for feature in fetch("lakes")["features"]:
        for ring in _rings(feature["geometry"]):
            r_lon0, r_lat0, r_lon1, r_lat1 = _bbox_of(ring)
            if r_lon1 < lon0 or r_lon0 > lon1 or r_lat1 < lat0 or r_lat0 > lat1:
                continue
            # tiny lakes cannot survive tiling and only add noise
            if (r_lon1 - r_lon0) * (r_lat1 - r_lat0) < min_size:
                continue
            rings.append(ring)
    return RingIndex(rings)


def mountain_index(bbox: tuple[float, float, float, float]) -> RingIndex:
    """Named ranges (Alps, Pyrenees, Carpathians, Scandes, ...)."""
    lon0, lat0, lon1, lat1 = bbox
    rings: list[list] = []
    for feature in fetch("regions")["features"]:
        if feature["properties"].get("FEATURECLA") != "Range/mtn":
            continue
        for ring in _rings(feature["geometry"]):
            r_lon0, r_lat0, r_lon1, r_lat1 = _bbox_of(ring)
            if r_lon1 < lon0 or r_lon0 > lon1 or r_lat1 < lat0 or r_lat0 > lat1:
                continue
            rings.append(ring)
    return RingIndex(rings)


def river_tiles(bbox: tuple[float, float, float, float],
                tile_of: Callable[[float, float], tuple[int, int]],
                max_scalerank: int = 6) -> dict[str, set[tuple[int, int]]]:
    """Major river courses rasterised onto the grid, keyed by river name.

    `scalerank` is NE's own prominence ordering (0 = the Amazon/Nile class);
    keeping <= 6 gives the Rhine/Danube/Elbe/Rhône/Po/Vistula/Loire family
    without every tributary creek.
    """
    lon0, lat0, lon1, lat1 = bbox
    out: dict[str, set[tuple[int, int]]] = {}
    for feature in fetch("rivers")["features"]:
        props = feature["properties"]
        rank = props.get("scalerank")
        if rank is None or rank > max_scalerank:
            continue
        name = props.get("name_en") or props.get("NAME") or props.get("name") or "river"
        for line in _lines(feature["geometry"]):
            previous: tuple[int, int] | None = None
            for lon, lat in line:
                if not (lon0 <= lon <= lon1 and lat0 <= lat <= lat1):
                    previous = None
                    continue
                tile = tile_of(lon, lat)
                bucket = out.setdefault(name, set())
                if previous is not None:
                    bucket.update(_walk(previous, tile))
                bucket.add(tile)
                previous = tile
    return out


def _walk(a: tuple[int, int], b: tuple[int, int]) -> Iterable[tuple[int, int]]:
    """4-connected line between two tiles — NE vertices are far apart at
    5 km, so consecutive points must be joined or rivers come out dotted."""
    x0, y0 = a
    x1, y1 = b
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    error = dx - dy
    guard = 0
    while (x0, y0) != (x1, y1) and guard < 10_000:
        guard += 1
        yield (x0, y0)
        doubled = error * 2
        if doubled > -dy:
            error -= dy
            x0 += sx
        elif doubled < dx:
            error += dx
            y0 += sy
    yield (x1, y1)
