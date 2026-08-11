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
	var boot := preload("res://smokes/dispatch_day.gd").new()
	add_child(boot)
	if not await boot.gridco_boot():
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

	check("dark_day_scarce", dark["scarcity_blocks"] >= 4)
	check("dark_day_sags", dark["f_min"] < normal["f_min"] - 0.05)
	check("normal_day_holds", normal["f_min"] > 49.5)
	check("dark_wind_really_calm", dark["renewable_mwh"] < normal["renewable_mwh"] * 0.6)
	_finish(TAG, {"dark_f_min": dark["f_min"], "normal_f_min": normal["f_min"],
		"dark_scarcity_blocks": dark["scarcity_blocks"]})


func _run_day() -> Dictionary:
	var f_min := 100.0
	var scarcity_blocks := 0
	var renewable_mwh := 0.0
	for _block in range(96):
		if _block % 16 == 0:
			print("CALM_WEEK block ", _block)  # progress: ALERT days run slow
		var result: Dictionary = await Orchestrator.step_once(900.0)
		if result.get("_status", 0) != 200:
			continue
		var island: Dictionary = result.get("islands", {}).get("0", {})
		f_min = minf(f_min, numf(island, "f_min", 100.0))
		if Dispatch.scarcity:
			scarcity_blocks += 1
		for pid: String in result.get("devices", {}):
			if pid.begins_with("wind") or pid.begins_with("solar"):
				renewable_mwh += numf(result["devices"][pid], "energy_mwh_step", 0.0)
	return {"f_min": f_min, "scarcity_blocks": scarcity_blocks,
		"renewable_mwh": renewable_mwh}


## Hamburg-anchored: lots of wind + a little gas — deliberately calm-fragile.
func _renewables_heavy_build() -> void:
	World.clear_build()
	var lc_id: String = "hamburg" if World.load_centers.has("hamburg") else \
		str((World.load_centers.keys() as Array).front())
	var lc: Dictionary = World.load_centers[lc_id]
	var anchor: Vector2i = lc["tiles"][0]
	# foreign-footprint avoid rings: without them the wind spurs brushed FIVE
	# neighboring cities and dragged their load onto a 5 GW island (the P5
	# 47.4 Hz lesson, refound — the fleet tripped at t=0.25 s)
	var avoid := {}
	for other_id: String in World.load_centers:
		if other_id == lc_id:
			continue
		for tile: Vector2i in World.load_centers[other_id]["tiles"]:
			avoid[tile] = true
			for offset: Vector2i in GridTopology.NEIGHBORS:
				avoid[tile + offset] = true
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"], avoid)
	World.place_corridor(lc_tap)
	var peak: float = lc["peak_mw"]
	var placed_wind := 0.0
	# 1.6×: block-to-block CF jitter on the nameplate is the island's ΔP
	# excitation — 2.5× peak stepped ±1.5 GW per block and tripped the grid
	# even on the NORMAL day (pre-aFRR small island, fork finding)
	while placed_wind < peak * 1.6:
		var site := DemoBuild.find_site(World, "wind_onshore", anchor, 10, avoid)
		if site == Vector2i(-1, -1):
			break
		World.place_plant("wind_onshore", site)
		placed_wind += World.PLANT_SIZES["wind_onshore"]
		var tap := DemoBuild.tap_for(World, [site], avoid)
		if tap != Vector2i(-1, -1):
			for tile: Vector2i in DemoBuild.route(World, tap, lc_tap, true, avoid):
				World.place_corridor(tile)
	var placed_gas := 0.0
	var gas_pids: Array[String] = []
	# 1.28×: pre-UFLS the island survives only while the dark-day deficit
	# stays inside FCR band + load damping (~150 MW here) — sized so the
	# evening residual is ~80 MW: real scarcity pricing, sag, no collapse
	while placed_gas < peak * 1.28:
		var site := DemoBuild.find_site(World, "gas_ccgt", anchor, 10, avoid)
		if site == Vector2i(-1, -1):
			break
		var gas_pid := World.place_plant("gas_ccgt", site)
		gas_pids.append(gas_pid)
		placed_gas += World.PLANT_SIZES["gas_ccgt"]
		var tap := DemoBuild.tap_for(World, [site], avoid)
		if tap != Vector2i(-1, -1):
			for tile: Vector2i in DemoBuild.route(World, tap, lc_tap, true, avoid):
				World.place_corridor(tile)
	# must_run: decommitting the gas fleet at night left a near-zero-inertia
	# island where ordinary wind steps tripped everything — the operator of
	# a renewables-heavy island keeps the synchronous fleet spinning
	for gas_pid: String in gas_pids:
		Dispatch.plant_mode[gas_pid] = "must_run"
	# batteries bridge the 15-min dispatch cadence: gas FCR (~270 MW) cannot
	# hold a sustained wind ramp between decisions — even slewed, a normal
	# frontal passage killed the island 64 s into a block. FFR + arbitrage
	# is exactly the storage role P7 ships (battery_response proves it).
	var placed_bat := 0.0
	while placed_bat < peak * 0.3:
		var site := DemoBuild.find_site(World, "battery", anchor, 10, avoid)
		if site == Vector2i(-1, -1):
			break
		World.place_plant("battery", site)
		placed_bat += World.PLANT_SIZES["battery"]
		var tap := DemoBuild.tap_for(World, [site], avoid)
		if tap != Vector2i(-1, -1):
			for tile: Vector2i in DemoBuild.route(World, tap, lc_tap, true, avoid):
				World.place_corridor(tile)
