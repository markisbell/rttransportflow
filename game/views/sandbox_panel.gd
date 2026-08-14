class_name SandboxPanel
extends PanelContainer
## Classroom controls (GAME_DESIGN §5.4): the demonstrator's console.
##
## Hidden unless sandbox mode is active — the campaign must not offer a
## "trip the largest unit" button, and a treasury slider would make its
## milestones meaningless. Every control here drives the SAME paths the
## campaign uses (a scheduled engine event, a weather force window, the
## economy ledger), so what a class sees demonstrated is what the game
## actually does.

const WIDTH := 260.0

var _status: Label
var _built := false


func _ready() -> void:
	# explicit anchors: the preset does not apply to a CanvasLayer child
	# (found when the build menu came out stuck in the corner)
	anchor_left = 0.0
	anchor_top = 0.0
	position = Vector2(40, 120)
	custom_minimum_size = Vector2(WIDTH, 0)
	visible = Sandbox.active
	Sandbox.knobs_changed.connect(_refresh)
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	add_child(column)

	var title := Label.new()
	title.text = "Sandbox — classroom controls"
	title.add_theme_font_size_override("font_size", 14)
	column.add_child(title)

	var difficulty := HBoxContainer.new()
	column.add_child(difficulty)
	for name: String in Sandbox.PRESETS:
		var button := Button.new()
		button.text = name.capitalize()
		button.pressed.connect(func() -> void:
			Sandbox.set_difficulty(name)
			_refresh())
		difficulty.add_child(button)

	var trip := Button.new()
	trip.text = "Trip the largest unit NOW"
	trip.pressed.connect(func() -> void:
		var pid := Sandbox.trip_largest_unit()
		_say("tripping %s in 1 s" % pid if pid != "" else "nothing online to trip"))
	column.add_child(trip)

	# Weather demos: each opens a 6 h window from now, so a class sees the
	# transition rather than a world that was always becalmed.
	var weather := HBoxContainer.new()
	column.add_child(weather)
	_add_force(weather, "Calm", "wind_lambda_scale", 0.3)
	_add_force(weather, "Storm", "wind_lambda_scale", 1.6)
	_add_force(weather, "Dark", "clearness_scale", 0.3)
	var clear := Button.new()
	clear.text = "Clear forces"
	clear.pressed.connect(func() -> void:
		Sandbox.clear_weather_forces()
		_say("weather forces cleared"))
	column.add_child(clear)

	var money := HBoxContainer.new()
	column.add_child(money)
	for amount: float in [1000.0, 10000.0]:
		var button := Button.new()
		button.text = "+%d M€" % int(amount)
		button.pressed.connect(func() -> void:
			Economy.treasury_eur += amount * 1e6
			_say("treasury %.1f B€" % (Economy.treasury_eur / 1e9)))
		money.add_child(button)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	column.add_child(_status)
	_refresh()


func _add_force(row: HBoxContainer, label: String, kind: String,
		value: float) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(func() -> void:
		Sandbox.force_weather(kind, value)
		_say("%s for 6 h" % label.to_lower()))
	row.add_child(button)


func _refresh() -> void:
	visible = Sandbox.active
	if _status != null:
		_status.text = "difficulty: %s  (capex ×%.2f, growth ×%.2f, VoLL ×%.2f)" % [
			Sandbox.difficulty, Sandbox.knob("capex"),
			Sandbox.knob("demand_growth"), Sandbox.knob("voll_scale")]


func _say(message: String) -> void:
	if _status != null:
		_status.text = message
