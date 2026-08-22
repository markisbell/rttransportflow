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
## Circuits per corridor. A 400 kV right-of-way carries four circuits in
## practice (~2.5 GVA); two circuits (~1.26 GVA) cannot even evacuate a
## single 1.6 GW nuclear unit, which is how the first 5 km build tripped
## three lines at 165-222 % loading within 10 ms of registering.
const DEFAULT_PARALLEL := 4
## One 380 kV circuit of the shipped std_type, and the share of it a planner
## actually schedules against (the rest is N-1 margin). Used to size a
## branch's circuit count from the capacity it joins.
const CIRCUIT_MVA := 625.0
## one 400 kV XLPE cable circuit at 1.8 kA (the emitted max_i_ka)
const CIRCUIT_MVA_CABLE := 1100.0
const CIRCUIT_UTILISATION := 0.9
## Ledger 29's fleet-sizing margin: the LIVE weather-driven peak runs above
## the map's static peak_mw_2025, so builds size generation at 1.35x the
## static peak. Named HERE (one definition; DemoBuild references it).
## Deliberately NOT applied to branch sizing: the corrected-projection
## overload event (day 1.34, L116/L108 at ~121 %) sits on branches whose
## sizing is generation-bound/meshed — a load-side margin measurably
## changed nothing there while silently re-sizing every load-bound spur in
## other worlds. Meshed-trunk flow estimation is a modeling project, not a
## margin (see the re-baseline ledger entry).
const LIVE_PEAK_MARGIN := 1.35
## A corridor tile stands for a bundle of rights-of-way, not an unbounded
## one: past this the answer is another corridor, not a wider one.
const MAX_PARALLEL := 12
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


