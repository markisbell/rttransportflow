extends Control
## P8 replay panel — "What just happened" (GAME_DESIGN §4.5 subset): after
## any significant frequency event the game fetches its counterfactual set
## RIGHT AWAY (ledger 23 — the backend's rolling snapshot ring only holds
## ~120 s of sim time) and caches the ghost traces with the event-log entry.
## Key R toggles the panel: actual aftermath trace + counterfactual ghost
## (dashed), UFLS stage chips per trace, and the nadir delta as the headline
## ("the battery fleet bought +X.XX Hz"). The ring keeps the last 3 events.
##
## The fetch path (`fetch_counterfactuals`) is the REAL code the
## replay_panel smoke exercises — keep it UI-free.

const SIGNIFICANT := ["trip", "ufls_stage", "island_split", "blackout"]
const WINDOW_S := 60.0
const CACHE_MAX := 3
const TRACE_F_MIN := 47.4
const TRACE_F_MAX := 50.6

var _cache: Array = []  # [{event, plain, cf, cf_label, expired}]
var _fetching := false
var _shown := false


func _ready() -> void:
	position = Vector2(180, 150)
	size = Vector2(660, 430)
	visible = false
	Orchestrator.events_received.connect(_on_events)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_R:
		return
	_shown = not _shown
	visible = _shown and not _cache.is_empty()
	queue_redraw()


func _on_events(events: Array) -> void:
	if _fetching:
		return  # one fetch per event burst — the ring holds, no need to race
	for event: Dictionary in events:
		if str(event.get("kind", "")) in SIGNIFICANT:
			_fetch_and_cache(event)
			return


func _fetch_and_cache(event: Dictionary) -> void:
	_fetching = true
	var entry := await fetch_counterfactuals(event)
	var campaign := get_node_or_null("/root/Campaign")
	if campaign != null:
		campaign.notify_replay_viewed()  # milestone 1's "replay viewed" gate
	_cache.push_front(entry)
	while _cache.size() > CACHE_MAX:
		_cache.pop_back()
	_fetching = false
	if _shown:
		visible = true
		queue_redraw()


## The testable fetch path: plain aftermath replay + one counterfactual
## ("without the biggest battery" when batteries exist, else "without the
## largest online sync unit that did not trip"). Returns
## {event, plain, cf, cf_label, expired}; plain/cf are raw /gb/replay
## responses ({} when the fetch failed entirely).
func fetch_counterfactuals(event: Dictionary) -> Dictionary:
	var t_sim := _numf(event, "t_sim", 0.0)
	var plain: Dictionary = await CosimBridge.replay(Orchestrator.ID,
		{"t_sim": t_sim, "window_s": WINDOW_S})
	var target := counterfactual_target(event)
	var cf := {}
	if target["id"] != "" and str(plain.get("status", "")) == "ok":
		cf = await CosimBridge.replay(Orchestrator.ID,
			{"t_sim": t_sim, "window_s": WINDOW_S,
				"overrides": {"remove_devices": [target["id"]]}})
	return {"event": event, "plain": plain, "cf": cf,
		"cf_label": target["label"],
		"expired": str(plain.get("status", "")) == "window_expired"}


## Pick the ghost-trace override: the biggest battery (the P7 storage
## lesson), else the largest online sync unit that was NOT the victim.
func counterfactual_target(event: Dictionary) -> Dictionary:
	var best_bat := ""
	var best_bat_mw := 0.0
	for dev: Dictionary in Boundary.wire_devices:
		var kind := str(dev.get("kind", ""))
		if kind == "battery" or kind == "grid_forming":
			var p_max := _numf(dev.get("params", {}), "p_max_mw", 0.0)
			if p_max > best_bat_mw:
				best_bat_mw = p_max
				best_bat = str(dev.get("id", ""))
	if best_bat != "":
		return {"id": best_bat, "label": "without %s (battery)" % best_bat}
	var victim := str(event.get("element", ""))
	var devices: Dictionary = Orchestrator.latest().get("devices", {})
	var best := ""
	var best_p := 0.0
	for pid: String in devices:
		var device: Dictionary = devices[pid]
		if pid != victim and str(device.get("state", "")) == "online" \
				and device.has("headroom_mw") and _numf(device, "p_mw", 0.0) > best_p:
			best_p = _numf(device, "p_mw", 0.0)
			best = pid
	if best != "":
		return {"id": best, "label": "without %s" % best}
	return {"id": "", "label": ""}


