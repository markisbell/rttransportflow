class_name DemoBuild
extends RefCounted
## Scripted demo builds — shared by the smokes and the in-game B key.
## `fixture_build` uses EXPLICIT tiles on the test fixture map (the golden
## test depends on it staying byte-stable — do not touch casually).
## `auto_build` works on any map via BFS corridor routing between sites.


## The golden-pinned fixture build: two cities, four plants, one trunk line.
static func fixture_build(world: Node) -> void:
	world.clear_build()
	assert(world.place_plant("gas_ocgt", Vector2i(8, 8)) != "")
	assert(world.place_plant("gas_ccgt", Vector2i(10, 8)) != "")
	assert(world.place_plant("gas_ccgt", Vector2i(12, 8)) != "")
	assert(world.place_plant("coal", Vector2i(14, 8)) != "")
	assert(world.place_plant("wind_onshore", Vector2i(16, 8)) != "")
	for x in range(5, 19):  # trunk along y = 6, (5,6) taps west, (18,6) taps east
		assert(world.place_corridor(Vector2i(x, 6)))
	for x in [8, 10, 12, 14, 16]:  # plant taps
		assert(world.place_corridor(Vector2i(x, 7)))


## BFS shortest corridor route over placeable tiles (deterministic: fixed
## neighbor order, first-found path). With `stop_at_existing` the walk ends
## on the FIRST tile that already carries a corridor — plant spurs merge
## into shared trunks instead of laying parallel spaghetti (a junction
## explosion blew the bus budget on the real Europe map).
static func route(world: Node, from_tile: Vector2i, to_tile: Vector2i,
		stop_at_existing: bool = false, avoid: Dictionary = {}) -> Array[Vector2i]:
	var queue: Array[Vector2i] = [from_tile]
	var came := {from_tile: from_tile}
	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		if current == to_tile \
				or (stop_at_existing and world.corridors.has(current)):
			var path: Array[Vector2i] = []
			while current != came[current]:
				path.append(current)
				current = came[current]
			path.append(from_tile)
			path.reverse()
			return path
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var n := current + offset
			if came.has(n) or avoid.has(n) or not world.can_place_corridor(n):
				continue
			came[n] = current
			queue.append(n)
	return []


## Find a placeable tile for `kind` near `anchor` (ring search, deterministic).
static func find_site(world: Node, kind: String, anchor: Vector2i, max_r: int = 8) -> Vector2i:
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tile := anchor + Vector2i(dx, dy)
				if world.can_place_plant(kind, tile):
					return tile
	return Vector2i(-1, -1)


## First corridor-placeable tile on a site's perimeter (deterministic scan).
static func tap_for(world: Node, tiles: Array) -> Vector2i:
	for tile: Vector2i in tiles:
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var n: Vector2i = tile + offset
			if world.can_place_corridor(n) and world.plant_at(n) == "" \
					and world.load_center_at(n) == "":
				return n
	return Vector2i(-1, -1)


## Pick a compact cluster: the seed city plus its 2 nearest neighbors
## (chaining alphabetically-distant capitals across seas is how a demo
## build times out — found the hard way on the real Europe map).
static func _nearby_cluster(world: Node, seed_id: String) -> Array[String]:
	var anchor: Vector2i = world.load_centers[seed_id]["tiles"][0]
	var others: Array[String] = []
	others.assign(world.load_centers.keys())
	others.erase(seed_id)
	others.sort_custom(func(a: String, b: String) -> bool:
		var da: Vector2i = (world.load_centers[a]["tiles"][0] as Vector2i) - anchor
		var db: Vector2i = (world.load_centers[b]["tiles"][0] as Vector2i) - anchor
		var la := absi(da.x) + absi(da.y)
		var lb := absi(db.x) + absi(db.y)
		return la < lb or (la == lb and a < b))
	var cluster: Array[String] = [seed_id]
	cluster.append_array(others.slice(0, 2))
	return cluster


## Auto-build on ANY map: a compact 3-city cluster, each with local
## generation sized to its peak, joined by corridors.
static func auto_build(world: Node, lc_ids: Array[String] = []) -> bool:
	world.clear_build()
	var ids: Array[String] = lc_ids.duplicate()
	if ids.is_empty() and not world.load_centers.is_empty():
		# Prefer a SPREAD trio (adjacent metros collapse into one bus blob at
		# 50 km tiles — no branches, no grid); fall back to a nearby cluster.
		var spread: Array[String] = ["frankfurt", "berlin", "munich"]
		var have_all := true
		for lc_id: String in spread:
			have_all = have_all and world.load_centers.has(lc_id)
		if have_all:
			ids = spread
		else:
			var all_ids: Array[String] = []
			all_ids.assign(world.load_centers.keys())
			all_ids.sort()
			ids = _nearby_cluster(world, all_ids[0])
	if ids.is_empty():
		return false

	# Corridors that brush a FOREIGN load center's footprint connect that
	# city — and its load — without any generation (a 47.4 Hz dive taught us).
	# The demo router steers clear of every non-cluster footprint.
	var avoid := {}
	for lc_id: String in world.load_centers:
		if lc_id in ids:
			continue
		for tile: Vector2i in world.load_centers[lc_id]["tiles"]:
			avoid[tile] = true
			for offset: Vector2i in GridTopology.NEIGHBORS:
				avoid[tile + offset] = true

	var taps: Array[Vector2i] = []
	for lc_id: String in ids:
		var lc: Dictionary = world.load_centers[lc_id]
		var lc_tap := tap_for(world, lc["tiles"])
		if lc_tap == Vector2i(-1, -1):
			continue
		var anchor: Vector2i = lc["tiles"][0]
		var need: float = lc["peak_mw"] * 1.2
		var placed := 0.0
		world.place_corridor(lc_tap)  # seed so plant spurs can merge into it
		while placed < need:
			# unit-size ladder keeps big cities to a sane plant count and
			# the plant ring COMPACT (sprawling rings of neighboring metros
			# merge into one bus blob)
			var kinds: Array[String] = []
			if need - placed > 1200.0:
				kinds = ["nuclear", "coal"]  # nuclear needs coast/river; coal fallback
			elif need - placed > 700.0:
				kinds = ["coal"]
			elif need - placed > 300.0:
				kinds = ["gas_ccgt"]
			else:
				kinds = ["gas_ocgt"]
			var site := Vector2i(-1, -1)
			var kind := ""
			for candidate: String in kinds:
				site = find_site(world, candidate, anchor, 6)
				if site != Vector2i(-1, -1):
					kind = candidate
					break
			if site == Vector2i(-1, -1):
				break
			world.place_plant(kind, site)
			placed += world.PLANT_SIZES[kind]
			var plant_tap := tap_for(world, [site])
			if plant_tap == Vector2i(-1, -1):
				continue
			for tile: Vector2i in route(world, plant_tap, lc_tap, true, avoid):
				world.place_corridor(tile)
		taps.append(lc_tap)

	for i in range(taps.size() - 1):  # chain the cluster
		for tile: Vector2i in route(world, taps[i], taps[i + 1], false, avoid):
			world.place_corridor(tile)
	return not taps.is_empty()
