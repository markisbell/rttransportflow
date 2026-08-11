extends Node
## Weather — seeded, deterministic regional weather (authority:
## docs/PARAMETERS.md §3). 12 regions with correlated OU processes
## (Cholesky of exp(−d/L) correlation matrices), Weibull-transformed wind,
## clear-sky solar geometry with stochastic clearness, the Dunkelflaute
## Markov regime over the NW macro-zone, and `force_*` override windows as
## THE test hook (family pattern; LAST-registered wins).
##
## Time base: the representative-day calendar — campaign day N is the epoch
## day of month N % 12 (doy = mid-month), hour = fract(t_days)·24. All
## stochastic state advances in fixed 15-min steps via `advance_to()`;
## identical seeds → identical histories (fixed draw order per step:
## regions in table order, wind → solar → temp → regime).
##
## Documented deviations from §3: the per-farm ε_farm OU is skipped (farm
## smoothing is implicit at 50 km tiles); the cut-out restart hysteresis
## (10 min below 22 m/s) is realized as one 15-min step below 22 m/s;
## solar hour angle uses local epoch-hour without longitude offset.
##
## Runs as the `Weather` autoload or as a plain instanced Node (tests).

const STEPS_PER_DAY := 96
const DT_HOURS := 0.25
const TAU_WIND_H := 40.0
const TAU_SOLAR_H := 12.0
const TAU_TEMP_H := 24.0
const SIGMA_TEMP_C := 3.0
const L_WIND_KM := 1200.0
const L_SOLAR_KM := 900.0
const L_TEMP_KM := 1500.0
const GAMMA_K20 := 0.8862  # Γ(1.5), onshore Weibull k = 2.0
const GAMMA_K22 := 0.8856  # Γ(1 + 1/2.2), offshore k = 2.2
const CUT_IN := 3.0
const RATED_ON := 11.0
const RATED_OFF := 10.5
const CUT_OUT := 25.0
const RESTART := 22.0
const TILT_GAIN: Array[float] = [1.40, 1.30, 1.20, 1.10, 1.05, 1.00,
	1.02, 1.10, 1.20, 1.30, 1.40, 1.45]
## Global λ calibration so LONG-RUN mean CFs land on the §3.1 table
## targets. The raw formula overshoots (Jensen convexity of the cubic curve
## under the OU spread + seasonal λ swing). Measured (seed 3, 60 epoch days
## = 5 seasonal cycles): scale 1.00 → BI-on 0.408 / IB-on 0.273 / DE-off
## 0.547; scale 0.90 → 0.331 / 0.212 / 0.499 vs targets 0.32 / 0.25 / 0.47.
const LAMBDA_CALIBRATION := 0.90

const DUNKELFLAUTE_ENTRY_PER_DAY := 0.012
const DUNKELFLAUTE_EXIT_PER_DAY := 1.0 / 6.0
const DUNKELFLAUTE_WIND_SCALE := 0.35
const DUNKELFLAUTE_CLEARNESS_SCALE := 0.6
const DUNKELFLAUTE_TEMP_DELTA := -3.0

