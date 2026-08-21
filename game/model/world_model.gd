extends Node
## WorldModel — the SOURCE OF TRUTH for the built world (infrastruct ADR-002
## pattern): pure logical tile data in Vector2i-keyed Dictionaries, versioned
## JSON envelope, NO scene nodes. Views only render; the topology builder and
## solvers are reset FROM this model, never the other way around.
##
## Static typing mandatory in model/ (infrastruct ADR-004 discipline).

signal world_changed  # any edit; the debounced reset listens to this
signal plant_placed(pid: String, kind: String, p_max_mw: float)
signal corridor_placed(tile: Vector2i, kind: String)
signal substation_placed(tile: Vector2i)

const ENVELOPE_VERSION := 1

## Terrain is stored as the map document's ROWS (one String per row), not a
## per-tile Dictionary: at 5 km tiles the map holds ~772 000 tiles and a
## Vector2i-keyed Dictionary of that size costs tens of MB and seconds to
## build. Read it through terrain_at()/in_bounds() — never index directly.
var terrain_rows: PackedStringArray = PackedStringArray()
var width: int = 0
var height: int = 0
var tile_km: float = 50.0

## RENDER-ONLY relief sidecar (tools/map_authoring/relief.py): real per-tile
## elevation, vegetation density and a lake mask. Terrain CLASSES stay the
## gameplay truth — the relief only changes what the ground looks like, and
## a map without a sidecar (fixtures, europe_mini) renders on the class
## fallback. Row-major byte layers, read through the accessors below.
var has_relief := false
var _relief_elev: PackedByteArray = PackedByteArray()
var _relief_green: PackedByteArray = PackedByteArray()
var _relief_flags: PackedByteArray = PackedByteArray()
var _relief_urban: PackedByteArray = PackedByteArray()
var _relief_elev_step := 22.0
var _relief_elev_offset := -900.0
var _relief_lat0 := 71.0
var _relief_dlat := 0.044916

## resources: kind -> {Vector2i: params Dictionary} (coal_basin, salt_cavern,
## phs_site, wind_resource, river); solar bands kept separately
var resources: Dictionary = {}
var solar_bands: Array[Dictionary] = []

## load centers: id -> {name, peak_mw, season, temp_coeff, tiles: Array[Vector2i]}
var load_centers: Dictionary = {}
var _load_center_tiles: Dictionary = {}  # Vector2i -> load-center id

## corridors: Vector2i -> String line kind ("line_220" | "line_400")
var corridors: Dictionary = {}
## hvdc passing OVER an AC corridor tile (crossing spans): Vector2i -> true.
## The tile keeps its AC line in `corridors`; the DC web includes the tile.
var dc_overlay: Dictionary = {}
## RENDER-ONLY corner fillers of diagonal spans: Vector2i -> true. The tile
## is a normal corridor electrically (the topology walks the 4-connected
## staircase unchanged), but the renderer skips its mast and draws the
## conductors cutting the corner — that is what a diagonal line IS here.
var diag_fillers: Dictionary = {}
## explicit substations: Vector2i -> true
var substations: Dictionary = {}
## plants: pid -> {kind, tile: Vector2i, p_max_mw}
var plants: Dictionary = {}
var _plant_tiles: Dictionary = {}  # Vector2i -> pid
var _next_pid: int = 1

const SYNC_KINDS: Array[String] = ["nuclear", "coal", "lignite", "gas_ccgt",
	"gas_ocgt", "hydro_ps"]
const CONVERTER_KINDS: Array[String] = ["wind_onshore", "wind_offshore", "solar_pv"]
## SYNC_KINDS minus nuclear: what a dispatcher may actually move (nuclear is
## must-run identity, ledger 9). The topology builder's stub dispatch used to
## re-type this list inline.
const DISPATCHABLE_KINDS: Array[String] = ["coal", "lignite", "gas_ccgt",
	"gas_ocgt", "hydro_ps"]
## P7 wire devices: placed like plants but emitted on the reset `devices`
## channel, never in the native plants doc (contract v2 kinds table).
const DEVICE_KINDS: Array[String] = ["battery", "electrolyzer", "h2_cavern",
	"hvdc_converter", "offshore_platform"]

