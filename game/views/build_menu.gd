class_name BuildMenu
extends PanelContainer
## The build palette (infrastruct's HUD pattern): a slim category tab row
## over ONE tile row showing the active category, anchored bottom-centre.
## Every tile's icon is the component's REAL 3D model, rendered once into an
## offscreen viewport — what you pick is what lands on the map.
##
## Deliberately NO build hotkeys (user direction): the menu is the only way
## to arm a tool, so nothing is hidden behind a keyboard shortcut. Q/E and
## the arrow keys stay with the camera.

signal tool_selected(tool_id: String)

const TILE := Vector2(46, 46)

## Categories in build order: what you inherit, what you add, what makes it
## flexible, and how you move it. Each item is {tool, label, desc}.
const ITEMS := [
	{"cat": "Thermal", "items": [
		{"tool": "nuclear", "label": "Nuclear 1600 MW",
			"desc": "Base load, huge inertia, tiny reserve band.\nNeeds a coast or river tile."},
		{"tool": "coal", "label": "Coal 800 MW",
			"desc": "Mid-merit, slow reheat, heavy CO2."},
		{"tool": "lignite", "label": "Lignite 900 MW",
			"desc": "Cheapest fuel, dirtiest. Needs a coal basin."},
		{"tool": "gas_ccgt", "label": "CCGT 600 MW",
			"desc": "Fast then breathes: gas turbine now, steam tail over minutes."},
		{"tool": "gas_ocgt", "label": "OCGT 200 MW",
			"desc": "The peaker: full output in seconds, expensive fuel."},
		{"tool": "hydro_ps", "label": "Pumped hydro 300 MW",
			"desc": "Pumps to store, generates to serve.\nWatch the wrong-way kick. Needs a PHS site."},
	]},
	{"cat": "Renewable", "items": [
		{"tool": "wind_onshore", "label": "Wind onshore 200 MW",
			"desc": "No inertia. Output follows the weather."},
		{"tool": "wind_offshore", "label": "Wind offshore 500 MW",
			"desc": "Best capacity factors. Shelf sea, or deep sea inside a platform's ring."},
		{"tool": "solar_pv", "label": "Solar 150 MW",
			"desc": "Midday only — the low-inertia hours."},
	]},
	{"cat": "Storage & H2", "items": [
		{"tool": "battery", "label": "Battery 300 MW / 600 MWh",
			"desc": "Full power in 0.3 s: catches the fall a steam plant cannot."},
		{"tool": "electrolyzer", "label": "Electrolyzer 300 MW",
			"desc": "Turns surplus power into hydrogen. Sheds instantly on under-frequency."},
		{"tool": "h2_cavern", "label": "H2 cavern 4000 t",
			"desc": "Seasonal storage. Needs a salt cavern site."},
	]},
	{"cat": "Grid", "items": [
		{"tool": "corridor_400", "label": "400 kV corridor",
			"desc": "The backbone. Drag to draw."},
		{"tool": "corridor_220", "label": "220 kV corridor",
			"desc": "Regional lines, lower rating."},
		{"tool": "substation", "label": "Substation",
			"desc": "Forces a bus where corridors meet."},
	]},
	{"cat": "HVDC & Offshore", "items": [
		{"tool": "corridor_cable", "label": "400 kV cable (underground)",
			"desc": "buried/submarine AC: no pylons, ~4x the cost, heavy charging"},
		{"tool": "corridor_hvdc", "label": "HVDC corridor",
			"desc": "Point-to-point DC. May cross deep sea."},
		{"tool": "hvdc_converter", "label": "HVDC converter 2 GW",
			"desc": "Both ends of a link, or the onshore end of a hub."},
		{"tool": "offshore_platform", "label": "Offshore platform 2 GW",
			"desc": "Collects far-shore farms within 100 km and exports by DC."},
	]},
]

var _tab_rows := {}      # cat -> HBoxContainer
var _tab_buttons := {}   # cat -> Button
var _tool_buttons := {}  # tool_id -> Button
var _tool_tips := {}     # tool_id -> base tooltip (locked state appends)
var _tool_group := ButtonGroup.new()
var _tab_group := ButtonGroup.new()
var _active_tool := ""


func _ready() -> void:
	# explicit anchors: set_anchors_preset() left the panel full-height at
	# x = 0 as a CanvasLayer child, so pin the bottom-centre point directly
	# and let the content's minimum size grow the panel up and outward
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = 0.0
	offset_right = 0.0
	offset_top = 0.0
	offset_bottom = -12.0
	add_theme_stylebox_override("panel", _panel_style())

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 5)
	add_child(stack)

	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 2)
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_child(tab_row)

	for category: Dictionary in ITEMS:
		var cat := str(category["cat"])
		# rows live directly in the VBox — hidden children leave the layout,
		# so the panel auto-sizes around tabs + the ACTIVE row
		var tile_row := HBoxContainer.new()
		tile_row.add_theme_constant_override("separation", 5)
		tile_row.alignment = BoxContainer.ALIGNMENT_CENTER
		tile_row.visible = false
		for item: Dictionary in category["items"]:
			tile_row.add_child(_make_tile(item))
		stack.add_child(tile_row)
		_tab_rows[cat] = tile_row

		var tab := Button.new()
		tab.text = cat
		tab.toggle_mode = true
		tab.button_group = _tab_group
		tab.focus_mode = Control.FOCUS_NONE
		tab.add_theme_font_size_override("font_size", 12)
		tab.pressed.connect(func() -> void: show_category(cat))
		tab_row.add_child(tab)
		_tab_buttons[cat] = tab

	var probe := OS.get_environment("PALETTE_TAB")
	show_category(probe if _tab_rows.has(probe) else str(ITEMS[0]["cat"]))
	_render_thumbnails.call_deferred()

	# Unlock-year gating (C1): the palette greys locked tools and re-greys
	# on the year signal (unlock years do not align with era boundaries).
	Campaign.year_changed.connect(func(_y: int) -> void: refresh_locks())
	refresh_locks()