## f_min over a replay response's trajectory + islands block.
static func replay_f_min(response: Dictionary) -> float:
	var f_min := 100.0
	for island_id: String in response.get("islands", {}):
		f_min = minf(f_min, _numf(response["islands"][island_id], "f_min", 100.0))
	var traj: Dictionary = response.get("trajectory", {})
	for island_id: String in traj.get("islands", {}):
		for value: Variant in traj["islands"][island_id].get("f", []):
			if value != null:
				f_min = minf(f_min, float(value))
	return f_min


static func ufls_stages(response: Dictionary) -> Array:
	var stages: Array = []
	for event: Dictionary in response.get("events", []):
		if str(event.get("kind", "")) == "ufls_stage":
			stages.append(int(event.get("data", {}).get("stage", 0)))
	return stages


func _draw() -> void:
	if _cache.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.09, 0.11, 0.96))
	var font := ThemeDB.fallback_font
	var entry: Dictionary = _cache[0]
	var event: Dictionary = entry["event"]
	draw_string(font, Vector2(16, 26), "REPLAY — %s %s @ t=%.1f s   (R closes)" % [
		str(event.get("kind", "?")), str(event.get("element", "")),
		_numf(event, "t_sim", 0.0)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)

	if bool(entry["expired"]):
		draw_string(font, Vector2(16, 56), "window expired — the snapshot ring has moved on",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.55, 0.58, 0.62))
		return

	var plain: Dictionary = entry["plain"]
	var cf: Dictionary = entry["cf"]
	var headline_y := 52.0
	if not cf.is_empty() and str(cf.get("status", "")) == "ok":
		var delta := replay_f_min(plain) - replay_f_min(cf)
		var verb := "bought +%.2f Hz of nadir" % delta if delta > 0.0 \
			else "made no difference (%.2f Hz)" % delta
		draw_string(font, Vector2(16, headline_y),
			"%s → the removed device %s" % [entry["cf_label"], verb],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.95, 0.8, 0.3))
	# stage chips per trace
	var chip_y := 74.0
	_draw_chips(font, Vector2(16, chip_y), "actual", ufls_stages(plain),
		Color(0.35, 0.85, 1.0))
	if not cf.is_empty():
		_draw_chips(font, Vector2(340, chip_y), entry["cf_label"],
			ufls_stages(cf), Color(1.0, 0.55, 0.3))

	var plot := Rect2(16, 92, size.x - 32, size.y - 108)
	draw_rect(plot, Color(0.05, 0.06, 0.08))
	for f_line: float in [48.0, 49.0, 49.8, 50.0]:
		var y := _f_to_y(f_line, plot)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y),
			Color(0.3, 0.32, 0.36), 1.0)
		draw_string(font, Vector2(plot.position.x + 4, y - 3), "%.1f" % f_line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.5, 0.55, 0.6))
	_draw_trace(plain, plot, Color(0.35, 0.85, 1.0), false)
	if not cf.is_empty():
		_draw_trace(cf, plot, Color(1.0, 0.55, 0.3), true)


func _draw_chips(font: Font, at: Vector2, label: String, stages: Array,
		color: Color) -> void:
	draw_rect(Rect2(at + Vector2(0, -9), Vector2(9, 9)), color)
	var text := label
	text += "   UFLS " + " ".join(stages.map(func(s: int) -> String: return str(s))) \
		if not stages.is_empty() else "   no shedding"
	draw_string(font, at + Vector2(14, 0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.88, 0.9))


func _draw_trace(response: Dictionary, plot: Rect2, color: Color,
		dashed: bool) -> void:
	var traj: Dictionary = response.get("trajectory", {})
	var t_rel: Array = traj.get("t_rel_s", [])
	if t_rel.is_empty():
		return
	var t_max := float(t_rel[-1])
	for island_id: String in traj.get("islands", {}):
		var f_arr: Array = traj["islands"][island_id].get("f", [])
		var prev := Vector2.ZERO
		var have_prev := false
		for i in range(mini(t_rel.size(), f_arr.size())):
			if f_arr[i] == null:
				have_prev = false
				continue
			var p := Vector2(
				remap(float(t_rel[i]), 0.0, maxf(t_max, 0.001),
					plot.position.x, plot.end.x),
				_f_to_y(float(f_arr[i]), plot))
			if have_prev and (not dashed or i % 2 == 0):
				draw_line(prev, p, color, 1.6)
			prev = p
			have_prev = true


func _f_to_y(f: float, plot: Rect2) -> float:
	return remap(clampf(f, TRACE_F_MIN, TRACE_F_MAX), TRACE_F_MAX, TRACE_F_MIN,
		plot.position.y, plot.end.y)


static func _numf(data: Dictionary, key: String, default: float) -> float:
	var value: Variant = data.get(key, default)
	return default if value == null else float(value)
