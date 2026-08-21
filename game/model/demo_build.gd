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
## `passable` (optional) replaces the default can_place_corridor expansion
## test — the ONE deterministic BFS now also serves the DC corridor layer
## (P7SmokeBase.lay_hvdc used to keep a private second copy).
static func route(world: Node, from_tile: Vector2i, to_tile: Vector2i,
		stop_at_existing: bool = false, avoid: Dictionary = {},
		passable: Callable = Callable(),
		stop_kinds: Array = []) -> Array[Vector2i]:
	var queue: Array[Vector2i] = [from_tile]
	var head := 0  # index head, not pop_front: Array.pop_front is O(n) and
	# a continental-scale search (tens of thousands of tiles) goes quadratic
	var came := {from_tile: from_tile}
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		# stop_kinds narrows what counts as "existing": an AC plant spur
		# stopping at an HVDC corridor tile merges with NOTHING — it ends
		# beside a line of the wrong kind and orphans its plant (24 islands
		# at t=0 taught this once DC corridors crossed the country)
		if current == to_tile \
				or (stop_at_existing and world.corridors.has(current)
					and (stop_kinds.is_empty()
						or str(world.corridors[current]) in stop_kinds)):
			var path: Array[Vector2i] = []
			while current != came[current]:
				path.append(current)
				current = came[current]
			path.append(from_tile)
			path.reverse()
			return path
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var n := current + offset
			if came.has(n) or avoid.has(n):
				continue
			if not (passable.call(n) if passable.is_valid()
					else world.can_place_corridor(n)):
				continue
			came[n] = current
			queue.append(n)
	return []


## Find a placeable tile for `kind` near `anchor` (ring search, deterministic).
## `banned`: sites that already failed routing — never offer them again.
## Ring radii are given in TILES but tuned as distances: `tiles_for_km`
## keeps them honest when the grid resolution changes (ledger 38).
## Delegates to the ONE converter on WorldModel — a second implementation is
## how the sixth tile-count bite happens.
static func tiles_for_km(km: float, world: Node) -> int:
	return world.tiles_for_km(km)


static func find_site(world: Node, kind: String, anchor: Vector2i, max_r: int = 8,
		banned: Dictionary = {}) -> Vector2i:
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tile := anchor + Vector2i(dx, dy)
				if not banned.has(tile) and world.can_place_plant(kind, tile):
					return tile
	return Vector2i(-1, -1)


## First corridor-placeable tile on a site's perimeter (deterministic scan).
## Prefers tiles outside `avoid` — a tap seeded inside a foreign city's ring
## can never route anywhere (frankfurt sat in ruhr's ring; found offline).
static func tap_for(world: Node, tiles: Array, avoid: Dictionary = {}) -> Vector2i:
	var fallback := Vector2i(-1, -1)
	for tile: Vector2i in tiles:
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var n: Vector2i = tile + offset
			if world.can_place_corridor(n) and world.plant_at(n) == "" \
					and world.load_center_at(n) == "":
				if not avoid.has(n):
					return n
				if fallback == Vector2i(-1, -1):
					fallback = n
	return fallback


## A tile ~60 km to the side of `from_tile`, used to start the alternate
## trunk so the two routes do not immediately re-merge into one corridor.
static func _detour_seed(world: Node, from_tile: Vector2i,
		avoid: Dictionary) -> Vector2i:
	var offset := tiles_for_km(60.0, world)
	for candidate: Vector2i in [from_tile + Vector2i(0, offset),
			from_tile + Vector2i(0, -offset), from_tile + Vector2i(offset, 0),
			from_tile + Vector2i(-offset, 0)]:
		if world.can_place_corridor(candidate) and not avoid.has(candidate):
			var spur := route(world, from_tile, candidate, false, avoid)
			if not spur.is_empty():
				for tile: Vector2i in spur:
					world.place_corridor(tile)
				return candidate
	return from_tile