## PARAMETERS §3.1 table, verbatim (order fixed — draw order depends on it).
## v_off < 0 marks "—" (no offshore); falls back to the onshore process.
const REGIONS: Array[Dictionary] = [
	{"id": "iberia", "lat": 40.0, "lon": -4.0, "v_on": 6.5, "cf_on": 0.25,
		"v_off": 8.5, "cf_off": 0.38, "kc_sum": 0.75, "kc_win": 0.55,
		"cf_pv": 0.18, "t_year": 15.0},
	{"id": "france", "lat": 47.0, "lon": 2.0, "v_on": 6.8, "cf_on": 0.26,
		"v_off": 9.0, "cf_off": 0.42, "kc_sum": 0.65, "kc_win": 0.40,
		"cf_pv": 0.14, "t_year": 12.0},
	{"id": "british_isles", "lat": 54.0, "lon": -2.0, "v_on": 7.8, "cf_on": 0.32,
		"v_off": 10.5, "cf_off": 0.48, "kc_sum": 0.55, "kc_win": 0.30,
		"cf_pv": 0.10, "t_year": 10.0},
	{"id": "de_north_benelux", "lat": 53.0, "lon": 7.0, "v_on": 7.2, "cf_on": 0.28,
		"v_off": 10.0, "cf_off": 0.47, "kc_sum": 0.60, "kc_win": 0.32,
		"cf_pv": 0.11, "t_year": 10.0},
	{"id": "de_south_alps", "lat": 48.0, "lon": 10.0, "v_on": 5.8, "cf_on": 0.21,
		"v_off": -1.0, "cf_off": 0.0, "kc_sum": 0.62, "kc_win": 0.38,
		"cf_pv": 0.12, "t_year": 9.0},
	{"id": "italy", "lat": 42.0, "lon": 13.0, "v_on": 6.0, "cf_on": 0.22,
		"v_off": 7.5, "cf_off": 0.30, "kc_sum": 0.72, "kc_win": 0.50,
		"cf_pv": 0.16, "t_year": 15.0},
	{"id": "scandinavia_s", "lat": 58.0, "lon": 12.0, "v_on": 7.0, "cf_on": 0.28,
		"v_off": 9.5, "cf_off": 0.44, "kc_sum": 0.55, "kc_win": 0.25,
		"cf_pv": 0.10, "t_year": 8.0},
	{"id": "scandinavia_n", "lat": 65.0, "lon": 18.0, "v_on": 7.3, "cf_on": 0.30,
		"v_off": 9.8, "cf_off": 0.45, "kc_sum": 0.50, "kc_win": 0.20,
		"cf_pv": 0.09, "t_year": 2.0},
	{"id": "poland_baltic", "lat": 52.0, "lon": 19.0, "v_on": 6.6, "cf_on": 0.26,
		"v_off": 9.2, "cf_off": 0.43, "kc_sum": 0.58, "kc_win": 0.32,
		"cf_pv": 0.11, "t_year": 9.0},
	{"id": "balkans", "lat": 44.0, "lon": 21.0, "v_on": 5.9, "cf_on": 0.22,
		"v_off": -1.0, "cf_off": 0.0, "kc_sum": 0.68, "kc_win": 0.45,
		"cf_pv": 0.14, "t_year": 12.0},
	{"id": "greece_aegean", "lat": 38.0, "lon": 24.0, "v_on": 7.0, "cf_on": 0.28,
		"v_off": 8.8, "cf_off": 0.38, "kc_sum": 0.78, "kc_win": 0.55,
		"cf_pv": 0.17, "t_year": 17.0},
	{"id": "east", "lat": 47.0, "lon": 26.0, "v_on": 6.2, "cf_on": 0.23,
		"v_off": 8.5, "cf_off": 0.37, "kc_sum": 0.65, "kc_win": 0.42,
		"cf_pv": 0.14, "t_year": 10.0},
]

## §3.4 NW macro-zone (Dunkelflaute effects apply here only).
const NW_ZONE: Array[String] = ["british_isles", "de_north_benelux", "france",
	"de_south_alps", "scandinavia_s", "poland_baltic"]

var _rng := RandomNumberGenerator.new()
var _index := {}  # region id -> row
var _l_wind: Array = []
var _l_solar: Array = []
var _l_temp: Array = []
var _z_wind: Array[float] = []
var _y_solar: Array[float] = []
var _u_temp: Array[float] = []
var _cutout_on: Array[bool] = []
var _cutout_off: Array[bool] = []
var _dunkelflaute := false
var _last_step := 0
var _forces: Array[Dictionary] = []
var _curve_on: Array[float] = []  # smoothed power-curve lookup, 0.1 m/s bins
var _curve_off: Array[float] = []


func _ready() -> void:
	if _index.is_empty():
		setup(0)


## Deterministic init; all state derives from `seed_value`.
func setup(seed_value: int) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed_value
	_index.clear()
	for i in range(REGIONS.size()):
		_index[REGIONS[i]["id"]] = i
	_l_wind = _cholesky(_correlation(L_WIND_KM))
	_l_solar = _cholesky(_correlation(L_SOLAR_KM))
	_l_temp = _cholesky(_correlation(L_TEMP_KM))
	if _curve_on.is_empty():
		_curve_on = _smoothed_curve(RATED_ON)
		_curve_off = _smoothed_curve(RATED_OFF)
	# stationary initial draws (correlated)
	_z_wind = _correlated_noise(_l_wind)
	_y_solar = _correlated_noise(_l_solar)
	_u_temp = _correlated_noise(_l_temp)
	for i in range(_u_temp.size()):
		_u_temp[i] *= SIGMA_TEMP_C
	_cutout_on.clear()
	_cutout_off.clear()
	for _i in range(REGIONS.size()):
		_cutout_on.append(false)
		_cutout_off.append(false)
	_dunkelflaute = false
	_last_step = 0
	_forces.clear()


