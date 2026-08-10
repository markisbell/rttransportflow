extends Control
## Frequency instrument: readout, scrolling f(t) trace (last TRACE_WINDOW_S
## of SIM time, appended from each step's trajectory block — one-step lag),
## H_sys / E_k labels, mode indicator.

const TRACE_WINDOW_S := 120.0
const F_MIN := 49.4
const F_MAX := 50.6

var _points: Array = []  # [{t: sim_s, f: hz}]
var _f_now := 50.0
var _h_sys := 0.0
var _e_k_gj := 0.0
var _mode := "calm"


func _ready() -> void:
	position = Vector2(820, 120)
	size = Vector2(430, 300)
	Orchestrator.step_completed.connect(_on_step)


func _on_step(_t: int, result: Dictionary) -> void:
	var dt_done := float(result.get("dt_done_s", 0.0))
	var t_end := float(result.get("t_sim_end", GameClock.t_sim))
	var t0 := t_end - dt_done
	var traj: Dictionary = result.get("trajectory", {})
	var t_rel: Array = traj.get("t_rel_s", [])
	var f_arr: Array = traj.get("islands", {}).get("0", {}).get("f", [])
	for i in range(mini(t_rel.size(), f_arr.size())):
		_points.append({"t": t0 + float(t_rel[i]), "f": float(f_arr[i])})
	while _points.size() > 0 and _points[0]["t"] < t_end - TRACE_WINDOW_S:
		_points.pop_front()
	var island: Dictionary = result.get("islands", {}).get("0", {})
	_f_now = float(island.get("f_hz", 50.0))
	_h_sys = float(island.get("h_sys_s", 0.0))
	_e_k_gj = float(island.get("e_k_mj", 0.0)) / 1000.0
	_mode = str(result.get("mode", "calm"))
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.08, 0.1, 0.12, 0.9))
	var font := ThemeDB.fallback_font
	var mode_color := Color.ORANGE if _mode == "alert" else Color(0.4, 0.75, 0.5)
	draw_string(font, Vector2(14, 34), "%.3f Hz" % _f_now,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color.WHITE)
	draw_string(font, Vector2(200, 24), "H_sys %.2f s" % _h_sys,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.8, 0.85, 0.9))
	draw_string(font, Vector2(200, 42), "E_k  %.0f GJ" % _e_k_gj,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.8, 0.85, 0.9))
	draw_string(font, Vector2(340, 34), _mode.to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, mode_color)

	var plot := Rect2(14, 60, size.x - 28, size.y - 80)
	draw_rect(plot, Color(0.05, 0.06, 0.08))
	for f_line: float in [49.8, 50.0, 50.2]:
		var y := _f_to_y(f_line, plot)
		var color := Color(0.35, 0.4, 0.45) if f_line == 50.0 else Color(0.5, 0.25, 0.25)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), color, 1.0)
		draw_string(font, Vector2(plot.position.x + 4, y - 3), "%.1f" % f_line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)
	if _points.size() < 2:
		return
	var t_end: float = _points[-1]["t"]
	var prev := Vector2.ZERO
	for i in range(_points.size()):
		var pt: Dictionary = _points[i]
		var x: float = remap(float(pt["t"]), t_end - TRACE_WINDOW_S, t_end,
			plot.position.x, plot.end.x)
		var p := Vector2(x, _f_to_y(float(pt["f"]), plot))
		if i > 0:
			draw_line(prev, p, Color(0.35, 0.85, 1.0), 1.6)
		prev = p


func _f_to_y(f: float, plot: Rect2) -> float:
	return remap(clampf(f, F_MIN, F_MAX), F_MAX, F_MIN, plot.position.y, plot.end.y)
