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
const PLANTS_SEED := "data/grids/europe_plants_seed.json"
## Stations below this stay synthetic: every real site costs a tap bus,
## and the 150-bus budget affords roughly fifty distinct stations — the
## gigawatt class gets its real ground, the packed parks carry the rest
## (measured: real-siting the full >=500 MW fleet put 244 buses on the
## ledger).
const REAL_SITE_MIN_MW := 1000.0
## ...and at most this many real stations per metro: the budget affords
## ~35 real stations continent-wide — each metro gets its biggest.
const REAL_SITES_PER_METRO := 2
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
		if _lay_dc(world, tiles[link[1]], tiles[link[2]],
				str(link[0]).capitalize(),
				str(link[1]).capitalize(), str(link[2]).capitalize()):
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
static func _lay_dc(world: Node, from_tile: Vector2i, to_tile: Vector2i,
		link_name := "", from_name := "", to_name := "") -> bool:
	var conv_a := _nearest_placeable(world, "hvdc_converter", from_tile)
	var conv_b := _nearest_placeable(world, "hvdc_converter", to_tile)
	if conv_a == Vector2i(-1, -1) or conv_b == Vector2i(-1, -1):
		return false
	var tap_a := _free_flank(world, conv_a)
	var tap_b := _free_flank(world, conv_b)
	if tap_a == Vector2i(-1, -1) or tap_b == Vector2i(-1, -1):
		return false
	var pid_a: String = world.place_plant("hvdc_converter", conv_a)
	var pid_b: String = world.place_plant("hvdc_converter", conv_b)
	if link_name != "":  # real DC-project names from the seed
		world.plants[pid_a]["name"] = "%s · %s" % [link_name, from_name]
		world.plants[pid_b]["name"] = "%s · %s" % [link_name, to_name]
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
	var real_fleet := _real_fleet(world)
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
			var tap2: Vector2i = taps[i % taps.size()]
			world.place_corridor(tap2, "line_400")
			if not _lay(world, sub_tile, tap2, "line_400", 12):
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
		# REAL plants first (GPPD, ledger 47), biggest-first until the need
		# is met — the synthetic ladder only tops up what reality leaves
		var real_used := 0
		var unit_n := {}  # per-metro synthetic numbering, per kind
		for plant: Dictionary in real_fleet.get(lc_id, []):
			if placed >= need or real_used >= REAL_SITES_PER_METRO:
				break
			if float(plant["capacity_mw"]) < REAL_SITE_MIN_MW:
				continue
			var rkind := str(plant["kind"])
			var station_mw := 0.0
			var station_tap := Vector2i(-1, -1)
			var size: float = world.PLANT_SIZES[rkind]
			var units := clampi(int(round(float(plant["capacity_mw"]) / size)), 1, 3)
			var snap: Vector2i = plant["tile"]
			var snap_r := 20 if rkind == "lignite" else 8
			for u in units:
				# a web-adjacent tile near the real site needs NO spur (and
				# no tap bus of its own); only stations away from any line
				# pay for a spur
				var site := _site_on_web(world, snap, rkind, banned, snap_r)
				var needs_spur := site == Vector2i(-1, -1)
				if needs_spur:
					site = DemoBuild.find_site(world, rkind, snap, snap_r, banned)
				if site == Vector2i(-1, -1):
					break
				var pid: String = world.place_plant(rkind, site)
				world.plants[pid]["name"] = str(plant["name"]) if units == 1 \
					else "%s %d" % [str(plant["name"]), u + 1]
				if needs_spur:
					var ptap: Vector2i = DemoBuild.tap_for(world, [site], _halo)
					var spur: Array[Vector2i] = []
					if ptap != Vector2i(-1, -1):
						spur = _spur(world, ptap, taps[count % taps.size()])
					if spur.is_empty():
						world.remove_plant(pid)
						banned[site] = true
						continue
					for tile: Vector2i in spur:
						world.place_corridor(tile, "line_400")
				placed += size
				count += 1
				real_used += 1 if u == 0 else 0
				station_mw += size
				if station_tap == Vector2i(-1, -1):
					for offset: Vector2i in GridTopology.NEIGHBORS:
						if str(world.corridors.get(site + offset, "")) == "line_400":
							station_tap = site + offset
							break
				snap = site  # a station's units stand together
			if station_tap != Vector2i(-1, -1) and station_mw > 0.0:
				# the zone balances in ENERGY, not geography: a gigawatt
				# station 100-300 km from its metro transits the feed
				# corridors at full output from the first startup profile
				# on — its evacuation path must be sized for it (L107/L73
				# duty-tripped at ~122 % and islanded an 8-unit pocket)
				_author_evacuation(world, station_tap, taps[0], station_mw)
		while placed < need:
			# synthetic units stand ADJACENT TO THE WEB — no spur: a spur
			# per unit fragmented the parks into dozens of lone tap buses;
			# a unit strung along an existing corridor collapses into the
			# same site-bus group as its neighbours (and plants along the
			# lines is what the real countryside looks like)
			var site := Vector2i(-1, -1)
			var kind := ""
			for candidate: String in _ladder_kinds(need - placed, placed, need):
				site = _site_on_web(world, anchor, candidate, banned,
					world.tiles_for_km(220.0))
				if site != Vector2i(-1, -1):
					kind = candidate
					break
			if site == Vector2i(-1, -1):
				push_warning("GridPlan: ladder exhausted for " + lc_id)
				ok = false
				break
			var spid: String = world.place_plant(kind, site)
			# synthetic units get a readable name: metro + kind + number
			unit_n[kind] = int(unit_n.get(kind, 0)) + 1
			world.plants[spid]["name"] = "%s %s %d" % [str(lc["name"]),
				str(world.KIND_LABELS.get(kind, kind)), unit_n[kind]]
			placed += float(world.PLANT_SIZES[kind])
			count += 1
	# the collector web inside and between the plant parks is built HEAVY:
	# every short segment there carries the accumulated output of the
	# string of stations behind it, and the morning ramp runs ~1.5x the
	# startup point (measured: 84 % at startup, 121 % at the ramp, duty
	# trip, pocket blackout)
	for pid: String in world.plants:
		var pt: Vector2i = world.plants[pid]["tile"]
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var t := pt + Vector2i(dx, dy)
				if str(world.corridors.get(t, "")) == "line_400":
					world.corridor_circuits[t] = 12
	_phs_pass(world, real_fleet.get("_phs", []), sub_tiles, feeds)
	_city_cable_pass(world)
	var hub_used := _hub_pass(world, real_fleet.get("_offshore", []),
		sub_tiles)
	var ac_candidates: Array = []
	for p: Dictionary in real_fleet.get("_offshore", []):
		if not hub_used.has(str(p["name"])):
			ac_candidates.append(p)
	_offshore_pass(world, ac_candidates)
	_halo = {}
	return ok


