extends GdUnitTestSuite
## P9 campaign data validation + state round-trips (no backend needed).


func _data() -> Dictionary:
	var loaded := Campaign.load_data()
	assert_bool(loaded).is_true()
	return Campaign.data


func test_eras_monotonic_and_ratcheting() -> void:
	var eras: Array = _data()["eras"]
	assert_int(eras.size()).is_equal(5)
	var prev_day := -1.0
	var prev_co2 := 0.0
	for era: Dictionary in eras:
		assert_float(float(era["from_day"])).is_greater(prev_day)
		assert_float(float(era["co2_eur_per_t"])).is_greater_equal(prev_co2)
		prev_day = float(era["from_day"])
		prev_co2 = float(era["co2_eur_per_t"])
	# §5.1 ratchet endpoints
	assert_float(float(eras[0]["co2_eur_per_t"])).is_equal(30.0)
	assert_float(float(eras[-1]["co2_eur_per_t"])).is_equal(250.0)


func test_milestones_ordered_with_criteria() -> void:
	var milestones: Array = _data()["milestones"]
	assert_int(milestones.size()).is_equal(7)
	var prev_end := 0.0
	for milestone: Dictionary in milestones:
		var window: Array = milestone["window_days"]
		assert_int(window.size()).is_equal(2)
		assert_float(float(window[1])).is_greater(float(window[0]))
		assert_float(float(window[0])).is_greater_equal(prev_end - 36.0)
		prev_end = float(window[1])
		assert_bool((milestone["pass"] as Dictionary).is_empty()).is_false()


func test_scripted_event_ids_resolve() -> void:
	var data := _data()
	var ids := {}
	for ev: Dictionary in data["scripted_events"]:
		ids[str(ev["id"])] = true
	for milestone: Dictionary in data["milestones"]:
		for ev_id: String in milestone.get("scripted", []):
			assert_bool(ids.has(ev_id)).is_true()


func test_unlock_years_match_design_table() -> void:
	var unlocks: Dictionary = _data()["unlocks"]
	assert_int(int(unlocks["battery"])).is_equal(2027)
	assert_int(int(unlocks["hvdc_converter"])).is_equal(2028)
	assert_int(int(unlocks["electrolyzer"])).is_equal(2029)
	assert_int(int(unlocks["wind_synthetic_inertia"])).is_equal(2035)


func test_sandbox_leaves_everything_open() -> void:
	Campaign.load_data()
	Campaign.active = false
	assert_bool(Campaign.unlocked("battery")).is_true()
	assert_bool(Campaign.unlocked("offshore_platform")).is_true()


func test_campaign_state_round_trip() -> void:
	Campaign.load_data()
	Campaign.start_campaign()
	Campaign.replay_viewed = true
	Campaign.fired_events["m1_trip"] = true
	Campaign.acc["ufls_events"] = 3
	Campaign.ufls_days = [0.5, 0.7]
	# ints float through JSON — compare parse-normalized forms
	var before := JSON.stringify(JSON.parse_string(
		JSON.stringify(Campaign.to_dict(), "", false, true)), "", false, true)
	Campaign.from_dict(JSON.parse_string(before))
	var after := JSON.stringify(JSON.parse_string(
		JSON.stringify(Campaign.to_dict(), "", false, true)), "", false, true)
	assert_str(after).is_equal(before)
	Campaign.active = false  # leave the suite in sandbox mode


func test_weather_state_round_trip_is_deterministic() -> void:
	var weather_a: Node = (load("res://model/weather.gd") as GDScript).new()
	weather_a.setup(7)
	weather_a.advance_to(0.5)
	var snap: Dictionary = weather_a.to_dict()
	weather_a.advance_to(1.0)
	var expect: float = weather_a.wind_cf("de_north_benelux", true)

	var weather_b: Node = (load("res://model/weather.gd") as GDScript).new()
	weather_b.setup(7)  # factors derive from setup; state overwritten below
	weather_b.from_dict(JSON.parse_string(
		JSON.stringify(snap, "", false, true)))
	weather_b.advance_to(1.0)
	assert_float(weather_b.wind_cf("de_north_benelux", true)).is_equal(expect)
	weather_a.free()
	weather_b.free()


