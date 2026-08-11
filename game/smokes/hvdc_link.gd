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
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return

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
	var loss_frac := 0.02 + 0.003 * length_km / 100.0

	# --- baseline: AC carries the Berlin import --------------------------
	await Orchestrator.step_once(900.0)
	var base: Dictionary = await Orchestrator.step_once(900.0)
	if base.get("_status", 0) != 200:
		_fail(TAG, "baseline step failed")
		return
	var base_lines := _loadings(base)
	var hot_line := _max_line(base_lines)
	if hot_line == "":
		_fail(TAG, "no PF lines in the baseline result")
		return
	var base_loading: float = base_lines[hot_line]

	# --- setpoint: shift the transfer onto the DC pair -------------------
	Dispatch.link_setpoints[conv_h] = SETPOINT_MW
	var relieved: Dictionary = await Orchestrator.step_once(900.0)
	if relieved.get("_status", 0) != 200:
		_fail(TAG, "setpoint step failed")
		return
	var relieved_loading: float = _loadings(relieved).get(hot_line, base_loading)
	var p_send := numf(relieved.get("devices", {}).get(conv_h, {}), "p_mw", 0.0)
	var p_recv := numf(relieved.get("devices", {}).get(conv_b, {}), "p_mw", 0.0)
	print("HVDC base=", base_loading, " relieved=", relieved_loading,
		" p_send=", p_send, " p_recv=", p_recv)
	check("ac_relieved", base_loading - relieved_loading > 2.0)
	check("sending_end_draws", absf(p_send + SETPOINT_MW) < 40.0)
	check("receiving_end_injects",
		absf(p_recv - SETPOINT_MW * (1.0 - loss_frac)) < 40.0)
	# neutrality is measured against the island's AMBIENT operating point —
	# a small island idles ~0.1 Hz low with standing droop response (the
	# dispatcher's 15-min energy allocation is never exact; aFRR lands in P8)
	var island_b: Dictionary = base.get("islands", {}).get("0", {})
	var island_r: Dictionary = relieved.get("islands", {}).get("0", {})
	var f_ambient := numf(island_b, "f_hz", 50.0)
	check("setpoint_frequency_neutral",
		absf(numf(island_r, "f_hz", 50.0) - f_ambient) < 0.1)

	# --- trip the bipole: flows redistribute, frequency barely moves -----
	# The ledger-28 contrast: an 800 MW INFEED loss would saturate this
	# island's 400 MW FCR and crater it toward the 47.5 Hz relays (exactly
	# what battery_response run A shows for 490 MW). The embedded ±P pair
	# cancels — only the loss delta (~66 MW) lands on the COI ledger.
	Orchestrator.inject([{"at_s_rel": 30.0, "kind": "trip", "element": conv_h}])
	var trip_step: Dictionary = await Orchestrator.step_once(600.0)
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
	var after: Dictionary = await Orchestrator.step_once(900.0)
	if after.get("_status", 0) != 200:
		_fail(TAG, "post-trip step failed")
		return
	var island_a: Dictionary = after.get("islands", {}).get("0", {})
	var after_loading: float = _loadings(after).get(hot_line, relieved_loading)
	print("HVDC after_trip=", after_loading, " f_min_trip=", f_min_trip,
		" after_f_min=", island_a.get("f_min"))
	check("terminals_dead", numf(after.get("devices", {}).get(conv_h, {}), "p_mw", 1.0) == 0.0
		and numf(after.get("devices", {}).get(conv_b, {}), "p_mw", 1.0) == 0.0)
	check("flows_redistribute_back", after_loading - relieved_loading > 1.0)
	check("trip_is_not_an_infeed_loss",
		f_min_trip > 49.5 and numf(island_t, "f_max", 50.0) < 50.5)
	check("no_cascade", stray_trips == 0
		and numf(island_a, "f_min", 0.0) > 49.0
		and not bool(island_a.get("blackout", false)))
	_finish(TAG, {"base_loading": base_loading, "relieved": relieved_loading,
		"after_trip": after_loading, "f_min_trip": f_min_trip,
		"loss_frac": loss_frac})


func _loadings(result: Dictionary) -> Dictionary:
	var out := {}
	var lines: Dictionary = result.get("pf", {}).get("latest", {}).get("lines", {})
	for line_id: String in lines:
		out[line_id] = numf(lines[line_id], "loading_percent", 0.0)
	return out


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

	# ONE thermal tier across both cities (mixed tiers destabilize small
	# islands at block boundaries — see battery_response); Hamburg heavy,
	# Berlin thin, so the Berlin import loads the AC path
	var coal_h: Array[String] = place_ring("coal", 8, ham["tiles"][0], tap_h, avoid)
	var coal_b: Array[String] = place_ring("coal", 2, ber["tiles"][0], tap_b, avoid)
	if coal_h.size() < 8 or coal_b.size() < 2:
		_fail(TAG, "site exhaustion: coal_h=%d coal_b=%d"
			% [coal_h.size(), coal_b.size()])
		return {}

	# converters OFF the direct axis (south) so the DC path clears the AC trunk
	var conv_h_site := DemoBuild.find_site(World, "hvdc_converter",
		(ham["tiles"][0] as Vector2i) + Vector2i(-2, 4), 3)
	var conv_b_site := DemoBuild.find_site(World, "hvdc_converter",
		(ber["tiles"][0] as Vector2i) + Vector2i(1, 4), 3)
	if conv_h_site == Vector2i(-1, -1) or conv_b_site == Vector2i(-1, -1):
		_fail(TAG, "no converter sites")
		return {}
	var conv_h: String = World.place_plant("hvdc_converter", conv_h_site)
	var conv_b: String = World.place_plant("hvdc_converter", conv_b_site)

	# AC trunk between the cities FIRST (BFS), then converter AC taps
	for tile: Vector2i in DemoBuild.route(World, tap_h, tap_b, false, avoid):
		World.place_corridor(tile)
	for pair: Array in [[conv_h_site, tap_h], [conv_b_site, tap_b]]:
		var conv_tap := free_neighbor(pair[0])
		if conv_tap == Vector2i(-1, -1):
			_fail(TAG, "converter has no free AC tap neighbor")
			return {}
		for tile: Vector2i in DemoBuild.route(World, conv_tap, pair[1], true, avoid):
			World.place_corridor(tile)

	# the DC bipole, greedily south of everything
	var dc_from := hvdc_neighbor(conv_h_site)
	var dc_to := hvdc_neighbor(conv_b_site)
	if dc_from == Vector2i(-1, -1) or dc_to == Vector2i(-1, -1) \
			or not lay_hvdc(dc_from, dc_to):
		_fail(TAG, "could not lay the DC corridor")
		return {}
	return {"conv_h": conv_h, "conv_b": conv_b}