## Default unit sizes per kind (PARAMETERS §1; balancing constants)
const PLANT_SIZES := {
	"nuclear": 1600.0, "coal": 800.0, "lignite": 900.0,
	"gas_ccgt": 600.0, "gas_ocgt": 200.0, "hydro_ps": 300.0,
	"wind_onshore": 200.0, "wind_offshore": 500.0, "solar_pv": 150.0,
	"battery": 300.0, "electrolyzer": 300.0, "h2_cavern": 0.0,
	"hvdc_converter": 2000.0, "offshore_platform": 2000.0,
}
const BATTERY_HOURS := 2.0  # PARAMETERS §1.11 default duration
const CAVERN_CAPACITY_KG := 4_000_000.0  # §1.14 working gas
## Far-shore farms bind to a platform within 100 km (PARAMETERS §1.16
## collector rule). Expressed in KILOMETRES: as a tile count it silently
## became 10 km on the 5 km grid and no farm could reach a platform
## (ledger 38 — the same trap as the build radii).
const HUB_BIND_KM := 100.0


func load_map(doc: Dictionary) -> bool:
	terrain_rows = PackedStringArray()
	resources.clear()
	solar_bands.clear()
	load_centers.clear()
	_load_center_tiles.clear()
	has_relief = false  # a new map never inherits the old map's relief
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
		terrain_rows.push_back(row)
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


func in_bounds(tile: Vector2i) -> bool:
	return tile.x >= 0 and tile.y >= 0 and tile.x < width and tile.y < height


func terrain_at(tile: Vector2i) -> String:
	if not in_bounds(tile):
		return "S"  # off-map reads as open sea
	return terrain_rows[tile.y][tile.x]


## Attach the relief sidecar for the CURRENT map. Rejects a layer whose
## size disagrees with the loaded grid rather than rendering garbage.
func load_relief(doc: Dictionary) -> bool:
	var n := width * height
	if int(doc.get("width", 0)) != width or int(doc.get("height", 0)) != height:
		return false
	var elev := Marshalls.base64_to_raw(str(doc.get("elev_b64", "")))
	var green := Marshalls.base64_to_raw(str(doc.get("green_b64", "")))
	var flags := Marshalls.base64_to_raw(str(doc.get("flags_b64", "")))
	if elev.size() != n or green.size() != n or flags.size() != n:
		return false
	_relief_elev = elev
	_relief_green = green
	_relief_flags = flags
	# urban footprints arrived later than the first sidecars — optional
	var urban := Marshalls.base64_to_raw(str(doc.get("urban_b64", "")))
	_relief_urban = urban if urban.size() == n else PackedByteArray()
	_relief_elev_step = float(doc.get("elev_step_m", 22.0))
	_relief_elev_offset = float(doc.get("elev_offset_m", -900.0))
	_relief_lat0 = float(doc.get("lat0", 71.0))
	_relief_dlat = float(doc.get("deg_lat_per_tile", 0.044916))
	has_relief = true
	return true


## Real elevation in metres (off-map and relief-less read as open sea).
func elev_at(tile: Vector2i) -> float:
	if not has_relief or not in_bounds(tile):
		return -400.0
	return _relief_elev[tile.y * width + tile.x] * _relief_elev_step \
		+ _relief_elev_offset


## Vegetation density 0..1 — drives forest tint and tree scatter.
func green_at(tile: Vector2i) -> float:
	if not has_relief or not in_bounds(tile):
		return 0.0
	return _relief_green[tile.y * width + tile.x] / 255.0


## Urban footprint density 0..1 (NE urban areas) — drives the city sprawl
## scatter, the concrete terrain tint and the night lights.
func urban_at(tile: Vector2i) -> float:
	if _relief_urban.is_empty() or not in_bounds(tile):
		return 0.0
	return _relief_urban[tile.y * width + tile.x] / 255.0


