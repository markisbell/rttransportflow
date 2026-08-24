extends P7SmokeBase
## --smoke=hvdc_link: an EMBEDDED point-to-point HVDC bipole between a
## generation-heavy Hamburg and a load-heavy Berlin, in parallel with the AC
## corridor. A setpoint visibly RELIEVES the AC path (loadings move), the
## terminals report the paired ±P injection minus §1.16 losses — and
## tripping the bipole is a flow-redistribution contingency with near-zero
## Δf, NOT an infeed loss (ledger 28).

const TAG := "SMOKE_HVDC_LINK"
const SETPOINT_MW := 800.0


func run() -> void:
	if not await p7_boot(TAG):
		return
	var built := _build()
	if built.is_empty():
		return
	var conv_h: String = built["conv_h"]
	var conv_b: String = built["conv_b"]
	var coal_h: Array = built["coal_h"]
	var coal_b: Array = built["coal_b"]
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)

	# the builder must have paired the two stations into ONE link
	var link_id := ""
	var length_km := 0.0
	var n_hvdc := 0
	for dev: Dictionary in registered.get("devices", []):
		if str(dev.get("kind", "")) == "hvdc":
			n_hvdc += 1
			link_id = str(dev["params"]["link_id"])
			length_km = float(dev["params"]["length_km"])
	check("link_paired", n_hvdc == 2 and link_id != "")
	var loss_frac := hvdc_path_loss_frac(length_km)

	# --- baseline: AC carries the Berlin import --------------------------
	await p7_block("base")
	var base: Dictionary = await p7_block("base")
	if base.get("_status", 0) != 200:
		_fail(TAG, "baseline step failed")
		return
	# Relief is measured on the INTER-CITY TRANSIT, not on the single hottest
	# branch in the network. Since branch ratings became demand-driven the
	# hottest line is usually a plant-cluster spur, whose flow the DC draw
	# barely touches (it even rises — the sending terminal pulls through it);
	# the transit is what the bipole is parallel to. Long branches are the
	# transit: plant spurs are a few tiles, the routes between two metros are
	# hundreds of kilometres.
	var transit := _transit_lines(registered)
	if transit.is_empty():
		_fail(TAG, "no inter-city transit lines in the build")
		return
	var sched_base := _schedule(coal_h, coal_b)
	var base_lines := _loadings(base)
	var hot_line := _max_line(base_lines)
	if hot_line == "":
		_fail(TAG, "no PF lines in the baseline result")
		return
	var base_loading := _sum_loading(base_lines, transit)

	# --- setpoint: shift the transfer onto the DC pair -------------------
	# The setpoint reaches the wire through the dispatcher's 15-min schedule
	# and is RAMPED in, so the block in which it is set still carries the old
	# (zero) transfer. Wait for it to actually appear on the wire rather than
	# assuming a fixed number of blocks: how many the schedule needs depends
	# on where the smoke's clock sits inside the block.
	Dispatch.link_setpoints[conv_h] = SETPOINT_MW
	var relieved: Dictionary = {}
	for _i in range(4):
		relieved = await p7_block("setpoint")
		print("HVDC setpoint wait: commanded=",
			Dispatch.last_commands.get(conv_h, {}).get("dispatch_mw", "none"),
			" p_mw=", relieved.get("devices", {}).get(conv_h, {}).get("p_mw"))
		if absf(numf(relieved.get("devices", {}).get(conv_h, {}), "p_mw", 0.0)) > 1.0:
			break
	if relieved.get("_status", 0) != 200:
		_fail(TAG, "setpoint step failed")
		return
	var relieved_loading := _sum_loading(_loadings(relieved), transit)
	var island_b: Dictionary = base.get("islands", {}).get("0", {})
	var island_r: Dictionary = relieved.get("islands", {}).get("0", {})
	var p_send := numf(relieved.get("devices", {}).get(conv_h, {}), "p_mw", 0.0)
	var p_recv := numf(relieved.get("devices", {}).get(conv_b, {}), "p_mw", 0.0)
	# What the dispatcher's HVDC netting had to work with. `latest()` is fed
	# by the orchestrator's own tick loop, which a smoke driving step_once()
	# never runs — if it is empty the netting falls back to the SETPOINT,
	# whose sign convention is the opposite of the wire's for the sending end.
	print("HVDC schedule hamburg/berlin coal: base=", sched_base,
		" with_link=", _schedule(coal_h, coal_b),
		" wire_devices=", Dispatch.wire_devices.size(),
		" hvdc_devices=", _hvdc_device_count())
	print("HVDC ledger: latest_devices=",
		(Orchestrator.latest().get("devices", {}) as Dictionary).size(),
		" latest_p=", Orchestrator.latest().get("devices", {}).get(conv_h, {}).get("p_mw"),
		" home_zone=", Dispatch.home_zone.get(conv_h, "<none>"),
		" setpoints=", Dispatch.link_setpoints)
	print("HVDC transit_lines=", transit.size(), " hottest=", hot_line,
		" base=", base_loading, " relieved=", relieved_loading,
		" p_send=", p_send, " p_recv=", p_recv,
		" f_base=", island_b.get("f_hz"), " f_relieved=", island_r.get("f_hz"),
		" load=", island_b.get("p_load_mw"))
	check("ac_relieved", base_loading - relieved_loading > 4.0)
	check("sending_end_draws", absf(p_send + SETPOINT_MW) < 40.0)
	check("receiving_end_injects",
		absf(p_recv - SETPOINT_MW * (1.0 - loss_frac)) < 40.0)
	# neutrality is measured against the island's AMBIENT operating point —
	# a small island idles ~0.1 Hz low with standing droop response (the
	# dispatcher's 15-min energy allocation is never exact; aFRR lands in P8)
	# Neutrality measured as a frequency SPREAD, not an absolute level: over
	# the ~45 min this takes, the demand curve moves the island's operating
	# point on its own (and the dispatcher's 15-min allocation is never
	# exact), so comparing f_hz across blocks tests the demand curve rather
	# than the link. What ledger 28 actually claims is that shifting 800 MW
	# onto the bipole does not DISTURB the island — its ±P pair cancels in
	# the COI — so the block carrying the transfer must not swing any wider
	# than the quiet baseline block did.
	var spread_base := numf(island_b, "f_max", 50.0) - numf(island_b, "f_min", 50.0)
	var spread_set := numf(island_r, "f_max", 50.0) - numf(island_r, "f_min", 50.0)
	print("HVDC spread base=", spread_base, " setpoint=", spread_set)
	check("setpoint_frequency_neutral", spread_set < spread_base + 0.05)

	# --- trip the bipole: flows redistribute, frequency barely moves -----
	# The ledger-28 contrast: an 800 MW INFEED loss would saturate this
	# island's 400 MW FCR and crater it toward the 47.5 Hz relays (exactly
	# what battery_response run A shows for 490 MW). The embedded ±P pair
	# cancels — only the loss delta (~66 MW) lands on the COI ledger.
	Orchestrator.inject([{"at_s_rel": 30.0, "kind": "trip", "element": conv_h}])
	var trip_step: Dictionary = await p7_step(600.0, "trip")
	if trip_step.get("_status", 0) != 200:
		_fail(TAG, "trip step failed")
		return
	var island_t: Dictionary = trip_step.get("islands", {}).get("0", {})
	var f_min_trip := numf(island_t, "f_min", 50.0)
	var stray_trips := 0
	for event: Dictionary in trip_step.get("events", []):
		if str(event.get("kind", "")) == "trip" \
				and str(event.get("element", "")) != conv_h:
			stray_trips += 1
	var after: Dictionary = await p7_block("after")
	if after.get("_status", 0) != 200:
		_fail(TAG, "post-trip step failed")
		return
	var island_a: Dictionary = after.get("islands", {}).get("0", {})
	var after_loading := _sum_loading(_loadings(after), transit)
	print("HVDC after_trip=", after_loading, " f_min_trip=", f_min_trip,
		" after_f_min=", island_a.get("f_min"))
	check("terminals_dead", numf(after.get("devices", {}).get(conv_h, {}), "p_mw", 1.0) == 0.0
		and numf(after.get("devices", {}).get(conv_b, {}), "p_mw", 1.0) == 0.0)
	check("flows_redistribute_back", after_loading - relieved_loading > 1.0)
	# ledger 28, measured AMBIENT-RELATIVE (P7 discovery 5: small islands
	# idle off-nominal, and the corrected-projection demand parks this
	# fixture's island ABOVE 50 Hz — the old absolute [49.5, 50.5] window
	# tested the operating point, not the trip): an 800 MW infeed loss
	# would swing this island by well over a Hz (battery_response run A
	# craters 1.25 Hz on ~370 MW); the embedded pair's COI cancellation
	# must keep the trip window's swing around its pre-trip point tight.
	var f_pre := numf(island_r, "f_hz", 50.0)
	check("trip_is_not_an_infeed_loss",
		absf(f_min_trip - f_pre) < 0.4
		and absf(numf(island_t, "f_max", 50.0) - f_pre) < 0.4)
	check("no_cascade", stray_trips == 0
		and numf(island_a, "f_min", 0.0) > 49.0
		and not bool(island_a.get("blackout", false)))
	_finish(TAG, {"base_loading": base_loading, "relieved": relieved_loading,
		"after_trip": after_loading, "f_min_trip": f_min_trip,
		"loss_frac": loss_frac})


