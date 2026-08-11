extends Node2D
## Build-mode map view: renders the WorldModel (views render ONLY — never
## own state) and turns clicks into model edits. Tool keys are drawn in the
## legend; B runs the demo auto-build, X clears, right-click deletes.

const TILE := 12.0

const TERRAIN_COLORS := {
	"S": Color(0.07, 0.10, 0.18), "s": Color(0.12, 0.22, 0.34),
	"c": Color(0.75, 0.68, 0.48), "p": Color(0.30, 0.46, 0.28),
	"h": Color(0.38, 0.42, 0.26), "m": Color(0.52, 0.50, 0.48),
}
const KIND_COLORS := {
	"line_400": Color(0.90, 0.25, 0.20), "line_220": Color(0.20, 0.75, 0.35),
	"hvdc": Color(0.55, 0.25, 0.85),
}

## tool id -> [key label, description]
const TOOLS: Array = [
	["corridor_400", "1", "400 kV corridor"],
	["corridor_220", "2", "220 kV corridor"],
	["substation", "3", "substation"],
	["gas_ccgt", "4", "CCGT 600 MW"],
	["gas_ocgt", "5", "OCGT 200 MW"],
	["coal", "6", "coal 800 MW"],
	["nuclear", "7", "nuclear 1600 MW (coast/river)"],
	["wind_onshore", "8", "wind onshore 200 MW"],
	["wind_offshore", "9", "wind offshore 500 MW (shelf)"],
	["solar_pv", "0", "solar 150 MW"],
	["hydro_ps", "-", "pumped hydro 300 MW (PHS site)"],
	["battery", "q", "battery 300 MW / 600 MWh"],
	["electrolyzer", "w", "electrolyzer 300 MW"],
	["h2_cavern", "e", "H2 cavern 4000 t (salt cavern)"],
	["hvdc_converter", "r", "HVDC converter 2000 MW"],
	["offshore_platform", "u", "offshore platform 2000 MW (sea)"],
	["corridor_hvdc", "z", "HVDC corridor (may cross deep sea)"],
]

var tool_index := 0
var _hover := Vector2i(-1, -1)
var _painting := false
var _status_text := "build something — a corridor must connect a plant to a load center"
var _status_ok := true
var _camera: Camera2D
var _legend: Label


func _ready() -> void:
	_camera = Camera2D.new()
	_camera.position = Vector2(World.width, World.height) * TILE / 2.0
	add_child(_camera)
	_camera.make_current()

	_legend = Label.new()
	_legend.add_theme_font_size_override("font_size", 12)
	var lines: Array[String] = []
	for tool_def: Array in TOOLS:
		lines.append("%s  %s" % [tool_def[1], tool_def[2]])
	lines.append("B demo build · X clear · right-click delete · wheel zoom · arrows pan")
	_legend.text = "\n".join(lines)
	var canvas := CanvasLayer.new()
	canvas.add_child(_legend)
	_legend.position = Vector2(1020, 60)
	add_child(canvas)

	World.world_changed.connect(queue_redraw)
	Orchestrator.step_completed.connect(func(_t: int, _r: Dictionary) -> void: queue_redraw())
	BuildSession.build_status.connect(_on_build_status)


func _on_build_status(ok: bool, message: String, warnings: Array) -> void:
	_status_ok = ok
	_status_text = message
	for warning: String in warnings:
		_status_text += "\n! " + str(warning)
	queue_redraw()


func _tile_at(screen_pos: Vector2) -> Vector2i:
	var world_pos := get_global_mouse_position()
	return Vector2i(int(floor(world_pos.x / TILE)), int(floor(world_pos.y / TILE)))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		for i in range(TOOLS.size()):
			if char(key.unicode) == TOOLS[i][1]:
				tool_index = i
				queue_redraw()
				return
		match key.keycode:
			KEY_B:
				DemoBuild.auto_build(World)
				BuildSession.rebuild_now()
			KEY_X:
				World.clear_build()
			KEY_LEFT:
				_camera.position.x -= 120
			KEY_RIGHT:
				_camera.position.x += 120
			KEY_UP:
				_camera.position.y -= 120
			KEY_DOWN:
				_camera.position.y += 120
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.zoom *= 1.15
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.zoom /= 1.15
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_painting = mb.pressed
			if mb.pressed:
				_apply_tool(_tile_at(mb.position))
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_delete_at(_tile_at(mb.position))
	elif event is InputEventMouseMotion:
		var tile := _tile_at((event as InputEventMouseMotion).position)
		if tile != _hover:
			_hover = tile
			queue_redraw()
		if _painting:
			_apply_tool(tile)


func _apply_tool(tile: Vector2i) -> void:
	var tool_id: String = TOOLS[tool_index][0]
	match tool_id:
		"corridor_400":
			World.place_corridor(tile, "line_400")
		"corridor_220":
			World.place_corridor(tile, "line_220")
		"corridor_hvdc":
			World.place_corridor(tile, "hvdc")
		"substation":
			World.place_substation(tile)
		_:
			World.place_plant(tool_id, tile)


