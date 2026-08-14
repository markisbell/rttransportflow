extends Control
## P8 frequency instrument cluster (GAME_DESIGN §4.2): analog dial with the
## defense-plan bands, RoCoF readout with §2.2 threshold colors + peak-hold,
## inertia gauge (H_sys bands), reserve stack (FCR procured vs deployed),
## UFLS shed state, per-island rows when the grid has split, and the f(t)
## trace (all islands, null-tolerant — series born mid-step carry nulls).
## The hum (§4.2 item 5) is deferred: audio needs a non-headless run to tune.

const TRACE_WINDOW_S := 120.0
const TRACE_F_MIN := 47.4
const TRACE_F_MAX := 51.6
const DIAL_F_MIN := 47.5
const DIAL_F_MAX := 51.5
const ROCOF_HOLD_S := 12.0

## dial bands (GAME_DESIGN §4.2): [from_hz, to_hz, color]
const BANDS: Array = [
	[47.5, 49.0, Color(0.75, 0.15, 0.15)],   # red: UFLS territory
	[49.0, 49.8, Color(0.85, 0.45, 0.10)],   # orange
	[49.8, 49.9, Color(0.85, 0.70, 0.15)],   # amber: FCR deploying
	[49.9, 50.1, Color(0.25, 0.65, 0.30)],   # green
	[50.1, 50.2, Color(0.85, 0.70, 0.15)],
	[50.2, 51.0, Color(0.85, 0.45, 0.10)],
	[51.0, 51.5, Color(0.75, 0.15, 0.15)],   # red: disconnection cascade
]
const ISLAND_COLORS: Array = [
	Color(0.35, 0.85, 1.0), Color(1.0, 0.65, 0.3), Color(0.7, 1.0, 0.4),
	Color(1.0, 0.45, 0.8), Color(0.8, 0.8, 0.4),
]

var _islands: Dictionary = {}  # wire islands block, latest step
var _mode := "calm"
var _points: Dictionary = {}  # island id -> [{t, f}]
var _rocof_peak := 0.0
var _rocof_peak_wall := 0.0


func _ready() -> void:
	position = Vector2(798, 74)
	size = Vector2(470, 322)
	Orchestrator.step_completed.connect(_on_step)


func _on_step(_t: int, result: Dictionary) -> void:
	_islands = result.get("islands", {})
	_mode = str(result.get("mode", "calm"))

	# RoCoF peak-hold across every island (events are why the player looks)
	for island_id: String in _islands:
		var rocof: float = absf(numf(_islands[island_id], "rocof_max",
			numf(_islands[island_id], "rocof_hz_s", 0.0)))
		if rocof >= _rocof_peak or \
				Time.get_ticks_msec() / 1000.0 - _rocof_peak_wall > ROCOF_HOLD_S:
			_rocof_peak = rocof
			_rocof_peak_wall = Time.get_ticks_msec() / 1000.0

	var dt_done := float(result.get("dt_done_s", 0.0))
	var t_end := float(result.get("t_sim_end", GameClock.t_sim))
	var t0 := t_end - dt_done
	var traj: Dictionary = result.get("trajectory", {})
	var t_rel: Array = traj.get("t_rel_s", [])
	var traj_islands: Dictionary = traj.get("islands", {})
	for island_id: String in traj_islands:
		var f_arr: Array = traj_islands[island_id].get("f", [])
		var series: Array = _points.get(island_id, [])
		for i in range(mini(t_rel.size(), f_arr.size())):
			if f_arr[i] == null:
				continue  # pre-birth stretch of a split island
			series.append({"t": t0 + float(t_rel[i]), "f": float(f_arr[i])})
		_points[island_id] = series
	for island_id: String in _points.keys():
		var series: Array = _points[island_id]
		while series.size() > 0 and float(series[0]["t"]) < t_end - TRACE_WINDOW_S:
			series.pop_front()
		if series.is_empty() and not _islands.has(island_id):
			_points.erase(island_id)  # merged away
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.1, 0.12, 0.92))
	var font := ThemeDB.fallback_font
	var main: Dictionary = _islands.get("0", {})

	_draw_dial(font, main)
	_draw_readouts(font, main)
	var y := _draw_island_rows(font)
	_draw_trace(font, Rect2(14, y, size.x - 28, size.y - y - 14))