## A second, disjoint AC route between the same two taps, bowed ~150 km off
## the direct one so the pair forms a genuine cycle. The bow direction is
## SEARCHED, not assumed: the DC cable is laid first and a tile carries one
## corridor kind, so the bipole is a wall between the cities — a waypoint on
## its far side cannot be reached at all, and only the side the taps sit on
## routes. Both legs are checked before any copper goes down.
func _mesh_route(tap_h: Vector2i, tap_b: Vector2i, avoid: Dictionary) -> bool:
	var bow := DemoBuild.tiles_for_km(150.0, World)
	var mid := Vector2i((tap_h.x + tap_b.x) / 2, (tap_h.y + tap_b.y) / 2)
	for direction: Vector2i in [Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 0), Vector2i(-1, 0)]:
		for extra in range(0, bow):
			var waypoint: Vector2i = mid + direction * (bow - extra)
			if not World.can_place_corridor(waypoint) or avoid.has(waypoint):
				continue
			var first: Array[Vector2i] = DemoBuild.route(World, tap_h, waypoint,
				false, avoid)
			if first.is_empty():
				continue
			var second: Array[Vector2i] = DemoBuild.route(World, waypoint, tap_b,
				false, avoid)
			if second.is_empty():
				continue
			for tile: Vector2i in first:
				World.place_corridor(tile)
			for tile: Vector2i in second:
				World.place_corridor(tile)
			return true
	return false