## From the 400 kV ring into the city, the feed's LAST stretch runs as
## underground cable — overhead ends at the nearest substation or
## junction outside the metro (the real transition-station pattern).
## The walk stops exactly ON a tile that already forms a bus, so the
## line|cable kind change never costs a node-budget slot.
static func _city_cable_pass(world: Node) -> void:
	for lc_id: String in Campaign.CONTINENTAL_CORE:
		if not world.load_centers.has(lc_id):
			continue
		for lc_tile: Vector2i in world.load_centers[lc_id]["tiles"]:
			for offset: Vector2i in GridTopology.NEIGHBORS:
				var entry: Vector2i = lc_tile + offset
				if str(world.corridors.get(entry, "")) == "line_400":
					_cable_entry(world, entry)


## Only SHORT urban approaches are cabled (real practice: a handful of
## km of 400 kV cable into the city, never the whole feed) — 56 km of
## 12-circuit cable injects ~7 GVAr of charging, and twenty such feeds
## diverged the PF outright and blacked the world out at boot (found
## live). Longer feeds keep their overhead line.
const CITY_CABLE_MAX_TILES := 4  # <= 20 km underground approach


static func _cable_entry(world: Node, entry: Vector2i) -> void:
	var path: Array[Vector2i] = []
	var prev := Vector2i(-99999, -99999)
	var current := entry
	for _i in CITY_CABLE_MAX_TILES + 1:
		if world.substations.has(current) or world.diag_fillers.has(current):
			break  # substation = the transition bus; fillers stay overhead
		var degree := 0
		var next := Vector2i(-99999, -99999)
		for o: Vector2i in GridTopology.NEIGHBORS:
			var n := current + o
			if world.corridors.has(n):
				degree += 1
				if n != prev:
					next = n
		if current != entry and degree > 2:
			break  # junction: already a bus, overhead continues from here
		path.append(current)
		if next.x < -90000 or str(world.corridors.get(next, "")) != "line_400":
			break
		prev = current
		current = next
	if path.size() > CITY_CABLE_MAX_TILES:
		return  # a long feed stays overhead — cable is the exception
	# walk must have ENDED on a bus-forming tile (substation or junction);
	# a dead-end break converts a stub whose far end is mid-corridor and
	# would buy a kind-change bus for nothing
	if not (world.substations.has(current) or world.diag_fillers.has(current)):
		var degree := 0
		for o: Vector2i in GridTopology.NEIGHBORS:
			if world.corridors.has(current + o):
				degree += 1
		if degree <= 2:
			return
	for tile: Vector2i in path:
		var circuits: int = world.corridor_circuits.get(tile, 0)
		world.remove_corridor(tile)
		world.place_corridor(tile, "cable_400")
		if circuits > 0:
			# one 400 kV cable circuit carries ~2x an overhead circuit
			# (1.8 kA vs 0.85): half the circuits move the same power and
			# HALVE the charging injection
			world.corridor_circuits[tile] = maxi(2, circuits / 2)


