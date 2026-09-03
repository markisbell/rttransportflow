extends GdUnitTestSuite
## C5 — restoration state machine, black-start candidates, the need
## guard, and the pending-command overlays. All synthetic: the live wire
## path is the black_start smoke's job.


func _teardown_world() -> void:
	World.plants.clear()
	Dispatch.home_zone.clear()
	Restoration.reset()
	Orchestrator.last_result = {}
	Boundary.pending_device_commands = {}
	Boundary.pending_zone_commands = {}


func test_black_start_candidates_ranked() -> void:
	# suite-order hygiene: earlier suites leave fixture worlds behind, and
	# this test blankets home_zone over whatever plants exist
	World.plants.clear()
	Dispatch.home_zone.clear()
	World.plants["ocgt_a"] = {"kind": "gas_ocgt", "p_max_mw": 200.0}
	World.plants["ocgt_b"] = {"kind": "gas_ocgt", "p_max_mw": 200.0}
	World.plants["coal_a"] = {"kind": "coal", "p_max_mw": 800.0}
	World.plants["wind_a"] = {"kind": "wind_onshore", "p_max_mw": 200.0}
	World.plants["ocgt_c"] = {"kind": "gas_ocgt", "p_max_mw": 200.0}
	World.plants["ccgt_a"] = {"kind": "gas_ccgt", "p_max_mw": 600.0}
	for pid: String in World.plants:
		Dispatch.home_zone[pid] = "hamburg"
	Dispatch.home_zone["ocgt_c"] = "berlin"  # not a dead zone
	# online is no candidate; PARKED "starting" IS one (the dispatcher
	# breaker-closes committed units blackout-blind and the sick-island
	# hold parks them — the backend accepts black_start on that row)
	var devices := {"ocgt_b": {"state": "online"}, "ccgt_a": {"state": "starting"}}
	var out := FleetQuery.black_start_candidates(devices, {"hamburg": true})
	# fast class first, deterministic tiebreak; wind (no rank), slow steam
	# (cannot black-start) and the online/foreign units excluded
	assert_that(out).is_equal(["ocgt_a", "ccgt_a"] as Array[String])
	_teardown_world()


func test_restoration_begin_refuses_without_black_zones() -> void:
	World.plants["u1"] = {"kind": "gas_ocgt", "p_max_mw": 200.0}
	Orchestrator.last_result = {"zones": {"hamburg": {"supplied": 0.925}}}
	assert_bool(Restoration.begin("u1")).is_false()
	assert_int(Restoration.phase).is_equal(Restoration.Phase.IDLE)
	_teardown_world()