func _converter_beside(tap: Vector2i) -> String:
	for offset: Vector2i in GridTopology.NEIGHBORS:
		var site: Vector2i = tap + offset
		if not World.can_place_plant("hvdc_converter", site):
			continue
		var has_exit := false
		for other: Vector2i in GridTopology.NEIGHBORS:
			if _hvdc_free(site + other):
				has_exit = true
		if has_exit:
			return World.place_plant("hvdc_converter", site)
	return ""


func _schedule(coal_h: Array, coal_b: Array) -> Dictionary:
	var hamburg := 0.0
	var berlin := 0.0
	for pid: String in coal_h:
		hamburg += float(Dispatch.last_commands.get(pid, {}).get("dispatch_mw", 0.0))
	for pid: String in coal_b:
		berlin += float(Dispatch.last_commands.get(pid, {}).get("dispatch_mw", 0.0))
	return {"hamburg": snappedf(hamburg, 0.1), "berlin": snappedf(berlin, 0.1)}


func _hvdc_device_count() -> int:
	var n := 0
	for device: Dictionary in Dispatch.wire_devices:
		if str(device.get("kind", "")) == "hvdc":
			n += 1
	return n


func _loadings(result: Dictionary) -> Dictionary:
	var out := {}
	var lines: Dictionary = result.get("pf", {}).get("latest", {}).get("lines", {})
	for line_id: String in lines:
		out[line_id] = numf(lines[line_id], "loading_percent", 0.0)
	return out