## Short plant spur into the web: bounded BFS that stops on the FIRST
## existing corridor tile (spurs merge into trunks, never lay parallels).
static func _spur(world: Node, from_tile: Vector2i,
		toward: Vector2i, kind := "line_400") -> Array[Vector2i]:
	var margin: int = world.tiles_for_km(60.0)
	var bx0 := mini(from_tile.x, toward.x) - margin
	var bx1 := maxi(from_tile.x, toward.x) + margin
	var by0 := mini(from_tile.y, toward.y) - margin
	var by1 := maxi(from_tile.y, toward.y) + margin
	var passable := func(n: Vector2i) -> bool:
		var k := str(world.corridors.get(n, ""))
		return n.x >= bx0 and n.x <= bx1 and n.y >= by0 and n.y <= by1 \
			and not _halo.has(n) \
			and (k == kind or k == "line_400" \
				or (k == "" and world.can_place_corridor(n, kind)))
	return DemoBuild.route(world, from_tile, toward, true, {}, passable,
		["line_400", kind])


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


## The GPPD real fleet, deduped and assigned: metro id -> plants sorted
## biggest-first, plus "_phs" and "_offshore" lists. Dedup keys on the
## normalized name AND 3-tile proximity (GPPD carries duplicate rows).
static func _real_fleet(world: Node) -> Dictionary:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		AppPaths.root() + "/" + PLANTS_SEED))
	if not (doc is Dictionary):
		return {}
	var projection: Dictionary = BuildSession.map_projection()
	var lon0 := float(projection["lon0"])
	var lat0 := float(projection["lat0"])
	var dlon := float(projection["deg_lon_per_tile"])
	var dlat := float(projection["deg_lat_per_tile"])
	var centers := {}
	for lc_id: String in Campaign.CONTINENTAL_CORE:
		if world.load_centers.has(lc_id):
			centers[lc_id] = world.load_centers[lc_id]["tiles"][0]
	var seen := {}
	var out := {"_phs": [], "_offshore": []}
	for p: Dictionary in doc["plants"]:
		var tile := Vector2i(int((float(p["lon"]) - lon0) / dlon),
			int((lat0 - float(p["lat"])) / dlat))
		var dup := false
		for d: Vector2i in seen.get(str(p["kind"]), []):
			if maxi(absi(d.x - tile.x), absi(d.y - tile.y)) <= 3:
				dup = true
				break
		if dup:
			continue
		if not seen.has(str(p["kind"])):
			seen[str(p["kind"])] = []
		(seen[str(p["kind"])] as Array).append(tile)
		var entry := {"kind": p["kind"], "capacity_mw": p["capacity_mw"],
			"tile": tile, "name": p["name"]}
		if str(p["kind"]) == "hydro_ps":
			(out["_phs"] as Array).append(entry)
			continue
		if str(p["kind"]) == "wind_offshore":
			(out["_offshore"] as Array).append(entry)
			continue
		# nearest core metro within 60 tiles (300 km) claims the plant
		var best := ""
		var best_d := 60
		for lc_id: String in centers:
			var c: Vector2i = centers[lc_id]
			var d := maxi(absi(c.x - tile.x), absi(c.y - tile.y))
			if d < best_d:
				best_d = d
				best = lc_id
		if best == "":
			continue
		if not out.has(best):
			out[best] = []
		(out[best] as Array).append(entry)
	for key: String in out:
		(out[key] as Array).sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["capacity_mw"]) > float(b["capacity_mw"]))
	return out