func test_restoration_crank_to_reload_to_done() -> void:
	World.plants.clear()
	Dispatch.home_zone.clear()
	World.plants["u1"] = {"kind": "gas_ocgt", "p_max_mw": 200.0}
	# a big online sibling so the capacity gate opens (the gate compares
	# measured online MW against the next block's demand share)
	World.plants["big"] = {"kind": "gas_ccgt", "p_max_mw": 20000.0}
	Dispatch.home_zone["u1"] = "hamburg"
	Dispatch.home_zone["big"] = "hamburg"
	var t0: float = GameClock.t_sim
	Orchestrator.last_result = {"zones": {"hamburg": {"supplied": 0.0},
		"berlin": {"supplied": 1.0}}}
	assert_bool(Restoration.begin("u1")).is_true()
	assert_int(Restoration.phase).is_equal(Restoration.Phase.CRANK)
	# the one-shot crank command is armed, override-shaped
	var crank: Dictionary = Boundary.pending_device_commands.get("u1", {})
	assert_bool(bool(crank.get("black_start", false))).is_true()
	assert_str(str(crank.get("breaker", ""))).is_equal("close")
	assert_bool(Restoration.active_zones.has("hamburg")).is_true()
	assert_bool(Restoration.active_zones.has("berlin")).is_false()
	Boundary.pending_device_commands = {}
	# the black_start wire event flips CRANK -> RELOAD; a NEW block must
	# open before the first restore command (one block per wire block)
	GameClock.t_sim += Dispatch.BLOCK_S
	Restoration._on_step(1, {"events": [{"kind": "black_start",
		"element": "island:0", "t_sim": 100.0}], "zones": {
		"hamburg": {"supplied": 0.0}},
		"devices": {"big": {"state": "online"}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.RELOAD)
	# reload: sustain floor armed, restore block released (capacity ok),
	# and the staged fleet restart breaker-closed the offline sibling
	assert_bool(Boundary.pending_device_commands.has("u1")).is_true()
	assert_bool(float((Boundary.pending_zone_commands.get("hamburg", {})
		as Dictionary).get("restore_load", 0.0)) > 0.0).is_true()
	# full supply completes the machine
	Restoration._on_step(2, {"events": [], "zones": {
		"hamburg": {"supplied": 1.0}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.IDLE)
	assert_bool(Restoration.active_zones.is_empty()).is_true()
	GameClock.t_sim = t0
	_teardown_world()


func test_restoration_recollapse_returns_to_crank() -> void:
	World.plants["u1"] = {"kind": "gas_ocgt", "p_max_mw": 200.0}
	var t0: float = GameClock.t_sim
	Orchestrator.last_result = {"zones": {"hamburg": {"supplied": 0.0}}}
	Restoration.begin("u1")
	Restoration._on_step(1, {"events": [{"kind": "black_start",
		"element": "island:0"}], "zones": {"hamburg": {"supplied": 0.0}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.RELOAD)
	Boundary.pending_device_commands = {}
	# the crank re-arm is BLOCK-paced (a lost one-shot or a lockout note
	# is retried every block — the wedge fix): advance one block
	GameClock.t_sim += Dispatch.BLOCK_S
	Restoration._on_step(2, {"events": [{"kind": "blackout",
		"element": "island:0"}], "zones": {"hamburg": {"supplied": 0.0}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.CRANK)
	assert_bool(bool((Boundary.pending_device_commands.get("u1", {})
		as Dictionary).get("black_start", false))).is_true()
	GameClock.t_sim = t0
	_teardown_world()


## The wedge fixes: a machine orphaned by a rebuild (world back healthy)
## completes itself, and a swept-up second pocket cannot deadlock the
## first pocket's completion.
func test_restoration_self_heal_and_multi_pocket() -> void:
	World.plants["u1"] = {"kind": "gas_ocgt", "p_max_mw": 200.0}
	var t0: float = GameClock.t_sim
	# orphaned CRANK, world rebuilt healthy -> completes
	Orchestrator.last_result = {"zones": {"hamburg": {"supplied": 0.0}}}
	Restoration.begin("u1")
	Restoration._on_step(1, {"events": [],
		"zones": {"hamburg": {"supplied": 1.0}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.IDLE)
	# multi-pocket: hamburg restores, munich (a separate pocket the begin
	# swept up) stays pitch-black -> done for hamburg, munich released
	Orchestrator.last_result = {"zones": {"hamburg": {"supplied": 0.0},
		"munich": {"supplied": 0.0}}}
	Restoration.begin("u1")
	Restoration._on_step(2, {"events": [{"kind": "black_start",
		"element": "island:0"}], "zones": {"hamburg": {"supplied": 0.0},
		"munich": {"supplied": 0.0}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.RELOAD)
	# mid-reload (hamburg 0.4, munich black): NOT done
	Restoration._on_step(3, {"events": [], "zones": {
		"hamburg": {"supplied": 0.4}, "munich": {"supplied": 0.0}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.RELOAD)
	# hamburg full, munich still black: done, machine free for munich
	Restoration._on_step(4, {"events": [], "zones": {
		"hamburg": {"supplied": 1.0}, "munich": {"supplied": 0.0}}})
	assert_int(Restoration.phase).is_equal(Restoration.Phase.IDLE)
	GameClock.t_sim = t0
	_teardown_world()


## The dispatcher's need guard: black zones bill their measured supplied
## (ledger 34/44); ordinary UFLS keeps FULL need (the pinned behavior).
func test_decide_need_scaling_black_vs_ufls() -> void:
	Orchestrator.last_result = {"zones": {"dead": {"supplied": 0.0},
		"shed": {"supplied": 0.925}, "fine": {"supplied": 1.0}}}
	var t_days := 0.5
	var zone_need := {}
	var wire_zones: Dictionary = Orchestrator.latest().get("zones", {})
	for zone_id: String in ["dead", "shed", "fine"]:
		var mw := 1000.0
		var supplied := Wire.numf(wire_zones.get(zone_id, {}), "supplied", 1.0)
		if supplied == 0.0 or Restoration.active_zones.has(zone_id):
			mw *= supplied
		zone_need[zone_id] = mw
	assert_float(float(zone_need["dead"])).is_equal(0.0)
	assert_float(float(zone_need["shed"])).is_equal(1000.0)  # UFLS: full
	assert_float(float(zone_need["fine"])).is_equal(1000.0)
	# a restoring zone tracks its measured ramp
	Restoration.active_zones["shed"] = true
	var mw2 := 1000.0
	if Wire.numf(wire_zones.get("shed", {}), "supplied", 1.0) == 0.0 \
			or Restoration.active_zones.has("shed"):
		mw2 *= Wire.numf(wire_zones.get("shed", {}), "supplied", 1.0)
	assert_float(mw2).is_equal(925.0)
	_teardown_world()


func test_boundary_overlay_overrides_and_clears() -> void:
	Boundary.pending_device_commands = {"u1": {"dispatch_mw": 30.0,
		"breaker": "close", "black_start": true}}
	# stub mode returns profile commands; the overlay must ride on top
	var mode_0: String = Boundary.mode
	Boundary.mode = "stub_absent"  # neither gridco nor a doc profile hit
	var merged: Dictionary = Boundary._merge_pending({"u1": {"dispatch_mw": 500.0},
		"u2": {"dispatch_mw": 100.0}})
	assert_float(float((merged["u1"] as Dictionary)["dispatch_mw"])).is_equal(30.0)
	assert_bool(bool((merged["u1"] as Dictionary)["black_start"])).is_true()
	assert_float(float((merged["u2"] as Dictionary)["dispatch_mw"])).is_equal(100.0)
	# one-shot: consumed by the merge
	assert_bool(Boundary.pending_device_commands.is_empty()).is_true()
	Boundary.mode = mode_0
	_teardown_world()


func test_advisor_black_start_hint() -> void:
	World.plants["ocgt_a"] = {"kind": "gas_ocgt", "p_max_mw": 200.0,
		"name": "Hamburg Gas OCGT 1"}
	Dispatch.home_zone["ocgt_a"] = "hamburg"
	var hint := Advisor.black_start_hint({"zones": {"hamburg": {"supplied": 0.0}},
		"devices": {"ocgt_a": {"state": "tripped"}}})
	assert_str(hint).contains("BLACKOUT hamburg")
	assert_str(hint).contains("Hamburg Gas OCGT 1")
	assert_str(Advisor.black_start_hint({"zones": {"hamburg": {"supplied": 1.0}},
		"devices": {}})).is_equal("")
	_teardown_world()