## Analog dial: 180° arc, 47.5 (collapse) to 51.5 (cascade), banded.
func _draw_dial(font: Font, island: Dictionary) -> void:
	var center := Vector2(105, 118)
	var radius := 82.0
	for band: Array in BANDS:
		var a0 := _f_to_angle(band[0])
		var a1 := _f_to_angle(band[1])
		draw_arc(center, radius, a0, a1, 24, band[2], 10.0, true)
	# collapse mark at the very edge (47.5: every synchronous machine trips)
	var collapse := _f_to_angle(47.5)
	draw_line(center + Vector2(cos(collapse), sin(collapse)) * (radius - 10),
		center + Vector2(cos(collapse), sin(collapse)) * (radius + 8),
		Color.BLACK, 4.0)
	for tick: float in [48.0, 49.0, 50.0, 51.0]:
		var angle := _f_to_angle(tick)
		var dir := Vector2(cos(angle), sin(angle))
		draw_line(center + dir * (radius - 8), center + dir * (radius + 2),
			Color(0.7, 0.75, 0.8), 1.5)
		draw_string(font, center + dir * (radius + 14) + Vector2(-8, 4),
			"%.0f" % tick, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.6, 0.65, 0.7))

	var blackout := bool(island.get("blackout", false))
	var f_now := numf(island, "f_hz", 50.0)
	var needle_angle := _f_to_angle(clampf(f_now, DIAL_F_MIN, DIAL_F_MAX))
	var needle_color := Color(0.45, 0.45, 0.5) if blackout else Color.WHITE
	draw_line(center, center + Vector2(cos(needle_angle), sin(needle_angle)) * (radius - 14),
		needle_color, 2.5)
	draw_circle(center, 4.0, needle_color)

	if blackout:
		draw_string(font, center + Vector2(-44, 34), "BLACKOUT",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.9, 0.2, 0.2))
	else:
		draw_string(font, center + Vector2(-52, 34), "%.3f Hz" % f_now,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 21, Color.WHITE)


func _draw_readouts(font: Font, island: Dictionary) -> void:
	var x := 225.0
	var mode_color := Color.ORANGE if _mode == "alert" else Color(0.4, 0.75, 0.5)
	draw_string(font, Vector2(x + 170, 22), _mode.to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, mode_color)

	# RoCoF, §2.2 threshold colors, peak-hold
	var rocof := absf(numf(island, "rocof_hz_s", 0.0))
	draw_string(font, Vector2(x, 22), "RoCoF %.2f Hz/s" % rocof,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _rocof_color(rocof))
	draw_string(font, Vector2(x, 40), "peak  %.2f Hz/s" % _rocof_peak,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, _rocof_color(_rocof_peak))

	# inertia gauge: H_sys bar, GAME_DESIGN bands (>5 / 3–5 / <3 / <2)
	var h_sys := numf(island, "h_sys_s", 0.0)
	var e_k_gws := numf(island, "e_k_mj", 0.0) / 1000.0
	draw_string(font, Vector2(x, 66), "inertia H %.2f s   E_k %.0f GWs" % [h_sys, e_k_gws],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.8, 0.85, 0.9))
	var bar := Rect2(x, 72, 220, 10)
	draw_rect(bar, Color(0.05, 0.06, 0.08))
	var h_color := Color(0.25, 0.65, 0.30)
	if h_sys < 2.0:
		h_color = Color(0.85, 0.15, 0.15)
	elif h_sys < 3.0:
		h_color = Color(0.85, 0.45, 0.10)
	elif h_sys < 5.0:
		h_color = Color(0.85, 0.70, 0.15)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(h_sys / 8.0, 0.0, 1.0), 10)),
		h_color)
	var warn_x := bar.position.x + bar.size.x * (2.5 / 8.0)
	draw_line(Vector2(warn_x, bar.position.y - 2), Vector2(warn_x, bar.end.y + 2),
		Color(0.9, 0.3, 0.3), 1.0)  # low-inertia warning band edge

	# reserve stack: FCR deployed vs procured
	var fcr_used := 0.0
	for island_id: String in _islands:
		fcr_used += numf(_islands[island_id], "fcr_used_mw", 0.0)
	var procured := 3000.0
	if not Dispatch.economy_cfg.is_empty():
		procured = float(Dispatch.economy_cfg.get("reserve_margin_mw_min", 3000.0))
	draw_string(font, Vector2(x, 104), "FCR %d / %d MW" % [int(fcr_used), int(procured)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.8, 0.85, 0.9))
	var reserve_bar := Rect2(x, 110, 220, 10)
	draw_rect(reserve_bar, Color(0.05, 0.06, 0.08))
	var used_frac := clampf(fcr_used / maxf(procured, 1.0), 0.0, 1.0)
	var reserve_color := Color(0.35, 0.6, 0.9) if used_frac < 0.8 else Color(0.85, 0.45, 0.10)
	draw_rect(Rect2(reserve_bar.position, Vector2(reserve_bar.size.x * used_frac, 10)),
		reserve_color)

	# UFLS state of the main island, prominent when load is shed
	var w := numf(island, "w", 1.0)
	if w < 0.9995:
		draw_string(font, Vector2(x, 140), "UFLS: %.1f %% LOAD SHED" % ((1.0 - w) * 100.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.95, 0.35, 0.25))
	else:
		draw_string(font, Vector2(x, 140), "load fully served",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.5, 0.6, 0.55))


