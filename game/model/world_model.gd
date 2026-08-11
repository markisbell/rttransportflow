extends Node
## WorldModel — the SOURCE OF TRUTH for the built world (infrastruct ADR-002
## pattern): pure logical tile data in Vector2i-keyed Dictionaries, versioned
## JSON envelope, NO scene nodes. Views only render; the topology builder and
## solvers are reset FROM this model, never the other way around.
##
## Static typing mandatory in model/ (infrastruct ADR-004 discipline).

signal world_changed  # any edit; the debounced reset listens to this

const ENVELOPE_VERSION := 1

## terrain: Vector2i -> String (one of S s c p h m), loaded from the map doc
var terrain: Dictionary = {}
var width: int = 0
var height: int = 0
var tile_km: float = 50.0

## resources: kind -> {Vector2i: params Dictionary} (coal_basin, salt_cavern,
## phs_site, wind_resource, river); solar bands kept separately
var resources: Dictionary = {}
var solar_bands: Array[Dictionary] = []

## load centers: id -> {name, peak_mw, season, temp_coeff, tiles: Array[Vector2i]}
var load_centers: Dictionary = {}
var _load_center_tiles: Dictionary = {}  # Vector2i -> load-center id

## corridors: Vector2i -> String line kind ("line_220" | "line_400")
var corridors: Dictionary = {}
## explicit substations: Vector2i -> true
var substations: Dictionary = {}
## plants: pid -> {kind, tile: Vector2i, p_max_mw}
var plants: Dictionary = {}
var _plant_tiles: Dictionary = {}  # Vector2i -> pid
var _next_pid: int = 1

const SYNC_KINDS: Array[String] = ["nuclear", "coal", "lignite", "gas_ccgt",
	"gas_ocgt", "hydro_ps"]
const CONVERTER_KINDS: Array[String] = ["wind_onshore", "wind_offshore", "solar_pv"]

## Default unit sizes per kind (PARAMETERS §1; balancing constants)
const PLANT_SIZES := {
	"nuclear": 1600.0, "coal": 800.0, "lignite": 900.0,
	"gas_ccgt": 600.0, "gas_ocgt": 200.0, "hydro_ps": 300.0,
	"wind_onshore": 200.0, "wind_offshore": 500.0, "solar_pv": 150.0,
}


func load_map(doc: Dictionary) -> bool:
	terrain.clear()
	resources.clear()
	solar_bands.clear()
	load_centers.clear()
	_load_center_tiles.clear()
	width = int(doc.get("width", 0))
	height = int(doc.get("height", 0))
	tile_km = float(doc.get("tile_km", 50.0))
	var rows: Array = doc.get("terrain_rows", [])
	if rows.size() != height:
		return false
	for y in range(height):
		var row: String = rows[y]
		if row.length() != width:
			return false
		for x in range(width):
			terrain[Vector2i(x, y)] = row[x]
	for res: Dictionary in doc.get("resources", []):
		var kind := str(res.get("kind", ""))
		if res.has("band_lat"):
			solar_bands.append(res)
			continue
		var bucket: Dictionary = resources.get(kind, {})
		for t: Array in res.get("tiles", []):
			bucket[Vector2i(int(t[0]), int(t[1]))] = res
		resources[kind] = bucket
	for lc: Dictionary in doc.get("load_centers", []):
		var tiles: Array[Vector2i] = []
		for t: Array in lc.get("tiles", []):
			var tv := Vector2i(int(t[0]), int(t[1]))
			tiles.append(tv)
			_load_center_tiles[tv] = str(lc["id"])
		load_centers[str(lc["id"])] = {
			"name": str(lc.get("name", lc["id"])),
			"peak_mw": float(lc.get("peak_mw_2025", 0.0)),
			"season": str(lc.get("season", "flat")),
			"temp_coeff": float(lc.get("temp_coeff_pct_per_c", 1.0)),
			"tiles": tiles,
		}
	return true


func terrain_at(tile: Vector2i) -> String:
	return str(terrain.get(tile, "S"))


func is_land(tile: Vector2i) -> bool:
	return terrain_at(tile) in ["c", "p", "h", "m"]


func load_center_at(tile: Vector2i) -> String:
	return str(_load_center_tiles.get(tile, ""))


func plant_at(tile: Vector2i) -> String:
	return str(_plant_tiles.get(tile, ""))