func test_economy_state_round_trip() -> void:
	var before_dict: Dictionary = Economy.to_dict()
	before_dict["treasury_eur"] = 123456789.5
	before_dict["delivered_mwh"] = 42.25
	Economy.from_dict(before_dict)
	var after: Dictionary = Economy.to_dict()
	assert_float(float(after["treasury_eur"])).is_equal(123456789.5)
	assert_float(float(after["delivered_mwh"])).is_equal(42.25)


# ------------------------------------------------------------- C1: rails & rubric truth

class FakeSnapBridge:
	extends RefCounted
	var snapshots := 0

	func snapshot(_id: String) -> Dictionary:
		snapshots += 1
		return {"_status": 200, "model_hash": "test", "version": 2, "blob": {}}


func _fresh_campaign(milestone: int = 0) -> void:
	Campaign.load_data()
	Campaign.start_campaign()
	Campaign.milestone_index = milestone


func _leave_sandbox() -> void:
	Campaign.active = false
	Campaign.failed_reason = ""


static func _event(kind: String, island: String, t_sim: float) -> Dictionary:
	return {"kind": kind, "element": island, "t_sim": t_sim, "data": {}}


## engine_end defaults to game time (a rebuild-free run, where the two
## clocks are identical); pass an explicit engine_end to model a rebuilt
## backend whose engine clock restarted.
static func _result(events: Array, day: float, engine_end: float = -1.0) -> Dictionary:
	if engine_end < 0.0:
		engine_end = day * 86400.0
	return {"events": events, "zones": {}, "islands": {},
		"t_sim_end": engine_end}


## The failure trackers see EVERY step — a day-8 blackout reaches
## _check_failures even though milestone 2's window opens at day 12; the
## milestone accumulator stays window-guarded. (The guard used to sit
## above the whole event scan.)
func test_failure_trackers_see_prewindow_events() -> void:
	_fresh_campaign(1)  # merit_order, window [12, 24]
	Campaign._accumulate(_result(
		[_event("blackout", "island:0", 8.0 * 86400.0)], 8.0), 8.0)
	assert_int(Campaign.blackout_days.size()).is_equal(1)
	assert_int(int(Campaign.acc["blackouts"])).is_equal(0)
	Campaign._accumulate(_result(
		[_event("blackout", "island:0", 13.0 * 86400.0)], 13.0), 13.0)
	assert_int(Campaign.blackout_days.size()).is_equal(2)
	assert_int(int(Campaign.acc["blackouts"])).is_equal(1)
	_leave_sandbox()


## D1 (ledger 50): stages coalesce into ONE incident per island per
## 15-min block; a different island or a later block is a new incident.
func test_ufls_stages_coalesce_to_one_incident() -> void:
	_fresh_campaign(1)
	var t := 12.5 * 86400.0
	Campaign._accumulate(_result([
		_event("ufls_stage", "island:0", t),
		_event("ufls_stage", "island:0", t + 2.0),
		_event("ufls_stage", "island:0", t + 5.0),
	], 12.5), 12.5)
	assert_int(int(Campaign.acc["ufls_events"])).is_equal(1)
	assert_int(Campaign.ufls_days.size()).is_equal(1)
	Campaign._accumulate(_result([
		_event("ufls_stage", "island:1", t + 6.0),   # other island: new incident
		_event("ufls_stage", "island:0", t + 950.0),  # next block: new incident
	], 12.51), 12.51)
	assert_int(int(Campaign.acc["ufls_events"])).is_equal(3)
	assert_int(Campaign.ufls_days.size()).is_equal(3)
	_leave_sandbox()