## One compact row per EXTRA island after a split; returns the next free y.
func _draw_island_rows(font: Font) -> float:
	var y := 216.0
	if _islands.size() <= 1:
		return y
	for island_id: String in _islands:
		if island_id == "0":
			continue
		var island: Dictionary = _islands[island_id]
		var color: Color = ISLAND_COLORS[int(island_id) % ISLAND_COLORS.size()]
		var line: String
		if bool(island.get("blackout", false)):
			line = "island %s  BLACKOUT" % island_id
			color = Color(0.6, 0.3, 0.3)
		else:
			line = "island %s  %.3f Hz  H %.1f s" % [island_id,
				numf(island, "f_hz", 0.0), numf(island, "h_sys_s", 0.0)]
			var w := numf(island, "w", 1.0)
			if w < 0.9995:
				line += "  shed %.0f%%" % ((1.0 - w) * 100.0)
		draw_rect(Rect2(14, y - 9, 8, 8), color)
		draw_string(font, Vector2(28, y), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.88, 0.9))
		y += 17.0
	return y + 4.0


func _draw_trace(font: Font, plot: Rect2) -> void:
	draw_rect(plot, Color(0.05, 0.06, 0.08))
	for f_line: float in [49.0, 49.8, 50.0, 50.2]:
		var y := _f_to_y(f_line, plot)
		var color := Color(0.35, 0.4, 0.45) if f_line == 50.0 else Color(0.5, 0.25, 0.25)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), color, 1.0)
		draw_string(font, Vector2(plot.position.x + 4, y - 3), "%.1f" % f_line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
	var t_end := -1.0
	for island_id: String in _points:
		var series: Array = _points[island_id]
		if not series.is_empty():
			t_end = maxf(t_end, float(series[-1]["t"]))
	if t_end < 0.0:
		return
	for island_id: String in _points:
		var series: Array = _points[island_id]
		if series.size() < 2:
			continue
		var color: Color = ISLAND_COLORS[int(island_id) % ISLAND_COLORS.size()]
		var prev := Vector2.ZERO
		for i in range(series.size()):
			var pt: Dictionary = series[i]
			var x: float = remap(float(pt["t"]), t_end - TRACE_WINDOW_S, t_end,
				plot.position.x, plot.end.x)
			var p := Vector2(clampf(x, plot.position.x, plot.end.x),
				_f_to_y(float(pt["f"]), plot))
			if i > 0:
				draw_line(prev, p, color, 1.6)
			prev = p


func _f_to_angle(f: float) -> float:
	# 180° sweep, left (PI) = collapse floor, right (2·PI) = cascade ceiling
	return remap(f, DIAL_F_MIN, DIAL_F_MAX, PI, TAU)


func _f_to_y(f: float, plot: Rect2) -> float:
	return remap(clampf(f, TRACE_F_MIN, TRACE_F_MAX), TRACE_F_MAX, TRACE_F_MIN,
		plot.position.y, plot.end.y)


func _rocof_color(rocof: float) -> Color:
	if rocof >= 1.0:
		return Color(0.95, 0.2, 0.2)
	if rocof >= 0.5:
		return Color(0.9, 0.5, 0.1)
	if rocof >= 0.1:
		return Color(0.9, 0.8, 0.2)
	return Color(0.8, 0.85, 0.9)


## Null-tolerant getter (the wire nulls non-finite floats).
static func numf(data: Dictionary, key: String, default: float) -> float:
	var value: Variant = data.get(key, default)
	return default if value == null else float(value)
