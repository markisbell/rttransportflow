extends P7SmokeBase
## --smoke=battery_response: the SAME plant trip on the SAME island, with
## and without a battery fleet — the nadir delta is the P7 storage lesson
## (batteries fix the nadir, PARAMETERS §1.11: full FFR in ~0.3 s where
## steam physically cannot). Run A: no batteries, trip the biggest coal
## unit, record f_min. Run B: identical build + 4x300 MW batteries, same
## trip, record f_min again. Deterministic: same seed, same pids.

const TAG := "SMOKE_BATTERY_RESPONSE"
const SOC_START := 0.55


func run() -> void:
	if not await p7_boot(TAG):
		return

	# --- run A: no batteries ---------------------------------------------
	var built_a := _build(false)
	if built_a.is_empty():
		return
	var victim: String = built_a["coal"][0]
	if (await p7_register(TAG)).is_empty():
		return
	check("single_zone",
		(BuildSession.last_build["native"]["load_centers"]["items"] as Array).size() == 1)
	var nadir_without := await _settle_trip_measure(victim, [])
	print("BATRESP nadir_without=", nadir_without)

	# --- run B: same island + battery fleet (fresh reset, t continues) ----
	var built_b := _build(true)
	if built_b.is_empty():
		return
	check("same_victim_pid", str(built_b["coal"][0]) == victim)
	if (await p7_register(TAG)).is_empty():
		return
	var bats: Array = built_b["bats"]
	var nadir_with := await _settle_trip_measure(victim, bats)
	print("BATRESP nadir_with=", nadir_with, " delta=", nadir_with - nadir_without)

	check("both_dipped", nadir_without < 49.99 and nadir_with < 49.99)
	check("battery_arrests_nadir", nadir_with > nadir_without + 0.03)
	check("battery_discharged", _bat_discharged)
	check("battery_soc_drained", _bat_soc_min < SOC_START - 0.0005)
	_finish(TAG, {"nadir_without": nadir_without, "nadir_with": nadir_with,
		"delta_hz": nadir_with - nadir_without,
		"bat_p_peak": _bat_p_peak, "bat_soc_min": _bat_soc_min})


var _bat_discharged := false
var _bat_p_peak := 0.0
var _bat_soc_min := 1.0


## Settle two blocks, inject the trip, then chase the nadir through 30 s of
## 1 s steps (trip_reaction pattern — the dip lives AFTER the early return).
func _settle_trip_measure(victim: String, bats: Array) -> float:
	for _i in range(2):
		await Orchestrator.step_once(900.0)
	Orchestrator.inject([{"at_s_rel": 30.0, "kind": "trip", "element": victim}])
	var f_min := 100.0
	var result: Dictionary = await Orchestrator.step_once(600.0)
	if result.get("_status", 0) == 200:
		f_min = minf(f_min, numf(result.get("islands", {}).get("0", {}), "f_min", 100.0))
	for _i in range(30):
		var follow: Dictionary = await Orchestrator.step_once(1.0)
		if follow.get("_status", 0) != 200:
			continue
		f_min = minf(f_min, numf(follow.get("islands", {}).get("0", {}), "f_min", 100.0))
		for pid: String in bats:
			var device: Dictionary = follow.get("devices", {}).get(pid, {})
			var p := numf(device, "p_mw", 0.0)
			_bat_p_peak = maxf(_bat_p_peak, p)
			if p > 10.0:
				_bat_discharged = true
			_bat_soc_min = minf(_bat_soc_min, numf(device, "soc", 1.0))
	return f_min


## Hamburg island: coal x5 + ccgt x2 (identical both runs — clear_build
## resets the pid counter, so placement order fixes the pid names), plus the
## battery ring only in run B (placed LAST: earlier pids stay identical).
func _build(with_batteries: bool) -> Dictionary:
	World.clear_build()
	var lc_id := "hamburg"
	if not World.load_centers.has(lc_id):
		_fail(TAG, "map has no hamburg")
		return {}
	var lc: Dictionary = World.load_centers[lc_id]
	var anchor: Vector2i = lc["tiles"][0]
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"])
	World.place_corridor(lc_tap)
	var avoid := foreign_avoid([lc_id])
	# SINGLE-tier thermal (all coal, one marginal cost): mixed tiers made the
	# dispatcher zero a whole tier at a block boundary and the slew transient
	# over-frequency-tripped the island (51.5 Hz) before the test even ran
	var coal: Array[String] = place_ring("coal", 7, anchor, lc_tap, avoid)
	if coal.size() < 7:
		_fail(TAG, "site exhaustion: coal=%d" % coal.size())
		return {}
	var bats: Array[String] = []
	if with_batteries:
		bats = place_ring("battery", 4, anchor, lc_tap, avoid)
		if bats.size() < 4:
			_fail(TAG, "site exhaustion: bats=%d" % bats.size())
			return {}
	return {"coal": coal, "bats": bats}
