extends Node
## Demand — per-zone load model (authority: docs/GAME_DESIGN.md §2.2):
## P_z(t) = peak · G(y) · S_z(m) · D_class(τ, dow) · W_z(T) · (1 + noise).
## Seeded and deterministic; per-zone AR(1) band noise (±1.5 %) is keyed by
## hash(seed, zone id) so evaluation ORDER never changes histories.
##
## Zone data comes from World.load_centers (peak_mw, season, temp_coeff,
## tiles) unless a test injects `zone_override`; the zone's weather region
## resolves via Weather.region_of_tile with the map projection (`projection`
## property — assigned from the map document by BuildSession.load_map).
##
## Documented interpretations of §2.2 (the spec leaves these to the
## implementation): weekend scales the SHAPED part around the 0.62 valley
## (D' = 0.62 + 0.86·(D − 0.62)); flat/industrial zones use 60 % base +
## 40 % shape (D_flat = 0.6 + 0.4·D); the summer-south daily variant moves
## the 14:00 anchor to 1.00 and 18:30 to 0.93; year = floor(t_days / 12)
## (representative-day calendar: 12 epoch days per year).
##
## Runs as the `Demand` autoload or as a plain instanced Node (tests).

const NOISE_TAU_H := 1.0
const NOISE_SIGMA := 0.0075  # stationary sigma; clamped to the ±1.5 % band
const NOISE_CLAMP := 0.015
const DT_HOURS := 0.25
const STEPS_PER_DAY := 96

## Workday daily-shape anchors (hour -> factor), winter/default class.
const ANCHORS_DEFAULT: Array = [
	[0.0, 0.70], [3.0, 0.62], [6.0, 0.68], [7.5, 0.84], [9.0, 0.95],
	[12.0, 0.97], [14.0, 0.93], [17.0, 0.97], [18.5, 1.00], [21.0, 0.88],
	[23.0, 0.76], [24.0, 0.70],
]
## Summer-south variant: A/C peak at 14:00, softer evening.
const ANCHORS_SUMMER: Array = [
	[0.0, 0.70], [3.0, 0.62], [6.0, 0.68], [7.5, 0.84], [9.0, 0.95],
	[12.0, 0.97], [14.0, 1.00], [17.0, 0.97], [18.5, 0.93], [21.0, 0.88],
	[23.0, 0.76], [24.0, 0.70],
]

var weather: Node = null  # injected (the Weather autoload in-game)
var zone_override: Dictionary = {}  # tests: id -> {peak_mw, season, temp_coeff, tiles}
## FIXTURE fallback only (v1-era numbers): BuildSession.load_map assigns
## the real map's projection block on every boot; a test fixture without
## one keeps this default so region resolution stays deterministic.
var projection: Dictionary = {
	"lon0": -20.0, "lat0": 71.0,
	"deg_lon_per_tile": 0.72955, "deg_lat_per_tile": 0.449156,
}

var _seed := 0
var _noise: Dictionary = {}  # zone id -> {rng, x, last_step}
var _region_cache: Dictionary = {}


func _ready() -> void:
	if weather == null:
		weather = get_node_or_null("/root/Weather")


func setup(seed_value: int) -> void:
	_seed = seed_value
	_noise.clear()
	_region_cache.clear()


func zone_mw(lc_id: String, t_days: float) -> float:
	return zone_mw_base(lc_id, t_days) * (1.0 + _noise_value(lc_id, t_days))


## Deterministic component (no noise) — also the dispatcher's forecast.
func zone_mw_base(lc_id: String, t_days: float) -> float:
	var zone := _zone(lc_id)
	if zone.is_empty():
		return 0.0
	var peak: float = float(zone.get("peak_mw", 0.0))
	var season := str(zone.get("season", "flat"))
	return peak * _growth(t_days) * _seasonal(season, _month(t_days)) \
		* _daily(season, t_days) * _weather_factor(lc_id, zone, t_days)


## Forecast variant: deterministic shape evaluated against the CURRENT
## weather state — NEVER advances the stochastic processes (a 24 h forecast
## loop was dragging the weather timeline a day ahead per dispatch block;
## found in P6 integration).
func zone_mw_forecast(lc_id: String, t_days: float) -> float:
	var zone := _zone(lc_id)
	if zone.is_empty():
		return 0.0
	var peak: float = float(zone.get("peak_mw", 0.0))
	var season := str(zone.get("season", "flat"))
	return peak * _growth(t_days) * _seasonal(season, _month(t_days)) \
		* _daily(season, t_days) * _weather_factor(lc_id, zone, t_days, false)


func total_mw(t_days: float, zone_ids: Array) -> float:
	var total := 0.0
	for lc_id in zone_ids:
		total += zone_mw(str(lc_id), t_days)
	return total


# ---------------------------------------------------------------- factors

## Growth: +1.5 %/yr for the first 5 years, +2.5 %/yr after (electrification),
## scaled by the difficulty knob — how fast the world electrifies is a
## scenario choice, unlike the physics it drives.
func _growth(t_days: float) -> float:
	var year := int(floor(t_days / 12.0))
	var scale := Sandbox.knob("demand_growth")
	return pow(1.0 + 0.015 * scale, mini(year, 5)) \
		* pow(1.0 + 0.025 * scale, maxi(year - 5, 0))