## Tiles whose urban density exceeds `min_frac` (night lights, sprawl);
## empty when the sidecar carries no urban layer.
func urban_tiles(min_frac: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _relief_urban.is_empty():
		return out
	var threshold := int(min_frac * 255.0)
	for i in _relief_urban.size():
		if _relief_urban[i] > threshold:
			out.append(Vector2i(i % width, i / width))
	return out


func lake_at(tile: Vector2i) -> bool:
	if not has_relief or not in_bounds(tile):
		return false
	return (_relief_flags[tile.y * width + tile.x] & 1) != 0


## Latitude of a row's tile centres — snow and rock lines fall with it.
func lat_of_row(y: int) -> float:
	return _relief_lat0 - (float(y) + 0.5) * _relief_dlat


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
	# corridors block plant sites too: a plant dropped ON a corridor tile
	# blocks routing through it and orphaned whole demo cities (frankfurt's
	# single tap exit buried under a nuclear unit — found by buildcheck)
	if _plant_tiles.has(tile) or _load_center_tiles.has(tile) \
			or corridors.has(tile):
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
			# near-shore AC on the shelf; far-shore DEEP sea only within the
			# collector ring of an offshore platform (§1.16 binding rule)
			return t == "s" or (t == "S" and platform_near(tile) != "")
		"solar_pv":
			return t in ["p", "h"]
		"hydro_ps":
			return has_resource("phs_site", tile)
		"battery", "electrolyzer", "hvdc_converter":
			return is_land(tile)
		"h2_cavern":
			return has_resource("salt_cavern", tile)
		"offshore_platform":
			return t in ["s", "S"]
	return false


## THE km→tiles conversion (ledger 38: every radius is a DISTANCE — a tile
## count in a rule is a bug; write kilometres, convert at this one edge).
func tiles_for_km(km: float) -> int:
	return maxi(1, int(round(km / maxf(tile_km, 1.0))))


## Nearest offshore platform pid within the collector ring, "" if none.
func hub_bind_tiles() -> int:
	return tiles_for_km(HUB_BIND_KM)


func platform_near(tile: Vector2i) -> String:
	var best := ""
	var reach := hub_bind_tiles()
	var best_d := reach + 1
	for pid: String in plants:
		if str(plants[pid]["kind"]) != "offshore_platform":
			continue
		var d: Vector2i = (plants[pid]["tile"] as Vector2i) - tile
		var cheb := maxi(absi(d.x), absi(d.y))
		if cheb <= reach and cheb < best_d:
			best_d = cheb
			best = pid
	return best


func can_place_corridor(tile: Vector2i, kind: String = "line_400") -> bool:
	# AC corridors: land or shelf sea (submarine). HVDC corridors may also
	# cross DEEP sea (the far-shore export path). Never across an occupied
	# site tile.
	var allowed: bool = terrain_at(tile) in ["c", "p", "h", "m", "s"] \
		or (kind == "hvdc" and terrain_at(tile) == "S")
	return allowed \
		and not _plant_tiles.has(tile) and not _load_center_tiles.has(tile)


func place_plant(kind: String, tile: Vector2i) -> String:
	if not can_place_plant(kind, tile):
		return ""
	var pid := "%s_%d" % [kind, _next_pid]
	_next_pid += 1
	var entry := {"kind": kind, "tile": tile,
		"p_max_mw": float(PLANT_SIZES[kind])}
	match kind:
		"battery":
			entry["e_mwh"] = float(PLANT_SIZES[kind]) * BATTERY_HOURS
		"h2_cavern":
			entry["capacity_kg"] = CAVERN_CAPACITY_KG
	plants[pid] = entry
	_plant_tiles[tile] = pid
	plant_placed.emit(pid, kind, float(PLANT_SIZES[kind]))
	world_changed.emit()
	return pid


## Fuel-switch a gas plant to H2 firing from a named cavern (GAME_DESIGN
## §1.4 conversion; the engine gates it per PHYSICS §2.8).
func convert_to_h2(pid: String, cavern_pid: String) -> bool:
	if not plants.has(pid) or not plants.has(cavern_pid):
		return false
	if not str(plants[pid]["kind"]).begins_with("gas_"):
		return false
	if str(plants[cavern_pid]["kind"]) != "h2_cavern":
		return false
	plants[pid]["fuel"] = "h2"
	plants[pid]["h2_store_id"] = cavern_pid
	world_changed.emit()
	return true


func remove_plant(pid: String) -> void:
	if plants.has(pid):
		_plant_tiles.erase(plants[pid]["tile"])
		plants.erase(pid)
		world_changed.emit()


func place_corridor(tile: Vector2i, kind: String = "line_400") -> bool:
	if not can_place_corridor(tile, kind):
		return false
	if corridors.get(tile, "") == kind:
		return true
	if corridors.has(tile):
		# an hvdc line may CROSS an AC corridor: the tile keeps its AC line,
		# the DC line passes over (dc_overlay) and the two stay electrically
		# separate — a real crossing span. Any other collision is refused:
		# silently overwriting the kind used to cut the standing line's web.
		if kind == "hvdc" and str(corridors[tile]) != "hvdc":
			dc_overlay[tile] = true
			corridor_placed.emit(tile, kind)
			world_changed.emit()
			return true
		return false
	corridors[tile] = kind
	corridor_placed.emit(tile, kind)
	world_changed.emit()
	return true


func remove_corridor(tile: Vector2i) -> void:
	diag_fillers.erase(tile)
	var removed := dc_overlay.erase(tile)
	if corridors.erase(tile) or removed:
		world_changed.emit()


func place_substation(tile: Vector2i) -> bool:
	if not is_land(tile):
		return false
	substations[tile] = true
	substation_placed.emit(tile)
	world_changed.emit()
	return true


func clear_build() -> void:
	corridors.clear()
	dc_overlay.clear()
	diag_fillers.clear()
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
	var overlay_list := []
	for tile: Vector2i in dc_overlay:
		overlay_list.append([tile.x, tile.y])
	var filler_list := []
	for tile: Vector2i in diag_fillers:
		filler_list.append([tile.x, tile.y])
	var substation_list: Array = []
	for tile: Vector2i in substations:
		substation_list.append([tile.x, tile.y])
	var plant_list: Array = []
	for pid: String in plants:
		var p: Dictionary = plants[pid]
		var row := {"pid": pid, "kind": p["kind"],
			"tile": [(p["tile"] as Vector2i).x, (p["tile"] as Vector2i).y],
			"p_max_mw": p["p_max_mw"]}
		for extra: String in ["e_mwh", "capacity_kg", "fuel", "h2_store_id"]:
			if p.has(extra):
				row[extra] = p[extra]
		plant_list.append(row)
	return {"version": ENVELOPE_VERSION, "corridors": corridor_list,
		"dc_overlay": overlay_list, "diag_fillers": filler_list,
		"substations": substation_list, "plants": plant_list,
		"next_pid": _next_pid}


func restore(envelope: Dictionary) -> bool:
	if int(envelope.get("version", -1)) != ENVELOPE_VERSION:
		return false
	clear_build()
	for entry: Array in envelope.get("corridors", []):
		corridors[Vector2i(int(entry[0]), int(entry[1]))] = str(entry[2])
	for entry: Array in envelope.get("dc_overlay", []):
		dc_overlay[Vector2i(int(entry[0]), int(entry[1]))] = true
	for entry: Array in envelope.get("diag_fillers", []):
		diag_fillers[Vector2i(int(entry[0]), int(entry[1]))] = true
	for entry: Array in envelope.get("substations", []):
		substations[Vector2i(int(entry[0]), int(entry[1]))] = true
	for p: Dictionary in envelope.get("plants", []):
		var tile := Vector2i(int(p["tile"][0]), int(p["tile"][1]))
		var entry := {"kind": str(p["kind"]), "tile": tile,
			"p_max_mw": float(p["p_max_mw"])}
		for extra: String in ["e_mwh", "capacity_kg", "fuel", "h2_store_id"]:
			if p.has(extra):
				entry[extra] = p[extra]
		plants[str(p["pid"])] = entry
		_plant_tiles[tile] = str(p["pid"])
	_next_pid = int(envelope.get("next_pid", 1))
	world_changed.emit()
	return true