## Advance all stochastic state to `t_days` (internal fixed 15-min steps;
## idempotent — re-advancing to the past is a no-op).
func advance_to(t_days: float) -> void:
	var target := int(floor(t_days * STEPS_PER_DAY + 1e-9))
	while _last_step < target:
		_last_step += 1
		_advance_one_step(_last_step)


# ---------------------------------------------------------------- forces

## kinds: wind_lambda_scale | clearness_scale | temp_delta | dunkelflaute.
## region "" applies to all regions. LAST-registered wins on overlap.
func force_window(kind: String, region: String, t0_days: float,
		t1_days: float, value: float) -> void:
	_forces.append({"kind": kind, "region": region, "t0": t0_days,
		"t1": t1_days, "value": value})


func clear_forces() -> void:
	_forces.clear()


func _force(kind: String, region: String, t_days: float, default: float) -> float:
	var value := default
	for f: Dictionary in _forces:
		if str(f["kind"]) != kind:
			continue
		if str(f["region"]) != "" and str(f["region"]) != region:
			continue
		if t_days >= float(f["t0"]) and t_days < float(f["t1"]):
			value = float(f["value"])  # last wins
	return value


# ---------------------------------------------------------------- calendar

func month(t_days: float) -> int:
	return int(floor(t_days)) % 12  # 0 = January epoch day


func doy(t_days: float) -> int:
	return int(round(month(t_days) * 30.42)) + 15


func hour(t_days: float) -> float:
	return (t_days - floor(t_days)) * 24.0


# ---------------------------------------------------------------- public state

func dunkelflaute_active() -> bool:
	var t := _last_step / float(STEPS_PER_DAY)
	return _force("dunkelflaute", "", t, 1.0 if _dunkelflaute else 0.0) >= 0.5


func wind_speed(region: String, offshore: bool) -> float:
	var i: int = _index[region]
	var t := _last_step / float(STEPS_PER_DAY)
	return _wind_speed_at(i, offshore, t)


func wind_cf(region: String, offshore: bool) -> float:
	var i: int = _index[region]
	if offshore and _cutout_off[i]:
		return 0.0
	if not offshore and _cutout_on[i]:
		return 0.0
	var v := wind_speed(region, offshore)
	var curve := _curve_off if offshore else _curve_on
	var bin := clampi(int(round(v * 10.0)), 0, curve.size() - 1)
	return curve[bin]


func pv_cf(region: String) -> float:
	var i: int = _index[region]
	var t := _last_step / float(STEPS_PER_DAY)
	var d := doy(t)
	var h := hour(t)
	var lat_rad := deg_to_rad(float(REGIONS[i]["lat"]))
	var decl := deg_to_rad(23.45) * sin(TAU * (284.0 + d) / 365.0)
	var hour_angle := deg_to_rad(15.0 * (h - 12.0))
	var sin_alpha := sin(lat_rad) * sin(decl) \
		+ cos(lat_rad) * cos(decl) * cos(hour_angle)
	if sin_alpha <= 0.0:
		return 0.0
	var kc_bar: float = float(REGIONS[i]["kc_win"]) \
		+ (float(REGIONS[i]["kc_sum"]) - float(REGIONS[i]["kc_win"])) \
		* 0.5 * (1.0 - cos(TAU * (d - 15.0) / 365.0))
	var kc: float = clampf(kc_bar + 0.25 * _y_solar[i], 0.05, 1.0)
	if REGIONS[i]["id"] in NW_ZONE and dunkelflaute_active():
		kc *= DUNKELFLAUTE_CLEARNESS_SCALE
	kc *= _force("clearness_scale", REGIONS[i]["id"], t, 1.0)
	var ghi := 1100.0 * pow(sin_alpha, 1.15) * kc
	var poa := ghi * TILT_GAIN[month(t)]
	var t_cell := temperature_c(region) + 0.034 * poa
	var p_dc_pu := 1.25 * (poa / 1000.0) * (1.0 - 0.004 * (t_cell - 25.0))
	return clampf(minf(0.97 * p_dc_pu, 1.0), 0.0, 1.0)


