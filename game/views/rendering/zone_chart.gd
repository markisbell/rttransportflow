class_name ZoneChart
extends Control
## The weekly site graph, energy-charts style: measured generation stacked
## by source (negatives — charging, electrolysis, pumping, export — hang
## below the zero line), the measured load as a solid line, the load
## FORECAST as a dashed line across the whole week, and a slider marker at
## "now". Also draws the single-series plant variant (output area against
## a P_max limit line, rtpowerflow's Sparkline marker idea). Data comes
## from ZoneHistory (measured) + Demand (forecast); refresh() precomputes
## the columns, _draw() only paints — the owning SubViewport renders once
## per block, not per frame.

const COLS := 168  # one column per hour of the week (672 blocks / 4)
const STRIDE := 4

const GROUP_COLORS := {
	"nuclear": Color8(146, 43, 33),
	"lignite": Color8(133, 100, 68),
	"coal": Color8(82, 84, 92),
	"gas": Color8(233, 138, 44),
	"h2": Color8(64, 186, 178),
	"hydro": Color8(46, 116, 182),
	"wind_off": Color8(23, 84, 142),
	"wind_on": Color8(118, 182, 231),
	"solar": Color8(247, 208, 56),
	"battery": Color8(156, 116, 204),
	"electrolysis": Color8(96, 160, 196),
	"transfer": Color8(168, 172, 150),
}
const STACK_ORDER: Array[String] = ["nuclear", "lignite", "coal", "gas",
	"h2", "hydro", "wind_off", "wind_on", "solar", "battery", "transfer"]

const ACCENT := Color8(127, 209, 255)   # rtpowerflow's sparkline blue
const TEXT := Color(0.92, 0.94, 0.97)
const TEXT_DIM := Color(0.62, 0.67, 0.74)
const GRID_LINE := Color(1, 1, 1, 0.07)
const PAD_L := 46.0
const PAD_R := 10.0
const PAD_T := 30.0
const PAD_B := 24.0

var zone_id := ""       # zone mode when set
var pid := ""           # plant mode when set
var plant_kind := ""

var _title := ""
var _subtitle := ""
var _valid: Array = []          # per column
var _load: Array = []           # measured load (zone mode)
var _forecast: Array = []       # forecast load, full week (zone mode)
var _layers: Array = []         # [{color, base: Array, top: Array}] stacked
var _neg_min := 0.0
var _y_max := 1.0
var _now_frac := 0.0
var _now_text := ""
var _week_day0 := 0


func refresh() -> void:
	_week_day0 = ZoneHistory.week_start_day()
	var now_b := ZoneHistory.now_block()
	_now_frac = clampf(now_b / float(ZoneHistory.BLOCKS), 0.0, 1.0)
	var t_days := GameClock.t_sim / 86400.0
	_now_text = "day %d  %02d:%02d" % [int(t_days),
		int(fmod(t_days, 1.0) * 24.0), int(fmod(t_days * 24.0, 1.0) * 60.0)]
	_valid.resize(COLS)
	if zone_id != "":
		_refresh_zone()
	elif pid != "":
		_refresh_plant()
	queue_redraw()


func _refresh_zone() -> void:
	var lc: Dictionary = World.load_centers.get(zone_id, {})
	_title = str(lc.get("name", zone_id))
	_load.resize(COLS)
	_forecast.resize(COLS)
	var peak := 1.0
	for c in COLS:
		var i := c * STRIDE
		_valid[c] = ZoneHistory.valid(i)
		_load[c] = ZoneHistory.zone_load_at(zone_id, i) if _valid[c] else 0.0
		_forecast[c] = Demand.zone_mw_forecast(zone_id,
			_week_day0 + i / 96.0)
		peak = maxf(peak, maxf(float(_load[c]), float(_forecast[c])))
	# stacked layers in fixed order; sign-split so charging hangs below zero
	_layers.clear()
	_neg_min = 0.0
	var cum_pos: Array = []
	var cum_neg: Array = []
	cum_pos.resize(COLS)
	cum_pos.fill(0.0)
	cum_neg.resize(COLS)
	cum_neg.fill(0.0)
	var present := ZoneHistory.zone_groups(zone_id)
	for group: String in STACK_ORDER:
		if not present.has(group) and group != "electrolysis":
			continue
		_add_layer(group, 1.0, cum_pos)
	for group: String in ["battery", "electrolysis", "hydro", "transfer"]:
		if present.has(group):
			_add_layer(group, -1.0, cum_neg)
	for c in COLS:
		peak = maxf(peak, float(cum_pos[c]))
		_neg_min = minf(_neg_min, float(cum_neg[c]))
	_y_max = _nice_ceil(peak)
	_subtitle = "load %s" % _fmt_mw(ZoneHistory.zone_load_at(
		zone_id, clampi(ZoneHistory.now_block(), 0, ZoneHistory.BLOCKS - 1)))