## The ten biggest real pumped-storage stations that can reach one of the
## map's phs_site resource tiles: one 300 MW unit each (fixed unit sizes,
## ledger Q4), spurred into the web toward the nearest substation.
static func _phs_pass(world: Node, candidates: Array, sub_tiles: Dictionary,
		feeds: Dictionary) -> void:
	var placed := 0
	for plant: Dictionary in candidates:
		if placed >= 4:
			break
		var site := DemoBuild.find_site(world, "hydro_ps", plant["tile"], 20)
		if site == Vector2i(-1, -1):
			continue
		var pid: String = world.place_plant("hydro_ps", site)
		world.plants[pid]["name"] = str(plant["name"])
		var tap: Vector2i = DemoBuild.tap_for(world, [site], _halo)
		var spur: Array[Vector2i] = []
		if tap != Vector2i(-1, -1):
			spur = _spur(world, tap, _nearest_sub_tile(world, site, sub_tiles))
		if spur.is_empty():
			world.remove_plant(pid)
			continue
		for tile: Vector2i in spur:
			world.place_corridor(tile, "line_400")
		placed += 1


## The German Bight exports over a converter platform (the BorWin
## pattern, ledger 27): the big far parks bind to the platform by
## proximity — no AC spur, no bus cost — and the platform lands its DC
## export at the Diele substation, TenneT's real landing point. Returns
## the names it consumed so the AC pass skips them.
static func _hub_pass(world: Node, candidates: Array,
		sub_tiles: Dictionary) -> Array:
	var used: Array = []
	var bight: Array = []
	var centroid := Vector2.ZERO
	for p: Dictionary in candidates:
		var t: Vector2i = p["tile"]
		if t.x >= 344 and t.x <= 372 and t.y >= 358 and t.y <= 386:
			bight.append(p)
			centroid += Vector2(t)
	if bight.size() < 2:
		return used  # no cluster, no platform
	centroid /= bight.size()
	var plat_site := DemoBuild.find_site(world, "offshore_platform",
		Vector2i(int(centroid.x), int(centroid.y)), 8)
	var diele: Vector2i = sub_tiles.get("diele", Vector2i(-1, -1))
	if plat_site == Vector2i(-1, -1) or diele == Vector2i(-1, -1):
		return used
	var conv_site := DemoBuild.find_site(world, "hvdc_converter", diele, 6)
	if conv_site == Vector2i(-1, -1):
		return used
	var plat_pid: String = world.place_plant("offshore_platform", plat_site)
	var conv_pid: String = world.place_plant("hvdc_converter", conv_site)
	world.plants[plat_pid]["name"] = "BorWin platform"
	world.plants[conv_pid]["name"] = "BorWin · Diele"
	var flank_a := _free_flank(world, plat_site)
	var flank_b := _free_flank(world, conv_site)
	if flank_a == Vector2i(-1, -1) or flank_b == Vector2i(-1, -1) \
			or not _lay(world, flank_a, flank_b, "hvdc"):
		world.remove_plant(plat_pid)
		world.remove_plant(conv_pid)
		return used
	var reach: int = world.hub_bind_tiles()
	for p: Dictionary in bight:
		if used.size() >= 4:
			break
		var t: Vector2i = p["tile"]
		if maxi(absi(t.x - plat_site.x), absi(t.y - plat_site.y)) > reach:
			continue
		var site := t if world.can_place_plant("wind_offshore", t) \
			else DemoBuild.find_site(world, "wind_offshore", t, 4)
		if site == Vector2i(-1, -1):
			continue
		var pid: String = world.place_plant("wind_offshore", site)
		world.plants[pid]["name"] = str(p["name"])
		used.append(str(p["name"]))
	return used