## The AC branches on the bus path between the two metros — the path the
## bipole runs parallel to. Length cannot identify it: at 5 km tiles a plant
## spur reaches 200 km too, and a ">= 100 km" filter selected all twelve
## branches, including the Hamburg cluster spurs whose flow the sending
## terminal INCREASES. So walk the bus graph instead.
func _transit_lines(registered: Dictionary) -> Dictionary:
	var native: Dictionary = registered.get("native", {})
	var bus_of := {}
	for zone: Dictionary in native.get("grid", {}).get("zones", []):
		bus_of[str(zone["id"])] = str(zone["bus"])
	if not (bus_of.has("hamburg") and bus_of.has("berlin")):
		return {}
	var adjacency := {}
	for line: Dictionary in native.get("lines", {}).get("lines", []):
		var from_bus := str(line["from_bus"])
		var to_bus := str(line["to_bus"])
		if not adjacency.has(from_bus):
			adjacency[from_bus] = []
		if not adjacency.has(to_bus):
			adjacency[to_bus] = []
		(adjacency[from_bus] as Array).append([to_bus, str(line["id"])])
		(adjacency[to_bus] as Array).append([from_bus, str(line["id"])])
	var start := str(bus_of["hamburg"])
	var goal := str(bus_of["berlin"])
	var came := {start: ["", ""]}
	var queue: Array[String] = [start]
	while not queue.is_empty():
		var bus: String = queue.pop_front()
		if bus == goal:
			break
		for hop: Array in adjacency.get(bus, []):
			var next_bus := str(hop[0])
			if came.has(next_bus):
				continue
			came[next_bus] = [bus, str(hop[1])]
			queue.append(next_bus)
	if not came.has(goal):
		return {}
	var out := {}
	var walk := goal
	while walk != start:
		var step: Array = came[walk]
		out[str(step[1])] = true
		walk = str(step[0])
	return out


func _sum_loading(loadings: Dictionary, ids: Dictionary) -> float:
	var total := 0.0
	for line_id: String in ids:
		total += float(loadings.get(line_id, 0.0))
	return total


func _max_line(loadings: Dictionary) -> String:
	var best := ""
	var best_v := -1.0
	for line_id: String in loadings:
		if float(loadings[line_id]) > best_v:
			best_v = float(loadings[line_id])
			best = line_id
	return best


