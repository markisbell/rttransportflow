class_name GridPlan
extends RefCounted
## Authors a realistic (aggregated) 380 kV grid from a curated seed: real
## named substations at their real locations, the backbone corridors
## between them, the neighbour interconnectors, and the DC projects as
## hvdc corridors with converter stations at both ends.
##
## Two seeds ship: germany_380kv_seed.json (the standalone probe) and
## europe_380kv_seed.json (the Germany core plus lean spines to every
## CONTINENTAL_CORE metro) — author_start() builds the campaign's
## inherited world from the latter: grid, metro feeds, then the adequacy
## plant ladder anchored at each metro's real feeding substations.
##
## Routing honours the tile model's one-corridor-per-tile rule, which makes
## true line CROSSINGS impossible — so AC lines are laid first (the mesh),
## and DC lines are routed last, threading the gaps the BFS finds beside
## pinch-point substations. Every route search is bounded to the line's
## own bounding box (+ margin): an unbounded failing BFS floods all 772k
## tiles, the P6 freeze lesson.

const GERMANY_SEED := "data/grids/germany_380kv_seed.json"
const EUROPE_SEED := "data/grids/europe_380kv_seed.json"
const BOX_MARGIN_KM := 150.0  # route search box beyond the endpoints
## Corridors must not BRUSH a metro outside the plan: touching a foreign
## footprint connects its load with no fleet behind it (the P5 47.4 Hz
## lesson). Halo tiles are set for one author run and consulted by the
## router; core metros stay touchable — that is how they tap the grid.
static var _halo := {}


static func author(world: Node, projection: Dictionary,
		seed_path: String = GERMANY_SEED) -> Dictionary:
	var seed_doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		AppPaths.root() + "/" + seed_path))
	if not (seed_doc is Dictionary):
		return {"ok": false, "error": "seed missing/unparsable"}
	var lon0 := float(projection.get("lon0", -20.0))
	var lat0 := float(projection.get("lat0", 71.0))
	var dlon := float(projection.get("deg_lon_per_tile", 0.072955))
	var dlat := float(projection.get("deg_lat_per_tile", 0.044916))

	var tiles := {}  # substation name -> Vector2i
	var subs: Dictionary = seed_doc["substations"]
	for name: String in subs:
		var s: Dictionary = subs[name]
		var raw := Vector2i(int((float(s["lon"]) - lon0) / dlon),
			int((lat0 - float(s["lat"])) / dlat))
		var tile := _nearest_land(world, raw)
		if tile == Vector2i(-1, -1):
			return {"ok": false, "error": "no land near " + name}
		# an AC gateway is a corridor STUB: the line draws to the border but
		# a dead-end forms no bus — a leaf substation there bought nothing
		# electrically and cost a node-budget slot each
		if not bool(s.get("gateway", false)):
			world.place_substation(tile)
		tiles[name] = tile

	# a few real stations anchor the AC island for the topology pass
	for p: Array in seed_doc.get("plants", []):
		var site := _nearest_placeable(world, str(p[1]), Vector2i(
			int((float(p[3]) - lon0) / dlon), int((lat0 - float(p[2])) / dlat)))
		if site != Vector2i(-1, -1):
			world.place_plant(str(p[1]), site)

	var failed: Array[String] = []
	var laid_ac := 0
	for line: Array in seed_doc["ac_lines"]:
		if _lay(world, tiles[line[0]], tiles[line[1]], "line_400",
				int(line[2]) if line.size() > 2 else 0):
			laid_ac += 1
		else:
			failed.append("%s-%s" % [line[0], line[1]])
	var laid_dc := 0
	for link: Array in seed_doc["dc_links"]:
		if _lay_dc(world, tiles[link[1]], tiles[link[2]]):
			laid_dc += 1
		else:
			failed.append(str(link[0]))
	return {"ok": failed.is_empty(), "substations": tiles.size(),
		"ac_laid": laid_ac, "dc_laid": laid_dc, "failed": failed,
		"corridor_tiles": world.corridors.size()}


