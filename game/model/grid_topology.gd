class_name GridTopology
extends RefCounted
## Topology builder (infrastruct pattern): WorldModel tiles -> the backend's
## native scenario bundle + game-side interpretation maps. Deterministic by
## construction (sorted iteration everywhere) — the output is golden-file
## pinned byte-for-byte.
##
## Bus formation (GAME_DESIGN §1.4): a corridor tile becomes a bus tile when
## it (a) touches a plant or load-center footprint, (b) has 3+ corridor
## neighbors, (c) sits on a corridor-kind change, or (d) carries an explicit
## substation. Adjacent bus tiles collapse into one bus. Branches are the
## simple corridor paths between buses; L_km = steps × tile_km × 1.12.
## Islands without a synchronous source are dropped (warned); P5 keeps only
## the reference island (multi-island operation arrives with P8 protection).

const SINUOSITY := 1.12
const BUS_WARN := 120
const BUS_REFUSE := 150
const DEFAULT_PARALLEL := 2
const STEPS := 96

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)
]


static func _sorted_tiles(dict: Dictionary) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	tiles.assign(dict.keys())
	tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	return tiles


## Build. Returns {ok, native, zones, interpretation, warnings, error?}.
static func build(world: Node) -> Dictionary:
	var warnings: Array[String] = []
	var corridors: Dictionary = world.corridors
	if corridors.is_empty():
		return {"ok": false, "error": "nothing built", "warnings": warnings}

	# --- adjacency structures ------------------------------------------
	var site_of_tile := {}  # corridor-adjacent tile -> "plant:<pid>"|"lc:<id>"
	for pid: String in world.plants:
		site_of_tile[world.plants[pid]["tile"]] = "plant:%s" % pid
	for lc_id: String in world.load_centers:
		for tile: Vector2i in world.load_centers[lc_id]["tiles"]:
			site_of_tile[tile] = "lc:%s" % lc_id

	# --- 1. bus tiles ---------------------------------------------------
	var bus_tiles := {}
	for tile: Vector2i in _sorted_tiles(corridors):
		var kind: String = corridors[tile]
		var corridor_neighbors := 0
		var kind_change := false
		var touches_site := false
		for offset: Vector2i in NEIGHBORS:
			var n := tile + offset
			if corridors.has(n):
				corridor_neighbors += 1
				if corridors[n] != kind:
					kind_change = true
			if site_of_tile.has(n):
				touches_site = true
		if touches_site or corridor_neighbors >= 3 or kind_change \
				or world.substations.has(tile):
			bus_tiles[tile] = true

	if bus_tiles.is_empty():
		return {"ok": false, "error": "no bus forms (connect a corridor to a plant or load center)",
			"warnings": warnings}

	# --- 2. collapse adjacent bus tiles into buses ----------------------
	var bus_of_tile := {}  # bus-tile -> bus index
	var bus_min_tile: Array[Vector2i] = []
	for tile: Vector2i in _sorted_tiles(bus_tiles):
		if bus_of_tile.has(tile):
			continue
		var bus_index := bus_min_tile.size()
		var stack: Array[Vector2i] = [tile]
		var min_tile := tile
		while not stack.is_empty():
			var current: Vector2i = stack.pop_back()
			if bus_of_tile.has(current):
				continue
			bus_of_tile[current] = bus_index
			if current.y < min_tile.y or (current.y == min_tile.y and current.x < min_tile.x):
				min_tile = current
			for offset: Vector2i in NEIGHBORS:
				var n := current + offset
				if bus_tiles.has(n) and not bus_of_tile.has(n):
					stack.append(n)
		bus_min_tile.append(min_tile)

	var n_buses := bus_min_tile.size()
	if n_buses > BUS_REFUSE:
		return {"ok": false,
			"error": "node budget: %d buses > %d — consolidate substations" % [n_buses, BUS_REFUSE],
			"warnings": warnings}
	if n_buses > BUS_WARN:
		warnings.append("node budget: %d buses (warn at %d, refuse at %d)"
			% [n_buses, BUS_WARN, BUS_REFUSE])

	# --- 3. branches: walk corridor paths between buses -----------------
	var branches: Array[Dictionary] = []
	var seen_edges := {}
	for tile: Vector2i in _sorted_tiles(bus_tiles):
		var from_bus: int = bus_of_tile[tile]
		for offset: Vector2i in NEIGHBORS:
			var next := tile + offset
			if not corridors.has(next):
				continue
			if bus_tiles.has(next):
				if bus_of_tile[next] == from_bus:
					continue  # same collapsed bus
				var to_bus_adj: int = bus_of_tile[next]
				var key_adj := "%d:%d:%s" % [mini(from_bus, to_bus_adj),
					maxi(from_bus, to_bus_adj), str(tile) + str(next)]
				# adjacent distinct buses: zero-interior path, 1 step
				if not seen_edges.has(key_adj):
					seen_edges[key_adj] = true
					branches.append({"from": from_bus, "to": to_bus_adj,
						"steps": 1, "kind": corridors[tile]})
				continue
			# walk the simple path until the next bus tile
			var prev := tile
			var current := next
			var steps := 1
			var dead_end := false
			while not bus_tiles.has(current):
				var forward: Array[Vector2i] = []
				for o2: Vector2i in NEIGHBORS:
					var n2 := current + o2
					if n2 != prev and corridors.has(n2):
						forward.append(n2)
				if forward.size() != 1:
					dead_end = true  # stub or ambiguous (non-bus junction impossible)
					break
				prev = current
				current = forward[0]
				steps += 1
			if dead_end:
				continue  # dead-end stub: no branch (warned via dropped sites later)
			var to_bus: int = bus_of_tile[current]
			if to_bus == from_bus:
				continue
			var path_key := "%d:%d:%d" % [mini(from_bus, to_bus), maxi(from_bus, to_bus), steps]
			var mid_key := str(next)  # disambiguate parallel corridors
			var edge_key := path_key + ":" + mid_key
			if seen_edges.has(edge_key):
				continue
			seen_edges[edge_key] = true
			branches.append({"from": from_bus, "to": to_bus, "steps": steps,
				"kind": corridors[next]})

	# --- 4. attach plants and load centers to buses ---------------------
	var plant_bus := {}  # pid -> bus index
	var zone_bus := {}  # lc id -> bus index
	for tile: Vector2i in _sorted_tiles(bus_tiles):
		for offset: Vector2i in NEIGHBORS:
			var site: String = site_of_tile.get(tile + offset, "")
			if site.begins_with("plant:"):
				var pid := site.trim_prefix("plant:")
				if not plant_bus.has(pid):
					plant_bus[pid] = bus_of_tile[tile]
			elif site.begins_with("lc:"):
				var lc_id := site.trim_prefix("lc:")
				if not zone_bus.has(lc_id):
					zone_bus[lc_id] = bus_of_tile[tile]

	for pid: String in world.plants:
		if not plant_bus.has(pid):
			warnings.append("plant %s not connected (no corridor touches it)" % pid)
	var dropped_zones: Array[String] = []
	for lc_id: String in world.load_centers:
		if not zone_bus.has(lc_id):
			dropped_zones.append(lc_id)

	# --- 5. islands: keep only the reference island ---------------------
	var island_of := _bus_islands(n_buses, branches)
	var island_sync_capacity := {}
	for pid: String in plant_bus:
		if str(world.plants[pid]["kind"]) in world.SYNC_KINDS:
			var island: int = island_of[plant_bus[pid]]
			island_sync_capacity[island] = float(island_sync_capacity.get(island, 0.0)) \
				+ float(world.plants[pid]["p_max_mw"])
	if island_sync_capacity.is_empty():
		return {"ok": false, "error": "no synchronous source anywhere — build a plant",
			"warnings": warnings}
	var reference_island := -1
	var best_capacity := -1.0
	for island: int in island_sync_capacity:
		if float(island_sync_capacity[island]) > best_capacity:
			best_capacity = float(island_sync_capacity[island])
			reference_island = island
	var kept_bus := {}
	for bus in range(n_buses):
		if island_of[bus] == reference_island:
			kept_bus[bus] = true
		else:
			warnings.append("bus %d dropped (island without the reference source)" % bus)

	# --- 6. emit the native bundle (fixed key order for goldens) --------
	var bus_rename := {}
	var bus_names: Array = []
	for bus in range(n_buses):
		if kept_bus.has(bus):
			bus_rename[bus] = bus_names.size()
			bus_names.append("b%d" % bus_rename[bus])

	var kept_plants: Array[String] = []
	for pid: String in plant_bus:
		if kept_bus.has(plant_bus[pid]):
			kept_plants.append(pid)
		else:
			warnings.append("plant %s dropped with its island" % pid)
	kept_plants.sort()
	var kept_zones: Array[String] = []
	for lc_id: String in zone_bus:
		if kept_bus.has(zone_bus[lc_id]):
			kept_zones.append(lc_id)
		else:
			dropped_zones.append(lc_id)
	kept_zones.sort()
	dropped_zones.sort()
	if kept_zones.is_empty():
		return {"ok": false, "error": "no load center connected to the source island",
			"warnings": warnings}
	for lc_id: String in dropped_zones:
		warnings.append("load center %s UNSUPPLIED (not connected to the source island)" % lc_id)

	# reference bus: the largest kept sync plant's bus
	var reference_bus := ""
	var best_p := -1.0
	for pid: String in kept_plants:
		if str(world.plants[pid]["kind"]) in world.SYNC_KINDS \
				and float(world.plants[pid]["p_max_mw"]) > best_p:
			best_p = float(world.plants[pid]["p_max_mw"])
			reference_bus = "b%d" % bus_rename[plant_bus[pid]]

	var grid := {"buses": [], "reference_bus": reference_bus, "zones": []}
	for bus_name: String in bus_names:
		grid["buses"].append({"name": bus_name, "vn_kv": 380.0, "area": "CE"})
	for lc_id: String in kept_zones:
		grid["zones"].append({"id": lc_id, "bus": "b%d" % bus_rename[zone_bus[lc_id]]})

	var lines := {"lines": []}
	var line_seq := 0
	for branch: Dictionary in branches:
		if not (kept_bus.has(branch["from"]) and kept_bus.has(branch["to"])):
			continue
		var vn: float = 380.0 if branch["kind"] == "line_400" else 220.0
		lines["lines"].append({
			"id": "L%d" % line_seq,
			"from_bus": "b%d" % bus_rename[branch["from"]],
			"to_bus": "b%d" % bus_rename[branch["to"]],
			"length_km": snappedf(int(branch["steps"]) * world.tile_km * SINUOSITY, 0.01),
			"std_type": "490-AL1/64-ST1A 380.0",
			"parallel": DEFAULT_PARALLEL,
		})
		line_seq += 1
	if lines["lines"].is_empty():
		return {"ok": false, "error": "no branches between buses", "warnings": warnings}

	var demand := _demand_profiles(world, kept_zones)
	var dispatch := _dispatch_profiles(world, kept_plants, demand["total"])

	var plants_doc := {"plants": []}
	for pid: String in kept_plants:
		var p: Dictionary = world.plants[pid]
		plants_doc["plants"].append({
			"id": pid, "name": pid, "bus": "b%d" % bus_rename[plant_bus[pid]],
			"kind": str(p["kind"]), "p_max_mw": float(p["p_max_mw"]),
			"p_min_mw": 0.0, "vm_pu": 1.02,
			"profile_p_mw": dispatch[pid],
		})

	var load_centers_doc := {"resolution_minutes": 15, "steps": STEPS,
		"items": []}
	for lc_id: String in kept_zones:
		load_centers_doc["items"].append({"name": lc_id, "zone": lc_id,
			"p_mw": demand[lc_id]})

	var scenario := {"name": "built_world", "steps_per_day": STEPS,
		"description": "player-built grid (P5)"}

	return {
		"ok": true,
		"native": {"grid": grid, "lines": lines, "plants": plants_doc,
			"load_centers": load_centers_doc, "scenario": scenario},
		"zones": grid["zones"],
		"interpretation": {
			"n_buses": bus_names.size(),
			"bus_of_tile": bus_of_tile,
			"bus_rename": bus_rename,
			"dropped_zones": dropped_zones,
			"plant_bus": plant_bus,
		},
		"warnings": warnings,
	}