## Up to four taps around a footprint, one per side where possible — the
## routes into a metro must not all converge on one tile.
static func taps_around(world: Node, tiles: Array,
		avoid: Dictionary = {}) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for offset: Vector2i in GridTopology.NEIGHBORS:
		for tile: Vector2i in tiles:
			var n: Vector2i = tile + offset
			if out.has(n) or avoid.has(n):
				continue
			if world.can_place_corridor(n) and world.plant_at(n) == "" \
					and world.load_center_at(n) == "":
				out.append(n)
				break
	if out.is_empty():
		var single := tap_for(world, tiles, avoid)
		if single != Vector2i(-1, -1):
			out.append(single)
	return out


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
		# 50 km tiles — no branches, no grid). Frankfurt is out: ruhr's
		# footprint is ADJACENT to it and its avoid ring seals the tap
		# (verified offline against europe_v1). Hamburg/berlin/munich
		# pairwise-connect on the empty map.
		var spread: Array[String] = ["hamburg", "berlin", "munich"]
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
		# the ring must stay ~50 km wide however fine the grid is
		var ring := tiles_for_km(50.0, world)
		for tile: Vector2i in world.load_centers[lc_id]["tiles"]:
			for dx in range(-ring, ring + 1):
				for dy in range(-ring, ring + 1):
					avoid[tile + Vector2i(dx, dy)] = true

	# TRUNK FIRST. Routing the inter-city line after the plants are down
	# fails: a ring of plants around a metro walls its tap in, and the BFS
	# has no way through (the 5 km grid made the ring thick enough to seal).
	# On an empty map the trunk always routes, and every later spur simply
	# stops at it.
	var city_taps := {}  # lc_id -> Array[Vector2i]
	for lc_id: String in ids:
		city_taps[lc_id] = taps_around(world, world.load_centers[lc_id]["tiles"],
			avoid)
	var trunk_from := Vector2i(-1, -1)
	for lc_id: String in ids:
		var here: Array = city_taps[lc_id]
		if here.is_empty():
			continue
		var entry: Vector2i = here[0]
		world.place_corridor(entry)
		if trunk_from != Vector2i(-1, -1):
			var link := route(world, trunk_from, entry, false, avoid)
			if link.is_empty():
				push_warning("auto_build: trunk to %s unroutable" % lc_id)
			for tile: Vector2i in link:
				world.place_corridor(tile)
			# A SECOND path between the metros. One trunk carries every
			# merit-order exchange between cities — the first 5 km build put
			# 224 % on it and the duty protection cut the continent into
			# three islands. Real backbones are meshed for exactly this
			# reason; the alternate route also survives an outage on the first.
			if here.size() > 1:
				var alt_from: Vector2i = _detour_seed(world, trunk_from, avoid)
				var alt_to: Vector2i = here[mini(1, here.size() - 1)]
				world.place_corridor(alt_to)
				var alt := route(world, alt_from, alt_to, false, avoid)
				for tile: Vector2i in alt:
					world.place_corridor(tile)
		trunk_from = entry

	var taps: Array[Vector2i] = []
	for lc_id: String in ids:
		var lc: Dictionary = world.load_centers[lc_id]
		# Feed a metro from SEVERAL sides. One tap means one spur carrying the
		# city's whole supply — at 5 km tiles the ring search packs plants
		# next to each other and that single branch hit 222 % loading.
		var taps_here: Array = city_taps[lc_id]
		if taps_here.is_empty():
			continue
		var lc_tap: Vector2i = taps_here[0]
		var anchor: Vector2i = lc["tiles"][0]
		# 1.35: the LIVE demand model's weather-driven peak runs above the
		# map's static peak_mw — a 1.2 build blacked out at 10:00 (found by
		# the dispatch_day DBG trace: 10.4 GW fleet, 11.5 GW forecast peak).
		var need: float = lc["peak_mw"] * GridTopology.LIVE_PEAK_MARGIN
		var placed := 0.0
		var placed_count := 0
		# unroutable sites — retrying them loops forever; seeded with the
		# avoid rings: a site inside a foreign ring can never route out, and
		# each doomed BFS floods the whole map (385 of them stalled buildcheck)
		var banned := avoid.duplicate()
		world.place_corridor(lc_tap)  # seed so plant spurs can merge into it
		while placed < need:
			# unit-size ladder keeps big cities to a sane plant count and the
			# plant ring COMPACT. Every rung falls through to gas (gas only
			# needs land — nuclear/coal site exhaustion used to BREAK the loop
			# and leave the city short with zero peakers), and the top ~30 %
			# tranche is gas OUTRIGHT so the merit order has evening peakers.
			# tranches: ~45 % nuclear base, coal to ~70 %, gas for the top —
			# an all-nuclear build priced the whole day at 8 €/MWh with
			# 2.6 g/kWh and broke the economy smoke's mixed-fleet windows
			var remaining := need - placed
			var kinds: Array[String] = []
			if remaining > 1200.0 and placed < need * 0.45:
				kinds = ["nuclear", "coal", "gas_ccgt"]
			elif remaining > 700.0 and placed < need * 0.7:
				kinds = ["coal", "gas_ccgt"]
			elif remaining > 300.0:
				kinds = ["gas_ccgt", "gas_ocgt"]
			else:
				kinds = ["gas_ocgt"]
			var site := Vector2i(-1, -1)
			var kind := ""
			for candidate: String in kinds:
				site = find_site(world, candidate, anchor,
					tiles_for_km(300.0, world), banned)
				if site == Vector2i(-1, -1):
					site = find_site(world, candidate, anchor,
						tiles_for_km(600.0, world), banned)
				if site != Vector2i(-1, -1):
					kind = candidate
					break
			if site == Vector2i(-1, -1):
				break
			var pid: String = world.place_plant(kind, site)
			var plant_tap := tap_for(world, [site], avoid)
			var path: Array[Vector2i] = []
			if plant_tap != Vector2i(-1, -1):
				path = route(world, plant_tap, lc_tap, true, avoid)
			# rotate the target tap so spurs arrive on different sides
			lc_tap = taps_here[placed_count % taps_here.size()]
			if path.is_empty():
				# an unconnectable plant is 100 % waste: remove it and let the
				# ladder try elsewhere (silent orphans starved dispatch_day)
				world.remove_plant(pid)
				banned[site] = true
				push_warning("auto_build: %s at %s unroutable to %s — removed"
					% [kind, site, lc_id])
				continue
			placed += world.PLANT_SIZES[kind]
			placed_count += 1
			for tile: Vector2i in path:
				world.place_corridor(tile)
		taps.append(lc_tap)

	return not taps.is_empty()  # the trunk was laid before any plant landed
