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
## C7: the decommissionable thermal fleet — the kinds a coal-exit player
## retires. Renewables/devices are not "retired" with a decommission fee in
## v1; every listed kind has a capex_eur_per_kw for the §4.7 fee formula.
const RETIRABLE: Array[String] = ["coal", "lignite", "gas_ccgt", "gas_ocgt", "nuclear"]
## C8: the gas kinds a hydrogen-loop player converts to H2 firing (the
## backend gates on the `gas_` prefix — world_model.convert_to_h2).
const CONVERTIBLE: Array[String] = ["gas_ccgt", "gas_ocgt"]

var pid := ""
var _title: Label
var _state: Label
var _mode: OptionButton
var _policy: OptionButton
var _policy_row: HBoxContainer
var _black_start: Button
var _retire: Button
var _retire_armed := false  # two-press confirm: a mis-click must not scrap a unit
var _convert: Button
var _convert_armed := false  # two-press confirm: the retrofit fee is real


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

	# C7: the retire verb — the coal-exit path. Model-instant (the plant
	# leaves World and coal_mw() drops immediately) but physics-deferred:
	# remove_plant fires world_changed, BuildSession debounces a rebuild and
	# re-registers. Two-press confirm because the fee is real and there is no
	# refund (ledger 51/D6). Retire the inertia BEFORE the final year or the
	# ledger-13 reference incident has nothing to swing.
	_retire = Button.new()
	_retire.focus_mode = Control.FOCUS_NONE
	_retire.modulate = Color(1.0, 0.72, 0.62)
	_retire.pressed.connect(_on_retire)
	stack.add_child(_retire)

	# C8: the convert-to-H2 verb — the hydrogen-loop path. Model-instant (the
	# plant's fuel becomes "h2" and h2_converted_mw() rises) but physics-
	# deferred: world_changed → BuildSession rebuilds and the plant re-emits
	# as a native fuel="h2" row bound to its cavern. Two-press confirm; the
	# retrofit fee is real (ledger 51/D-C8-2). Needs a cavern to bind to.
	_convert = Button.new()
	_convert.focus_mode = Control.FOCUS_NONE
	_convert.modulate = Color(0.66, 0.86, 1.0)
	_convert.pressed.connect(_on_convert)
	stack.add_child(_convert)

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
	_retire_armed = false
	_retire.visible = kind in RETIRABLE
	_refresh_retire()
	# C8 convert-to-H2: a gas plant not already on H2, once the 2033
	# h2_retrofit unlock is open, and only if a cavern exists to bind to.
	# Unlock gates at the TOOL layer (C1), never in WorldModel.
	_convert_armed = false
	_convert.visible = kind in CONVERTIBLE \
		and str(plant.get("fuel", "")) != "h2" \
		and Campaign.unlocked("h2_retrofit") \
		and _nearest_cavern() != ""
	_refresh_convert()
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


func _retire_fee_eur() -> float:
	var plant: Dictionary = World.plants.get(pid, {})
	# ONE fee formula: Economy owns it, the inspector only displays it (a
	# second copy is a drift bug — the review's nit)
	return Economy.retirement_fee_eur(str(plant.get("kind", "")),
		float(plant.get("p_max_mw", 0.0)))


func _refresh_retire() -> void:
	if not _retire.visible:
		return
	if _retire_armed:
		_retire.text = "Confirm retire — €%.1fM fee" % (_retire_fee_eur() / 1e6)
	else:
		_retire.text = "Retire this unit"


func _on_retire() -> void:
	if pid == "" or not World.plants.has(pid):
		return
	if not _retire_armed:
		_retire_armed = true  # first press arms; the fee is shown, no charge yet
		_refresh_retire()
		return
	# second press: charge the decommission fee, drop the plant (coal_mw()
	# falls now), and let BuildSession debounce the rebuild/re-register that
	# actually removes its inertia from the island.
	var plant: Dictionary = World.plants.get(pid, {})
	Economy.book_retirement(str(plant.get("kind", "")), float(plant.get("p_max_mw", 0.0)))
	print("INSPECTOR retire %s (%s, %.0f MW) fee €%.1fM" % [pid,
		str(plant.get("kind", "")), float(plant.get("p_max_mw", 0.0)),
		_retire_fee_eur() / 1e6])
	Dispatch.plant_mode.erase(pid)  # no shadow mode for a gone plant
	World.remove_plant(pid)
	close_panel()


## The cavern this plant would fire from — the SAME one the wire binds an
## electrolyzer to (WireDeviceEmit._nearest_cavern), so the verb and the
## engine agree. "" when no cavern exists (the button then hides).
func _nearest_cavern() -> String:
	var caverns: Array[String] = []
	for cid: String in World.plants:
		if str(World.plants[cid]["kind"]) == "h2_cavern":
			caverns.append(cid)
	if caverns.is_empty():
		return ""
	var plant: Dictionary = World.plants.get(pid, {})
	return WireDeviceEmit._nearest_cavern(World, caverns, plant.get("tile", Vector2i.ZERO))


func _convert_fee_eur() -> float:
	var plant: Dictionary = World.plants.get(pid, {})
	# ONE fee formula: Economy owns it, the inspector only displays it
	return Economy.retrofit_fee_eur(str(plant.get("kind", "")),
		float(plant.get("p_max_mw", 0.0)))


func _refresh_convert() -> void:
	if not _convert.visible:
		return
	if _convert_armed:
		var cavern := _nearest_cavern()
		var name := str(World.plants.get(cavern, {}).get("name", cavern))
		_convert.text = "Confirm H2 retrofit — €%.1fM → %s" % [
			_convert_fee_eur() / 1e6, name]
	else:
		_convert.text = "Convert to hydrogen"


func _on_convert() -> void:
	if pid == "" or not World.plants.has(pid):
		return
	var cavern := _nearest_cavern()
	if cavern == "":
		return  # no cavern to bind to (button should be hidden anyway)
	if not _convert_armed:
		_convert_armed = true  # first press arms; the fee + target are shown
		_refresh_convert()
		return
	# second press: charge the retrofit fee, switch the fuel (h2_converted_mw
	# rises now), and let BuildSession rebuild so the plant re-emits as a
	# native fuel="h2" row bound to the cavern.
	var plant: Dictionary = World.plants.get(pid, {})
	Economy.book_retrofit(str(plant.get("kind", "")), float(plant.get("p_max_mw", 0.0)))
	print("INSPECTOR convert %s (%s, %.0f MW) to H2 from %s, fee €%.1fM" % [pid,
		str(plant.get("kind", "")), float(plant.get("p_max_mw", 0.0)), cavern,
		_convert_fee_eur() / 1e6])
	World.convert_to_h2(pid, cavern)
	close_panel()


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
