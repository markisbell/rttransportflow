extends SmokeBase
## --smoke=island_cut: cutting the only corridor to a load center leaves it
## on a source-less island — the builder DROPS it with a warning, the UI
## model marks it unsupplied, and the surviving zone keeps its supply.
## Runs on the fixture map (deterministic cut point).

const TAG := "SMOKE_ISLAND_CUT"


func run() -> void:
	SidecarManager.configure(SMOKE_PORT)
	SidecarManager.start_all()
	if not await _wait_healthy(120.0):
		_fail(TAG, "health timeout")
		return
	var fixture: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		"res://testdata/mini_map.json"))
	if not World.load_map(fixture):
		_fail(TAG, "fixture map load failed")
		return
	if not await CosimBridge.handshake(Orchestrator.ID):
		_fail(TAG, "handshake failed")
		return

	DemoBuild.fixture_build(World)
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	if not check("initial_build_ok", bool(status[0])):
		_fail(TAG, "initial build failed: %s" % str(status[1]))
		return
	Orchestrator.stop()
	check("both_zones_registered", (BuildSession.last_build["zones"] as Array).size() == 2)

	# Cut the trunk between the last plant tap (16,6-ish) and the east tap:
	# (17,6) is the only path to east_city on the fixture build.
	World.remove_corridor(Vector2i(17, 6))
	BuildSession.rebuild_now()
	status = await BuildSession.build_status
	if not check("rebuild_after_cut_ok", bool(status[0])):
		_fail(TAG, "rebuild failed: %s" % str(status[1]))
		return
	Orchestrator.stop()

	var interpretation: Dictionary = BuildSession.last_build["interpretation"]
	var dropped: Array = interpretation["dropped_zones"]
	check("east_dropped", dropped.has("east_city"))
	var warned := false
	for warning: String in status[2]:
		if warning.contains("east_city") and warning.contains("UNSUPPLIED"):
			warned = true
	check("unsupplied_warning_present", warned)
	check("one_zone_remains", (BuildSession.last_build["zones"] as Array).size() == 1)

	var supplied_west := false
	for _i in range(5):
		var result: Dictionary = await Orchestrator.step_once(60.0)
		if result.get("_status", 0) != 200:
			continue
		var zones: Dictionary = result.get("zones", {})
		supplied_west = zones.has("west_city") \
			and numf(zones["west_city"], "supplied", 0.0) > 0.999 \
			and not zones.has("east_city")
	check("west_still_supplied", supplied_west)
	_finish(TAG, {"dropped": dropped})
