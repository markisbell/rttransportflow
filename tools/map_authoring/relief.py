"""Render-relief sidecar for a quantized Europe map.

Produces data/map/<map>_relief.json — a RENDER-ONLY companion the game
renderer loads next to the map: per-tile real elevation (ETOPO), a
vegetation density byte (climate model: latitude + elevation + noise), and
a lake mask (Natural Earth lakes, distinct from sea). The map file itself
is untouched: terrain classes stay the gameplay truth (where you can build,
what a corridor crosses), the relief only changes what the ground LOOKS
like. That split is deliberate — the map digests stay pinned and a map
without a relief sidecar still renders on the class-lift fallback.

Elevation source: ETOPO1 (NOAA, public domain), fetched once as a Europe
subset via the ERDDAP griddap service at 2-arc-minute stride (~3.7 km —
finer than the 5 km tile) into ne_cache/etopo_europe.nc (netCDF3, readable
by scipy without new dependencies).

Encoding: row-major per-tile bytes, base64. Elevation is quantized to
ELEV_STEP-metre steps from ELEV_OFFSET so one byte covers the Dead
Sea shore to Mont Blanc; at the renderer's vertical scale a step is well
under a hundredth of a world unit, far below anything visible. The
quantization constants ride in the JSON so the reader never hardcodes them.
"""

from __future__ import annotations

import base64
import json
import time
import urllib.request
from pathlib import Path

import numpy as np
from scipy.io import netcdf_file

import natural_earth as ne

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ETOPO = HERE / "ne_cache" / "etopo_europe.nc"
ETOPO_URL = ("https://coastwatch.pfeg.noaa.gov/erddap/griddap/etopo180.nc"
             "?altitude%5B(34):2:(72)%5D%5B(-21):2:(51)%5D")

ELEV_STEP = 22       # metres per byte step
ELEV_OFFSET = -900   # metres at byte 0
FLAG_LAKE = 1

# vegetation model — tuned against the look, not against a land-cover
# product (none exists at a licence and download size that fits this
# repo; the macro pattern — boreal north, farmed plains, forested hills,
# dry Mediterranean — is what reads at 5 km tiles anyway)
VEG_SEED = 20260821


def _fetch_etopo() -> Path:
    if not ETOPO.exists():
        print("  downloading ETOPO Europe subset ...")
        with urllib.request.urlopen(ETOPO_URL, timeout=300) as response:
            ETOPO.write_bytes(response.read())
    return ETOPO


def _value_noise(height: int, width: int, cell: int, seed: int) -> np.ndarray:
    """Deterministic bilinear value noise in [0, 1] at `cell`-tile scale."""
    rng = np.random.default_rng(seed)
    gh = height // cell + 2
    gw = width // cell + 2
    grid = rng.random((gh, gw))
    ys = np.arange(height) / cell
    xs = np.arange(width) / cell
    y0 = ys.astype(int)
    x0 = xs.astype(int)
    fy = (ys - y0)[:, None]
    fx = (xs - x0)[None, :]
    a = grid[np.ix_(y0, x0)]
    b = grid[np.ix_(y0, x0 + 1)]
    c = grid[np.ix_(y0 + 1, x0)]
    d = grid[np.ix_(y0 + 1, x0 + 1)]
    return a * (1 - fy) * (1 - fx) + b * (1 - fy) * fx \
        + c * fy * (1 - fx) + d * fy * fx