## Near-shore AC parks: the biggest CONTINENTALLY REACHABLE parks export
## over a submarine cable to the web — capped at the §1.16 150 km AC
## limit, so a UK park can never end up wired to Belgium by sea pylons
## (which is exactly what the capacity-only pick did). Intermittent
## capacity — deliberately NOT counted toward any metro's firm need.
static func _offshore_pass(world: Node, candidates: Array) -> void:
	var placed := 0
	# 80 km, not the §1.16 150: charging eats an AC cable's ampacity with
	# distance, and past ~80 km the export is DC territory — which is WHY
	# the far parks go to the platform instead
	var cable_cap: int = world.tiles_for_km(80.0)
	for plant: Dictionary in candidates:
		if placed >= 4:
			break
		# UK-side waters (west of ~2.5 E): those parks belong to the UK
		# grid, which is not in the world — the 150 km cap alone let
		# London Array wire itself to Belgium
		var pt: Vector2i = plant["tile"]
		if pt.x < 309 and pt.y < 480:
			continue
		var units := 2  # two 500 MW units stand together: one shared spur
		var anchor: Vector2i = plant["tile"]
		var park_done := 0
		for u in units:
			var site := DemoBuild.find_site(world, "wind_offshore", anchor, 6)
			if site == Vector2i(-1, -1):
				break
			var pid: String = world.place_plant("wind_offshore", site)
			world.plants[pid]["name"] = str(plant["name"]) if units == 1 \
				else "%s %d" % [str(plant["name"]), u + 1]
			if u > 0:
				anchor = site
				park_done += 1
				continue  # the second unit shares the first unit's cable
			var tap: Vector2i = DemoBuild.tap_for(world, [site], _halo)
			var spur: Array[Vector2i] = []
			if tap != Vector2i(-1, -1):
				spur = _spur(world, tap,
					_nearest_sub_tile(world, site, {}), "cable_400")
			if spur.is_empty() or spur.size() > cable_cap:
				# too far for AC: the park stays if a platform can bind it
				# (connectivity binding routes it over the hub), else out
				if str(world.platform_near(site)) == "":
					world.remove_plant(pid)
				break
			for tile: Vector2i in spur:
				world.place_corridor(tile, "cable_400")
			anchor = site
			park_done += 1
		if park_done > 0:
			placed += 1


static func _nearest_sub_tile(world: Node, from_tile: Vector2i,
		sub_tiles: Dictionary) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 1 << 30
	for tile: Vector2i in world.substations:
		var d := maxi(absi(tile.x - from_tile.x), absi(tile.y - from_tile.y))
		if d < best_d:
			best_d = d
			best = tile
	return best


## A placeable tile touching an existing AC corridor: ring search out from
## the anchor. Deterministic (fixed scan order, first hit).
static func _site_on_web(world: Node, anchor: Vector2i, kind: String,
		banned: Dictionary, max_r: int) -> Vector2i:
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tile := anchor + Vector2i(dx, dy)
				if banned.has(tile) or not world.can_place_plant(kind, tile):
					continue
				for offset: Vector2i in GridTopology.NEIGHBORS:
					var n := tile + offset
					if str(world.corridors.get(n, "")) == "line_400":
						return tile
	return Vector2i(-1, -1)


## Raise the authored circuits along the existing-web path from a real
## station's tap to its metro tap, sized for the station's output. BFS over
## corridor tiles only (the web is small); no new corridors are laid.
static func _author_evacuation(world: Node, from_tile: Vector2i,
		to_tile: Vector2i, mw: float) -> void:
	var need_circuits := clampi(int(ceil(mw / 500.0)), 4, 12)
	var queue: Array[Vector2i] = [from_tile]
	var head := 0
	var came := {from_tile: from_tile}
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		if current == to_tile:
			break
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var n := current + offset
			if came.has(n):
				continue
			if str(world.corridors.get(n, "")) != "line_400":
				continue
			came[n] = current
			queue.append(n)
	if not came.has(to_tile):
		return
	var cur := to_tile
	while cur != came[cur]:
		world.corridor_circuits[cur] = maxi(
			int(world.corridor_circuits.get(cur, 0)), need_circuits)
		cur = came[cur]
