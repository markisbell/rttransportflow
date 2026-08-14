extends P7SmokeBase
## --smoke=replay_panel: the counterfactual replay chain end-to-end through
## the REAL panel fetch path (views/replay_panel.gd): trip the largest unit
## on a battery-backed island, fetch the aftermath replay + the
## "without the biggest battery" ghost via POST /gb/replay, and verify
## (a) the plain replay reproduces the live nadir (same engine!), (b) the
## no-battery ghost dips deeper, (c) a fresh window still replays after
## stepping on, (d) an aged-out window returns window_expired (ring 120 s).

const TAG := "SMOKE_REPLAY_PANEL"


func run() -> void:
	if not await p7_boot(TAG):
		return
	for region_def: Dictionary in Weather.REGIONS:
		Weather.force_window("wind_lambda_scale", str(region_def["id"]),
			0.0, 3.0, 0.7)
	if not _build():
		return
	if (await p7_register(TAG)).is_empty():
		return
	var settle: Dictionary = {}
	for _i in range(2):
		settle = await Orchestrator.step_once(900.0)
	if settle.get("_status", 0) != 200:
		_fail(TAG, "settle step failed")
		return

	# trip the largest online sync unit; chase the live nadir
	var victim := _largest_sync(settle.get("devices", {}))
	Orchestrator.inject([{"at_s_rel": 20.0, "kind": "trip", "element": victim}])
	var live_nadir := 100.0
	var trip_event := {}
	var results: Array = [await Orchestrator.step_once(300.0)]
	for _i in range(40):
		results.append(await Orchestrator.step_once(1.0))
	for result: Dictionary in results:
		if result.get("_status", 0) != 200:
			continue
		live_nadir = minf(live_nadir,
			numf(result.get("islands", {}).get("0", {}), "f_min", 100.0))
		for event: Dictionary in result.get("events", []):
			if str(event.get("kind", "")) == "trip" \
					and str(event.get("element", "")) == victim:
				trip_event = event
	if trip_event.is_empty():
		_fail(TAG, "trip event never arrived")
		return
	print("REPLAY victim=", victim, " live_nadir=", live_nadir,
		" event_t=", trip_event.get("t_sim"))

	# the REAL panel fetch path (instanced exactly as the HUD does)
	var panel := preload("res://views/replay_panel.gd").new()
	add_child(panel)
	var entry: Dictionary = await panel.fetch_counterfactuals(trip_event)
	var plain: Dictionary = entry["plain"]
	var cf: Dictionary = entry["cf"]
	check("plain_status_ok", str(plain.get("status", "")) == "ok")
	check("cf_targets_battery", str(entry["cf_label"]).contains("battery"))
	check("cf_status_ok", str(cf.get("status", "")) == "ok")
	var plain_nadir := panel.replay_f_min(plain)
	var cf_nadir := panel.replay_f_min(cf)
	print("REPLAY plain_nadir=", plain_nadir, " cf_nadir=", cf_nadir)
	check("replay_matches_live", absf(plain_nadir - live_nadir) < 0.15)
	check("no_battery_dips_deeper", cf_nadir < plain_nadir - 0.05)

	# a FRESH window still replays after stepping ~200 s of sim on
	for _i in range(4):
		await Orchestrator.step_once(50.0)
	var recent_t := GameClock.t_sim - 20.0
	var fresh: Dictionary = await CosimBridge.replay(Orchestrator.ID,
		{"t_sim": recent_t, "window_s": 15.0})
	check("fresh_window_ok", str(fresh.get("status", "")) == "ok")

	# ...but the ORIGINAL event has aged out of the 120 s ring by now
	for _i in range(2):
		await Orchestrator.step_once(60.0)
	var stale: Dictionary = await panel.fetch_counterfactuals(trip_event)
	check("old_window_expired", bool(stale["expired"]))
	_finish(TAG, {"live_nadir": live_nadir, "plain_nadir": plain_nadir,
		"cf_nadir": cf_nadir, "battery_bought_hz": plain_nadir - cf_nadir})


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


## Battery-backed hamburg island: 6 must-run CCGT + 2 batteries (no wind —
## the ghost comparison wants a clean ΔP story). Removing one of two
## batteries halves the FFR: the counterfactual dip is unmistakable.
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
	var bats: Array[String] = place_ring("battery", 2, anchor, lc_tap, avoid)
	if bats.size() < 2:
		_fail(TAG, "site exhaustion: bats=%d" % bats.size())
		return false
	return true
