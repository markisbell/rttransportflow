class_name WorldView3D
extends Node3D
## The map in real 3D (the infrastruct CityView pattern, ported to the
## transmission scale): locked isometric orthographic camera, warm sun +
## sky ambient, a vertex-coloured continent mesh, and one procedural model
## per built component. Views RENDER ONLY — every edit goes through
## WorldModel, which stays the source of truth.
##
## One tile = 1.0 world unit; a component on tile (x, y) is centred at
## (x + 0.5, ground, y + 0.5). Instances are diffed per layer on redraw, so
## a rebuild does not rebuild the continent.

signal tile_clicked(tile: Vector2i)
signal tile_hovered(tile: Vector2i)

const MIN_ZOOM := 6.0
const MAX_ZOOM := 90.0

## The tool the HUD has armed (a WorldModel kind, "corridor_*" or "") —
## drives the ghost preview and what a click builds.
var tool_id := "":
	set(value):
		tool_id = value
		_refresh_ghost()

var camera: Camera3D
var hover_tile := Vector2i(-1, -1)

var _zoom := 20.0
var _focus := Vector3(48.0, 0, 44.0)  # central Europe
var _yaw := 0.0
var _yaw_target := 0.0
var _sun: DirectionalLight3D
var _terrain: MeshInstance3D
var _water: MeshInstance3D
var _plants_root: Node3D
var _corridors_root: Node3D
var _cities_root: Node3D
var _ghost: Node3D
var _cursor: MeshInstance3D
var _plant_nodes := {}     # pid -> Node3D
var _corridor_nodes := {}  # Vector2i -> Node3D  (keyed by tile)
var _corridor_keys := {}   # Vector2i -> String  (kind + neighbour mask)
var _dragging := false


func _ready() -> void:
	_build_environment()
	_build_camera()
	_plants_root = Node3D.new()
	_corridors_root = Node3D.new()
	_cities_root = Node3D.new()
	add_child(_cities_root)
	add_child(_corridors_root)
	add_child(_plants_root)
	_cursor = MeshInstance3D.new()
	var cursor_mesh := PlaneMesh.new()
	cursor_mesh.size = Vector2(1.0, 1.0)
	_cursor.mesh = cursor_mesh
	_cursor.material_override = PlantModels.flat(Color(1, 1, 1, 0.30), true)
	add_child(_cursor)
	World.world_changed.connect(redraw)
	tile_clicked.connect(_apply_tool)
	redraw()


# ─── stage: sun, sky, camera ──────────────────────────────────────────

func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -34, 0)
	sun.shadow_enabled = true
	sun.light_color = Color(1.0, 0.965, 0.89)  # late-morning warmth
	sun.light_energy = 1.45
	sun.shadow_blur = 0.75
	sun.shadow_normal_bias = 2.5  # the iGPU edge-sparkle guard from the sibling
	sun.directional_shadow_max_distance = 260.0
	add_child(sun)
	_sun = sun

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.33, 0.52, 0.78)
	sky_material.sky_horizon_color = Color(0.74, 0.82, 0.88)
	sky_material.ground_bottom_color = Color(0.29, 0.35, 0.30)
	sky_material.ground_horizon_color = Color(0.62, 0.68, 0.70)
	var sky := Sky.new()
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.72
	env.ssao_enabled = true
	env.ssao_intensity = 1.4
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.80, 0.88)
	# the camera sits 240 units back for ortho depth, so density must be a
	# fraction of the city-scale sibling's or the continent turns to haze
	env.fog_density = 0.00035
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = _zoom
	camera.near = 0.1
	camera.far = 800.0
	add_child(camera)
	_apply_camera()


func _apply_camera() -> void:
	# locked isometric: fixed pitch, yaw in 90° steps, orthographic zoom
	var yaw := deg_to_rad(_yaw)
	var direction := Vector3(sin(yaw), 0.92, cos(yaw)).normalized()
	camera.size = _zoom
	camera.position = _focus + direction * 240.0
	camera.look_at(_focus, Vector3.UP)


func focus_tile(tile: Vector2i, zoom: float = -1.0) -> void:
	_focus = Vector3(tile.x + 0.5, 0.0, tile.y + 0.5)
	if zoom > 0.0:
		_zoom = clampf(zoom, MIN_ZOOM, MAX_ZOOM)
	_apply_camera()


func _process(delta: float) -> void:
	if not is_equal_approx(_yaw, _yaw_target):
		_yaw = lerp_angle(deg_to_rad(_yaw), deg_to_rad(_yaw_target),
			clampf(delta * 8.0, 0.0, 1.0))
		_yaw = rad_to_deg(_yaw)
		if absf(angle_difference(deg_to_rad(_yaw), deg_to_rad(_yaw_target))) < 0.01:
			_yaw = _yaw_target
		_apply_camera()


