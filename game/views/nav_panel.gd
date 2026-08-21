class_name NavPanel
extends PanelContainer
## Navigation (top-right): a continent minimap plus a jump list, because at
## 5 km tiles the map is ~960 x 804 and arrow-key panning is hopeless.
##
## The minimap is built ONCE into an ImageTexture by sampling the terrain
## rows (every Nth tile), so the cost is paid at load and never per frame.
## The player's grid rides on a SECOND texture rebuilt only when the world
## changes (throttled) — corridors on a Europe-wide grid run to thousands of
## tiles, which is far too many per-frame draw_rect calls.
##
## The camera rectangle is derived by projecting the four viewport corners
## onto the ground plane, so it stays correct under yaw rotation and any
## zoom without the view having to expose its internals.

signal jumped(tile: Vector2i)

const PANEL_MARGIN := 12.0
const MAP_WIDTH := 260.0        # minimap draw width in pixels
const TARGET_PIXELS := 260      # sample the map down to about this wide
const OVERLAY_INTERVAL := 0.5   # seconds between overlay rebuilds

var view: Node3D:
	set(value):
		view = value
		_map.view = value

var _map: MiniMap
var _places_button: Button
var _places: PopupMenu
var _place_tiles: Array[Vector2i] = []
var _place_zooms: Array[float] = []
var _probe_order: Array[String] = []  # load-centre ids, in menu order


func _ready() -> void:
	# pinned to the top-right corner (user direction); the HUD moves the
	# instrument cluster below us so nothing overlaps
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_END
	offset_left = 0.0
	offset_right = -PANEL_MARGIN
	offset_top = 56.0
	offset_bottom = 0.0
	add_theme_stylebox_override("panel", _panel_style())

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	add_child(stack)

	var title := Label.new()
	title.text = "EUROPE"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	stack.add_child(title)

	_map = MiniMap.new()
	_map.custom_minimum_size = Vector2(MAP_WIDTH, MAP_WIDTH * 0.84)
	_map.jump_requested.connect(_on_jump)
	stack.add_child(_map)

	# A Button + PopupMenu, NOT an OptionButton: an OptionButton's minimum
	# width follows its longest ITEM ("Oresund CPH-Malmoe · 3.0 GW"), which
	# dragged the whole panel 110 px wider than the minimap. A popup sizes
	# itself independently of the button that opens it.
	_places_button = Button.new()
	_places_button.text = "Jump to…"
	_places_button.custom_minimum_size = Vector2(MAP_WIDTH, 26)
	_places_button.add_theme_font_size_override("font_size", 12)
	_places_button.focus_mode = Control.FOCUS_NONE
	_places_button.clip_text = true
	stack.add_child(_places_button)

	_places = PopupMenu.new()
	_places.id_pressed.connect(_on_place_selected)
	_places_button.add_child(_places)
	_places_button.pressed.connect(func() -> void:
		_places.position = Vector2i(_places_button.get_screen_position()) \
			+ Vector2i(0, int(_places_button.size.y))
		_places.reset_size()
		_places.popup())

	_fill_places()
	World.world_changed.connect(_on_world_changed)

	# look probe (the PALETTE_TAB pattern): NAV_JUMP=<load-centre id>
	# or NAV_JUMP=overview drives a jump so a screenshot can verify it
	var probe := OS.get_environment("NAV_JUMP")
	if probe != "":
		_run_jump_probe.call_deferred(probe)


func _run_jump_probe(probe: String) -> void:
	await get_tree().create_timer(0.4).timeout  # let the view finish booting
	if probe == "overview":
		_on_place_selected(0)
		_report_zoom("overview")
		return
	var index := 1
	for id: String in _probe_order:
		if id == probe:
			_on_place_selected(index)
			_report_zoom(probe)
			return
		index += 1


## The probe reports what the camera ACTUALLY took, so a clamp at the view's
## zoom ceiling shows up instead of silently framing the wrong area.
func _report_zoom(place: String) -> void:
	if view == null or view.camera == null:
		return
	print("NAV jump %s -> camera.size %.0f (view MAX_ZOOM %.0f), map %d x %d" % [
		place, view.camera.size, float(view.MAX_ZOOM),
		World.width, World.height])


func _panel_style() -> StyleBoxFlat:
	# same visual language as the build menu's panel
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.14, 0.93)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(8)
	style.border_color = Color(0.24, 0.27, 0.33)
	style.set_border_width_all(1)
	return style


