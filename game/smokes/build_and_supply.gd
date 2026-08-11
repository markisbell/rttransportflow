extends SmokeBase
## --smoke=build_and_supply: scripted build connects load centers to plants;
## after the (forced) rebuild+register every registered zone is supplied 1.0
## and the frequency stays sane — the P5 acceptance gate.

const TAG := "SMOKE_BUILD_AND_SUPPLY"


func run() -> void:
	SidecarManager.configure(SMOKE_PORT)
	SidecarManager.start_all()
	if not await _wait_healthy(120.0):
		_fail(TAG, "health timeout")
		return
	if not BuildSession.load_map():
		_fail(TAG, "map load failed")
		return
	if not await CosimBridge.handshake(Orchestrator.ID):
		_fail(TAG, "handshake failed")
		return

	if World.load_centers.has("west_city"):
		DemoBuild.fixture_build(World)  # fixture map: the golden-pinned build
	else:
		DemoBuild.auto_build(World)  # europe map: BFS-routed 3-city build
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	if not check("build_registered", bool(status[0])):
		_fail(TAG, "build failed: %s" % str(status[1]))
		return
	Orchestrator.stop()  # drive steps manually below

	var n_zones := (BuildSession.last_build["zones"] as Array).size()
	check("has_zones", n_zones >= 2)

	var supplied_ok := true
	var f_min := 100.0
	var f_max := 0.0
	var failures := 0
	for _i in range(20):
		var result: Dictionary = await Orchestrator.step_once(60.0)
		if result.get("_status", 0) != 200:
			failures += 1
			continue
		var zones: Dictionary = result.get("zones", {})
		if zones.size() != n_zones:
			supplied_ok = false
		for zone_id: String in zones:
			if numf(zones[zone_id], "supplied", 0.0) < 0.999:
				supplied_ok = false
		var island: Dictionary = result.get("islands", {}).get("0", {})
		f_min = minf(f_min, numf(island, "f_min", 100.0))
		f_max = maxf(f_max, numf(island, "f_max", 0.0))
	check("no_transport_failures", failures == 0)
	check("all_zones_supplied", supplied_ok)
	check("f_band_sane", f_min > 49.5 and f_max < 50.5)
	_finish(TAG, {"n_zones": n_zones, "f_min": f_min, "f_max": f_max,
		"warnings": (status[2] as Array).size()})