func _add_layer(group: String, sign: float, cum: Array) -> void:
	var base: Array = cum.duplicate()
	var any := false
	for c in COLS:
		var v := 0.0
		if _valid[c]:
			v = ZoneHistory.zone_gen_at(zone_id, group, c * STRIDE)
			v = maxf(v, 0.0) if sign > 0.0 else minf(v, 0.0)
		if absf(v) > 0.5:
			any = true
		cum[c] = float(cum[c]) + v
	if any:
		_layers.append({"color": GROUP_COLORS[group],
			"base": base, "top": cum.duplicate()})


func _refresh_plant() -> void:
	var plant: Dictionary = World.plants.get(pid, {})
	_title = "%s  ·  %s" % [str(plant.get("name", pid)),
		str(World.KIND_LABELS.get(plant_kind, plant_kind))]
	var p_max := float(plant.get("p_max_mw", 0.0))
	_load.clear()
	_forecast.clear()
	_layers.clear()
	_neg_min = 0.0
	var base: Array = []
	var top: Array = []
	base.resize(COLS)
	base.fill(0.0)
	top.resize(COLS)
	var now_p := 0.0
	for c in COLS:
		var i := c * STRIDE
		_valid[c] = ZoneHistory.valid(i)
		var v := ZoneHistory.plant_p_at(pid, i) if _valid[c] else 0.0
		top[c] = maxf(v, 0.0)
		_neg_min = minf(_neg_min, v)
	var nb := clampi(ZoneHistory.now_block(), 0, ZoneHistory.BLOCKS - 1)
	now_p = ZoneHistory.plant_p_at(pid, nb)
	var group := str(ZoneHistory.GROUP_OF_KIND.get(plant_kind, "gas"))
	if str(plant.get("fuel", "")) == "h2":
		group = "h2"
	_layers.append({"color": GROUP_COLORS.get(group, ACCENT),
		"base": base, "top": top})
	if _neg_min < 0.0:  # pumping / charging / electrolysis half
		var nbase: Array = []
		var ntop: Array = []
		nbase.resize(COLS)
		nbase.fill(0.0)
		ntop.resize(COLS)
		for c in COLS:
			ntop[c] = minf(ZoneHistory.plant_p_at(pid, c * STRIDE) \
				if _valid[c] else 0.0, 0.0)
		_layers.append({"color": GROUP_COLORS.get(group, ACCENT).darkened(0.3),
			"base": nbase, "top": ntop})
	_y_max = _nice_ceil(maxf(p_max, 1.0))
	_subtitle = "%s / %s" % [_fmt_mw(now_p), _fmt_mw(p_max)]


## Ceil to the 1/2/5 ladder, so axis maxima land on round numbers.
static func _nice_ceil(v: float) -> float:
	var mag := pow(10.0, floorf(log(v) / log(10.0)))
	var m := v / mag
	var nice := 1.0 if m <= 1.0 else 2.0 if m <= 2.0 else 5.0 if m <= 5.0 \
		else 10.0
	return nice * mag


static func _fmt_mw(v: float) -> String:
	if absf(v) >= 10000.0:
		return "%.1f GW" % (v / 1000.0)
	if absf(v) >= 1000.0:
		return "%.2f GW" % (v / 1000.0)
	return "%d MW" % roundi(v)


func _plot_rect() -> Rect2:
	return Rect2(PAD_L, PAD_T, size.x - PAD_L - PAD_R,
		size.y - PAD_T - PAD_B)