## The jump list: biggest metros first — that is the order a grid operator
## thinks in, and it puts the interesting places at the top.
func _fill_places() -> void:
	_places.clear()
	_place_tiles.clear()
	_place_zooms.clear()
	_probe_order.clear()

	_places.add_item("Overview — all of Europe", 0)
	_place_tiles.append(Vector2i(World.width / 2, World.height / 2))
	_place_zooms.append(-1.0)  # resolved to the view's max zoom on use

	var ids: Array[String] = []
	ids.assign(World.load_centers.keys())
	ids.sort_custom(func(a: String, b: String) -> bool:
		var pa: float = float((World.load_centers[a] as Dictionary).get("peak_mw", 0.0))
		var pb: float = float((World.load_centers[b] as Dictionary).get("peak_mw", 0.0))
		return pa > pb or (pa == pb and a < b))
	for id: String in ids:
		var lc: Dictionary = World.load_centers[id]
		var tiles: Array = lc.get("tiles", [])
		if tiles.is_empty():
			continue
		var center: Vector2i = tiles[0]
		_places.add_item("%s  ·  %.1f GW" % [str(lc.get("name", id)),
			float(lc.get("peak_mw", 0.0)) / 1000.0], _place_tiles.size())
		_place_tiles.append(center)
		_place_zooms.append(40.0)
		_probe_order.append(id)


func _on_place_selected(index: int) -> void:
	if view == null or index < 0 or index >= _place_tiles.size():
		return
	var zoom: float = _place_zooms[index]
	if zoom < 0.0:
		zoom = float(view.MAX_ZOOM)  # follows the view if the range changes
	view.focus_tile(_place_tiles[index], zoom)
	jumped.emit(_place_tiles[index])


func _on_jump(tile: Vector2i) -> void:
	if view == null:
		return
	view.focus_tile(tile)
	jumped.emit(tile)


func _on_world_changed() -> void:
	_map.mark_overlay_dirty()


# ---------------------------------------------------------------------------