## Hamburg exports to Berlin: 6.4 GW thermal at Hamburg, thin 1.6 GW backup
## at Berlin, one AC trunk between them, one embedded DC bipole SOUTH of it.
func _build() -> Dictionary:
	World.clear_build()
	for lc_id: String in ["hamburg", "berlin"]:
		if not World.load_centers.has(lc_id):
			_fail(TAG, "map has no " + lc_id)
			return {}
	var ham: Dictionary = World.load_centers["hamburg"]
	var ber: Dictionary = World.load_centers["berlin"]
	var tap_h := DemoBuild.tap_for(World, ham["tiles"])
	var tap_b := DemoBuild.tap_for(World, ber["tiles"])
	World.place_corridor(tap_h)
	World.place_corridor(tap_b)
	var avoid := foreign_avoid(["hamburg", "berlin"])

	# Converters off the direct axis (~100 km south, ~50 km to the side), each
	# spurred into its city's AC network.
	#
	# KNOWN LIMITATION (`ac_relieved` has PASSED since the corrected-demand
	# re-baseline — 23.2 vs the 4.0 threshold, twice — but the margin exists
	# despite, not because of, the delivery point): that spur is
	# routed with `stop_at_existing`, which ends at the FIRST corridor tile it
	# meets — for conv_b that is the southern mesh route, not Berlin. So the
	# bipole delivers its 772 MW halfway down the corridor instead of at the
	# load, and the Berlin import it exists to displace barely moves (transit
	# 66.5 % -> 63.3 % for an 800 MW transfer). Kirchhoff, not the dispatcher:
	# the injection has to arrive where the load is. The fix is to give each
	# converter the metro's own bus by placing it on a tile touching the city
	# tap — which needs the DC cable's exit tile RESERVED before the AC web
	# is laid, since a tile carries one corridor kind and the spurs pave every
	# neighbour of the tap otherwise.
	var off := DemoBuild.tiles_for_km(100.0, World)
	var side := DemoBuild.tiles_for_km(50.0, World)
	var conv_h_site := DemoBuild.find_site(World, "hvdc_converter",
		(ham["tiles"][0] as Vector2i) + Vector2i(-side, off),
		DemoBuild.tiles_for_km(80.0, World))
	var conv_b_site := DemoBuild.find_site(World, "hvdc_converter",
		(ber["tiles"][0] as Vector2i) + Vector2i(side, off),
		DemoBuild.tiles_for_km(80.0, World))
	if conv_h_site == Vector2i(-1, -1) or conv_b_site == Vector2i(-1, -1):
		_fail(TAG, "no converter sites")
		return {}
	var conv_h: String = World.place_plant("hvdc_converter", conv_h_site)
	var conv_b: String = World.place_plant("hvdc_converter", conv_b_site)

	# ONE thermal tier across both cities (mixed tiers destabilize small
	# islands at block boundaries — see battery_response); Hamburg heavy,
	# Berlin thin (2 units against its own multi-GW load) so the import is
	# ~1.8 GW and the meshed AC path runs at a loading worth relieving, and
	# Hamburg deliberately over-built: at 8+1 the two cities together needed
	# more than the fleet's nameplate and the island sat at 48.2 Hz shedding
	# load — a congested test grid still has to be an ADEQUATE one.
	var coal_h: Array[String] = place_ring("coal", 10, ham["tiles"][0], tap_h, avoid)
	var coal_b: Array[String] = place_ring("coal", 2, ber["tiles"][0], tap_b, avoid)
	if coal_h.size() < 10 or coal_b.size() < 2:
		_fail(TAG, "site exhaustion: coal_h=%d coal_b=%d"
			% [coal_h.size(), coal_b.size()])
		return {}

	# AC path between the cities FIRST — TWO routes, not one. The topology
	# builder sizes a BRIDGE branch to the transfer it has to carry (up to 12
	# circuits), so a single trunk is widened until it physically cannot
	# congest, and a DC link that relieves nothing measures nothing. Two
	# disjoint routes are a mesh: each keeps the default 4 circuits
	# (~2.25 GVA) and they SHARE the Berlin import, which is the operating
	# point the bipole is supposed to take over.
	for tile: Vector2i in DemoBuild.route(World, tap_h, tap_b, false, avoid):
		World.place_corridor(tile)
	if not _mesh_route(tap_h, tap_b, avoid):
		_fail(TAG, "could not lay the parallel AC route")
		return {}
	for pair: Array in [[conv_h_site, tap_h], [conv_b_site, tap_b]]:
		var conv_tap := free_neighbor(pair[0])
		if conv_tap == Vector2i(-1, -1):
			_fail(TAG, "converter has no free AC tap neighbor")
			return {}
		for tile: Vector2i in DemoBuild.route(World, conv_tap, pair[1], true, avoid):
			World.place_corridor(tile)

	# the DC bipole, laid last over whatever ground the AC web left
	var dc_from := hvdc_neighbor(conv_h_site)
	var dc_to := hvdc_neighbor(conv_b_site)
	if dc_from == Vector2i(-1, -1) or dc_to == Vector2i(-1, -1) \
			or not lay_hvdc(dc_from, dc_to):
		_fail(TAG, "could not lay the DC corridor")
		return {}

	return {"conv_h": conv_h, "conv_b": conv_b,
		"coal_h": coal_h, "coal_b": coal_b}