## The TOOL layer enforces unlocks, never WorldModel.can_place_plant —
## authoring, recipes and smokes place freely (§5.4 "sandbox is also where
## smokes run"); the player's palette is what the campaign gates.
func refresh_locks() -> void:
	for tool_id: String in _tool_buttons:
		var button: Button = _tool_buttons[tool_id]
		var open := Campaign.unlocked(tool_id)
		button.disabled = not open
		if open:
			button.tooltip_text = str(_tool_tips.get(tool_id, ""))
		else:
			button.tooltip_text = "%s\n[locked — unlocks %d]" \
				% [_tool_tips.get(tool_id, ""), Campaign.unlock_year(tool_id)]
			if _active_tool == tool_id:
				button.button_pressed = false  # toggled(false) clears the tool


func show_category(cat: String) -> void:
	for name: String in _tab_rows:
		(_tab_rows[name] as HBoxContainer).visible = name == cat
	if _tab_buttons.has(cat):
		(_tab_buttons[cat] as Button).set_pressed_no_signal(true)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.14, 0.93)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(8)
	style.border_color = Color(0.24, 0.27, 0.33)
	style.set_border_width_all(1)
	return style


func _make_tile(item: Dictionary) -> Button:
	var tool_id := str(item["tool"])
	var accent := _accent_for(tool_id)
	var button := Button.new()
	button.custom_minimum_size = TILE
	button.toggle_mode = true
	button.button_group = _tool_group
	button.focus_mode = Control.FOCUS_NONE
	button.text = str(item["label"]).substr(0, 1)  # until the 3D icon lands
	button.tooltip_text = "%s\n%s" % [item["label"], item["desc"]]
	_tool_tips[tool_id] = button.tooltip_text

	# neutral slate so the 3D thumbnail carries the identity; the network
	# colour survives as a slim bottom accent
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.16, 0.18, 0.22)
	normal.set_corner_radius_all(6)
	normal.set_content_margin_all(3)
	normal.border_color = accent
	normal.border_width_bottom = 3
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.24, 0.27, 0.33)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.30, 0.42, 0.34)
	pressed.border_color = Color(0.55, 0.95, 0.6)
	pressed.set_border_width_all(2)
	pressed.border_width_bottom = 3
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", normal)

	button.toggled.connect(func(on: bool) -> void:
		_active_tool = tool_id if on else ""
		tool_selected.emit(_active_tool))
	_tool_buttons[tool_id] = button
	return button


func _accent_for(tool_id: String) -> Color:
	match tool_id:
		"corridor_400": return Color(0.90, 0.25, 0.20)
		"corridor_cable": return Color(0.62, 0.16, 0.14)
		"corridor_220": return Color(0.20, 0.75, 0.35)
		"corridor_hvdc", "hvdc_converter", "offshore_platform":
			return Color(0.55, 0.25, 0.85)
		"battery", "electrolyzer", "h2_cavern": return Color(0.30, 0.70, 0.85)
		"wind_onshore", "wind_offshore", "solar_pv": return Color(0.45, 0.80, 0.35)
	return Color(0.85, 0.60, 0.25)


## Each tile's icon is the real model rendered once into an offscreen
## viewport, so the palette always matches what appears on the map.
func _render_thumbnails() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(112, 112)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.3
	vp.add_child(sun)
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.9
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)

	for tool_id: String in _tool_buttons:
		var sample: Node3D = null
		if tool_id.begins_with("corridor_"):
			var kind := "line_400"
			if tool_id == "corridor_220":
				kind = "line_220"
			elif tool_id == "corridor_hvdc":
				kind = "hvdc"
			elif tool_id == "corridor_cable":
				kind = "cable_400"
			sample = PlantModels.corridor(kind, [Vector2i(1, 0), Vector2i(-1, 0)])
		else:
			sample = PlantModels.make(tool_id)
		if sample == null:
			continue
		vp.add_child(sample)
		var bounds := PlantModels.aabb_of(sample)
		var center := bounds.position + bounds.size / 2.0
		cam.size = maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z)) * 1.25
		cam.position = center + Vector3(-1, 0.85, -1).normalized() * 12.0
		cam.look_at(center, Vector3.UP)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var texture := ImageTexture.create_from_image(vp.get_texture().get_image())
		vp.remove_child(sample)
		sample.queue_free()
		var button: Button = _tool_buttons[tool_id]
		if not is_instance_valid(button):
			continue
		button.text = ""
		button.icon = texture
		button.expand_icon = true
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vp.queue_free()


## Clear the armed tool (e.g. after a build that consumes the selection).
func clear_selection() -> void:
	for tool_id: String in _tool_buttons:
		(_tool_buttons[tool_id] as Button).set_pressed_no_signal(false)
	_active_tool = ""
	tool_selected.emit("")
