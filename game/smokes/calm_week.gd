extends SmokeBase
## --smoke=calm_week: a renewables-heavy grid under a FORCED Dunkelflaute
## (the family `force_*` window as the test hook) goes scarce and its
## frequency sags; the same build on a normal day holds. UFLS shedding
## arrives with P8 protection — the P6 observable is scarcity + sag.
## The NORMAL day runs FIRST: there is no restoration before P8, so a
## collapsed island stays dead — running the dark day first poisoned the
## baseline (and the old order plus dispatcher auto-restarts into the dying
## island integrated f to −27 Hz — now blocked engine-side).

const TAG := "SMOKE_CALM_WEEK"


func run() -> void:
	if not await gridco_boot(TAG):
		return
	_renewables_heavy_build()
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	if not check("build_registered", bool(status[0])):
		_fail(TAG, "build failed: %s" % str(status[1]))
		return
	Orchestrator.stop()

	# Day 1: normal weather — the healthy baseline.
	var normal := await _run_day()
	# Day 2: forced calm-dark, STAIRCASED over ~6 h (an instant λ step is a
	# GW-scale ΔP that relays out the wind fleet — found by the P7 smokes).
	for region_def: Dictionary in Weather.REGIONS:
		var region := str(region_def["id"])
		var stairs: Array[float] = [0.85, 0.7, 0.55, 0.45]
		for k in range(stairs.size()):
			Weather.force_window("wind_lambda_scale", region,
				1.0 + k * 0.0625, 1.0 + (k + 1) * 0.0625, stairs[k])
		Weather.force_window("wind_lambda_scale", region, 1.25, 2.0, 0.35)
		Weather.force_window("clearness_scale", region, 1.0, 2.0, 0.5)
	var dark := await _run_day()

	# NOT "the dark day is scarce". Scarcity means the fleet cannot cover
	# demand — a CAPACITY verdict — and this fleet can: it burns 67 GWh of
	# thermal and holds 49.82 Hz with nothing shed. Asserting scarcity here
	# was asserting that the world is under-built, which is a property of
	# the fixture, not the lesson. What a Dunkelflaute actually teaches is
	# that the same demand now comes from the expensive end of the merit
	# order, and THAT is what the cost and thermal-burn checks below
	# measure. (Second retarget of this smoke: the first assumed a becalmed
	# day sags deeper, but wind VARIABILITY moves frequency, not wind
	# absence, so a calm day is frequency-quieter than a windy one.)
	check("dark_day_priced_up", dark["cost_eur"] > normal["cost_eur"] * 5.0)
	check("normal_day_holds", normal["f_min"] > 49.5)
	check("dark_wind_really_calm", dark["renewable_mwh"] < normal["renewable_mwh"] * 0.6)
	# The ADEQUACY signal, not a frequency one: the thermal fleet + storage
	# carry the calm day. (Asserting "the dark day sags deeper" was wrong —
	# wind VARIABILITY is what moves frequency, so a becalmed day is
	# frequency-QUIETER than a windy one. The Dunkelflaute costs energy and
	# money, not stability, once the must-run fleet is spinning.)
	check("dark_day_burns_thermal", dark["thermal_mwh"] > normal["thermal_mwh"] * 1.2)
	check("dark_day_costlier", dark["cost_eur"] > normal["cost_eur"] * 1.2)
	# and it stays a SURVIVABLE day: no island collapse either way
	check("no_blackout", not dark["blackout"] and not normal["blackout"])
	_finish(TAG, {"dark_f_min": dark["f_min"], "normal_f_min": normal["f_min"],
		"dark_scarcity_blocks": dark["scarcity_blocks"],
		"dark_thermal_gwh": dark["thermal_mwh"] / 1000.0,
		"normal_thermal_gwh": normal["thermal_mwh"] / 1000.0,
		"dark_cost_meur": dark["cost_eur"] / 1e6,
		"normal_cost_meur": normal["cost_eur"] / 1e6})


