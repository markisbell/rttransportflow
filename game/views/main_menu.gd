extends CanvasLayer
## The boot menu (C2): the first thing a player sees — a packaged-bundle
## player previously could not reach the campaign at all (--campaign was a
## CLI flag). Deliberately functional-first (D9): dark panel, real actions,
## no art pass. `--campaign` and every smoke bypass this entirely, so
## scripted boots stay headless-deterministic. No class_name: fresh
## scripts are preloaded by PATH (the sandbox_panel lesson — a class_name
## not yet in the global cache fails headless compilation).
##
## Actions surface as ONE signal; main.gd owns what each choice boots.
## Continue only shows when a savegame exists; the scenario list is read
## from data/scenarios/*.json titles (the recipes are the registry).

signal chosen(action: String, arg: String)


func _ready() -> void:
	var panel := PanelContainer.new()
	# CanvasLayer child: anchor presets do not apply — set them explicitly
	# (the documented HUD gotcha), centering on both axes
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.add_theme_stylebox_override("panel", _style())
	add_child(panel)

	var stack := VBoxContainer.new()
	stack.custom_minimum_size = Vector2(340, 0)
	stack.add_theme_constant_override("separation", 8)
	panel.add_child(stack)

	var title := Label.new()
	title.text = "rttransportflow"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	stack.add_child(title)
	var sub := Label.new()
	sub.text = "Europe-scale power transmission"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.modulate = Color(0.75, 0.8, 0.85)
	stack.add_child(sub)
	stack.add_child(HSeparator.new())

	if FileAccess.file_exists(SaveLoad.DEFAULT_PATH):
		stack.add_child(_action_button("Continue", "continue", ""))
	stack.add_child(_action_button("New campaign", "campaign", ""))
	stack.add_child(_action_button("Sandbox (free play)", "sandbox", ""))

	var ids := Scenario.available()
	if not ids.is_empty():
		stack.add_child(HSeparator.new())
		var head := Label.new()
		head.text = "SCENARIOS"
		head.add_theme_font_size_override("font_size", 11)
		head.modulate = Color(0.6, 0.66, 0.72)
		stack.add_child(head)
		for id: String in ids:
			var meta := _recipe_meta(id)
			var button := _action_button(str(meta.get("title", id)), "scenario", id)
			button.tooltip_text = str(meta.get("description", ""))
			stack.add_child(button)


func _action_button(text: String, action: String, arg: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 34)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func() -> void: chosen.emit(action, arg))
	return button


func _recipe_meta(id: String) -> Dictionary:
	var path := AppPaths.root().path_join(Scenario.DIR).path_join(id + ".json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.14, 0.96)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(18)
	style.border_color = Color(0.24, 0.27, 0.33)
	style.set_border_width_all(1)
	return style
