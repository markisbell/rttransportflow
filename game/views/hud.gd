extends CanvasLayer
## HUD: sim-time display, speed buttons, event log, frequency instrument.

const SPEEDS: Array[float] = [0.0, 1.0, 60.0, 300.0, 900.0]
const SPEED_LABELS: Array[String] = ["⏸", "1×", "60×", "300×", "900×"]

var _time_label: Label
var _event_label: Label
var _events: Array[String] = []


func _ready() -> void:
	var bar := HBoxContainer.new()
	bar.position = Vector2(40, 20)
	add_child(bar)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(260, 0)
	bar.add_child(_time_label)

	for i in range(SPEEDS.size()):
		var button := Button.new()
		button.text = SPEED_LABELS[i]
		var speed := SPEEDS[i]
		button.pressed.connect(func() -> void: GameClock.speed = speed)
		bar.add_child(button)

	_event_label = Label.new()
	_event_label.position = Vector2(40, 760)
	_event_label.add_theme_font_size_override("font_size", 13)
	add_child(_event_label)

	var freq_panel := preload("res://views/frequency_panel.gd").new()
	add_child(freq_panel)

	Orchestrator.events_received.connect(_on_events)
	Orchestrator.supply_event.connect(_on_supply_event)
	Orchestrator.step_completed.connect(_on_step_completed)


var _latest_devices := {}


func _on_step_completed(_t: int, result: Dictionary) -> void:
	_latest_devices = result.get("devices", {})


## Debug key (P4 testing aid): T trips the largest online synchronous unit.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_T:
		return
	var best_id := ""
	var best_p := 0.0
	for id: String in _latest_devices:
		var device: Dictionary = _latest_devices[id]
		# synchronous devices carry headroom_mw; converters don't
		if device.get("state", "") == "online" and device.has("headroom_mw") \
				and float(device.get("p_mw", 0.0)) > best_p:
			best_p = float(device["p_mw"])
			best_id = id
	if best_id != "":
		Orchestrator.inject_events([{"at_s_rel": 1.0, "kind": "trip", "element": best_id}])
		_push("[debug] tripping %s (%.0f MW) in 1 s" % [best_id, best_p])


func _process(_delta: float) -> void:
	_time_label.text = "day %d  %s   speed %s   t=%d" % [
		GameClock.day(), GameClock.time_of_day_string(),
		("%.0f×" % GameClock.speed) if GameClock.speed > 0.0 else "paused",
		Orchestrator.last_t,
	]


func _on_events(events: Array) -> void:
	for event: Dictionary in events:
		_push("%s %s" % [event.get("kind", "?"), event.get("element", "")])


func _on_supply_event(kind: String, severity: String, _data: Dictionary) -> void:
	if severity != "info" or kind == "auto_slow" or kind == "backend_recovered":
		_push("[%s] %s" % [severity, kind])


func _push(line: String) -> void:
	_events.append(line)
	if _events.size() > 5:
		_events.pop_front()
	_event_label.text = "\n".join(_events)