## Route + place one AC line. Endpoint substation tiles are shareable on
## purpose: several lines terminating on one station tile merge there,
## which IS the switching station.
static func _lay(world: Node, from_tile: Vector2i, to_tile: Vector2i,
		kind: String, circuits: int = 0) -> bool:
	var path := _route_astar(world, from_tile, to_tile, kind)
	if path.is_empty():
		return false
	var previous := path[0]
	world.place_corridor(previous, kind)
	if circuits > 0:
		for tile: Vector2i in path:
			world.corridor_circuits[tile] = maxi(
				int(world.corridor_circuits.get(tile, 0)), circuits)
	for i in range(1, path.size()):
		var tile := path[i]
		var step := tile - previous
		if step.x != 0 and step.y != 0:
			# diagonal step: the corner FILLER keeps the web 4-connected
			# (the topology walks the staircase unchanged); flagged so the
			# renderer draws the span cutting across it
			var corner := previous + Vector2i(step.x, 0)
			var alt := previous + Vector2i(0, step.y)
			if not _corner_ok(world, corner, kind):
				corner = alt
			var pre_existing: bool = world.corridors.has(corner)
			world.place_corridor(corner, kind)
			if not pre_existing \
					and str(world.corridors.get(corner, "")) == kind:
				world.diag_fillers[corner] = true
		world.place_corridor(tile, kind)
		previous = tile
	return true


static func _corner_ok(world: Node, corner: Vector2i, kind: String) -> bool:
	if not world.can_place_corridor(corner, kind):
		return false
	if not world.corridors.has(corner):
		return true
	# an existing same-kind tile serves as the corner; hvdc may overlay AC
	return str(world.corridors[corner]) == kind \
		or (kind == "hvdc" and not world.dc_overlay.has(corner))


## Route directions: 4 straight (cost 10) then 4 diagonal (cost 14 — the
## octile ratio). Order is part of determinism.
const ROUTE_DIRS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1)]


static func _octile(a: Vector2i, b: Vector2i) -> int:
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return 10 * maxi(dx, dy) + 4 * mini(dx, dy)


## Deterministic A* (octile heuristic, integer-bucket open list, LIFO
## within a bucket — a fixed rule, so the same seed always lays the same
## grid). NOT the shared DemoBuild.route: plain BFS explores an area
## quadratic in path length and 84 continental routes took minutes; A*
## walks a narrow corridor along the straight line instead. The shared
## BFS keeps its expansion order — existing builds pin their paths on it.
## Diagonal steps need a placeable corner tile (the filler _lay adds).
static func _route_astar(world: Node, from_tile: Vector2i, to_tile: Vector2i,
		kind: String) -> Array[Vector2i]:
	var margin: int = world.tiles_for_km(BOX_MARGIN_KM)
	var bx0 := mini(from_tile.x, to_tile.x) - margin
	var bx1 := maxi(from_tile.x, to_tile.x) + margin
	var by0 := mini(from_tile.y, to_tile.y) - margin
	var by1 := maxi(from_tile.y, to_tile.y) + margin
	var g := {from_tile: 0}
	var came := {from_tile: from_tile}
	var open := {}  # f-score -> Array[Vector2i]
	var f0 := _octile(from_tile, to_tile)
	open[f0] = [from_tile] as Array[Vector2i]
	var f := f0
	var f_max := f0
	while f <= f_max:
		var bucket: Array[Vector2i] = open.get(f, [] as Array[Vector2i])
		if bucket.is_empty():
			f += 1
			continue
		var current: Vector2i = bucket.pop_back()
		if current == to_tile:
			var path: Array[Vector2i] = []
			while current != came[current]:
				path.append(current)
				current = came[current]
			path.append(from_tile)
			path.reverse()
			return path
		for offset: Vector2i in ROUTE_DIRS:
			var n := current + offset
			if g.has(n):
				continue
			if n != to_tile and not _passable(world, n, to_tile, from_tile,
					kind, bx0, bx1, by0, by1):
				continue
			var diagonal := offset.x != 0 and offset.y != 0
			if diagonal and not (
					_corner_ok(world, current + Vector2i(offset.x, 0), kind)
					or _corner_ok(world, current + Vector2i(0, offset.y), kind)):
				continue
			# a crossing span costs extra, so DC routes cross AC lines
			# perpendicular instead of riding along them as endless overlay
			var step := 14 if diagonal else 10
			if world.corridors.has(n) and str(world.corridors.get(n, "")) != kind:
				step += 30
			g[n] = int(g[current]) + step
			came[n] = current
			var fn: int = g[n] + _octile(n, to_tile)
			if not open.has(fn):
				open[fn] = [] as Array[Vector2i]
			open[fn].append(n)
			f_max = maxi(f_max, fn)
	return []


## A DC link: converter stations beside both endpoints, hvdc corridor
## between the converters' free flanks (P7 topology: converter pair +
## continuous hvdc web = link).
static func _lay_dc(world: Node, from_tile: Vector2i, to_tile: Vector2i) -> bool:
	var conv_a := _nearest_placeable(world, "hvdc_converter", from_tile)
	var conv_b := _nearest_placeable(world, "hvdc_converter", to_tile)
	if conv_a == Vector2i(-1, -1) or conv_b == Vector2i(-1, -1):
		return false
	var tap_a := _free_flank(world, conv_a)
	var tap_b := _free_flank(world, conv_b)
	if tap_a == Vector2i(-1, -1) or tap_b == Vector2i(-1, -1):
		return false
	world.place_plant("hvdc_converter", conv_a)
	world.place_plant("hvdc_converter", conv_b)
	if not _lay(world, tap_a, tap_b, "hvdc"):
		return false
	return true


