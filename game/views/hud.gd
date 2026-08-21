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
	_time_label.custom_minimum_size = Vector2(760, 0)
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

	_advisor_label = Label.new()
	_advisor_label.position = Vector2(40, 700)
	_advisor_label.add_theme_font_size_override("font_size", 13)
	_advisor_label.add_theme_color_override("font_color", Color(0.95, 0.75, 0.3))
	add_child(_advisor_label)

	# Navigation (top-right): the continent is far too big to pan across, so
	# a minimap + jump list owns the corner. The instrument cluster moves
	# BELOW it — set from here, so the cluster script stays untouched.
	_nav_panel = NavPanel.new()
	add_child(_nav_panel)
	# main.gd assigns hud.view BEFORE add_child, so the setter ran while
	# _nav_panel was still null — hand the view over now that it exists
	_nav_panel.view = view

	# P8 instrument cluster (dial, RoCoF, inertia gauge, reserve stack, UFLS)
	var cluster := preload("res://views/frequency_cluster.gd").new()
	add_child(cluster)
	# AFTER add_child: the cluster sets its own position in _ready(), which
	# runs on add_child and would overwrite an earlier assignment.
	# Docked to the RIGHT edge below the nav panel via ANCHORS (user
	# direction): a fixed x floated the panel mid-screen on wide displays.
	cluster.anchor_left = 1.0
	cluster.anchor_right = 1.0
	cluster.offset_left = -482.0
	cluster.offset_right = -12.0
	cluster.offset_top = 356.0
	cluster.offset_bottom = 678.0

	# menu-driven building (user direction): no build hotkeys anywhere
	_build_menu = BuildMenu.new()
	add_child(_build_menu)
	_build_menu.tool_selected.connect(func(tool_id: String) -> void:
		if view != null:
			view.tool_id = tool_id)

	# classroom console — shows itself only in sandbox mode (§5.4).
	# preload by path, not by class_name: a freshly added script is not in
	# the global class cache until the project is re-imported, and a headless
	# smoke run then fails to compile the whole HUD.
	add_child(preload("res://views/sandbox_panel.gd").new())

	# P8 replay panel: auto-fetches counterfactual ghosts after significant
	# events (the ring only holds ~120 s — ledger 23); key R toggles it
	var replay := preload("res://views/replay_panel.gd").new()
	add_child(replay)

	Orchestrator.events_received.connect(_on_events)
	Orchestrator.supply_event.connect(_on_supply_event)
	Orchestrator.step_completed.connect(_on_step_completed)


var _latest_devices := {}
var _nav_panel: NavPanel
var _advisor_label: Label
var _build_menu: BuildMenu
## the 3D map this HUD drives (set by main.gd after both exist)
var view: WorldView3D:
	set(value):
		view = value
		if _nav_panel != null:
			_nav_panel.view = value


func _on_step_completed(_t: int, result: Dictionary) -> void:
	_latest_devices = result.get("devices", {})
	if BuildSession.use_gridco:
		_advisor_label.text = "\n".join(Advisor.assess(result))


## Debug key (P4 testing aid): T trips the largest online synchronous unit.
## F5 saves, F9 loads (P9 — the save enforces the SPEC §4.2 quiesce rule).
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F5:
		_do_save()
		return
	if key.keycode == KEY_F9:
		_do_load()
		return
	if key.keycode != KEY_T:
		return
	var ranked: Array = FleetQuery.online_sync_ranked(_latest_devices)
	if not ranked.is_empty():
		var best_id: String = str(ranked.front())
		var best_p := Wire.numf(_latest_devices.get(best_id, {}), "p_mw", 0.0)
		Orchestrator.inject([{"at_s_rel": 1.0, "kind": "trip", "element": best_id}])
		_push("[debug] tripping %s (%.0f MW) in 1 s" % [best_id, best_p])


func _do_save() -> void:
	var out: Dictionary = await SaveLoad.save_game()
	_push("[save] %s" % ("saved" if bool(out["ok"])
		else "FAILED: %s" % str(out["reason"])))


func _do_load() -> void:
	var out: Dictionary = await SaveLoad.load_game()
	var note := "loaded"
	if bool(out.get("refused_snapshot", false)):
		note = "loaded (snapshot refused — cold start)"
	elif not bool(out["ok"]):
		note = "load FAILED: %s" % str(out["reason"])
	_push("[save] %s" % note)