func _month(t_days: float) -> int:
	return int(floor(t_days)) % 12  # 0 = January epoch day


func _seasonal(season: String, m: int) -> float:
	match season:
		"winter":
			return 0.87 + 0.13 * cos(TAU * m / 12.0)  # 1.00 Dec/Jan, 0.74 Jul
		"summer":
			return 0.91 + 0.09 * cos(TAU * (m - 6.5) / 12.0)  # 1.00 Jul/Aug, 0.82 Jan
	return 0.95 + 0.04 * cos(TAU * m / 12.0)  # flat 0.95 ± 0.04


func _daily(season: String, t_days: float) -> float:
	var h: float = (t_days - floor(t_days)) * 24.0
	var anchors: Array = ANCHORS_SUMMER if season == "summer" else ANCHORS_DEFAULT
	var shape := 1.0
	for i in range(anchors.size() - 1):
		var a: Array = anchors[i]
		var b: Array = anchors[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			var f: float = (h - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-9)
			shape = lerpf(float(a[1]), float(b[1]), f)
			break
	if season == "flat":
		shape = 0.6 + 0.4 * shape  # industrial: 60 % base + 40 % shape
	var dow := int(floor(t_days)) % 7
	if dow >= 5:  # weekend scales the shaped part around the 0.62 valley
		shape = 0.62 + 0.86 * (shape - 0.62)
	return shape


func _weather_factor(lc_id: String, zone: Dictionary, t_days: float,
		advance: bool = true) -> float:
	if weather == null:
		return 1.0
	if advance:
		weather.advance_to(t_days)  # idempotent, monotonic
	var region := _region_for(lc_id, zone)
	if region == "":
		return 1.0
	var temp: float = weather.temperature_c(region)
	var coeff: float = float(zone.get("temp_coeff", 1.0)) / 100.0
	if str(zone.get("season", "flat")) == "summer":
		return 1.0 + coeff * maxf(temp - 24.0, 0.0)  # cooling
	return 1.0 + coeff * maxf(10.0 - temp, 0.0)  # heating


# ---------------------------------------------------------------- plumbing

func _zone(lc_id: String) -> Dictionary:
	if zone_override.has(lc_id):
		return zone_override[lc_id]
	# Runtime lookup (not the bare autoload identifier): keeps the script
	# compiling standalone and usable as a plain instanced Node in tests.
	if is_inside_tree():
		var world := get_node_or_null("/root/World")
		if world != null and (world.get("load_centers") as Dictionary).has(lc_id):
			return world.get("load_centers")[lc_id]
	return {}


func _region_for(lc_id: String, zone: Dictionary) -> String:
	if _region_cache.has(lc_id):
		return _region_cache[lc_id]
	var tiles: Array = zone.get("tiles", [])
	if tiles.is_empty() or weather == null:
		return ""
	var region: String = weather.region_of_tile(tiles[0], projection)
	_region_cache[lc_id] = region
	return region


## Per-zone AR(1) noise, own RNG keyed by (seed, zone) — call-order safe.
func _noise_value(lc_id: String, t_days: float) -> float:
	if not _noise.has(lc_id):
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("%d:%s" % [_seed, lc_id])
		_noise[lc_id] = {"rng": rng, "x": 0.0, "last_step": 0}
	var state: Dictionary = _noise[lc_id]
	var target := int(floor(t_days * STEPS_PER_DAY + 1e-9))
	var a := exp(-DT_HOURS / NOISE_TAU_H)
	var s := sqrt(1.0 - a * a)
	while int(state["last_step"]) < target:
		state["last_step"] = int(state["last_step"]) + 1
		state["x"] = a * float(state["x"]) \
			+ s * NOISE_SIGMA * (state["rng"] as RandomNumberGenerator).randfn()
	return clampf(float(state["x"]), -NOISE_CLAMP, NOISE_CLAMP)


# ---------------------------------------------------------------- save/load

## Per-zone AR(1) noise state (P9 save); RNG states as strings (JSON floats
## every number — a uint64 would lose precision).
func to_dict() -> Dictionary:
	var noise := {}
	for lc_id: String in _noise:
		var state: Dictionary = _noise[lc_id]
		noise[lc_id] = {"rng_state": str((state["rng"] as RandomNumberGenerator).state),
			"x": float(state["x"]), "last_step": int(state["last_step"])}
	return {"seed": _seed, "noise": noise}


func from_dict(state: Dictionary) -> void:
	_seed = int(state.get("seed", 0))
	_noise.clear()
	_region_cache.clear()
	var noise: Dictionary = state.get("noise", {})
	for lc_id: String in noise:
		var entry: Dictionary = noise[lc_id]
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("%d:%s" % [_seed, lc_id])
		rng.state = int(str(entry.get("rng_state", "0")))
		_noise[lc_id] = {"rng": rng, "x": float(entry.get("x", 0.0)),
			"last_step": int(entry.get("last_step", 0))}
