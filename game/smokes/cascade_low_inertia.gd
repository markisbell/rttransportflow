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
## Fleet A spins 16 machines; fleet B serves the same island with 7 plus a
## wind fleet. The unit COUNT is the experiment: E_k is set by how many
## machines are synchronised, and the dispatcher cannot express "spinning but
## decommitted" — an uncommitted unit simply receives no dispatch command and
## keeps spinning at 0 MW, so its inertia stays on the island (seen directly:
## fleet B with wind covering the whole load reported dP 0 MW at E_k 42 GJ,
## byte-identical to fleet A).
## 200 MW peakers, not 600 MW CCGTs. The dispatcher fills its locality pass
## greedily, so the biggest online units sit at p_max whatever the fleet
## size — with CCGTs the two victims were 1.1 GW of a 2.7 GW island, a 40 %
## N-2 that no amount of inertia rides through, and even the HIGH-inertia
## fleet shed a UFLS stage. At 200 MW the same script removes ~15 %, which
## is a severe but survivable double contingency, and the A/B difference is
## then genuinely about E_k rather than about unit size.
const GAS_KIND := "gas_ocgt"
const GAS_UNITS_HIGH := 20
const GAS_UNITS_LOW := 10


func run() -> void:
	if not await p7_boot(TAG):
		return
	# Same weather for both fleets, unscaled (lambda 1.0). The old x0.7 lull
	# was meant to keep B's gas loaded, but it starved fleet B instead: its
	# wind delivered ~0.6 GW into a ~5.5 GW island, the four must-run units
	# could not cover the gap and the island was already at 48.2 Hz before
	# the script fired. Inertia, not weather, is what this smoke varies.
	for region_def: Dictionary in Weather.REGIONS:
		Weather.force_window("wind_lambda_scale", str(region_def["id"]),
			0.0, 3.0, 1.0)

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
		"h_sys_high": high["h_sys"], "h_sys_low": low["h_sys"],
		"e_k_high": high["e_k_mj"], "e_k_low": low["e_k_mj"],
		"dp_high": high["dp_mw"], "dp_low": low["dp_mw"]})


## Build, register, settle, fire the double-trip script, chase the event.
func _run_fleet(low_inertia: bool) -> Dictionary:
	if not _build(low_inertia):
		return {}
	if (await p7_register(TAG)).is_empty():
		return {}
	# Fleet B needs longer: the dispatcher has to DECOMMIT the gas that wind
	# displaces, and unit commitment is not instantaneous.
	var settle: Dictionary = {}
	for _i in range(4):
		settle = await p7_block("settle")
	if settle.get("_status", 0) != 200:
		_fail(TAG, "settle step failed")
		return {}

	# the SAME script: trip the two largest online sync units, 10 s apart
	var victims: Array = online_sync_ranked(settle.get("devices", {})).slice(0, 2)
	if victims.size() < 2:
		_fail(TAG, "fewer than 2 online sync units after settle")
		return {}
	# E_k, not H, is the inertia that sets RoCoF: H is a per-machine ratio and
	# stays ~4.5 s for any all-CCGT fleet, so an h_sys comparison shows nothing.
	var island_pre: Dictionary = settle.get("islands", {}).get("0", {})
	var online_sync := 0
	var victim_mw := 0.0
	for pid: String in settle.get("devices", {}):
		var device: Dictionary = settle["devices"][pid]
		if str(device.get("state", "")) == "online" and device.has("headroom_mw"):
			online_sync += 1
	for pid: String in victims:
		victim_mw += numf(settle.get("devices", {}).get(pid, {}), "p_mw", 0.0)
	var gen_sum := 0.0
	for pid: String in settle.get("devices", {}):
		gen_sum += numf(settle["devices"][pid], "p_mw", 0.0)
	var demand_sum := 0.0
	var zones: Dictionary = Boundary.zone_demand(GameClock.t_sim)
	for zid: String in zones:
		demand_sum += float((zones[zid] as Dictionary).get("value_mw", 0.0))
	print("CASCADE gen=", gen_sum, " demand=", demand_sum)
	print("CASCADE victims: ", victims, " dP=", victim_mw,
		" online_sync=", online_sync,
		" e_k_mj=", island_pre.get("e_k_mj"), " f_pre=", island_pre.get("f_hz"),
		" load=", island_pre.get("p_load_mw"))
	Orchestrator.inject([
		{"at_s_rel": 20.0, "kind": "trip", "element": victims[0]},
		{"at_s_rel": 30.0, "kind": "trip", "element": victims[1]},
	])

	var out := {"f_min": 100.0, "rocof_max": 0.0, "trips": 0,
		"ufls_stages": 0, "w": 1.0, "blackout": false,
		"h_sys": numf(island_pre, "h_sys_s", 0.0),
		"e_k_mj": numf(island_pre, "e_k_mj", 0.0),
		"dp_mw": victim_mw, "online_sync": online_sync}
	# 45 chase steps: both trips + the UFLS pickups at 1 s
	var chased := await chase_event(300.0, 45, "event", Callable(), 60.0)
	out["f_min"] = chased["f_min"]
	out["rocof_max"] = chased["rocof_max"]
	for event: Dictionary in chased["events"]:
		var kind := str(event.get("kind", ""))
		if kind == "trip" and str(event.get("element", "")) in victims:
			out["trips"] = int(out["trips"]) + 1
		elif kind == "ufls_stage":
			out["ufls_stages"] = int(out["ufls_stages"]) + 1
	var island: Dictionary = (chased["tail"] as Dictionary).get("islands", {}).get("0", {})
	out["w"] = numf(island, "w", 1.0)
	out["blackout"] = bool(island.get("blackout", false))
	return out