func _run_day() -> Dictionary:
	var f_min := 100.0
	var scarcity_blocks := 0
	var renewable_mwh := 0.0
	var thermal_mwh := 0.0
	var blackout := false
	var cost_start: float = Economy.fuel_cost + Economy.co2_cost + Economy.vom_cost
	for _block in range(96):
		if _block % 16 == 0:
			print("CALM_WEEK block ", _block)  # progress: ALERT days run slow
		var result: Dictionary = await Orchestrator.step_once(900.0)
		if result.get("_status", 0) != 200:
			continue
		for island_id: String in result.get("islands", {}):
			var island: Dictionary = result["islands"][island_id]
			f_min = minf(f_min, numf(island, "f_min", 100.0))
			blackout = blackout or bool(island.get("blackout", false))
		if Dispatch.scarcity:
			scarcity_blocks += 1
		for pid: String in result.get("devices", {}):
			var energy := numf(result["devices"][pid], "energy_mwh_step", 0.0)
			if pid.begins_with("wind") or pid.begins_with("solar"):
				renewable_mwh += energy
			elif pid.begins_with("gas") or pid.begins_with("coal") \
					or pid.begins_with("nuclear") or pid.begins_with("lignite"):
				thermal_mwh += energy
	var cost_end: float = Economy.fuel_cost + Economy.co2_cost + Economy.vom_cost
	return {"f_min": f_min, "scarcity_blocks": scarcity_blocks,
		"renewable_mwh": renewable_mwh, "thermal_mwh": thermal_mwh,
		"cost_eur": cost_end - cost_start, "blackout": blackout}


## Hamburg-anchored: lots of wind + a little gas — deliberately calm-fragile.
## Built with the shared place_ring (connect-or-remove + site banning): the
## old inline loops predated that hardening and could silently count plants
## the topology builder later dropped as orphans.
func _renewables_heavy_build() -> void:
	World.clear_build()
	var lc_id: String = "hamburg" if World.load_centers.has("hamburg") else \
		str((World.load_centers.keys() as Array).front())
	var lc: Dictionary = World.load_centers[lc_id]
	var anchor: Vector2i = lc["tiles"][0]
	# foreign-footprint avoid rings: without them the wind spurs brushed FIVE
	# neighboring cities and dragged their load onto a 5 GW island (the P5
	# 47.4 Hz lesson, refound — the fleet tripped at t=0.25 s)
	var avoid := foreign_avoid([lc_id])
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"], avoid)
	World.place_corridor(lc_tap)
	var peak: float = lc["peak_mw"]
	# 1.6×: block-to-block CF jitter on the nameplate is the island's ΔP
	# excitation — 2.5× peak stepped ±1.5 GW per block and tripped the grid
	# even on the NORMAL day (pre-aFRR small island, fork finding)
	place_ring("wind_onshore", units_for("wind_onshore", peak * 1.6),
		anchor, lc_tap, avoid)
	# 1.28×: pre-UFLS the island survives only while the dark-day deficit
	# stays inside FCR band + load damping (~150 MW here) — sized so the
	# evening residual is ~80 MW: real scarcity pricing, sag, no collapse
	var gas_pids := place_ring("gas_ccgt", units_for("gas_ccgt", peak * 1.28),
		anchor, lc_tap, avoid)
	# must_run: decommitting the gas fleet at night left a near-zero-inertia
	# island where ordinary wind steps tripped everything — the operator of
	# a renewables-heavy island keeps the synchronous fleet spinning
	for gas_pid: String in gas_pids:
		Dispatch.plant_mode[gas_pid] = "must_run"
	# batteries bridge the 15-min dispatch cadence: gas FCR (~270 MW) cannot
	# hold a sustained wind ramp between decisions — even slewed, a normal
	# frontal passage killed the island 64 s into a block. FFR + arbitrage
	# is exactly the storage role P7 ships (battery_response proves it).
	place_ring("battery", units_for("battery", peak * 0.3),
		anchor, lc_tap, avoid)