## The minimap itself: owns its textures, its input and its camera rectangle.
class MiniMap:
	extends Control

	signal jump_requested(tile: Vector2i)

	var view: Node3D
	var _base: ImageTexture
	var _overlay: ImageTexture
	var _overlay_image: Image
	var _step := 1           # tiles per minimap pixel
	var _px := Vector2i.ZERO # minimap image size in pixels
	var _overlay_dirty := true
	var _overlay_cooldown := 0.0
	var _dragging := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		clip_contents = true  # the camera quad must never spill onto the panel
		set_process(true)

	func mark_overlay_dirty() -> void:
		_overlay_dirty = true

	func _process(delta: float) -> void:
		_overlay_cooldown -= delta
		if _base == null and World.width > 0:
			_build_base()
		if _overlay_dirty and _overlay_cooldown <= 0.0 and _base != null:
			_build_overlay()
			_overlay_dirty = false
			_overlay_cooldown = NavPanel.OVERLAY_INTERVAL
		queue_redraw()  # the camera rectangle tracks every frame

	## Terrain sampled once into an image; at 960 tiles wide that is a step
	## of 4, so the whole continent costs ~48 000 set_pixel calls ONCE.
	func _build_base() -> void:
		# floor, not ceil: the image must be at least as wide as the widget so
		# the GPU downscales (crisp) instead of upscaling (mush)
		_step = maxi(1, int(floor(float(World.width) / float(NavPanel.TARGET_PIXELS))))
		_px = Vector2i(int(ceil(float(World.width) / _step)),
			int(ceil(float(World.height) / _step)))
		var started := Time.get_ticks_msec()
		var image := Image.create(_px.x, _px.y, false, Image.FORMAT_RGBA8)
		for py in range(_px.y):
			for px in range(_px.x):
				image.set_pixel(px, py, EuropeTerrain.map_pixel(World,
					Vector2i(px * _step, py * _step)))
		_base = ImageTexture.create_from_image(image)
		print("NAV base %dx%d px (step %d) from %dx%d tiles in %d ms" % [
			_px.x, _px.y, _step, World.width, World.height,
			Time.get_ticks_msec() - started])
		_overlay_image = Image.create(_px.x, _px.y, false, Image.FORMAT_RGBA8)
		_overlay_dirty = true

	## The player's grid: corridors and plants as bright pixels. Rebuilt on
	## world_changed, throttled — never per frame.
	func _build_overlay() -> void:
		if _overlay_image == null:
			return
		_overlay_image.fill(Color(0, 0, 0, 0))
		for tile: Vector2i in World.corridors:
			_plot(tile, _corridor_color(str(World.corridors[tile])))
		for pid: String in World.plants:
			var plant: Dictionary = World.plants[pid]
			_plot(plant["tile"] as Vector2i, Color(1.0, 0.93, 0.35))
		for lc_id: String in World.load_centers:
			for tile: Vector2i in (World.load_centers[lc_id] as Dictionary)["tiles"]:
				_plot(tile, Color(0.85, 0.45, 0.95))
		_overlay = ImageTexture.create_from_image(_overlay_image)

	func _corridor_color(kind: String) -> Color:
		match kind:
			"line_220": return Color(0.35, 0.95, 0.5)
			"hvdc": return Color(0.72, 0.45, 1.0)
		return Color(1.0, 0.42, 0.32)

	func _plot(tile: Vector2i, color: Color) -> void:
		var px := tile.x / _step
		var py := tile.y / _step
		if px >= 0 and py >= 0 and px < _px.x and py < _px.y:
			_overlay_image.set_pixel(px, py, color)

	# --- drawing ---------------------------------------------------------

	func _map_rect() -> Rect2:
		if _px == Vector2i.ZERO:
			return Rect2(Vector2.ZERO, size)
		# letterbox the continent inside the widget, preserving its aspect
		var scale := minf(size.x / float(_px.x), size.y / float(_px.y))
		var draw_size := Vector2(_px.x * scale, _px.y * scale)
		return Rect2((size - draw_size) * 0.5, draw_size)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.07, 0.09))
		if _base == null:
			return
		var rect := _map_rect()
		draw_texture_rect(_base, rect, false)
		if _overlay != null:
			draw_texture_rect(_overlay, rect, false)
		_draw_camera_rect(rect)
		draw_rect(rect, Color(0.30, 0.34, 0.40), false, 1.0)

	## The visible ground quad, obtained by projecting the four viewport
	## corners onto y = 0 — correct under yaw and any zoom, and it needs
	## nothing from the view beyond its camera.
	func _draw_camera_rect(rect: Rect2) -> void:
		if view == null:
			return
		var camera: Camera3D = view.camera
		if camera == null:
			return
		var viewport_size := camera.get_viewport().get_visible_rect().size
		var corners: Array[Vector2] = []
		for corner: Vector2 in [Vector2.ZERO, Vector2(viewport_size.x, 0),
				viewport_size, Vector2(0, viewport_size.y)]:
			var origin := camera.project_ray_origin(corner)
			var direction := camera.project_ray_normal(corner)
			if absf(direction.y) < 1e-6:
				return
			var hit := origin + direction * (-origin.y / direction.y)
			# Clamp into the map: zoomed all the way out the viewport covers
			# MORE than the continent, and an unclamped quad would fall
			# outside the widget entirely — leaving no "you are here" at all.
			# Clamped, it collapses onto the border, which reads correctly.
			var point := _tile_to_widget(Vector2(hit.x, hit.z), rect)
			corners.append(Vector2(
				clampf(point.x, rect.position.x, rect.end.x),
				clampf(point.y, rect.position.y, rect.end.y)))
		corners.append(corners[0])
		var points := PackedVector2Array(corners)
		# dark backing stroke first: a white hairline vanishes over snow and
		# pale coast tiles
		draw_polyline(points, Color(0, 0, 0, 0.55), 3.0)
		draw_polyline(points, Color(1, 1, 1, 0.95), 1.5)

	func _tile_to_widget(tile: Vector2, rect: Rect2) -> Vector2:
		return rect.position + Vector2(
			tile.x / float(maxi(World.width, 1)) * rect.size.x,
			tile.y / float(maxi(World.height, 1)) * rect.size.y)

	func _widget_to_tile(point: Vector2, rect: Rect2) -> Vector2i:
		var local := (point - rect.position) / rect.size
		return Vector2i(
			clampi(int(local.x * World.width), 0, maxi(World.width - 1, 0)),
			clampi(int(local.y * World.height), 0, maxi(World.height - 1, 0)))

	# --- input -----------------------------------------------------------

	func _gui_input(event: InputEvent) -> void:
		var rect := _map_rect()
		if event is InputEventMouseButton:
			var button := event as InputEventMouseButton
			if button.button_index != MOUSE_BUTTON_LEFT:
				return
			_dragging = button.pressed
			if button.pressed and rect.has_point(button.position):
				jump_requested.emit(_widget_to_tile(button.position, rect))
				accept_event()
		elif event is InputEventMouseMotion and _dragging:
			# drag scrubs the camera across the continent
			var motion := event as InputEventMouseMotion
			if rect.has_point(motion.position):
				jump_requested.emit(_widget_to_tile(motion.position, rect))
				accept_event()
