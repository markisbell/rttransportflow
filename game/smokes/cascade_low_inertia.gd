extends P7SmokeBase
## --smoke=cascade_low_inertia: the ROADMAP P8 gate — the SAME scripted
## double contingency (trip the two largest online sync units, 10 s apart)
## against two fleets on the same island/night. Fleet A (high inertia):
## 10 must-run CCGT, no wind, 2 batteries. Fleet B (low inertia): the same
## island carried mostly by wind (H = 0) with 4 must-run CCGT + 2 batteries.
## The teaching point: B's RoCoF is a multiple of A's, its nadir is deeper,
## and UFLS is what saves it — at the price of shed load — while A rides the
## same script without shedding. A wind lull (λ 0.7) is forced in BOTH runs
## so the sync units carry comparable load when the script fires.

const TAG := "SMOKE_CASCADE_LOW_INERTIA"


func run() -> void:
	if not await p7_boot(TAG):
		return
	# same conditions for both fleets: a mild wind lull so B's gas carries
	# real load (a wind-surplus night would leave the victims at ~0 MW and
	# the "trip" would remove nothing)
	for region_def: Dictionary in Weather.REGIONS:
		Weather.force_window("wind_lambda_scale", str(region_def["id"]),
			0.0, 3.0, 0.7)

	print("CASCADE fleet A (high inertia)")
	var high := await _run_fleet(false)
	if high.is_empty():
		return
	print("CASCADE A: ", high)
	print("CASCADE fleet B (low inertia)")
	var low := await _run_fleet(true)
	if low.is_empty():
		return
	print("CASCADE B: ", low)

	check("both_trips_seen_high", high["trips"] >= 2)
	check("both_trips_seen_low", low["trips"] >= 2)
	check("low_rocof_multiple", low["rocof_max"] >= high["rocof_max"] * 1.5)
	check("low_nadir_deeper", low["f_min"] < high["f_min"])
	# UFLS saves the low-inertia island at the cost of shed load — while the
	# high-inertia fleet rides the same script without shedding anything
	check("high_no_ufls", high["ufls_stages"] == 0 and high["w"] > 0.9995)
	check("low_shed_or_shallow", low["ufls_stages"] > 0 or low["f_min"] > 49.0)
	check("both_survive", not high["blackout"] and not low["blackout"])
	_finish(TAG, {"rocof_high": high["rocof_max"], "rocof_low": low["rocof_max"],
		"nadir_high": high["f_min"], "nadir_low": low["f_min"],
		"ufls_low": low["ufls_stages"], "w_low": low["w"],
		"h_sys_high": high["h_sys"], "h_sys_low": low["h_sys"]})


## Build, register, settle, fire the double-trip script, chase the event.
func _run_fleet(low_inertia: bool) -> Dictionary:
	if not _build(low_inertia):
		return {}
	if (await p7_register(TAG)).is_empty():
		return {}
	var settle: Dictionary = {}
	for _i in range(2):
		settle = await Orchestrator.step_once(900.0)
	if settle.get("_status", 0) != 200:
		_fail(TAG, "settle step failed")
		return {}

	# the SAME script: trip the two largest online sync units, 10 s apart
	var victims := _two_largest_sync(settle.get("devices", {}))
	if victims.size() < 2:
		_fail(TAG, "fewer than 2 online sync units after settle")
		return {}
	print("CASCADE victims: ", victims)
	Orchestrator.inject([
		{"at_s_rel": 20.0, "kind": "trip", "element": victims[0]},
		{"at_s_rel": 30.0, "kind": "trip", "element": victims[1]},
	])

	var out := {"f_min": 100.0, "rocof_max": 0.0, "trips": 0,
		"ufls_stages": 0, "w": 1.0, "blackout": false,
		"h_sys": numf(settle.get("islands", {}).get("0", {}), "h_sys_s", 0.0)}
	var result: Dictionary = await Orchestrator.step_once(300.0)
	_collect(result, victims, out)
	for _i in range(45):  # chase both trips + the UFLS pickups at 1 s
		_collect(await Orchestrator.step_once(1.0), victims, out)
	var tail: Dictionary = await Orchestrator.step_once(60.0)
	_collect(tail, victims, out)
	var island: Dictionary = tail.get("islands", {}).get("0", {})
	out["w"] = numf(island, "w", 1.0)
	out["blackout"] = bool(island.get("blackout", false))
	return out


func _collect(result: Dictionary, victims: Array, out: Dictionary) -> void:
	if result.get("_status", 0) != 200:
		return
	var island: Dictionary = result.get("islands", {}).get("0", {})
	out["f_min"] = minf(out["f_min"], numf(island, "f_min", 100.0))
	out["rocof_max"] = maxf(out["rocof_max"], absf(numf(island, "rocof_max", 0.0)))
	for event: Dictionary in result.get("events", []):
		var kind := str(event.get("kind", ""))
		if kind == "trip" and str(event.get("element", "")) in victims:
			out["trips"] = int(out["trips"]) + 1
		elif kind == "ufls_stage":
			out["ufls_stages"] = int(out["ufls_stages"]) + 1


func _two_largest_sync(devices: Dictionary) -> Array:
	var sync: Array = []
	for pid: String in devices:
		var device: Dictionary = devices[pid]
		if str(device.get("state", "")) == "online" and device.has("headroom_mw"):
			sync.append([numf(device, "p_mw", 0.0), pid])
	sync.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] > b[0] or (a[0] == b[0] and str(a[1]) < str(b[1])))
	var out: Array = []
	for entry: Array in sync.slice(0, 2):
		out.append(entry[1])
	return out


## Same hamburg island both runs; only the fleet mix differs. Single thermal
## tier (all CCGT — mixed tiers made the dispatcher zero a whole tier at a
## block boundary, the battery_response lesson) and must_run everywhere so
## the synchronous count IS the inertia.
func _build(low_inertia: bool) -> bool:
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
	var gas_count := 4 if low_inertia else 10
	var gas: Array[String] = place_ring("gas_ccgt", gas_count, anchor, lc_tap, avoid)
	if gas.size() < gas_count:
		_fail(TAG, "site exhaustion: gas=%d" % gas.size())
		return false
	for pid: String in gas:
		Dispatch.plant_mode[pid] = "must_run"
	if low_inertia:
		var wind: Array[String] = place_ring("wind_onshore", 32, anchor, lc_tap, avoid)
		if wind.size() < 24:
			_fail(TAG, "site exhaustion: wind=%d" % wind.size())
			return false
	var bats: Array[String] = place_ring("battery", 2, anchor, lc_tap, avoid)
	if bats.size() < 2:
		_fail(TAG, "site exhaustion: bats=%d" % bats.size())
		return false
	return true