static func _bus_islands(n_buses: int, branches: Array[Dictionary]) -> Array[int]:
	var parent: Array[int] = []
	for i in range(n_buses):
		parent.append(i)
	var find := func(x: int) -> int:
		while parent[x] != x:
			parent[x] = parent[parent[x]]
			x = parent[x]
		return x
	for branch: Dictionary in branches:
		var ra: int = find.call(branch["from"])
		var rb: int = find.call(branch["to"])
		if ra != rb:
			parent[ra] = rb
	var result: Array[int] = []
	for i in range(n_buses):
		result.append(find.call(i))
	return result


## Winter-workday demand shape (same curve family as europe_mini authoring).
static func _load_shape(step: int) -> float:
	var h := step / 4.0
	return 0.62 + 0.22 * exp(-pow(h - 9.5, 2) / 8.0) \
		+ 0.16 * exp(-pow(h - 13.0, 2) / 14.0) \
		+ 0.38 * exp(-pow(h - 18.5, 2) / 5.0)


static func _demand_profiles(world: Node, zone_ids: Array[String]) -> Dictionary:
	var out := {"total": []}
	var totals: Array[float] = []
	totals.resize(STEPS)
	totals.fill(0.0)
	for lc_id: String in zone_ids:
		var peak: float = world.load_centers[lc_id]["peak_mw"]
		var profile: Array[float] = []
		for step in range(STEPS):
			var value := snappedf(peak * _load_shape(step), 0.1)
			profile.append(value)
			totals[step] += value
		out[lc_id] = profile
	out["total"] = totals
	return out