func _draw() -> void:
	var font := get_theme_default_font()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.075, 0.095, 0.125, 0.94)
	panel.border_color = Color(1, 1, 1, 0.13)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(7)
	draw_style_box(panel, Rect2(Vector2.ZERO, size))
	draw_string(font, Vector2(10, 19), _title,
		HORIZONTAL_ALIGNMENT_LEFT, size.x - 20, 13, TEXT)
	draw_string(font, Vector2(10, 19), _subtitle,
		HORIZONTAL_ALIGNMENT_RIGHT, size.x - 20, 12, ACCENT)

	var plot := _plot_rect()
	var y_min := minf(_neg_min * 1.05, 0.0)
	var span := _y_max - y_min
	if span <= 0.0:
		span = 1.0
	var xf := func(c: int) -> float:
		return plot.position.x + plot.size.x * c / float(COLS - 1)
	var yf := func(v: float) -> float:
		return plot.position.y + plot.size.y * (1.0 - (v - y_min) / span)

	# day grid + labels ("day N" under each of the 7 divisions)
	for d in 8:
		var gx: float = plot.position.x + plot.size.x * d / 7.0
		draw_line(Vector2(gx, plot.position.y),
			Vector2(gx, plot.end.y), GRID_LINE)
		if d < 7:
			draw_string(font, Vector2(gx + 3, plot.end.y + 14),
				"d%d" % (_week_day0 + d), HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				TEXT_DIM)
	# y ticks: 0, half, max (plus the zero line emphasized when negatives)
	for tick: float in [0.0, _y_max * 0.5, _y_max]:
		var gy: float = yf.call(tick)
		draw_line(Vector2(plot.position.x, gy), Vector2(plot.end.x, gy),
			GRID_LINE if tick > 0.0 else Color(1, 1, 1, 0.18))
		draw_string(font, Vector2(2, gy + 4), _fmt_axis(tick),
			HORIZONTAL_ALIGNMENT_LEFT, PAD_L - 4, 10, TEXT_DIM)

	# stacked measured areas, drawn per contiguous valid run
	for layer: Dictionary in _layers:
		_draw_layer(layer, xf, yf)

	# load: forecast dashed across the week, measured solid over it
	if not _forecast.is_empty():
		for c in range(0, COLS - 1, 2):
			draw_line(Vector2(xf.call(c), yf.call(float(_forecast[c]))),
				Vector2(xf.call(c + 1), yf.call(float(_forecast[c + 1]))),
				TEXT_DIM, 1.0, true)
		var run := PackedVector2Array()
		for c in COLS:
			if _valid[c]:
				run.push_back(Vector2(xf.call(c), yf.call(float(_load[c]))))
			elif run.size() > 1:
				draw_polyline(run, TEXT, 1.6, true)
				run.clear()
			else:
				run.clear()
		if run.size() > 1:
			draw_polyline(run, TEXT, 1.6, true)

	# the "you are here" slider: accent line + thumb + timestamp
	var nx: float = plot.position.x + plot.size.x * _now_frac
	draw_line(Vector2(nx, plot.position.y - 2), Vector2(nx, plot.end.y),
		ACCENT, 1.4, true)
	draw_colored_polygon(PackedVector2Array([
		Vector2(nx - 5, plot.position.y - 8), Vector2(nx + 5, plot.position.y - 8),
		Vector2(nx, plot.position.y - 1)]), ACCENT)
	var t_align := HORIZONTAL_ALIGNMENT_LEFT if _now_frac < 0.75 \
		else HORIZONTAL_ALIGNMENT_RIGHT
	var tx := nx + 7.0 if _now_frac < 0.75 else nx - 187.0
	draw_string(font, Vector2(tx, plot.position.y + 12), _now_text,
		t_align, 180, 10, ACCENT)


func _draw_layer(layer: Dictionary, xf: Callable, yf: Callable) -> void:
	var base: Array = layer["base"]
	var top: Array = layer["top"]
	var color: Color = layer["color"]
	var run_start := -1
	for c in COLS + 1:
		var ok: bool = c < COLS and bool(_valid[c])
		if ok and run_start < 0:
			run_start = c
		elif not ok and run_start >= 0:
			if c - run_start > 1:
				var pts := PackedVector2Array()
				for k in range(run_start, c):
					pts.push_back(Vector2(xf.call(k), yf.call(float(top[k]))))
				for k in range(c - 1, run_start - 1, -1):
					pts.push_back(Vector2(xf.call(k), yf.call(float(base[k]))))
				draw_colored_polygon(pts, color)
			run_start = -1


func _fmt_axis(v: float) -> String:
	if _y_max >= 2000.0:
		return "%.0f" % (v / 1000.0) if fmod(v, 1000.0) == 0.0 \
			else "%.1f" % (v / 1000.0)
	return "%.0f" % v
