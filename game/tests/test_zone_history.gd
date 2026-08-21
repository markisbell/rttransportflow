extends GdUnitTestSuite
## ZoneHistory — the measured-week ring behind the site notes' graphs:
## slot stamping, group mapping (incl. the h2 fuel override), week
## rollover invalidation, and the negative sign convention surviving
## the ring untouched.


func before_test() -> void:
	ZoneHistory.clear()
	World.plants["zh_coal"] = {"kind": "coal", "tile": Vector2i(4, 4),
		"p_max_mw": 800.0}
	World.plants["zh_gas"] = {"kind": "gas_ccgt", "tile": Vector2i(5, 4),
		"p_max_mw": 800.0, "fuel": "h2"}
	World.plants["zh_bat"] = {"kind": "battery", "tile": Vector2i(6, 4),
		"p_max_mw": 300.0}
	Dispatch.home_zone = {"zh_coal": "hamburg", "zh_gas": "hamburg",
		"zh_bat": "hamburg"}


func after_test() -> void:
	for pid in ["zh_coal", "zh_gas", "zh_bat"]:
		World.plants.erase(pid)
	Dispatch.home_zone = {}
	ZoneHistory.clear()
	GameClock.t_sim = 0.0


func _step(devices: Dictionary) -> void:
	ZoneHistory._on_step(0, {"devices": devices})


func test_records_measured_block() -> void:
	GameClock.t_sim = 3.0 * 86400.0 + 7.5 * 3600.0  # day 3, 07:30
	var i := ZoneHistory.now_block()
	assert_bool(ZoneHistory.valid(i)).is_false()
	_step({"zh_coal": {"p_mw": 640.0}, "zh_bat": {"p_mw": -120.0}})
	assert_bool(ZoneHistory.valid(i)).is_true()
	assert_float(ZoneHistory.zone_gen_at("hamburg", "coal", i)) \
		.is_equal_approx(640.0, 0.01)
	# charging stays NEGATIVE in the ring — the chart splits by sign
	assert_float(ZoneHistory.zone_gen_at("hamburg", "battery", i)) \
		.is_equal_approx(-120.0, 0.01)
	assert_float(ZoneHistory.plant_p_at("zh_bat", i)) \
		.is_equal_approx(-120.0, 0.01)


func test_h2_fuel_override_groups_as_hydrogen() -> void:
	GameClock.t_sim = 86400.0
	var i := ZoneHistory.now_block()
	_step({"zh_gas": {"p_mw": 400.0}})
	assert_float(ZoneHistory.zone_gen_at("hamburg", "h2", i)) \
		.is_equal_approx(400.0, 0.01)
	assert_float(ZoneHistory.zone_gen_at("hamburg", "gas", i)).is_zero()


func test_week_rollover_invalidates_old_slots() -> void:
	GameClock.t_sim = 2.0 * 86400.0
	var i := ZoneHistory.now_block()
	_step({"zh_coal": {"p_mw": 500.0}})
	assert_bool(ZoneHistory.valid(i)).is_true()
	# same slot, next week: the stale stamp must read invalid
	GameClock.t_sim += 7.0 * 86400.0
	assert_bool(ZoneHistory.valid(i)).is_false()