func _process(_delta: float) -> void:
	var economy_line := ""
	if BuildSession.use_gridco:
		economy_line = "   € %.0f M   price %.0f €/MWh%s   CO2 %.0f g/kWh%s" % [
			Economy.treasury_eur / 1e6, Dispatch.wholesale_price,
			" (SCARCITY)" if Dispatch.scarcity else "",
			Economy.g_co2_per_kwh(), _flex_line(),
		]
	var campaign_line := ""
	if Campaign.active:
		var milestone: Dictionary = Campaign.current_milestone()
		campaign_line = "   %s %d  M%d %s" % [Campaign.month_name(),
			Campaign.year(), Campaign.milestone_index + 1,
			str(milestone.get("id", "done"))]
		if Campaign.failed_reason != "":
			campaign_line += "  CAMPAIGN FAILED: " + Campaign.failed_reason
	_time_label.text = "day %d  %s   speed %s   t=%d%s%s   [F5 save · F9 load]" % [
		GameClock.day(), GameClock.time_of_day_string(),
		("%.0f×" % GameClock.speed) if GameClock.speed > 0.0 else "paused",
		Orchestrator.last_t, economy_line, campaign_line,
	]


## P7 flexibility strip: aggregate battery SoC + H2 cavern fill, only when
## such devices exist (the H2 panel proper is a P8 UI refinement).
func _flex_line() -> String:
	var soc_mwh := 0.0
	var e_mwh := 0.0
	var h2_kg := 0.0
	var h2_cap := 0.0
	for id: String in _latest_devices:
		var device: Dictionary = _latest_devices[id]
		if device.has("soc_mwh") and device.get("soc_mwh") != null:
			soc_mwh += float(device["soc_mwh"])
			for dev: Dictionary in Boundary.wire_devices:
				if str(dev.get("id", "")) == id:
					e_mwh += float((dev.get("params", {}) as Dictionary).get("e_mwh", 0.0))
		if device.has("h2_kg") and device.get("h2_kg") != null:
			h2_kg += float(device["h2_kg"])
			h2_cap += float(device.get("capacity_kg", 0.0))
	var line := ""
	if e_mwh > 0.0:
		line += "   bat %d%%" % int(100.0 * soc_mwh / e_mwh)
	if h2_cap > 0.0:
		line += "   H2 %d%% (%.0f t)" % [int(100.0 * h2_kg / h2_cap), h2_kg / 1000.0]
	return line


func _on_events(events: Array) -> void:
	for event: Dictionary in events:
		_push(_format_event(event))


## Wire events → readable log lines (P8 vocabulary: PARAMETERS §2.2 events).
func _format_event(event: Dictionary) -> String:
	var kind := str(event.get("kind", "?"))
	var element := str(event.get("element", ""))
	var data: Dictionary = event.get("data", {}) if event.get("data") is Dictionary else {}
	match kind:
		"ufls_stage":
			return "UFLS stage %d — shed %.1f%% (%s, load now %.0f%%)" % [
				int(data.get("stage", 0)), float(data.get("shed_frac", 0.0)) * 100.0,
				element, float(data.get("w", 1.0)) * 100.0]
		"island_split":
			return "GRID SPLIT — %d islands (%s)" % [int(data.get("n_islands", 2)), element]
		"island_merge":
			return "islands resynchronized — %d (%s)" % [int(data.get("n_islands", 1)), element]
		"rocof_dg_trip":
			return "RoCoF %.2f Hz/s — %.0f MW embedded DG tripped (%s)" % [
				float(data.get("rocof_hz_s", 0.0)), float(data.get("dg_mw", 0.0)), element]
		"ely_shed":
			return "electrolyzers shed — interruptible tier at %.2f Hz (%s)" % [
				float(data.get("f_hz", 0.0)), element]
		"line_trip":
			var cause := str(data.get("cause", ""))
			var why: String = str({"overload_duty": "overload duty",
				"overload_instant": "instant overload",
				"breaker": "breaker opened"}.get(cause, cause))
			return "line %s TRIPPED%s" % [element, (" (%s)" % why) if why else ""]
		"line_close":
			return "line %s closed" % element
		"resync_rejected":
			return "resync %s REJECTED — Δf %.2f Hz across the breaker" % [
				element, absf(float(data.get("df_hz", 0.0)))]
		"load_restored":
			return "load fully restored (%s) — defense re-armed" % element
		"trip":
			var cause := str(data.get("cause", ""))
			var why: String = str({"f_window": "f-window relay", "pole_slip": "pole slip",
				"interruptible": "interruptible tier",
				"defense_plan": "defense plan"}.get(cause, cause))
			return "%s TRIPPED%s" % [element, (" (%s)" % why) if why else ""]
		"fuel_starved":
			return "%s FUEL-STARVED (H2 cushion floor)" % element
		"fuel_recovered":
			return "%s fuel recovered" % element
		"start_complete":
			return "%s synchronized" % element
		"blackout":
			return "BLACKOUT (%s)" % element
		_:
			return "%s %s" % [kind, element]


func _on_supply_event(kind: String, severity: String, _data: Dictionary) -> void:
	if severity != "info" or kind == "auto_slow" or kind == "backend_recovered":
		_push("[%s] %s" % [severity, kind])


func _push(line: String) -> void:
	_events.append(line)
	if _events.size() > 5:
		_events.pop_front()
	_event_label.text = "\n".join(_events)