func has_resource(kind: String, tile: Vector2i) -> bool:
	return (resources.get(kind, {}) as Dictionary).has(tile)


## Placement validation per GAME_DESIGN §1.3 (ghost-preview truth).
func can_place_plant(kind: String, tile: Vector2i) -> bool:
	if _plant_tiles.has(tile) or _load_center_tiles.has(tile):
		return false
	var t := terrain_at(tile)
	match kind:
		"nuclear":
			return (t == "c" or (is_land(tile) and has_resource("river", tile))) \
				and t != "m"
		"coal", "lignite":
			var ok := t in ["p", "h", "c"]
			return ok and (kind != "lignite" or has_resource("coal_basin", tile))
		"gas_ccgt", "gas_ocgt":
			return is_land(tile)
		"wind_onshore":
			return t in ["p", "h", "c"]
		"wind_offshore":
			return t == "s"
		"solar_pv":
			return t in ["p", "h"]
		"hydro_ps":
			return has_resource("phs_site", tile)
	return false


func can_place_corridor(tile: Vector2i) -> bool:
	# AC corridors: land or shelf sea (submarine); deep sea is HVDC-only
	# (P7); never across an occupied site tile.
	return terrain_at(tile) in ["c", "p", "h", "m", "s"] \
		and not _plant_tiles.has(tile) and not _load_center_tiles.has(tile)


func place_plant(kind: String, tile: Vector2i) -> String:
	if not can_place_plant(kind, tile):
		return ""
	var pid := "%s_%d" % [kind, _next_pid]
	_next_pid += 1
	plants[pid] = {"kind": kind, "tile": tile,
		"p_max_mw": float(PLANT_SIZES[kind])}
	_plant_tiles[tile] = pid
	world_changed.emit()
	return pid


func remove_plant(pid: String) -> void:
	if plants.has(pid):
		_plant_tiles.erase(plants[pid]["tile"])
		plants.erase(pid)
		world_changed.emit()


func place_corridor(tile: Vector2i, kind: String = "line_400") -> bool:
	if not can_place_corridor(tile):
		return false
	if corridors.get(tile, "") == kind:
		return true
	corridors[tile] = kind
	world_changed.emit()
	return true


func remove_corridor(tile: Vector2i) -> void:
	if corridors.erase(tile):
		world_changed.emit()


func place_substation(tile: Vector2i) -> bool:
	if not is_land(tile):
		return false
	substations[tile] = true
	world_changed.emit()
	return true


func clear_build() -> void:
	corridors.clear()
	substations.clear()
	plants.clear()
	_plant_tiles.clear()
	_next_pid = 1
	world_changed.emit()


## Versioned envelope (save/load lands in P9; the format is fixed now).
func serialize() -> Dictionary:
	var corridor_list: Array = []
	for tile: Vector2i in corridors:
		corridor_list.append([tile.x, tile.y, corridors[tile]])
	var substation_list: Array = []
	for tile: Vector2i in substations:
		substation_list.append([tile.x, tile.y])
	var plant_list: Array = []
	for pid: String in plants:
		var p: Dictionary = plants[pid]
		plant_list.append({"pid": pid, "kind": p["kind"],
			"tile": [(p["tile"] as Vector2i).x, (p["tile"] as Vector2i).y],
			"p_max_mw": p["p_max_mw"]})
	return {"version": ENVELOPE_VERSION, "corridors": corridor_list,
		"substations": substation_list, "plants": plant_list,
		"next_pid": _next_pid}


func restore(envelope: Dictionary) -> bool:
	if int(envelope.get("version", -1)) != ENVELOPE_VERSION:
		return false
	clear_build()
	for entry: Array in envelope.get("corridors", []):
		corridors[Vector2i(int(entry[0]), int(entry[1]))] = str(entry[2])
	for entry: Array in envelope.get("substations", []):
		substations[Vector2i(int(entry[0]), int(entry[1]))] = true
	for p: Dictionary in envelope.get("plants", []):
		var tile := Vector2i(int(p["tile"][0]), int(p["tile"][1]))
		plants[str(p["pid"])] = {"kind": str(p["kind"]), "tile": tile,
			"p_max_mw": float(p["p_max_mw"])}
		_plant_tiles[tile] = str(p["pid"])
	_next_pid = int(envelope.get("next_pid", 1))
	world_changed.emit()
	return true
