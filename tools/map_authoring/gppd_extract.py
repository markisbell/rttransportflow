"""Real plant sites for the campaign world, from the WRI Global Power
Plant Database (CC-BY 4.0 — attribution required and given; a licence-clean
source where OSM/OpenInfraMap would attach ODbL, ledger 38/46).

Produces data/grids/europe_plants_seed.json: every plant >= 500 MW inside
the map window plus offshore wind parks >= 200 MW and the curated European
pumped-storage fleet, each with name, lat/lon, capacity and its GAME kind.
Curation rules, each a deliberate mapping to the game's model:

- Gas -> gas_ccgt, Oil -> gas_ocgt (peakers), Cogeneration -> gas_ccgt.
- Coal -> coal, except the named lignite stations (the game prices lignite
  separately, ledger 17); GPPD does not distinguish.
- Hydro is included ONLY where the plant is on the curated pumped-storage
  list -> hydro_ps: the game has no run-of-river/storage-hydro kind, and
  mapping Alpine storage to PHS would hand the dispatcher phantom pumping.
- Wind -> wind_offshore when the plant's tile is SEA on the game map (the
  map itself is the offshore truth), else skipped in v1 (onshore wind
  arrives through the campaign's unlock years, not the inherited fleet).
- GPPD is a 2021 snapshot; no real-world retirements are applied — the
  game's inherited-2025 fleet is deliberately conventional (GAME_DESIGN
  §5.1's premise, nuclear included).
"""

from __future__ import annotations

import csv
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
GPPD = HERE / "ne_cache" / "global_power_plant_database.csv"

# The European pumped-storage fleet (curated; GPPD's Storage tag is
# batteries, its Hydro tag mixes PHS with conventional storage hydro).
PHS_NAMES = [
    "goldisthal", "markersbach", "wehr", "waldeck", "hohenwarte",
    "vianden", "coo", "dinorwig", "cruachan", "ffestiniog", "foyers",
    "turlough hill", "grand maison", "grand'maison", "montezic", "revin",
    "super bissorte", "la coche", "le cheylas", "kopswerk", "malta",
    "kaprun", "limberg", "haeusling", "roßhag", "silz", "linth",
    "limmern", "nant de drance", "veytaux", "robiei", "la muela",
    "cortes", "aguayo", "tajo de la encantada", "estangento",
    "aldeadavila", "villarino", "frades", "alqueva", "entracque",
    "edolo", "presenzano", "anapo", "roncovalgrande", "chiotas",
    "cierny vah", "dlouhe strane", "zarnowiec", "porabka", "zydowo",
    "bajina basta", "capljina", "avce", "kruonis", "dniester",
    "tashlyk", "zagorsk", "kiev", "okinawa",
]
LIGNITE_NAMES = [
    "boxberg", "jaenschwalde", "jänschwalde", "schwarze pumpe", "lippendorf",
    "neurath", "niederaussem", "niederaußem", "weisweiler", "boa",
    "schkopau", "belchatow", "bełchatów", "turow", "turów", "patnow",
    "pątnów", "prunerov", "prunéřov", "pocerady", "počerady", "tusimice",
    "tušimice", "melnik", "mělník", "matra", "mátra", "maritsa",
    "kosovo", "bitola", "kostolac", "nikola tesla", "ugljevik", "tuzla",
    "sostanj", "šoštanj", "ptolemaida", "agios dimitrios", "kardia",
    "megalopoli", "sines",
]


def _norm(name: str) -> str:
    return (name.lower().replace("-", " ").replace("_", " ")
            .replace("power station", "").replace("power plant", "").strip())


def build() -> Path:
    doc = json.loads((REPO / "data" / "map" / "europe_v3.json").read_text())
    lon0, lat0 = doc["projection"]["lon0"], doc["projection"]["lat0"]
    dlon = doc["projection"]["deg_lon_per_tile"]
    dlat = doc["projection"]["deg_lat_per_tile"]
    rows_terrain = doc["terrain_rows"]
    width, height = doc["width"], doc["height"]

    def terrain(lat: float, lon: float) -> str:
        x = int((lon - lon0) / dlon)
        y = int((lat0 - lat) / dlat)
        if 0 <= x < width and 0 <= y < height:
            return rows_terrain[y][x]
        return "?"

    out = []
    counts = {}
    for r in csv.DictReader(open(GPPD)):
        if not (r["latitude"] and r["longitude"] and r["capacity_mw"]):
            continue
        lat, lon = float(r["latitude"]), float(r["longitude"])
        if not (34.9 < lat < 71.0 and -20.0 < lon < 50.0):
            continue
        cap = float(r["capacity_mw"])
        fuel = r["primary_fuel"]
        name = _norm(r["name"])
        kind = ""
        if any(p in name for p in PHS_NAMES) and fuel in ("Hydro", "Storage"):
            kind = "hydro_ps"
        elif fuel == "Nuclear" and cap >= 500:
            kind = "nuclear"
        elif fuel == "Coal" and cap >= 500:
            kind = "lignite" if any(l in name for l in LIGNITE_NAMES) else "coal"
        elif fuel in ("Gas", "Cogeneration") and cap >= 500:
            kind = "gas_ccgt"
        elif fuel == "Oil" and cap >= 500:
            kind = "gas_ocgt"
        elif fuel == "Wind" and cap >= 200 and terrain(lat, lon) in ("S", "s"):
            kind = "wind_offshore"
        if kind == "":
            continue
        out.append({"name": r["name"], "country": r["country"],
                    "lat": round(lat, 4), "lon": round(lon, 4),
                    "capacity_mw": cap, "kind": kind})
        counts[kind] = counts.get(kind, 0) + 1

    out.sort(key=lambda p: (p["kind"], -p["capacity_mw"], p["name"]))
    target = REPO / "data" / "grids" / "europe_plants_seed.json"
    target.write_text(json.dumps({
        "version": 1,
        "source": "Global Power Plant Database v1.3, World Resources "
                  "Institute (CC-BY 4.0) — curated per module docstring",
        "plants": out,
    }, indent=1))
    print("extracted:", counts, "total", len(out), "->", target.name)
    return target


if __name__ == "__main__":
    build()