func temperature_c(region: String) -> float:
	var i: int = _index[region]
	var t := _last_step / float(STEPS_PER_DAY)
	var d := doy(t)
	var h := hour(t)
	var a_t := 9.0 if float(REGIONS[i]["lat"]) > 48.0 else 7.0
	var temp: float = float(REGIONS[i]["t_year"]) \
		- a_t * cos(TAU * (d - 15.0) / 365.0) \
		+ 4.0 * sin(TAU * (h - 9.0) / 24.0) + _u_temp[i]
	if REGIONS[i]["id"] in NW_ZONE and dunkelflaute_active():
		temp += DUNKELFLAUTE_TEMP_DELTA
	return temp + _force("temp_delta", REGIONS[i]["id"], t, 0.0)


func region_of_latlon(lat: float, lon: float) -> String:
	var best := ""
	var best_d := INF
	for region: Dictionary in REGIONS:
		var d := _haversine_km(lat, lon, float(region["lat"]), float(region["lon"]))
		if d < best_d:
			best_d = d
			best = str(region["id"])
	return best


## Inverse of the map's projection block (data/map/europe_v1.json):
## lon = lon0 + (x+0.5)·deg_lon_per_tile, lat = lat0 − (y+0.5)·deg_lat_per_tile.
func region_of_tile(tile: Vector2i, projection: Dictionary) -> String:
	var lon: float = float(projection.get("lon0", -20.0)) \
		+ (tile.x + 0.5) * float(projection.get("deg_lon_per_tile", 0.72955))
	var lat: float = float(projection.get("lat0", 71.0)) \
		- (tile.y + 0.5) * float(projection.get("deg_lat_per_tile", 0.449156))
	return region_of_latlon(lat, lon)


func region_ids() -> Array[String]:
	var ids: Array[String] = []
	for region: Dictionary in REGIONS:
		ids.append(str(region["id"]))
	return ids


# ---------------------------------------------------------------- internals

func _advance_one_step(step: int) -> void:
	var t_days := step / float(STEPS_PER_DAY)
	# fixed draw order: wind, solar, temp (12 each, region order), regime (1)
	var a_w := exp(-DT_HOURS / TAU_WIND_H)
	var s_w := sqrt(1.0 - a_w * a_w)
	var n_w := _correlated_noise(_l_wind)
	for i in range(REGIONS.size()):
		_z_wind[i] = a_w * _z_wind[i] + s_w * n_w[i]
	var a_s := exp(-DT_HOURS / TAU_SOLAR_H)
	var s_s := sqrt(1.0 - a_s * a_s)
	var n_s := _correlated_noise(_l_solar)
	for i in range(REGIONS.size()):
		_y_solar[i] = a_s * _y_solar[i] + s_s * n_s[i]
	var a_t := exp(-DT_HOURS / TAU_TEMP_H)
	var s_t := sqrt(1.0 - a_t * a_t)
	var n_t := _correlated_noise(_l_temp)
	for i in range(REGIONS.size()):
		_u_temp[i] = a_t * _u_temp[i] + s_t * SIGMA_TEMP_C * n_t[i]
	# Dunkelflaute regime (always one draw — keeps the stream aligned)
	var u := _rng.randf()
	var m := month(t_days)
	var winter := m == 10 or m == 11 or m == 0 or m == 1  # Nov–Feb
	if _dunkelflaute:
		if u < DUNKELFLAUTE_EXIT_PER_DAY / STEPS_PER_DAY:
			_dunkelflaute = false
	elif winter and u < DUNKELFLAUTE_ENTRY_PER_DAY / STEPS_PER_DAY:
		_dunkelflaute = true
	# cut-out latches (per region, on & off) against this step's speeds
	for i in range(REGIONS.size()):
		for offshore in [false, true]:
			var v := _wind_speed_at(i, offshore, t_days)
			var latched: bool = _cutout_off[i] if offshore else _cutout_on[i]
			if v >= CUT_OUT:
				latched = true
			elif latched and v <= RESTART:
				latched = false  # one 15-min step below 22 ≥ the 10-min hysteresis
			if offshore:
				_cutout_off[i] = latched
			else:
				_cutout_on[i] = latched