def _smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def build(map_path: Path) -> Path:
    t0 = time.time()
    doc = json.loads(map_path.read_text())
    width, height = doc["width"], doc["height"]
    projection = doc["projection"]
    lon0, lat0 = projection["lon0"], projection["lat0"]
    dlon, dlat = projection["deg_lon_per_tile"], projection["deg_lat_per_tile"]
    rows = doc["terrain_rows"]
    water = np.array([[ch in "Ss" for ch in row] for row in rows])

    # --- elevation: mean of a 2x2 in-tile ETOPO sample -------------------
    nc = netcdf_file(str(_fetch_etopo()), mmap=False)
    e_lat = nc.variables["latitude"][:].astype(np.float64)
    e_lon = nc.variables["longitude"][:].astype(np.float64)
    e_alt = nc.variables["altitude"][:].astype(np.float64)

    def sample(lats: np.ndarray, lons: np.ndarray) -> np.ndarray:
        """Bilinear sample of the ETOPO grid at (lat, lon) arrays."""
        li = np.clip(np.searchsorted(e_lat, lats) - 1, 0, len(e_lat) - 2)
        lj = np.clip(np.searchsorted(e_lon, lons) - 1, 0, len(e_lon) - 2)
        fy = (lats - e_lat[li]) / (e_lat[li + 1] - e_lat[li])
        fx = (lons - e_lon[lj]) / (e_lon[lj + 1] - e_lon[lj])
        return (e_alt[li, lj] * (1 - fy) * (1 - fx)
                + e_alt[li, lj + 1] * (1 - fy) * fx
                + e_alt[li + 1, lj] * fy * (1 - fx)
                + e_alt[li + 1, lj + 1] * fy * fx)

    tile_y, tile_x = np.mgrid[0:height, 0:width].astype(np.float64)
    elev = np.zeros((height, width))
    for oy, ox in ((0.25, 0.25), (0.25, 0.75), (0.75, 0.25), (0.75, 0.75)):
        lats = lat0 - (tile_y + oy) * dlat
        lons = lon0 + (tile_x + ox) * dlon
        elev += sample(lats.ravel(), lons.ravel()).reshape(height, width)
    elev *= 0.25

    # Class truth wins at the coastline: a land tile never dips below the
    # water plane and a water tile never rises above it, whatever the DEM
    # says about a mixed 5 km cell — otherwise the renderer's smooth
    # shoreline and the buildability rules would visibly disagree.
    elev = np.where(water, np.minimum(elev, -6.0), np.maximum(elev, 4.0))

    # --- lake mask (NE lakes, the same layer quantize cut out of land) ---
    bbox = (lon0 - 1.0, lat0 - height * dlat - 1.0,
            lon0 + width * dlon + 1.0, lat0 + 1.0)

    def tile_of(lon: float, lat: float) -> tuple[float, float]:
        return (lon - lon0) / dlon, (lat0 - lat) / dlat

    lake_rings = ne.rings_in("lakes", bbox, min_size=0.02)
    lake_mask = np.array(ne.rasterize(lake_rings, tile_of, width, height))
    lake_mask &= water  # a lake byte on a land tile would be a lie

    # --- urban footprints (NE urban areas: real MODIS-derived city shapes,
    # public domain — Berlin's blob, the Ruhr sprawl). Blurred once so the
    # density grades from dense core to fringe instead of a hard edge.
    from scipy.ndimage import uniform_filter
    urban_rings = ne.rings_in("urban", bbox, min_size=0.0008)
    urban_mask = np.array(ne.rasterize(urban_rings, tile_of, width, height))
    urban_mask &= ~water
    urban = uniform_filter(urban_mask.astype(np.float64), size=3)
    urban[water] = 0.0

    # --- vegetation density (the forest layer) ---------------------------
    lat_grid = lat0 - (tile_y + 0.5) * dlat
    # macro moisture: dry Mediterranean south, temperate centre, wet north
    moisture = _smoothstep(36.0, 50.0, lat_grid) * 0.75 \
        + _smoothstep(54.0, 62.0, lat_grid) * 0.25
    # trees stop at the treeline, which falls with latitude
    treeline = 2400.0 - (lat_grid - 35.0) * 48.0
    alt_ok = 1.0 - _smoothstep(treeline * 0.72, treeline, elev)
    # the farmed lowland plains carry fields, not closed forest
    farmland = _smoothstep(45.0, 48.0, lat_grid) \
        * (1.0 - _smoothstep(55.0, 58.0, lat_grid)) \
        * (1.0 - _smoothstep(150.0, 420.0, elev))
    # forest masses are patchy at two scales (regions and stands)
    patch = 0.62 * _value_noise(height, width, 34, VEG_SEED) \
        + 0.38 * _value_noise(height, width, 9, VEG_SEED + 1)
    veg = moisture * alt_ok * (0.30 + 0.70 * _smoothstep(0.35, 0.72, patch))
    veg *= 1.0 - 0.62 * farmland
    veg[water] = 0.0
    green = np.clip(veg * 255.0, 0, 255).astype(np.uint8)

    # --- encode ----------------------------------------------------------
    elev_bytes = np.clip((elev - ELEV_OFFSET) / ELEV_STEP, 0, 255) \
        .astype(np.uint8)
    flags = np.where(lake_mask, FLAG_LAKE, 0).astype(np.uint8)
    out = {
        "version": 1,
        "width": width,
        "height": height,
        "elev_step_m": ELEV_STEP,
        "elev_offset_m": ELEV_OFFSET,
        "lat0": lat0,
        "deg_lat_per_tile": dlat,
        "elev_b64": base64.b64encode(elev_bytes.tobytes()).decode(),
        "green_b64": base64.b64encode(green.tobytes()).decode(),
        "flags_b64": base64.b64encode(flags.tobytes()).decode(),
        "urban_b64": base64.b64encode(
            np.clip(urban * 255.0, 0, 255).astype(np.uint8).tobytes()).decode(),
    }
    target = map_path.with_name(map_path.stem + "_relief.json")
    target.write_text(json.dumps(out))

    land = ~water
    print(f"relief: {target.name} in {time.time() - t0:.1f} s — "
          f"urban tiles {int((urban > 0.05).sum())}, "
          f"land elev {elev[land].min():.0f}..{elev[land].max():.0f} m, "
          f"lake tiles {int(lake_mask.sum())}, "
          f"green>128 on {int((green > 128).sum())} tiles, "
          f"{target.stat().st_size // 1024} KB")
    return target


if __name__ == "__main__":
    build(REPO / "data" / "map" / "europe_v3.json")
