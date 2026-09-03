class_name WireDeviceEmit
extends RefCounted
## The reset `devices` channel emission (P7): storage, the H2 chain, HVDC
## links and offshore hubs from the built world. Moved out of
## grid_topology.gd verbatim (see StartupProfiles for the rationale); the
## devices array is asserted semantically by GdUnit, not byte-pinned.


static func emit(world: Node, hvdc_corridors: Dictionary, farm_hub: Dictionary,
		device_bus: Dictionary, bus_rename: Dictionary,
		warnings: Array[String]) -> Dictionary:
	var devices: Array[Dictionary] = []
	var caverns: Array[String] = []
	for pid: String in world.plants:
		if str(world.plants[pid]["kind"]) == "h2_cavern":
			caverns.append(pid)
	caverns.sort()
	for pid: String in caverns:
		devices.append({"id": pid, "kind": "h2_store", "params": {
			"capacity_kg": float(world.plants[pid]["capacity_kg"]),
			# a fresh cavern starts at the recovery threshold: nothing to
			# burn until the electrolyzers fill it (PHYSICS §2.8 floor rule)
			"level_kg": 0.07 * float(world.plants[pid]["capacity_kg"]),
		}})
	var device_ids: Array[String] = []
	device_ids.assign(device_bus.keys())
	device_ids.sort()
	for pid: String in device_ids:
		var p: Dictionary = world.plants[pid]
		var node := "b%d" % bus_rename[device_bus[pid]]
		match str(p["kind"]):
			"battery", "grid_forming":
				# C6: grid_forming is the P7 backend device kind (virtual
				# inertia H_v = 4 s counted into island E_k); same params
				# as a battery, the catalog key battery_gfm carries the rest
				devices.append({"id": pid, "kind": str(p["kind"]), "node": node,
					"params": {"p_max_mw": float(p["p_max_mw"]),
						"e_mwh": float(p.get("e_mwh", float(p["p_max_mw"]) * 2.0))}})
			"electrolyzer":
				if caverns.is_empty():
					warnings.append("electrolyzer %s: no cavern anywhere — dropped" % pid)
					continue
				devices.append({"id": pid, "kind": "electrolyzer", "node": node,
					"params": {"p_max_mw": float(p["p_max_mw"]),
						"h2_store_id": _nearest_cavern(world, caverns, p["tile"])}})
			# hvdc_converter: emitted by the link/hub pass below
	var hvdc_result := _hvdc_devices(world, hvdc_corridors, farm_hub,
		device_bus, bus_rename, warnings)
	devices.append_array(hvdc_result["devices"])
	return {"devices": devices, "hub_farms": hvdc_result["hub_farms"]}


static func _nearest_cavern(world: Node, caverns: Array[String],
		tile: Vector2i) -> String:
	# H2 transport (pipeline/trucking) is abstracted: an electrolyzer feeds
	# its NEAREST cavern (deterministic tie-break by pid sort order).
	var best := caverns[0]
	var best_d := 1 << 30
	for pid: String in caverns:
		var d: Vector2i = (world.plants[pid]["tile"] as Vector2i) - tile
		var manhattan := absi(d.x) + absi(d.y)
		if manhattan < best_d:
			best_d = manhattan
			best = pid
	return best