func _wind_speed_at(i: int, offshore: bool, t_days: float) -> float:
	var region: Dictionary = REGIONS[i]
	var v_mean: float = float(region["v_off"]) if offshore else float(region["v_on"])
	if v_mean < 0.0:
		v_mean = float(region["v_on"])  # "—" regions: onshore fallback
	var k := 2.2 if offshore else 2.0
	var gamma := GAMMA_K22 if offshore else GAMMA_K20
	var lambda_bar := v_mean / gamma
	var d := doy(t_days)
	var h := hour(t_days)
	var a_s := 0.18 if float(region["lat"]) > 48.0 else 0.12
	var a_d := 0.0 if offshore else 0.08
	var lam := LAMBDA_CALIBRATION * lambda_bar \
		* (1.0 + a_s * cos(TAU * (d - 15.0) / 365.0)) \
		* (1.0 + a_d * cos(TAU * (h - 15.0) / 24.0))
	if str(region["id"]) in NW_ZONE and dunkelflaute_active():
		lam *= DUNKELFLAUTE_WIND_SCALE
	lam *= _force("wind_lambda_scale", str(region["id"]), t_days, 1.0)
	var phi := clampf(_phi(_z_wind[i]), 1e-6, 1.0 - 1e-6)
	return lam * pow(-log(1.0 - phi), 1.0 / k)


## Raw per-unit power curve, then ±1.5 m/s mean smoothing into 0.1 m/s bins.
func _smoothed_curve(rated: float) -> Array[float]:
	var curve: Array[float] = []
	for bin in range(0, 351):  # 0.0 .. 35.0 m/s
		var v := bin * 0.1
		var acc := 0.0
		var n := 0
		for j in range(-15, 16):
			var w := v + j * 0.1
			acc += _raw_power(maxf(w, 0.0), rated)
			n += 1
		curve.append(acc / n)
	return curve


func _raw_power(v: float, rated: float) -> float:
	if v < CUT_IN or v >= CUT_OUT:
		return 0.0
	if v >= rated:
		return 1.0
	return pow((v - CUT_IN) / (rated - CUT_IN), 3.0)


## Standard normal CDF via the Abramowitz–Stegun erf approximation.
func _phi(z: float) -> float:
	var x := z / sqrt(2.0)
	var sign_x := 1.0 if x >= 0.0 else -1.0
	x = absf(x)
	var t := 1.0 / (1.0 + 0.3275911 * x)
	var y := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
		- 0.284496736) * t + 0.254829592) * t * exp(-x * x)
	return 0.5 * (1.0 + sign_x * y)


func _correlation(length_km: float) -> Array:
	var n := REGIONS.size()
	var sigma: Array = []
	for i in range(n):
		var row: Array[float] = []
		for j in range(n):
			var d := _haversine_km(float(REGIONS[i]["lat"]), float(REGIONS[i]["lon"]),
				float(REGIONS[j]["lat"]), float(REGIONS[j]["lon"]))
			row.append(exp(-d / length_km))
		sigma.append(row)
	return sigma


## Plain Cholesky (Σ is PD for exponential correlation matrices).
func _cholesky(sigma: Array) -> Array:
	var n := sigma.size()
	var l: Array = []
	for i in range(n):
		var row: Array[float] = []
		row.resize(n)
		row.fill(0.0)
		l.append(row)
	for i in range(n):
		for j in range(i + 1):
			var acc: float = sigma[i][j]
			for k in range(j):
				acc -= l[i][k] * l[j][k]
			if i == j:
				l[i][j] = sqrt(maxf(acc, 1e-12))
			else:
				l[i][j] = acc / l[j][j]
	return l


func _correlated_noise(l: Array) -> Array[float]:
	var n := l.size()
	var iid: Array[float] = []
	for _i in range(n):
		iid.append(_rng.randfn())
	var out: Array[float] = []
	for i in range(n):
		var acc := 0.0
		for j in range(i + 1):
			acc += l[i][j] * iid[j]
		out.append(acc)
	return out


func _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dp := deg_to_rad(lat2 - lat1)
	var dl := deg_to_rad(lon2 - lon1)
	var a := sin(dp / 2.0) * sin(dp / 2.0) \
		+ cos(p1) * cos(p2) * sin(dl / 2.0) * sin(dl / 2.0)
	return 6371.0 * 2.0 * atan2(sqrt(a), sqrt(1.0 - a))


## Correlation sanity hook for tests: rebuild Σ_wind and return (Σ, L).
func correlation_and_factor_wind() -> Array:
	return [_correlation(L_WIND_KM), _l_wind]
