extends GdUnitTestSuite
## Demand model tests (GAME_DESIGN §2.2): shape, weekend, seasons,
## temperature coupling, determinism, noise band.

const WeatherScript := preload("res://model/weather.gd")
const DemandScript := preload("res://model/demand.gd")

## Injected zone fixtures (regions resolve via the shipped-map projection:
## winterville → Scandinavia-S, sunnyburg → Iberia, steadytown → central).
const ZONES := {
	"winterville": {"peak_mw": 1000.0, "season": "winter", "temp_coeff": 1.8,
		"tiles": [Vector2i(40, 30)]},
	"sunnyburg": {"peak_mw": 800.0, "season": "summer", "temp_coeff": 1.5,
		"tiles": [Vector2i(20, 62)]},
	"steadytown": {"peak_mw": 500.0, "season": "flat", "temp_coeff": 0.0,
		"tiles": [Vector2i(50, 40)]},
}


func _make(seed_value: int) -> Array:
	var weather: Node = auto_free(WeatherScript.new())
	weather.setup(seed_value)
	var demand: Node = auto_free(DemandScript.new())
	demand.setup(seed_value)
	demand.weather = weather
	demand.zone_override = ZONES.duplicate(true)
	return [weather, demand]


func test_evening_peak_above_night_valley() -> void:
	var demand: Node = _make(2)[1]
	var night: float = demand.zone_mw_base("winterville", 0.0 + 3.0 / 24.0)
	var evening: float = demand.zone_mw_base("winterville", 0.0 + 18.5 / 24.0)
	assert_float(evening).is_greater(night * 1.3)


func test_weekend_below_workday() -> void:
	# steadytown has temp_coeff 0 => W = 1; compare the same month across
	# years and divide out growth. Day 0 (dow 0, workday) vs day 48
	# (year 4, January, dow 48 % 7 = 6, weekend).
	var demand: Node = _make(2)[1]
	var workday: float = demand.zone_mw_base("steadytown", 0.0 + 18.5 / 24.0)
	var weekend: float = demand.zone_mw_base("steadytown", 48.0 + 18.5 / 24.0) \
		/ pow(1.015, 4)
	assert_float(weekend).is_less(workday)


func test_summer_zone_peaks_afternoon_in_july() -> void:
	var demand: Node = _make(4)[1]
	var best_h := -1.0
	var best := -1.0
	for quarter in range(96):
		var h := quarter * 0.25
		var value: float = demand.zone_mw_base("sunnyburg", 6.0 + h / 24.0)
		if value > best:
			best = value
			best_h = h
	assert_float(best_h).is_between(13.0, 16.0)


func test_cold_snap_raises_winter_demand() -> void:
	var free: Array = _make(6)
	var snapped: Array = _make(6)
	(snapped[0] as Node).force_window("temp_delta", "", 0.0, 1.0, -10.0)
	var t := 0.0 + 18.5 / 24.0
	var base_free: float = (free[1] as Node).zone_mw_base("winterville", t)
	var base_snapped: float = (snapped[1] as Node).zone_mw_base("winterville", t)
	assert_float(base_snapped).is_greater(base_free * 1.1)


func test_determinism_per_seed() -> void:
	var a: Node = _make(5)[1]
	var b: Node = _make(5)[1]
	for step in range(1, 51):
		var t := step / 96.0
		assert_float(a.zone_mw("winterville", t)).is_equal(b.zone_mw("winterville", t))


func test_noise_band_within_two_percent() -> void:
	var demand: Node = _make(7)[1]
	for step in range(1, 101):
		var t := step / 96.0
		var with_noise: float = demand.zone_mw("steadytown", t)
		var base: float = demand.zone_mw_base("steadytown", t)
		assert_float(absf(with_noise / base - 1.0)).is_less_equal(0.0151)