## HVDC pass: flood-fill `hvdc` corridor components; a component with exactly
## two stations becomes a point-to-point link (2 onshore converters) or an
## offshore hub (platform + onshore converter) per §1.16. Everything else
## warns and is dropped — never a half-registered link.
static func _hvdc_devices(world: Node, hvdc_corridors: Dictionary,
		farm_hub: Dictionary, device_bus: Dictionary, bus_rename: Dictionary,
		warnings: Array[String]) -> Dictionary:
	var devices: Array[Dictionary] = []
	var hub_farms := {}
	var used_stations := {}
	var seen := {}
	for start: Vector2i in GridTopology._sorted_tiles(hvdc_corridors):
		if seen.has(start):
			continue
		# flood-fill one component
		var tiles: Array[Vector2i] = []
		var stack: Array[Vector2i] = [start]
		while not stack.is_empty():
			var current: Vector2i = stack.pop_back()
			if seen.has(current):
				continue
			seen[current] = true
			tiles.append(current)
			for offset: Vector2i in GridTopology.NEIGHBORS:
				var n := current + offset
				if hvdc_corridors.has(n) and not seen.has(n):
					stack.append(n)
		# stations adjacent to the component
		var stations: Array[String] = []
		for tile: Vector2i in tiles:
			for offset: Vector2i in GridTopology.NEIGHBORS:
				var pid := str(world.plant_at(tile + offset))
				if pid == "" or stations.has(pid) or used_stations.has(pid):
					continue
				if str(world.plants[pid]["kind"]) in ["hvdc_converter", "offshore_platform"]:
					stations.append(pid)
		stations.sort()
		if stations.size() != 2:
			warnings.append("hvdc corridor (%d tiles) touches %d stations — needs exactly 2"
				% [tiles.size(), stations.size()])
			continue
		var length_km := snappedf(tiles.size() * world.tile_km * GridTopology.SINUOSITY, 0.01)
		var kinds: Array[String] = [str(world.plants[stations[0]]["kind"]),
			str(world.plants[stations[1]]["kind"])]
		if kinds[0] == "hvdc_converter" and kinds[1] == "hvdc_converter":
			if not (device_bus.has(stations[0]) and device_bus.has(stations[1])):
				warnings.append("hvdc link %s-%s: a terminal has no AC bus — dropped"
					% [stations[0], stations[1]])
				continue
			var p_max := minf(float(world.plants[stations[0]]["p_max_mw"]),
				float(world.plants[stations[1]]["p_max_mw"]))
			var link_id := "link_%s_%s" % [stations[0], stations[1]]
			for pid: String in stations:
				devices.append({"id": pid, "kind": "hvdc",
					"node": "b%d" % bus_rename[device_bus[pid]],
					"params": {"link_id": link_id, "p_max_mw": p_max,
						"length_km": length_km}})
				used_stations[pid] = true
		elif "offshore_platform" in kinds and "hvdc_converter" in kinds:
			var platform: String = stations[0] if kinds[0] == "offshore_platform" else stations[1]
			var onshore: String = stations[1] if kinds[0] == "offshore_platform" else stations[0]
			if not device_bus.has(onshore):
				warnings.append("hub %s: onshore converter %s has no AC bus — dropped"
					% [platform, onshore])
				continue
			var farms: Array[String] = []
			var farm_mw := 0.0
			for farm_pid: String in farm_hub:
				if str(farm_hub[farm_pid]) == platform:
					farms.append(farm_pid)
					farm_mw += float(world.plants[farm_pid]["p_max_mw"])
			farms.sort()
			var platform_mw := float(world.plants[platform]["p_max_mw"])
			if farm_mw > platform_mw:
				warnings.append("hub %s over-subscribed: %.0f MW farms on a %.0f MW platform"
					% [platform, farm_mw, platform_mw])
			devices.append({"id": platform, "kind": "offshore_hub",
				"node": "b%d" % bus_rename[device_bus[onshore]],
				"params": {"p_max_mw": minf(platform_mw,
						float(world.plants[onshore]["p_max_mw"])),
					"platform_mw": platform_mw, "cable_km": length_km}})
			hub_farms[platform] = farms
			used_stations[platform] = true
			used_stations[onshore] = true
		else:
			warnings.append("hvdc corridor joins two platforms (%s, %s) — dropped"
				% [stations[0], stations[1]])
	for pid: String in world.plants:
		var kind := str(world.plants[pid]["kind"])
		if kind in ["hvdc_converter", "offshore_platform"] \
				and not used_stations.has(pid):
			warnings.append("%s %s is not part of any HVDC link or hub" % [kind, pid])
	for farm_pid: String in farm_hub:
		if not hub_farms.has(str(farm_hub[farm_pid])):
			warnings.append("farm %s bound to %s which is not a working hub — idle"
				% [farm_pid, farm_hub[farm_pid]])
	return {"devices": devices, "hub_farms": hub_farms}


