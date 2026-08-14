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