## A tile the route may occupy. An existing SAME-KIND corridor is passable
## near either endpoint: a substation tile has four sides but a real
## station hosts six lines, so approaches must merge into shared
## rights-of-way at the hub (which is what real bundled Trassen do).
## Far from the endpoints existing corridors stay walls — a "new" line
## must not ride another line across the country.
const HUB_MERGE_TILES := 5


static func _passable(world: Node, n: Vector2i, to_tile: Vector2i,
		from_tile: Vector2i, kind: String,
		bx0: int, bx1: int, by0: int, by1: int) -> bool:
	if n.x < bx0 or n.x > bx1 or n.y < by0 or n.y > by1:
		return false
	if _halo.has(n):
		return false
	if not world.can_place_corridor(n, kind):
		return false
	if not world.corridors.has(n):
		return true
	if str(world.corridors[n]) != kind:
		# an hvdc route may CROSS an AC corridor (dc_overlay), but never
		# ride a tile that already carries a crossing
		return kind == "hvdc" and not world.dc_overlay.has(n)
	var near_hub := maxi(absi(n.x - to_tile.x), absi(n.y - to_tile.y)) \
		<= HUB_MERGE_TILES \
		or maxi(absi(n.x - from_tile.x), absi(n.y - from_tile.y)) \
		<= HUB_MERGE_TILES
	return near_hub