## Same hamburg island, the SAME 14 CCGT in both runs — the only difference
## is who carries the load. Fleet A: every unit must_run, no wind, so all 14
## machines spin. Fleet B: the same units on AUTO commitment plus a large
## wind fleet, so the dispatcher decommits most of them and the island runs
## on a handful of machines. That is the mechanism the P8 gate is about —
## renewables displacing synchronous plant lowers E_k — and it is also what
## keeps B ADEQUATE: if the wind under-delivers the dispatcher simply starts
## more gas instead of collapsing the island (the old fixture hard-wired B
## to four units and blacked out whenever the weather did not cooperate).
##
## 14 units, not 10: at 10 the fleet ran at ~550 of 600 MW and its own FCR
## headroom was too thin to arrest the double trip, so even the HIGH-inertia
## fleet shed load (the P3 adequacy lesson, in reverse).
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
	var gas_count := GAS_UNITS_LOW if low_inertia else GAS_UNITS_HIGH
	var gas: Array[String] = place_ring(GAS_KIND, gas_count, anchor, lc_tap, avoid)
	if gas.size() < gas_count:
		_fail(TAG, "site exhaustion: gas=%d" % gas.size())
		return false
	for pid: String in gas:
		Dispatch.plant_mode[pid] = "must_run"
	if low_inertia:
		# Wind covers the load the seven machines do not — sized to roughly
		# half the island, NOT all of it: wind that covers everything leaves
		# the gas at 0 MW and the double trip removes nothing. Offshore first
		# (500 MW a farm, and the German Bight draw sits above rated).
		# Three farms, ~1.5 GW: the island's night load is ~3 GW, so this
		# displaces about half of it. 3.6 GW of wind covered the load OUTRIGHT
		# and left all seven machines at 0 MW — the double trip then removed
		# 0.007 MW and measured nothing.
		var off: Array[String] = place_ring("wind_offshore", 3, anchor, lc_tap, avoid)
		var wind_mw := fleet_mw(off)
		print("CASCADE wind fleet: off=", off.size(), " nameplate=", wind_mw)
		if wind_mw < 1000.0:
			_fail(TAG, "wind fleet too small: %.0f MW" % wind_mw)
			return false
	var bats: Array[String] = place_ring("battery", 2, anchor, lc_tap, avoid)
	if bats.size() < 2:
		_fail(TAG, "site exhaustion: bats=%d" % bats.size())
		return false
	return true