## Build. Returns {ok, native, devices, hub_farms, zones, interpretation,
## warnings, error?}.
static func build(world: Node, demand_sampler: Callable = Callable()) -> Dictionary:
	var warnings: Array[String] = []
	# HVDC corridors are a separate electrical world: they never form AC
	# buses or branches — they pair converter stations (P7, §1.16).
	var corridors := {}
	var hvdc_corridors := {}
	# crossing spans: a dc_overlay tile carries BOTH its AC line (below)
	# and the hvdc line passing over — it joins both electrical worlds
	for tile: Vector2i in world.dc_overlay:
		hvdc_corridors[tile] = "hvdc"
	for tile: Vector2i in world.corridors:
		if str(world.corridors[tile]) == "hvdc":
			hvdc_corridors[tile] = "hvdc"
		else:
			corridors[tile] = world.corridors[tile]
	if corridors.is_empty():
		return {"ok": false, "error": "nothing built", "warnings": warnings}

	# far-shore farms bind to their platform and leave the AC world entirely
	# (never wire devices — the hub aggregates them; contract v2 kinds table)
	var farm_hub := {}  # wind_offshore pid -> platform pid
	for pid: String in world.plants:
		var p: Dictionary = world.plants[pid]
		if str(p["kind"]) != "wind_offshore":
			continue
		var terr := str(world.terrain_at(p["tile"]))
		# Deep-sea farms ALWAYS export over a platform. SHELF farms bind
		# only when they have no AC export of their own: the German Bight
		# is shallow end to end, yet its parks export over converter
		# platforms in reality (the BorWin pattern) — depth was a proxy
		# for DISTANCE, and connectivity is the honest criterion.
		var ac_connected := false
		if terr == "s":
			for offset: Vector2i in NEIGHBORS:
				if world.corridors.has((p["tile"] as Vector2i) + offset):
					ac_connected = true
					break
		if terr == "S" or (terr == "s" and not ac_connected):
			var platform: String = world.platform_near(p["tile"])
			if platform == "":
				if terr == "S":
					warnings.append(
						"far-shore farm %s has no platform in range — dropped" % pid)
				continue  # unconnected shelf farm without a hub: AC rules apply
			farm_hub[pid] = platform

	# --- adjacency structures ------------------------------------------
	var site_of_tile := {}  # corridor-adjacent tile -> "plant:<pid>"|"lc:<id>"
	for pid: String in world.plants:
		var kind := str(world.plants[pid]["kind"])
		# caverns and platforms never attract AC buses; bound farms are gone
		if kind in ["h2_cavern", "offshore_platform"] or farm_hub.has(pid):
			continue
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
						"steps": 1, "kind": corridors[tile],
						"authored": maxi(
							int(world.corridor_circuits.get(tile, 0)),
							int(world.corridor_circuits.get(next, 0)))})
				continue
			# walk the simple path until the next bus tile
			var prev := tile
			var current := next
			var steps := 1
			var authored: int = maxi(int(world.corridor_circuits.get(tile, 0)),
				int(world.corridor_circuits.get(next, 0)))
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
				authored = maxi(authored, int(world.corridor_circuits.get(current, 0)))
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
				"kind": corridors[next], "authored": authored})

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
		var kind := str(world.plants[pid]["kind"])
		if kind in ["h2_cavern", "offshore_platform"] or farm_hub.has(pid):
			continue  # deliberately outside the AC world
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
	var device_bus := {}  # battery/electrolyzer/hvdc_converter pid -> bus
	for pid: String in plant_bus:
		if not kept_bus.has(plant_bus[pid]):
			warnings.append("plant %s dropped with its island" % pid)
			continue
		if str(world.plants[pid]["kind"]) in world.DEVICE_KINDS:
			device_bus[pid] = plant_bus[pid]
		else:
			kept_plants.append(pid)
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

	# Circuits per branch are sized to what the branch has to move, not to a
	# constant. A right-of-way into a 12 GW metro is not the same asset as a
	# tie between two villages, and a flat 4 circuits (~2.5 GVA) put the
	# continental build's metro spurs at 157-211 % within 10 ms of
	# registering — five instant trips, the grid in eight pieces, UFLS
	# everywhere before the player had touched anything.
	#
	# Estimate: a branch can never be asked to carry more than the SMALLER of
	# the two capacities it joins (generation parked behind it, or load in
	# front of it), so that minimum is the sizing figure. On a leaf spur it
	# is exact; on a meshed trunk it is an over-estimate, which is why it is
	# capped — a corridor tile aggregates a real bundle of rights-of-way, but
	# not an unlimited one.
	var gen_mva := {}   # bus index -> generation capacity at that bus
	var load_mva := {}  # bus index -> peak load at that bus
	for pid: String in kept_plants:
		var bus: int = plant_bus[pid]
		gen_mva[bus] = float(gen_mva.get(bus, 0.0)) \
			+ float(world.plants[pid]["p_max_mw"])
	for lc_id: String in kept_zones:
		var bus: int = zone_bus[lc_id]
		load_mva[bus] = float(load_mva.get(bus, 0.0)) \
			+ float(world.load_centers[lc_id].get("peak_mw", 0.0))
	var kept_branches: Array[Dictionary] = []
	for branch: Dictionary in branches:
		if kept_bus.has(branch["from"]) and kept_bus.has(branch["to"]):
			kept_branches.append(branch)
	var needs := _branch_needs(kept_branches, gen_mva, load_mva)

	var lines := {"lines": []}
	var line_seq := 0
	for branch: Dictionary in kept_branches:
		# authored upgrades win where the local flow estimate cannot see
		# meshed transfers (ledger 45); the estimator still sizes bridges.
		# CABLES get a lower floor: one 400 kV cable circuit carries ~2x an
		# overhead circuit, and every parallel cable adds ~11 MVAr/km of
		# charging — the overhead min-4 clamp on a 100 km offshore export
		# quadrupled its reactive injection for no capacity reason
		var is_cable: bool = str(branch.get("kind", "")) == "cable_400"
		# a 400 kV XLPE circuit at 1.8 kA carries ~1.2 GVA — twice an
		# overhead circuit — and every parallel cable adds ~10.4 MVAr/km
		# of charging, so sizing cables in overhead units DOUBLED the
		# copper and the reactive injection (vm 3.2 pu, mass trips, the
		# boot blackout). Radial exports run a single circuit in reality.
		var per_circuit: float = CIRCUIT_MVA_CABLE if is_cable else CIRCUIT_MVA
		var floor_par: int = 1 if is_cable else DEFAULT_PARALLEL
		var circuits: int = clampi(maxi(
			int(ceil(needs[line_seq] / (per_circuit * CIRCUIT_UTILISATION))),
			int(branch.get("authored", 0))),
			floor_par, MAX_PARALLEL)
		var entry := {
			"id": "L%d" % line_seq,
			"from_bus": "b%d" % bus_rename[branch["from"]],
			"to_bus": "b%d" % bus_rename[branch["to"]],
			"length_km": snappedf(int(branch["steps"]) * world.tile_km * SINUOSITY, 0.01),
			"std_type": "490-AL1/64-ST1A 380.0",
			"parallel": circuits,
		}
		if str(branch.get("kind", "")) == "cable_400":
			# underground 380 kV XLPE: explicit parameters (the backend's
			# from-parameters path) — low series impedance, ~20x the OHL
			# charging, which the shunt compensation absorbs like any line.
			# A line<->cable transition forms a bus via the kind-change rule,
			# so a branch is never mixed.
			entry["std_type"] = null
			entry["r_ohm_per_km"] = 0.014
			entry["x_ohm_per_km"] = 0.12
			entry["c_nf_per_km"] = 230.0
			entry["max_i_ka"] = 1.8
		lines["lines"].append(entry)
		line_seq += 1
	if lines["lines"].is_empty():
		return {"ok": false, "error": "no branches between buses", "warnings": warnings}

	var demand := StartupProfiles._demand_profiles(world, kept_zones, demand_sampler)
	var dispatch := StartupProfiles._dispatch_profiles(world, kept_plants, demand["total"],
		StartupProfiles._home_zones(world, kept_plants, kept_zones), demand, kept_zones)

	var plants_doc := {"plants": []}
	for pid: String in kept_plants:
		var p: Dictionary = world.plants[pid]
		var row := {
			"id": pid, "name": pid, "bus": "b%d" % bus_rename[plant_bus[pid]],
			"kind": str(p["kind"]), "p_max_mw": float(p["p_max_mw"]),
			"p_min_mw": 0.0, "vm_pu": 1.02,
			"profile_p_mw": dispatch[pid],
		}
		if str(p.get("fuel", "")) == "h2":
			var cavern := str(p.get("h2_store_id", ""))
			if world.plants.has(cavern) \
					and str(world.plants[cavern]["kind"]) == "h2_cavern":
				row["fuel"] = "h2"
				row["h2_store_id"] = cavern
			else:
				# a dangling store reference would 400 the whole reset
				warnings.append("plant %s: h2 store %s missing — kept on gas" % [pid, cavern])
		plants_doc["plants"].append(row)

	var load_centers_doc := {"resolution_minutes": 15, "steps": STEPS,
		"items": []}
	for lc_id: String in kept_zones:
		load_centers_doc["items"].append({"name": lc_id, "zone": lc_id,
			"p_mw": demand[lc_id]})

	var scenario := {"name": "built_world", "steps_per_day": STEPS,
		"description": "player-built grid (P5)",
		# long EHV corridors need their charging compensated (shunt
		# reactors at the stations) or the PF drowns in Mvar — the
		# realistic continental grid measured 87 GVAr uncompensated;
		# FULL compensation (swept 0.84/0.9/0.95/1.0 on the live bundle:
		# night-peak vm 1.105/1.087/1.070/1.053) — the overvoltage was the
		# REMAINING charging (Ferranti at light load), so more, not less
		"shunt_comp": 1.0}

	# --- 7. wire devices (P7): storage, H2 chain, HVDC links + hubs -----
	var wire: Dictionary = WireDeviceEmit.emit(world, hvdc_corridors, farm_hub,
		device_bus, bus_rename, warnings)
	var devices: Array = wire["devices"]

	return {
		"ok": true,
		"native": {"grid": grid, "lines": lines, "plants": plants_doc,
			"load_centers": load_centers_doc, "scenario": scenario},
		"devices": devices,
		"hub_farms": wire["hub_farms"],
		"zones": grid["zones"],
		"interpretation": {
			"n_buses": bus_names.size(),
			"bus_of_tile": bus_of_tile,
			"bus_rename": bus_rename,
			"dropped_zones": dropped_zones,
			"plant_bus": plant_bus,
			"device_bus": device_bus,
		},
		"warnings": warnings,
	}


