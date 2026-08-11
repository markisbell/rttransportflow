extends GdUnitTestSuite
## Weather model tests (PARAMETERS §3): determinism, bounds, long-run CF
## targets, force_* hooks, Dunkelflaute scoping, Cholesky sanity, regions.

const WeatherScript := preload("res://model/weather.gd")


func _make(seed_value: int) -> Node:
	var weather: Node = auto_free(WeatherScript.new())
	weather.setup(seed_value)
	return weather


func test_same_seed_reproducible() -> void:
	var a := _make(7)
	var b := _make(7)
	for step in range(1, 201):
		var t := step / 96.0
		a.advance_to(t)
		b.advance_to(t)
		assert_float(a.wind_cf("british_isles", false)) \
			.is_equal(b.wind_cf("british_isles", false))
		assert_float(a.temperature_c("iberia")).is_equal(b.temperature_c("iberia"))


func test_different_seeds_differ() -> void:
	var a := _make(7)
	var b := _make(8)
	var diverged := false
	for step in range(1, 201):
		var t := step / 96.0
		a.advance_to(t)
		b.advance_to(t)
		if absf(a.wind_cf("british_isles", false)
				- b.wind_cf("british_isles", false)) > 1e-9:
			diverged = true
	assert_bool(diverged).is_true()


func test_cf_bounded() -> void:
	var weather := _make(11)
	for step in range(1, 201):
		weather.advance_to(step / 96.0)
		for region: String in ["iberia", "british_isles", "greece_aegean"]:
			var cf_on: float = weather.wind_cf(region, false)
			var cf_off: float = weather.wind_cf(region, true)
			var cf_pv: float = weather.pv_cf(region)
			assert_bool(cf_on >= 0.0 and cf_on <= 1.0).is_true()
			assert_bool(cf_off >= 0.0 and cf_off <= 1.0).is_true()
			assert_bool(cf_pv >= 0.0 and cf_pv <= 1.0).is_true()


func test_long_run_mean_wind_cf_hits_table_target() -> void:
	# 60 epoch days = 5 full seasonal cycles (12 representative days = 1 year).
	var weather := _make(3)
	var acc := 0.0
	var n := 0
	for step in range(1, 60 * 96 + 1):
		weather.advance_to(step / 96.0)
		acc += weather.wind_cf("british_isles", false)
		n += 1
	var mean := acc / n
	assert_float(mean).is_between(0.32 - 0.08, 0.32 + 0.08)


func test_pv_zero_at_night_positive_at_summer_noon() -> void:
	var weather := _make(5)
	weather.advance_to(6.0 + 2.0 / 24.0)  # July epoch day, 02:00
	assert_float(weather.pv_cf("iberia")).is_equal(0.0)
	weather.advance_to(6.0 + 12.0 / 24.0)  # July, solar noon
	assert_float(weather.pv_cf("iberia")).is_greater(0.15)


func test_force_wind_lambda_scale_is_exact() -> void:
	# Same seed => identical OU states; the force scales λ linearly.
	var free := _make(9)
	var forced := _make(9)
	forced.force_window("wind_lambda_scale", "british_isles", 0.0, 10.0, 0.35)
	free.advance_to(5.5)
	forced.advance_to(5.5)
	assert_float(forced.wind_speed("british_isles", false)) \
		.is_equal_approx(0.35 * free.wind_speed("british_isles", false), 1e-6)


func test_dunkelflaute_force_scopes_to_nw_zone() -> void:
	var free := _make(13)
	var forced := _make(13)
	forced.force_window("dunkelflaute", "", 0.0, 10.0, 1.0)
	free.advance_to(2.25)
	forced.advance_to(2.25)
	assert_bool(forced.dunkelflaute_active()).is_true()
	# NW region: wind λ × 0.35 and temperature −3 °C
	assert_float(forced.wind_speed("british_isles", false)) \
		.is_equal_approx(0.35 * free.wind_speed("british_isles", false), 1e-6)
	assert_float(forced.temperature_c("british_isles")) \
		.is_equal_approx(free.temperature_c("british_isles") - 3.0, 1e-6)
	# Non-NW region untouched
	assert_float(forced.wind_speed("iberia", false)) \
		.is_equal_approx(free.wind_speed("iberia", false), 1e-9)
	assert_float(forced.temperature_c("iberia")) \
		.is_equal_approx(free.temperature_c("iberia"), 1e-9)


func test_cholesky_reconstructs_sigma() -> void:
	var weather := _make(1)
	var pair: Array = weather.correlation_and_factor_wind()
	var sigma: Array = pair[0]
	var l: Array = pair[1]
	var n: int = sigma.size()
	for i in range(n):
		for j in range(n):
			var acc := 0.0
			for k in range(n):
				acc += float(l[i][k]) * float(l[j][k])
			assert_float(acc).is_equal_approx(float(sigma[i][j]), 1e-9)


func test_region_lookup() -> void:
	var weather := _make(1)
	assert_str(weather.region_of_latlon(40.4, -3.7)).is_equal("iberia")
	assert_str(weather.region_of_latlon(52.5, 13.4)).is_equal("poland_baltic")
	# London-ish tile on the shipped map projection
	var projection := {"lon0": -20.0, "lat0": 71.0,
		"deg_lon_per_tile": 0.72955, "deg_lat_per_tile": 0.449156}
	assert_str(weather.region_of_tile(Vector2i(26, 42), projection)) \
		.is_equal("british_isles")
