extends PanelContainer
## Mode-only plant inspector (C2): click a plant with no tool armed and
## see its name, live wire state, and the §3.3 dispatch mode. The mode
## selector writes `Dispatch.plant_mode` — the P6 surface that never had
## a writer ("auto" erases the key, the dispatcher's default). Effect
## arrives with the next block's decide() and ramps over Dispatch.RAMP_S:
## the game smoothing its own schedule, never the engine hiding physics.
## The inspector accretes verbs in later slices (Retire in C7,
## Convert-to-H2 in C8); C2 keeps it mode-only. No class_name (the
## sandbox_panel headless-cache lesson).

const MODES: Array[String] = ["auto", "must_run", "reserve_only", "mothballed"]

var pid := ""
var _title: Label
var _state: Label
var _mode: OptionButton
var _policy: OptionButton
var _policy_row: HBoxContainer
var _black_start: Button


func _ready() -> void:
	visible = false
	# CanvasLayer child: explicit anchors (left edge, mid-height)
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = 12.0
	offset_top = -80.0
	grow_vertical = Control.GROW_DIRECTION_BOTH
	add_theme_stylebox_override("panel", _style())

	var stack := VBoxContainer.new()
	stack.custom_minimum_size = Vector2(240, 0)
	stack.add_theme_constant_override("separation", 6)
	add_child(stack)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	stack.add_child(_title)
	_state = Label.new()
	_state.add_theme_font_size_override("font_size", 12)
	_state.modulate = Color(0.8, 0.85, 0.9)
	stack.add_child(_state)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	stack.add_child(row)
	var mode_label := Label.new()
	mode_label.text = "Mode"
	mode_label.add_theme_font_size_override("font_size", 12)
	row.add_child(mode_label)
	_mode = OptionButton.new()
	_mode.focus_mode = Control.FOCUS_NONE
	for m: String in MODES:
		_mode.add_item(m)
	_mode.item_selected.connect(_on_mode)
	row.add_child(_mode)
	# §3.3 battery policy (C4): GLOBAL fleet stance, shown only when a
	# battery is inspected — the campaign player's path to it
	_policy_row = HBoxContainer.new()
	_policy_row.add_theme_constant_override("separation", 6)
	var policy_label := Label.new()
	policy_label.text = "Fleet policy"
	policy_label.add_theme_font_size_override("font_size", 12)
	_policy_row.add_child(policy_label)
	_policy = OptionButton.new()
	_policy.focus_mode = Control.FOCUS_NONE
	for policy: String in Dispatch.BATTERY_POLICIES:
		_policy.add_item(policy)
	_policy.item_selected.connect(func(index: int) -> void:
		Dispatch.set_battery_policy(Dispatch.BATTERY_POLICIES[index])
		print("INSPECTOR battery policy -> %s" % Dispatch.battery_policy))
	_policy_row.add_child(_policy)
	stack.add_child(_policy_row)

	# C5: the black-start verb — visible only on an offline/tripped unit
	# whose home zone is BLACK on the wire (ledger 34's player action)
	_black_start = Button.new()
	_black_start.text = "Black-start this unit"
	_black_start.focus_mode = Control.FOCUS_NONE
	_black_start.pressed.connect(func() -> void:
		if Restoration.phase != Restoration.Phase.IDLE:
			Restoration.cancel()
		elif Restoration.begin(pid):
			pass
		_refresh_state())
	stack.add_child(_black_start)

	var close := Button.new()
	close.text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: close_panel())
	stack.add_child(close)

	Orchestrator.step_completed.connect(func(_t: int, _r: Dictionary) -> void:
		if visible:
			_refresh_state())
	# a load rewinds the world under the panel — a stale pid would write
	# shadow keys into Dispatch.plant_mode for plants that no longer exist
	SaveLoad.load_completed.connect(func(_ok: bool, _reason: String) -> void:
		close_panel())


func open(plant_id: String) -> void:
	pid = plant_id
	var plant: Dictionary = World.plants.get(pid, {})
	_title.text = str(plant.get("name", pid))
	var kind := str(plant.get("kind", ""))
	_mode.selected = MODES.find(str(Dispatch.plant_mode.get(pid, "auto")))
	_policy_row.visible = kind in ["battery", "grid_forming"]
	if _policy_row.visible:
		_policy.selected = Dispatch.BATTERY_POLICIES.find(Dispatch.battery_policy)
	_refresh_state()
	tooltip_text = "%s — %.0f MW" % [
		str(World.KIND_LABELS.get(kind, kind)), float(plant.get("p_max_mw", 0.0))]
	visible = true


func close_panel() -> void:
	visible = false
	pid = ""


func _refresh_state() -> void:
	var device: Dictionary = (Orchestrator.latest().get("devices", {}) as Dictionary) \
		.get(pid, {})
	var zone := str(Dispatch.home_zone.get(pid, ""))
	var supplied := Wire.numf((Orchestrator.latest().get("zones", {})
		as Dictionary).get(zone, {}), "supplied", 1.0)
	var state := str(device.get("state", ""))
	# "starting" counts: the dispatcher parks committed units at the
	# sick-island hold one block after a blackout, and the backend accepts
	# black_start on a STARTING row (the C5 review's blocking find)
	_black_start.visible = supplied == 0.0 and state != "online" \
		and FleetQuery.START_CLASS_RANK.has(
			str(World.plants.get(pid, {}).get("kind", "")))
	if Restoration.phase == Restoration.Phase.IDLE:
		_black_start.text = "Black-start this unit"
		_black_start.disabled = false
	else:
		# a stuck restoration must never lock the feature: the same
		# button cancels (Restoration re-arms its crank every block, so
		# cancel is for the player changing plans, not a rescue hatch)
		_black_start.text = "Cancel restoration"
		_black_start.visible = true
		_black_start.disabled = false
	if device.is_empty():
		_state.text = "no live data (not registered yet)"
		return
	var parts: Array[String] = ["%.0f MW" % Wire.numf(device, "p_mw", 0.0),
		str(device.get("state", "?"))]
	if device.has("soc"):
		parts.append("SoC %.0f %%" % (Wire.numf(device, "soc", 0.0) * 100.0))
	_state.text = " · ".join(parts)


func _on_mode(index: int) -> void:
	if pid == "" or not World.plants.has(pid):
		return  # never write a mode for a plant that no longer exists
	var mode := MODES[index]
	if mode == "auto":
		Dispatch.plant_mode.erase(pid)  # absent key IS auto — no shadow state
	else:
		Dispatch.plant_mode[pid] = mode
	print("INSPECTOR %s mode -> %s (applies next block, ramped)" % [pid, mode])


func _style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.14, 0.93)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	style.border_color = Color(0.24, 0.27, 0.33)
	style.set_border_width_all(1)
	return style