## MVA each branch may be asked to carry, one entry per branch in order.
##
## A branch whose removal SPLITS the network is a bridge, and power balance
## pins its flow exactly: everything one side generates and does not consume
## has to cross it. So the bound is max(gen, load) on the smaller-capability
## side — the spur out of a 4.8 GW nuclear cluster must be able to evacuate
## 4.8 GW whatever the metro beyond it is doing. Meshed branches share their
## flow with the parallel path and keep the default.
##
## Sizing this from bus-local capacity instead was the obvious first try and
## silently did nothing: every spur runs plant bus -> junction -> ... ->
## metro bus, and a junction has no capacity of its own, so `min()` over the
## two ends was zero for exactly the branches that were overloading.
static func _branch_needs(branches: Array[Dictionary], gen_mva: Dictionary,
		load_mva: Dictionary) -> Array[float]:
	var needs: Array[float] = []
	var adjacency := {}  # bus -> Array of [branch index, other bus]
	for i in range(branches.size()):
		var u: int = branches[i]["from"]
		var v: int = branches[i]["to"]
		if not adjacency.has(u):
			adjacency[u] = []
		if not adjacency.has(v):
			adjacency[v] = []
		(adjacency[u] as Array).append([i, v])
		(adjacency[v] as Array).append([i, u])
	for i in range(branches.size()):
		# reachable from `from` without using branch i
		var start: int = branches[i]["from"]
		var target: int = branches[i]["to"]
		var seen := {start: true}
		var stack: Array[int] = [start]
		while not stack.is_empty():
			var bus: int = stack.pop_back()
			for edge: Array in adjacency.get(bus, []):
				if int(edge[0]) == i or seen.has(int(edge[1])):
					continue
				seen[int(edge[1])] = true
				stack.append(int(edge[1]))
		if seen.has(target):
			needs.append(0.0)  # meshed — the parallel path shares the flow
			continue
		var gen_near := 0.0
		var load_near := 0.0
		var gen_far := 0.0
		var load_far := 0.0
		for bus: int in adjacency:
			if seen.has(bus):
				gen_near += float(gen_mva.get(bus, 0.0))
				load_near += float(load_mva.get(bus, 0.0))
			else:
				gen_far += float(gen_mva.get(bus, 0.0))
				load_far += float(load_mva.get(bus, 0.0))
		needs.append(minf(maxf(gen_near, load_near), maxf(gen_far, load_far)))
	return needs


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



## The ONE nearest-metro rule (Manhattan distance, candidate-list iteration
## order, strict <). StartupProfiles._home_zones and Boundary used private
## hand copies whose candidate DOMAINS had silently drifted — after a zone
## drop, Boundary could home a plant to a metro the topology no longer
## served (the ledger-44 split-brain class). The domain is now a visible
## argument instead of a hidden divergence.
static func nearest_zone(world: Node, tile: Vector2i, zone_ids: Array) -> String:
	var best := ""
	var best_d := 1 << 30
	for lc_id in zone_ids:
		for lc_tile: Vector2i in world.load_centers[lc_id]["tiles"]:
			var d: int = absi(lc_tile.x - tile.x) + absi(lc_tile.y - tile.y)
			if d < best_d:
				best_d = d
				best = str(lc_id)
	return best