# ─── terrain ──────────────────────────────────────────────────────────

func _build_terrain() -> void:
	if _terrain != null:
		_terrain.queue_free()
	if _water != null:
		_water.queue_free()
	if World.width == 0:
		return
	var data := EuropeTerrain.build(World)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_COLOR] = data["colors"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_terrain = MeshInstance3D.new()
	_terrain.mesh = mesh
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	# the colours above are picked in sRGB; without this flag Godot treats
	# them as linear and the whole continent bleaches to pastel
	material.vertex_color_is_srgb = true
	material.roughness = 0.95
	_terrain.material_override = material
	add_child(_terrain)

	# one translucent sheet over the whole map: shelf and deep sea read as
	# one body of water with the sea floor darkening beneath it
	var plane := PlaneMesh.new()
	plane.size = Vector2(World.width + 4, World.height + 4)
	_water = MeshInstance3D.new()
	_water.mesh = plane
	_water.position = Vector3(World.width / 2.0, EuropeTerrain.water_level(),
		World.height / 2.0)
	var water_material := StandardMaterial3D.new()
	water_material.albedo_color = Color(0.16, 0.40, 0.62, 0.82)
	water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_material.roughness = 0.12
	water_material.metallic = 0.35
	_water.material_override = water_material
	add_child(_water)


# ─── incremental redraw ───────────────────────────────────────────────

func redraw() -> void:
	if _terrain == null:
		_build_terrain()
		_scatter_decoration()
		_build_cities()
	_sync_plants()
	_sync_corridors()


func ground_y(tile: Vector2i) -> float:
	return EuropeTerrain.height_of(str(World.terrain_at(tile)))


func _tile_origin(tile: Vector2i) -> Vector3:
	return Vector3(tile.x + 0.5, ground_y(tile), tile.y + 0.5)


## Forest masses and stone fields, one MultiMesh per prop surface.
func _scatter_decoration() -> void:
	var placements := DecoScatter.placements(World)
	var deco := Node3D.new()
	add_child(deco)
	for prop: String in placements:
		for node: MultiMeshInstance3D in DecoScatter.build_multimeshes(
				prop, placements[prop]):
			deco.add_child(node)


func _build_cities() -> void:
	var index := 0
	for lc_id: String in World.load_centers:
		var lc: Dictionary = World.load_centers[lc_id]
		var peak: float = lc.get("peak_mw", 0.0)
		for tile: Vector2i in lc["tiles"]:
			var cluster := PlantModels.load_center(
				"large" if peak >= 6000.0 else "small", index)
			index += 1
			if cluster == null:
				continue
			cluster.position = _tile_origin(tile)
			_cities_root.add_child(cluster)


func _sync_plants() -> void:
	for pid: String in _plant_nodes.keys():
		if not World.plants.has(pid):
			(_plant_nodes[pid] as Node3D).queue_free()
			_plant_nodes.erase(pid)
	for pid: String in World.plants:
		if _plant_nodes.has(pid):
			continue
		var plant: Dictionary = World.plants[pid]
		var model := PlantModels.make(str(plant["kind"]))
		if model == null:
			continue
		model.position = _tile_origin(plant["tile"])
		_plants_root.add_child(model)
		_plant_nodes[pid] = model


func _sync_corridors() -> void:
	for tile: Vector2i in _corridor_nodes.keys():
		if not World.corridors.has(tile):
			(_corridor_nodes[tile] as Node3D).queue_free()
			_corridor_nodes.erase(tile)
			_corridor_keys.erase(tile)
	for tile: Vector2i in World.corridors:
		var kind := str(World.corridors[tile])
		var neighbors := _corridor_neighbors(tile, kind)
		# the cache key folds kind + which sides connect: a corridor is only
		# rebuilt when its SHAPE changes, not when a distant tile is edited
		var key := kind
		for offset: Vector2i in neighbors:
			key += "|%d,%d" % [offset.x, offset.y]
		if _corridor_keys.get(tile, "") == key:
			continue
		if _corridor_nodes.has(tile):
			(_corridor_nodes[tile] as Node3D).queue_free()
		var model := PlantModels.corridor(kind, neighbors)
		if model == null:
			continue
		model.position = _tile_origin(tile)
		_corridors_root.add_child(model)
		_corridor_nodes[tile] = model
		_corridor_keys[tile] = key


## Sides a corridor tile links to: same-kind corridors, plus any adjacent
## plant or load-center footprint (the visible tap into the grid).
func _corridor_neighbors(tile: Vector2i, kind: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for offset: Vector2i in [Vector2i(0, -1), Vector2i(1, 0),
			Vector2i(0, 1), Vector2i(-1, 0)]:
		var n := tile + offset
		var linked := str(World.corridors.get(n, "")) == kind
		if not linked and kind != "hvdc":
			# AC corridors also dress toward what they serve
			linked = World.plant_at(n) != "" or World.load_center_at(n) != ""
		elif not linked:
			linked = World.plant_at(n) != ""
		if linked:
			out.append(offset)
	return out


## Apply the armed tool to a tile. The VIEW never owns state — every edit
## goes through WorldModel, which re-emits world_changed and drives redraw.
func _apply_tool(tile: Vector2i) -> void:
	if tool_id == "" or not valid_here(tile):
		return
	if tool_id.begins_with("corridor_"):
		World.place_corridor(tile, _corridor_kind())
	elif tool_id == "substation":
		World.place_substation(tile)
	else:
		World.place_plant(tool_id, tile)


# ─── ghost preview + input ────────────────────────────────────────────

func _refresh_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	if tool_id == "":
		return
	var sample: Node3D = null
	if tool_id.begins_with("corridor_"):
		var kind := _corridor_kind()
		sample = PlantModels.corridor(kind, [Vector2i(1, 0), Vector2i(-1, 0)])
	else:
		sample = PlantModels.make(tool_id)
	if sample == null:
		return
	_ghost = sample
	_tint(_ghost, Color(0.4, 1.0, 0.5, 0.55))
	add_child(_ghost)


func _corridor_kind() -> String:
	match tool_id:
		"corridor_400": return "line_400"
		"corridor_220": return "line_220"
		"corridor_hvdc": return "hvdc"
	return "line_400"


func _tint(node: Node, color: Color) -> void:
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = PlantModels.flat(color, true)


func valid_here(tile: Vector2i) -> bool:
	if tool_id == "":
		return false
	if tool_id.begins_with("corridor_"):
		return World.can_place_corridor(tile, _corridor_kind())
	if tool_id == "substation":
		return World.is_land(tile)
	return World.can_place_plant(tool_id, tile)


func mouse_tile() -> Vector2i:
	var viewport := get_viewport()
	if viewport == null or camera == null:
		return Vector2i(-1, -1)
	var mouse := viewport.get_mouse_position()
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	if absf(direction.y) < 1e-6:
		return Vector2i(-1, -1)
	# intersect the average land plane; good enough at this tile size
	var t := -origin.y / direction.y
	var hit := origin + direction * t
	return Vector2i(int(floor(hit.x)), int(floor(hit.z)))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var tile := mouse_tile()
		if tile != hover_tile:
			hover_tile = tile
			tile_hovered.emit(tile)
			_place_cursor(tile)
		if _dragging and tool_id.begins_with("corridor_"):
			tile_clicked.emit(tile)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					_zoom = clampf(_zoom / 1.12, MIN_ZOOM, MAX_ZOOM)
					_apply_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					_zoom = clampf(_zoom * 1.12, MIN_ZOOM, MAX_ZOOM)
					_apply_camera()
			MOUSE_BUTTON_LEFT:
				_dragging = button.pressed
				if button.pressed:
					tile_clicked.emit(mouse_tile())
	elif event is InputEventKey and (event as InputEventKey).pressed:
		# camera only — building is menu-driven (no build hotkeys)
		match (event as InputEventKey).keycode:
			KEY_Q: _yaw_target = fmod(_yaw_target + 90.0, 360.0)
			KEY_E: _yaw_target = fmod(_yaw_target - 90.0 + 360.0, 360.0)
			KEY_LEFT: _pan(Vector3(-2, 0, 0))
			KEY_RIGHT: _pan(Vector3(2, 0, 0))
			KEY_UP: _pan(Vector3(0, 0, -2))
			KEY_DOWN: _pan(Vector3(0, 0, 2))


func _pan(delta: Vector3) -> void:
	var yaw := deg_to_rad(_yaw)
	_focus += delta.rotated(Vector3.UP, yaw)
	_apply_camera()


func _place_cursor(tile: Vector2i) -> void:
	var inside := tile.x >= 0 and tile.y >= 0 \
		and tile.x < World.width and tile.y < World.height
	_cursor.visible = inside
	if not inside:
		if _ghost != null:
			_ghost.visible = false
		return
	var origin := _tile_origin(tile)
	_cursor.position = origin + Vector3(0, 0.02, 0)
	if _ghost != null:
		_ghost.visible = tool_id != ""
		_ghost.position = origin
		_tint(_ghost, Color(0.4, 1.0, 0.5, 0.55) if valid_here(tile)
			else Color(1.0, 0.35, 0.3, 0.55))
