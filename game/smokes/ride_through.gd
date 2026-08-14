extends P7SmokeBase
## --smoke=ride_through: RfG converter ride-through — a deep-but-survivable
## under-frequency event (largest sync unit trips, no battery cushion) drags
## the island well under 49.5; the WIND FLEET rides straight through it
## (converters hold 47.5–51.5 per PARAMETERS §2.2) while the defense plan
## does its work. Asserts: the dip was real, wind never tripped, wind kept
## delivering energy through the event window, the island survived.

const TAG := "SMOKE_RIDE_THROUGH"


func run() -> void:
	p7_port = 8038
	if not await p7_boot(TAG):
		return
	# wind lull so the gas fleet carries real load (and the trip removes it)
	for region_def: Dictionary in Weather.REGIONS:
		Weather.force_window("wind_lambda_scale", str(region_def["id"]),
			0.0, 3.0, 0.7)
	if not _build():
		return
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)
	var settle: Dictionary = {}
	for _i in range(2):
		settle = await p7_step(900.0, "settle")
	if settle.get("_status", 0) != 200:
		_fail(TAG, "settle step failed")
		return

	var victim := _largest_sync(settle.get("devices", {}))
	var wind_pids := _wind_pids(settle.get("devices", {}))
	if victim == "" or wind_pids.is_empty():
		print("RIDE devices=", (settle.get("devices", {}) as Dictionary).keys())
		_fail(TAG, "no victim / no wind on the island")
		return
	print("RIDE victim=", victim, " wind_units=", wind_pids.size(),
		" devices=", (settle.get("devices", {}) as Dictionary).keys().size())
	Orchestrator.inject([{"at_s_rel": 20.0, "kind": "trip", "element": victim}])

	var f_min := 100.0
	var wind_tripped := false
	var wind_energy := 0.0
	var ufls_stages := 0
	var results: Array = [await Orchestrator.step_once(300.0)]
	for _i in range(40):
		results.append(await Orchestrator.step_once(1.0))
	results.append(await Orchestrator.step_once(60.0))
	var wind_online_end := true
	var tail: Dictionary = {}
	for result: Dictionary in results:
		if result.get("_status", 0) != 200:
			continue
		tail = result
		f_min = minf(f_min, numf(result.get("islands", {}).get("0", {}), "f_min", 100.0))
		for event: Dictionary in result.get("events", []):
			var kind := str(event.get("kind", ""))
			if kind == "trip" and str(event.get("element", "")).begins_with("wind"):
				wind_tripped = true
			elif kind == "ufls_stage":
				ufls_stages += 1
		for pid: String in wind_pids:
			var device: Dictionary = result.get("devices", {}).get(pid, {})
			wind_energy += numf(device, "energy_mwh_step", 0.0)
	for pid: String in wind_pids:
		var device: Dictionary = tail.get("devices", {}).get(pid, {})
		if str(device.get("state", "")) != "online":
			wind_online_end = false

	check("dip_was_real", f_min < 49.45)
	check("no_collapse", f_min > 47.5
		and not bool(tail.get("islands", {}).get("0", {}).get("blackout", true)))
	check("wind_never_tripped", not wind_tripped)
	check("wind_online_through_event", wind_online_end)
	check("wind_kept_delivering", wind_energy > 1.0)
	_finish(TAG, {"f_min": f_min, "ufls_stages": ufls_stages,
		"wind_mwh": wind_energy, "wind_units": wind_pids.size()})


func _largest_sync(devices: Dictionary) -> String:
	var best := ""
	var best_p := 0.0
	for pid: String in devices:
		var device: Dictionary = devices[pid]
		if str(device.get("state", "")) == "online" and device.has("headroom_mw") \
				and numf(device, "p_mw", 0.0) > best_p:
			best_p = numf(device, "p_mw", 0.0)
			best = pid
	return best


func _wind_pids(devices: Dictionary) -> Array:
	var out: Array = []
	for pid: String in devices:
		if pid.begins_with("wind"):
			out.append(pid)
	return out


## Mixed hamburg island: 6 must-run CCGT + wind, deliberately NO batteries —
## nothing arrests the dip except FCR + damping (+ UFLS if it reaches 49.0),
## which is exactly the depth the ride-through assertion needs.
func _build() -> bool:
	World.clear_build()
	Dispatch.plant_mode.clear()
	var lc_id := "hamburg"
	if not World.load_centers.has(lc_id):
		_fail(TAG, "map has no hamburg")
		return false
	var lc: Dictionary = World.load_centers[lc_id]
	var anchor: Vector2i = lc["tiles"][0]
	var avoid := foreign_avoid([lc_id])
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"], avoid)
	World.place_corridor(lc_tap)
	var gas: Array[String] = place_ring("gas_ccgt", 6, anchor, lc_tap, avoid)
	if gas.size() < 6:
		_fail(TAG, "site exhaustion: gas=%d" % gas.size())
		return false
	for pid: String in gas:
		Dispatch.plant_mode[pid] = "must_run"
	var wind: Array[String] = place_ring("wind_onshore", 10, anchor, lc_tap, avoid)
	if wind.size() < 8:
		_fail(TAG, "site exhaustion: wind=%d" % wind.size())
		return false
	return true