func _delete_at(tile: Vector2i) -> void:
	var pid := World.plant_at(tile)
	if pid != "":
		World.remove_plant(pid)
		return
	if World.substations.erase(tile):
		World.world_changed.emit()
		return
	World.remove_corridor(tile)


func _tool_valid(tile: Vector2i) -> bool:
	var tool_id: String = TOOLS[tool_index][0]
	if tool_id == "corridor_hvdc":
		return World.can_place_corridor(tile, "hvdc")
	if tool_id.begins_with("corridor"):
		return World.can_place_corridor(tile)
	if tool_id == "substation":
		return World.is_land(tile)
	return World.can_place_plant(tool_id, tile)


func _draw() -> void:
	for y in range(World.height):
		for x in range(World.width):
			var tile := Vector2i(x, y)
			var color: Color = TERRAIN_COLORS.get(World.terrain_at(tile), Color.BLACK)
			draw_rect(Rect2(x * TILE, y * TILE, TILE, TILE), color)

	for kind: String in ["coal_basin", "salt_cavern", "phs_site", "river"]:
		var marker := {"coal_basin": Color(0.15, 0.15, 0.15),
			"salt_cavern": Color(0.9, 0.9, 0.95), "phs_site": Color(0.2, 0.5, 0.9),
			"river": Color(0.35, 0.55, 0.95)}[kind] as Color
		for tile: Vector2i in World.resources.get(kind, {}):
			draw_circle(Vector2(tile) * TILE + Vector2(TILE, TILE) * 0.5, 2.0, marker)

	# load centers: purple footprints, dark red when unsupplied/dropped
	var dropped: Array = BuildSession.last_build.get("interpretation", {}).get("dropped_zones", [])
	var supplied := {}
	for zone_id: String in Orchestrator.latest().get("zones", {}):
		supplied[zone_id] = float(Orchestrator.latest()["zones"][zone_id].get("supplied", 0.0))
	for lc_id: String in World.load_centers:
		var color := Color(0.55, 0.25, 0.70)
		if lc_id in dropped or (BuildSession.registered and not supplied.has(lc_id)):
			color = Color(0.45, 0.10, 0.10)
		elif supplied.get(lc_id, 1.0) < 0.999:
			color = Color(0.85, 0.45, 0.10)
		for tile: Vector2i in World.load_centers[lc_id]["tiles"]:
			draw_rect(Rect2(Vector2(tile) * TILE, Vector2(TILE, TILE)), color)

	for tile: Vector2i in World.corridors:
		draw_rect(Rect2(Vector2(tile) * TILE + Vector2(2, 2),
			Vector2(TILE - 4, TILE - 4)), KIND_COLORS[World.corridors[tile]])
	for tile: Vector2i in World.substations:
		draw_rect(Rect2(Vector2(tile) * TILE + Vector2(3, 3),
			Vector2(TILE - 6, TILE - 6)), Color.WHITE, false, 2.0)
	for pid: String in World.plants:
		var p: Dictionary = World.plants[pid]
		var tile: Vector2i = p["tile"]
		draw_rect(Rect2(Vector2(tile) * TILE + Vector2(1, 1),
			Vector2(TILE - 2, TILE - 2)), Color(0.95, 0.85, 0.20))
		draw_string(ThemeDB.fallback_font, Vector2(tile) * TILE + Vector2(2, TILE - 2),
			str(p["kind"])[0].to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.BLACK)

	# buses from the last successful build
	var bus_of_tile: Dictionary = BuildSession.last_build.get("interpretation", {}).get("bus_of_tile", {})
	for tile: Vector2i in bus_of_tile:
		draw_circle(Vector2(tile) * TILE + Vector2(TILE, TILE) * 0.5, 3.0, Color.CYAN)

	if _hover.x >= 0 and _hover.x < World.width and _hover.y >= 0 and _hover.y < World.height:
		var ok := _tool_valid(_hover)
		draw_rect(Rect2(Vector2(_hover) * TILE, Vector2(TILE, TILE)),
			Color(0.2, 1.0, 0.2, 0.8) if ok else Color(1.0, 0.1, 0.1, 0.8), false, 2.0)

	# status line + selected tool (drawn in world space near the top-left tile)
	var status_color := Color(0.8, 1.0, 0.8) if _status_ok else Color(1.0, 0.6, 0.5)
	draw_string(ThemeDB.fallback_font, Vector2(4, -18),
		"tool: %s" % TOOLS[tool_index][2], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
	var y_offset := -4.0
	for line: String in _status_text.split("\n"):
		draw_string(ThemeDB.fallback_font, Vector2(4, y_offset), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, status_color)
		y_offset += 14.0