## Stub balanced dispatch (real dispatch arrives in P6): must-take renewables
## + flat nuclear + dispatchables sharing the residual pro-rata (capped 92 %).
static func _dispatch_profiles(world: Node, plant_ids: Array[String],
		total_load: Array[float]) -> Dictionary:
	var out := {}
	for pid: String in plant_ids:
		var profile: Array[float] = []
		profile.resize(STEPS)
		profile.fill(0.0)
		out[pid] = profile

	for step in range(STEPS):
		var target: float = total_load[step] * 1.015
		var fixed := 0.0
		var dispatchable_cap := 0.0
		var fixed_pids: Array[String] = []
		for pid: String in plant_ids:
			var p: Dictionary = world.plants[pid]
			var kind := str(p["kind"])
			var p_max: float = p["p_max_mw"]
			var value := 0.0
			match kind:
				"nuclear":
					value = 0.88 * p_max
				"solar_pv":
					var h := step / 4.0
					value = p_max * maxf(0.0, sin(PI * (h - 8.0) / 10.0)) if h >= 8.0 and h <= 18.0 else 0.0
				"wind_onshore", "wind_offshore":
					value = 0.55 * p_max
				_:
					dispatchable_cap += p_max
					continue
			out[pid][step] = snappedf(value, 0.1)
			fixed += out[pid][step]
			fixed_pids.append(pid)
		if fixed > target and fixed > 0.0:
			# Over-generation collapses the grid UPWARD (51.5 Hz trip cascade,
			# then blackout — found the hard way): scale must-run down so the
			# stub dispatch always balances.
			var scale := target / fixed
			for pid: String in fixed_pids:
				out[pid][step] = snappedf(out[pid][step] * scale, 0.1)
			fixed = target
		var residual := maxf(target - fixed, 0.0)
		if dispatchable_cap > 0.0:
			var share := minf(residual / dispatchable_cap, 0.92)
			for pid: String in plant_ids:
				var p: Dictionary = world.plants[pid]
				if str(p["kind"]) in ["coal", "lignite", "gas_ccgt", "gas_ocgt", "hydro_ps"]:
					out[pid][step] = snappedf(share * float(p["p_max_mw"]), 0.1)
	return out