static func _nearest_land(world: Node, anchor: Vector2i) -> Vector2i:
	for r in range(0, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tile := anchor + Vector2i(dx, dy)
				if world.in_bounds(tile) and world.is_land(tile) \
						and not world.corridors.has(tile) \
						and not world.substations.has(tile) \
						and world.load_center_at(tile) == "":
					return tile
	return Vector2i(-1, -1)


static func _nearest_placeable(world: Node, kind: String,
		anchor: Vector2i) -> Vector2i:
	return DemoBuild.find_site(world, kind, anchor, 6)


## First 4-neighbour of a (future) converter site a corridor may start on.
static func _free_flank(world: Node, site: Vector2i) -> Vector2i:
	for offset: Vector2i in GridTopology.NEIGHBORS:
		var n := site + offset
		if world.can_place_corridor(n, "hvdc") and not world.corridors.has(n):
			return n
	return Vector2i(-1, -1)


# ─── the campaign start world (inherited 2025) ────────────────────────

## Ladder rungs copied from the demo author's measured tuning: ~45 %
## nuclear base, coal to ~70 %, gas for the evening top, OCGT closer.
static func _ladder_kinds(remaining: float, placed: float,
		need: float) -> Array[String]:
	if remaining > 1200.0 and placed < need * 0.45:
		return ["nuclear", "coal", "gas_ccgt"]
	if remaining > 700.0 and placed < need * 0.7:
		return ["coal", "gas_ccgt"]
	if remaining > 300.0:
		return ["gas_ccgt", "gas_ocgt"]
	return ["gas_ocgt"]


## Build the campaign's inherited world on the European plan: the seed
## grid, every CONTINENTAL_CORE metro fed from its real substations, then
## the adequacy plant ladder (LIVE_PEAK_MARGIN over each metro's peak)
## anchored at those substations. Deterministic throughout.
static func author_start(world: Node) -> bool:
	# metros outside the plan must never be brushed by a route (their load
	# would ride along with no fleet behind it)
	_halo = {}
	var core := {}
	for lc_id: String in Campaign.CONTINENTAL_CORE:
		core[lc_id] = true
	for lc_id: String in world.load_centers:
		if core.has(lc_id):
			continue
		for tile: Vector2i in world.load_centers[lc_id]["tiles"]:
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					_halo[tile + Vector2i(dx, dy)] = true

	var stats := author(world, BuildSession.map_projection(), EUROPE_SEED)
	if not bool(stats.get("ok", false)):
		push_warning("GridPlan.author_start: seed grid incomplete: "
			+ JSON.stringify(stats.get("failed", [])))
	var seed_doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		AppPaths.root() + "/" + EUROPE_SEED))
	var sub_tiles := {}
	for name: String in seed_doc["substations"]:
		var sd: Dictionary = seed_doc["substations"][name]
		var raw := Vector2i(
			int((float(sd["lon"]) - float(BuildSession.map_projection()["lon0"]))
				/ float(BuildSession.map_projection()["deg_lon_per_tile"])),
			int((float(BuildSession.map_projection()["lat0"]) - float(sd["lat"]))
				/ float(BuildSession.map_projection()["deg_lat_per_tile"])))
		# the substation was placed at/near raw during author(); find it
		sub_tiles[name] = _nearest_substation(world, raw)

	var feeds: Dictionary = seed_doc.get("metro_feeds", {})
	var ok := true
	for lc_id: String in Campaign.CONTINENTAL_CORE:
		if not world.load_centers.has(lc_id) or not feeds.has(lc_id):
			continue
		var lc: Dictionary = world.load_centers[lc_id]
		var feed_names: Array = feeds[lc_id]
		var taps: Array = DemoBuild.taps_around(world, lc["tiles"], _halo)
		if taps.is_empty():
			push_warning("GridPlan: no tap around " + lc_id)
			ok = false
			continue
		# one corridor from every feeding substation into the metro
		for i in feed_names.size():
			var sub_tile: Vector2i = sub_tiles.get(str(feed_names[i]),
				Vector2i(-1, -1))
			if sub_tile == Vector2i(-1, -1):
				continue
			var tap: Vector2i = taps[i % taps.size()]
			world.place_corridor(tap, "line_400")
			if not _lay(world, sub_tile, tap, "line_400", 12):
				push_warning("GridPlan: feed %s -> %s unroutable"
					% [feed_names[i], lc_id])
				ok = false
		# the adequacy ladder, anchored at the metro's feeding substations
		var need: float = lc["peak_mw"] * GridTopology.LIVE_PEAK_MARGIN
		var placed := 0.0
		var count := 0
		var banned := _halo.duplicate()
		# The ladder anchors at the METRO, not at a distant substation: a
		# metro's fleet must sit around it (the old world's proven regime,
		# and the real one — big plants ring real metros), or its entire
		# supply squeezes through the one or two feed corridors and trips
		# them instantly (Paris: ~20 GW through two lines, measured 286 %).
		# The feeds then carry only inter-metro exchange. Ring placement
		# also packs the parks so their taps collapse into few buses.
		var anchor: Vector2i = lc["tiles"][0]
		while placed < need:
			var site := Vector2i(-1, -1)
			var kind := ""
			for candidate: String in _ladder_kinds(need - placed, placed, need):
				site = DemoBuild.find_site(world, candidate, anchor,
					world.tiles_for_km(150.0), banned)
				if site == Vector2i(-1, -1):
					site = DemoBuild.find_site(world, candidate, anchor,
						world.tiles_for_km(400.0), banned)
				if site != Vector2i(-1, -1):
					kind = candidate
					break
			if site == Vector2i(-1, -1):
				push_warning("GridPlan: ladder exhausted for " + lc_id)
				ok = false
				break
			var pid: String = world.place_plant(kind, site)
			var plant_tap: Vector2i = DemoBuild.tap_for(world, [site], _halo)
			var spur: Array[Vector2i] = []
			if plant_tap != Vector2i(-1, -1):
				spur = _spur(world, plant_tap, taps[count % taps.size()])
			if spur.is_empty():
				world.remove_plant(pid)
				banned[site] = true
				continue
			for tile: Vector2i in spur:
				world.place_corridor(tile, "line_400")
			placed += float(world.PLANT_SIZES[kind])
			count += 1
	_halo = {}
	return ok


## Short plant spur into the web: bounded BFS that stops on the FIRST
## existing corridor tile (spurs merge into trunks, never lay parallels).
static func _spur(world: Node, from_tile: Vector2i,
		toward: Vector2i) -> Array[Vector2i]:
	var margin: int = world.tiles_for_km(60.0)
	var bx0 := mini(from_tile.x, toward.x) - margin
	var bx1 := maxi(from_tile.x, toward.x) + margin
	var by0 := mini(from_tile.y, toward.y) - margin
	var by1 := maxi(from_tile.y, toward.y) + margin
	var passable := func(n: Vector2i) -> bool:
		return n.x >= bx0 and n.x <= bx1 and n.y >= by0 and n.y <= by1 \
			and not _halo.has(n) \
			and str(world.corridors.get(n, "line_400")) == "line_400" \
			and world.can_place_corridor(n, "line_400")
	return DemoBuild.route(world, from_tile, toward, true, {}, passable,
		["line_400"])


static func _nearest_substation(world: Node, anchor: Vector2i) -> Vector2i:
	for r in range(0, 10):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tile := anchor + Vector2i(dx, dy)
				if world.substations.has(tile):
					return tile
	return Vector2i(-1, -1)