## The blocking C1-review find: engine t_sim restarts at 0 on every
## rebuild-triggered net/reset, so incident keys MUST derive from game
## time — identical engine coordinates in two registrations are two
## different incidents.
func test_ufls_incidents_survive_backend_rebuild() -> void:
	_fresh_campaign(1)
	# generation 1: young engine clock (registered at day 12.49)
	Campaign._accumulate(_result(
		[_event("ufls_stage", "island:0", 890.0)], 12.51, 900.0), 12.51)
	assert_int(int(Campaign.acc["ufls_events"])).is_equal(1)
	# generation 2 after a rebuild: the SAME engine coordinates, later game day
	Campaign._accumulate(_result(
		[_event("ufls_stage", "island:0", 890.0)], 12.71, 900.0), 12.71)
	assert_int(int(Campaign.acc["ufls_events"])).is_equal(2)
	assert_int(Campaign.ufls_days.size()).is_equal(2)
	_leave_sandbox()


## D1 extension: a split cascade birthing several dead pockets in one
## block is ONE blackout incident for the dismissal ladder.
func test_blackout_pockets_coalesce_to_one_incident() -> void:
	_fresh_campaign(1)
	var t := 13.0 * 86400.0
	Campaign._accumulate(_result([
		_event("blackout", "island:1", t),
		_event("blackout", "island:2", t + 0.5),
		_event("blackout", "island:3", t + 1.0),
	], 13.0), 13.0)
	assert_int(Campaign.blackout_days.size()).is_equal(1)
	assert_int(int(Campaign.acc["blackouts"])).is_equal(1)
	_leave_sandbox()


## D3 (ledger 52): the finale exam is only real with BOTH components —
## a hub-less world must not pass by under-building.
func test_hubless_double_contingency_is_unmet() -> void:
	_fresh_campaign(6)
	var criteria := {"double_contingency_survived": true}
	# never fired at all -> unmet
	assert_str(Campaign._first_unmet(criteria)).is_equal("double_contingency_survived")
	# fired without a hub -> still unmet
	Campaign.acc["double_contingency_fired"] = true
	Campaign.acc["dc_unit_fired"] = true
	Campaign.acc["dc_hub_fired"] = false
	assert_str(Campaign._first_unmet(criteria)).is_equal("double_contingency_survived")
	# both components, no blackout -> met
	Campaign.acc["dc_hub_fired"] = true
	assert_str(Campaign._first_unmet(criteria)).is_equal("")
	# both components, blackout -> unmet
	Campaign.acc["double_contingency_blackout"] = true
	assert_str(Campaign._first_unmet(criteria)).is_equal("double_contingency_survived")
	_leave_sandbox()


## D2 (ledger 51): the cost window bills annualized capex, loan interest
## and penalties alongside the operating books — numeric fixture.
func test_cost_window_includes_capex_interest_penalties() -> void:
	var saved: Dictionary = Economy.to_dict()
	_fresh_campaign(1)
	Campaign.acc["cost_window_start"] = {"fuel": 0.0, "co2": 0.0, "vom": 0.0,
		"fom": 0.0, "voll": 0.0, "redispatch": 0.0, "capex_annuity": 0.0,
		"interest": 0.0, "penalties": 0.0, "delivered": 0.0}
	Economy.fuel_cost = 100.0
	Economy.co2_cost = 0.0
	Economy.vom_cost = 0.0
	Economy.fom_cost = 0.0
	Economy.voll_penalty = 0.0
	Economy.redispatch_cost = 0.0
	Economy.capex_annuity_eur = 50.0
	Economy.loan_eur = 25.0
	Economy.penalty_cost = 25.0
	Economy.delivered_mwh = 2.0
	assert_float(Campaign._window_avg_cost()).is_equal(100.0)
	Economy.from_dict(saved)
	_leave_sandbox()


func test_book_penalty_moves_treasury_and_category() -> void:
	var treasury_0: float = Economy.treasury_eur
	var penalty_0: float = Economy.penalty_cost
	Economy.book_penalty(1e6)
	assert_float(Economy.treasury_eur).is_equal(treasury_0 - 1e6)
	assert_float(Economy.penalty_cost).is_equal(penalty_0 + 1e6)
	Economy.treasury_eur = treasury_0
	Economy.penalty_cost = penalty_0


## First-ever execution of the §5.3 failure states (synthetic).
func test_insolvency_fires() -> void:
	var saved: Dictionary = Economy.to_dict()
	_fresh_campaign(0)
	Economy.treasury_eur = -3e9
	Campaign._check_failures(10.0)
	assert_str(Campaign.failed_reason).is_equal("")
	assert_float(Campaign.insolvent_since_day).is_equal(10.0)
	Campaign._check_failures(13.1)  # >= 3 sim-days under water
	assert_str(Campaign.failed_reason).is_equal("insolvency")
	Economy.from_dict(saved)
	_leave_sandbox()


func test_dismissal_fires_on_blackout_and_ufls_rates() -> void:
	var saved: Dictionary = Economy.to_dict()
	Economy.treasury_eur = 1e9  # keep insolvency quiet
	_fresh_campaign(0)
	Campaign.blackout_days = [1.0, 2.0, 3.0]
	Campaign._check_failures(5.0)
	assert_str(Campaign.failed_reason).is_equal("dismissed_blackouts")
	_fresh_campaign(0)
	for i in range(13):
		Campaign.ufls_days.append(1.0 + 0.5 * i)
	Campaign._check_failures(8.0)
	assert_str(Campaign.failed_reason).is_equal("dismissed_ufls")
	Economy.from_dict(saved)
	_leave_sandbox()


## Unlock enforcement (C1): 2025 locked, post-year open, sandbox open.
func test_unlock_matrix() -> void:
	var t_0: float = GameClock.t_sim
	_fresh_campaign(0)
	GameClock.t_sim = 0.0  # 2025
	assert_bool(Campaign.unlocked("battery")).is_false()
	assert_int(Campaign.unlock_year("battery")).is_equal(2027)
	GameClock.t_sim = 24.0 * 86400.0  # day 24 -> 2027
	assert_bool(Campaign.unlocked("battery")).is_true()
	assert_bool(Campaign.unlocked("hvdc_converter")).is_false()  # 2028
	Campaign.active = false  # sandbox: everything open
	assert_bool(Campaign.unlocked("hvdc_converter")).is_true()
	GameClock.t_sim = t_0
	_leave_sandbox()


## Autosave (§5.3/D7): quiesce refusal is honest, success writes a file
## whose campaign+clock sections round-trip.
func test_autosave_quiesce_refusal_then_success() -> void:
	var last_0: Dictionary = Orchestrator.last_result
	var t_0: float = GameClock.t_sim
	var path := "user://test_autosave_c1.json"
	# refusal: an unsettled island refuses the save before any bridge call
	Orchestrator.last_result = {"islands": {"0": {"f_hz": 49.0}}}
	var refused: Dictionary = await SaveLoad.save_game(path)
	assert_bool(bool(refused.get("ok", true))).is_false()
	assert_str(str(refused.get("reason", ""))).is_equal("not_quiesced")
	# success: quiesced island + fake snapshot bridge, no backend
	var bridge := FakeSnapBridge.new()
	SaveLoad.bridge_override = bridge
	Orchestrator.last_result = {"islands": {"0": {"f_hz": 50.0}}}
	_fresh_campaign(3)
	GameClock.t_sim = 50.0 * 86400.0
	var res: Dictionary = await SaveLoad.save_game(path)
	assert_bool(bool(res.get("ok", false))).is_true()
	assert_int(bridge.snapshots).is_equal(1)
	assert_bool(FileAccess.file_exists(path)).is_true()
	# the envelope's campaign + clock sections restore what was saved
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	Campaign.milestone_index = 0
	Campaign.from_dict(envelope.get("campaign", {}))
	assert_int(Campaign.milestone_index).is_equal(3)
	assert_float(float((envelope.get("clock", {}) as Dictionary)
		.get("t_sim", 0.0))).is_equal(50.0 * 86400.0)
	SaveLoad.bridge_override = null
	Orchestrator.last_result = last_0
	GameClock.t_sim = t_0
	# the day-50 from_dict re-applied era 2 (CO2 100) into the shared
	# Economy/Dispatch cfg — re-anchor the era baseline for later suites
	Campaign.load_data()
	Campaign.start_campaign()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_leave_sandbox()
