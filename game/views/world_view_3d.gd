class_name WorldView3D
extends Node3D
## The map in real 3D (the infrastruct CityView pattern at continental
## scale): locked isometric orthographic camera, warm sun + sky ambient, a
## vertex-coloured continent, and one procedural model per built component.
## Views RENDER ONLY — every edit goes through WorldModel, which stays the
## source of truth.
##
## STREAMING (the reason this file is not just "build everything"): the map
## is ~772 000 tiles. Resident geometry for all of it costs seconds of build
## time and hundreds of MB, so the world is cut into CHUNKS that are built
## when they come near the camera and freed when they fall away. Underneath
## them sits ONE coarse whole-map mesh — a cheap backdrop that means an
## unstreamed distance still reads as continent instead of a hole, and the
## overview zoom stays smooth without streaming anything at all.
##
## One tile = 1.0 world unit; a component on tile (x, y) is centred at
## (x + 0.5, ground, y + 0.5).

signal tile_clicked(tile: Vector2i)
signal tile_hovered(tile: Vector2i)

const MIN_ZOOM := 5.0
const MAX_ZOOM := 1200.0  # the whole continent fits at ~1000 on the 5 km grid

## Streaming constants. CHUNK is a compromise: smaller chunks stream more
## smoothly but multiply node count and per-chunk overhead.
const CHUNK := 32
## visible half-extent multiplier — the loaded ring must reach PAST the
## frustum so its boundary is never on screen (that, plus the coarse
## backdrop, is why no popping edge is visible)
const VIEW_MARGIN := 1.35
## chunks are dropped only past this multiple of the load radius, so panning
## back and forth across a boundary does not thrash
const EVICT_MARGIN := 1.9
const MAX_LOADED_CHUNKS := 120
const BUILD_PER_FRAME := 3
## chunks built synchronously when the camera JUMPS (nav widget, boot)
const FOCUS_BUILD_BUDGET := 60
## beyond this ortho size the detail layer is pointless (and unaffordable):
## the coarse backdrop carries the overview alone
const DETAIL_MAX_SIZE := 150.0
## one coarse quad per COARSE_STEP tiles
const COARSE_STEP := 8
## A metro footprint is ~12 x 12 tiles at 5 km and every tile carries a
## cluster of four building models — by far the heaviest thing per chunk.
## Past this ortho size a single building is barely a pixel, so the clusters
## are dropped and rebuilt on the way back in.
const CITY_DETAIL_MAX_SIZE := 70.0

## The tool the HUD has armed (a WorldModel kind, "corridor_*" or "") —
## drives the ghost preview and what a click builds.
var tool_id := "":
	set(value):
		tool_id = value
		_refresh_ghost()

var camera: Camera3D
var hover_tile := Vector2i(-1, -1)

var _zoom := 44.0
var _focus := Vector3(480.0, 0, 400.0)  # central Europe; re-centred on load
var _yaw := 0.0
var _yaw_target := 0.0
var _sun: DirectionalLight3D
var _coarse: MeshInstance3D
var _water: MeshInstance3D
var _chunk_root: Node3D
var _ghost: Node3D
var _cursor: MeshInstance3D
var _terrain_material: StandardMaterial3D
var _env: Environment

## chunk key Vector2i(cx, cy) -> {root: Node3D, plants: {}, corridors: {},
## corridor_keys: {}, cities: {}}
var _chunks := {}
var _pending: Array[Vector2i] = []
var _dragging := false
var _map_ready := false
var _stream_dirty := false
var _components_dirty := false
var _cities_shown := true


func _ready() -> void:
	_build_environment()
	_build_camera()
	_chunk_root = Node3D.new()
	add_child(_chunk_root)
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
	sun.directional_shadow_max_distance = 420.0
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
	# Aerial haze. EXPONENTIAL fog is useless here: under an orthographic
	# camera every ground tile sits at nearly the same depth, so density
	# applies as one flat veil over the whole map instead of a gradient
	# (it was why the continent looked bleached). DEPTH fog with an explicit
	# near/far band gives a real falloff toward the horizon; _apply_camera
	# keeps the band tied to the current zoom.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.74, 0.82, 0.90)
	env.fog_density = 0.9
	env.fog_depth_curve = 1.6
	_env = env
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = _zoom
	camera.near = 0.1
	camera.far = 2000.0
	add_child(camera)
	_apply_camera()


func _apply_camera() -> void:
	# locked isometric: fixed pitch, yaw in 90° steps, orthographic zoom
	var yaw := deg_to_rad(_yaw)
	var direction := Vector3(sin(yaw), 0.92, cos(yaw)).normalized()
	camera.size = _zoom
	camera.position = _focus + direction * 700.0
	camera.look_at(_focus, Vector3.UP)
	if _env != null:
		# the haze band always starts just past the focus plane and ends
		# beyond the streamed ring, so distance reads as air at every zoom
		_env.fog_depth_begin = 700.0 + _zoom * 0.35
		_env.fog_depth_end = 700.0 + _zoom * 2.6
	_stream_dirty = true


func focus_tile(tile: Vector2i, zoom: float = -1.0) -> void:
	_focus = Vector3(tile.x + 0.5, 0.0, tile.y + 0.5)
	if zoom > 0.0:
		_zoom = clampf(zoom, MIN_ZOOM, MAX_ZOOM)
	_apply_camera()
	# a jump must land on built ground rather than stream in after the fact,
	# but only the screenful is urgent — the ring finishes over later frames
	_update_stream()
	_drain_pending(FOCUS_BUILD_BUDGET)


func _process(delta: float) -> void:
	if not is_equal_approx(_yaw, _yaw_target):
		_yaw = lerp_angle(deg_to_rad(_yaw), deg_to_rad(_yaw_target),
			clampf(delta * 8.0, 0.0, 1.0))
		_yaw = rad_to_deg(_yaw)
		if absf(angle_difference(deg_to_rad(_yaw), deg_to_rad(_yaw_target))) < 0.01:
			_yaw = _yaw_target
		_apply_camera()
	# Edits arrive in bursts (a scripted build fires hundreds of
	# world_changed signals in one frame). Reconciling per signal made boot
	# quadratic, so redraw() only marks dirty and the work happens once here.
	if _stream_dirty:
		_stream_dirty = false
		_update_stream()
	# crossing the city-detail band adds or drops thousands of building
	# instances; do it once on the crossing, not per frame
	var want_cities := _cities_wanted()
	if want_cities != _cities_shown:
		_cities_shown = want_cities
		if want_cities:
			_components_dirty = true
		else:
			_drop_cities()
	if _components_dirty:
		_components_dirty = false
		_sync_components()
	_drain_pending(BUILD_PER_FRAME)


# ─── coarse backdrop + water ──────────────────────────────────────────

func _build_backdrop() -> void:
	if World.width == 0:
		return
	var data := EuropeTerrain.build_coarse(World, COARSE_STEP)
	_coarse = MeshInstance3D.new()
	_coarse.mesh = _mesh_from(data)
	_coarse.material_override = _terrain_mat()
	# the backdrop is a stand-in for detail, never a shadow caster
	_coarse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_coarse)

	var plane := PlaneMesh.new()
	plane.size = Vector2(World.width + 8, World.height + 8)
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


func _terrain_mat() -> StandardMaterial3D:
	if _terrain_material == null:
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		# the palette is picked in sRGB; without this flag Godot reads the
		# colours as linear and the whole continent bleaches to pastel
		material.vertex_color_is_srgb = true
		material.roughness = 0.95
		_terrain_material = material
	return _terrain_material


func _mesh_from(data: Dictionary) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_COLOR] = data["colors"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]
	var mesh := ArrayMesh.new()
	if (data["vertices"] as PackedVector3Array).size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ─── streaming ────────────────────────────────────────────────────────

func _chunk_of(tile: Vector2i) -> Vector2i:
	return Vector2i(floori(float(tile.x) / CHUNK), floori(float(tile.y) / CHUNK))


## Which chunks should be resident, nearest first.
func _wanted_chunks() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _zoom > DETAIL_MAX_SIZE:
		return out  # overview: the coarse backdrop carries the whole map
	var radius := _zoom * VIEW_MARGIN + CHUNK
	var cx0 := floori((_focus.x - radius) / CHUNK)
	var cx1 := floori((_focus.x + radius) / CHUNK)
	var cy0 := floori((_focus.z - radius) / CHUNK)
	var cy1 := floori((_focus.z + radius) / CHUNK)
	var max_cx := floori(float(World.width - 1) / CHUNK)
	var max_cy := floori(float(World.height - 1) / CHUNK)
	var scored: Array = []
	for cy in range(maxi(cy0, 0), mini(cy1, max_cy) + 1):
		for cx in range(maxi(cx0, 0), mini(cx1, max_cx) + 1):
			var centre := Vector2((cx + 0.5) * CHUNK, (cy + 0.5) * CHUNK)
			var d := centre.distance_to(Vector2(_focus.x, _focus.z))
			if d > radius + CHUNK:
				continue
			scored.append({"key": Vector2i(cx, cy), "d": d})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["d"]) < float(b["d"]))
	for entry: Dictionary in scored:
		out.append(entry["key"] as Vector2i)
		if out.size() >= MAX_LOADED_CHUNKS:
			break
	return out


func _update_stream() -> void:
	if not _map_ready:
		return
	var wanted := _wanted_chunks()
	var keep := {}
	_pending.clear()
	for key: Vector2i in wanted:
		keep[key] = true
		if not _chunks.has(key):
			_pending.append(key)
	# evict what fell well outside the ring (hysteresis: EVICT_MARGIN)
	var radius := _zoom * VIEW_MARGIN + CHUNK
	for key: Vector2i in _chunks.keys():
		if keep.has(key):
			continue
		var centre := Vector2((key.x + 0.5) * CHUNK, (key.y + 0.5) * CHUNK)
		if _zoom > DETAIL_MAX_SIZE \
				or centre.distance_to(Vector2(_focus.x, _focus.z)) \
					> radius * EVICT_MARGIN:
			_free_chunk(key)


func _drain_pending(budget: int) -> void:
	var built := 0
	while built < budget and not _pending.is_empty():
		var key: Vector2i = _pending.pop_front()
		if not _chunks.has(key):
			_build_chunk(key)
		built += 1


func _build_chunk(key: Vector2i) -> void:
	var x0 := key.x * CHUNK
	var y0 := key.y * CHUNK
	var x1 := mini(x0 + CHUNK, World.width)
	var y1 := mini(y0 + CHUNK, World.height)
	if x0 >= x1 or y0 >= y1:
		return
	var root := Node3D.new()
	_chunk_root.add_child(root)

	var terrain := MeshInstance3D.new()
	terrain.mesh = _mesh_from(EuropeTerrain.build_region(World, x0, y0, x1, y1))
	terrain.material_override = _terrain_mat()
	root.add_child(terrain)

	var placements := DecoScatter.placements_region(World, x0, y0, x1, y1)
	for prop: String in placements:
		for node: MultiMeshInstance3D in DecoScatter.build_multimeshes(
				prop, placements[prop]):
			root.add_child(node)

	_chunks[key] = {"root": root, "plants": {}, "corridors": {},
		"corridor_keys": {}, "cities": {}}
	_populate_chunk(key)


func _free_chunk(key: Vector2i) -> void:
	var chunk: Dictionary = _chunks[key]
	(chunk["root"] as Node3D).queue_free()
	_chunks.erase(key)


# ─── components (plants, corridors, cities) ───────────────────────────

## Fill a chunk with everything standing on its tiles.
##
## This scans the chunk's OWN tiles rather than iterating World.plants /
## World.corridors: a Europe-wide grid holds thousands of corridor tiles, and
## walking all of them once per resident chunk made every edit O(chunks x
## components). Tile lookups keep it O(chunk area) no matter how much the
## player has built.
func _populate_chunk(key: Vector2i) -> void:
	var chunk: Dictionary = _chunks[key]
	var root := chunk["root"] as Node3D
	var plants := chunk["plants"] as Dictionary
	var cities := chunk["cities"] as Dictionary
	var x0 := key.x * CHUNK
	var y0 := key.y * CHUNK
	var x1 := mini(x0 + CHUNK, World.width)
	var y1 := mini(y0 + CHUNK, World.height)
	for y in range(y0, y1):
		for x in range(x0, x1):
			var tile := Vector2i(x, y)
			var pid := World.plant_at(tile)
			if pid != "" and not plants.has(pid) and World.plants.has(pid):
				var model := PlantModels.make(str(World.plants[pid]["kind"]))
				if model != null:
					model.position = _tile_origin(tile)
					root.add_child(model)
					plants[pid] = model
			if World.corridors.has(tile):
				_build_corridor(key, tile)
			var lc_id := World.load_center_at(tile)
			if lc_id != "" and not cities.has(tile) and _cities_wanted():
				var lc: Dictionary = World.load_centers.get(lc_id, {})
				var peak: float = lc.get("peak_mw", 0.0)
				# the variant is picked from the TILE, not a running counter:
				# a re-streamed chunk must rebuild the same skyline
				var cluster := PlantModels.load_center(
					"large" if peak >= 6000.0 else "small",
					absi(x * 31 + y * 17))
				if cluster != null:
					cluster.position = _tile_origin(tile)
					root.add_child(cluster)
					cities[tile] = cluster


func _build_corridor(key: Vector2i, tile: Vector2i) -> void:
	var chunk: Dictionary = _chunks[key]
	var kind := str(World.corridors[tile])
	var neighbors := _corridor_neighbors(tile, kind)
	# the cache key folds kind + which sides connect: a corridor is only
	# rebuilt when its SHAPE changes, not when a distant tile is edited
	var shape := kind
	for offset: Vector2i in neighbors:
		shape += "|%d,%d" % [offset.x, offset.y]
	var keys := chunk["corridor_keys"] as Dictionary
	var nodes := chunk["corridors"] as Dictionary
	if str(keys.get(tile, "")) == shape:
		return
	if nodes.has(tile):
		(nodes[tile] as Node3D).queue_free()
		nodes.erase(tile)
	var model := PlantModels.corridor(kind, neighbors)
	if model == null:
		return
	model.position = _tile_origin(tile)
	(chunk["root"] as Node3D).add_child(model)
	nodes[tile] = model
	keys[tile] = shape


## Reconcile loaded chunks with the model after an edit. Only chunks that
## are resident do any work — the rest pick their components up when they
## stream in.
func _cities_wanted() -> bool:
	return _zoom <= CITY_DETAIL_MAX_SIZE


## Drop every resident city cluster (called when the zoom leaves the band
## where individual buildings are legible).
func _drop_cities() -> void:
	for key: Vector2i in _chunks:
		var cities := (_chunks[key] as Dictionary)["cities"] as Dictionary
		for tile: Vector2i in cities.keys():
			(cities[tile] as Node3D).queue_free()
		cities.clear()


func _sync_components() -> void:
	for key: Vector2i in _chunks:
		var chunk: Dictionary = _chunks[key]
		var plants := chunk["plants"] as Dictionary
		for pid: String in plants.keys():
			if not World.plants.has(pid):
				(plants[pid] as Node3D).queue_free()
				plants.erase(pid)
		var nodes := chunk["corridors"] as Dictionary
		var keys := chunk["corridor_keys"] as Dictionary
		for tile: Vector2i in nodes.keys():
			if not World.corridors.has(tile):
				(nodes[tile] as Node3D).queue_free()
				nodes.erase(tile)
				keys.erase(tile)
		# the tile scan re-keys every resident corridor, which also catches
		# the shape change a NEW neighbour causes in an existing tile
		_populate_chunk(key)


func redraw() -> void:
	if not _map_ready:
		if World.width == 0:
			return
		_build_backdrop()
		_map_ready = true
		_focus = Vector3(World.width / 2.0, 0.0, World.height / 2.0)
		_apply_camera()
	# never stream or reconcile inline: see _process
	_stream_dirty = true
	_components_dirty = true


func ground_y(tile: Vector2i) -> float:
	return EuropeTerrain.height_of(World.terrain_at(tile))


func _tile_origin(tile: Vector2i) -> Vector3:
	return Vector3(tile.x + 0.5, ground_y(tile), tile.y + 0.5)


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
		sample = PlantModels.corridor(_corridor_kind(),
			[Vector2i(1, 0), Vector2i(-1, 0)])
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
		var step := maxf(2.0, _zoom * 0.08)  # pan scales with the zoom level
		match (event as InputEventKey).keycode:
			KEY_Q: _yaw_target = fmod(_yaw_target + 90.0, 360.0)
			KEY_E: _yaw_target = fmod(_yaw_target - 90.0 + 360.0, 360.0)
			KEY_LEFT: _pan(Vector3(-step, 0, 0))
			KEY_RIGHT: _pan(Vector3(step, 0, 0))
			KEY_UP: _pan(Vector3(0, 0, -step))
			KEY_DOWN: _pan(Vector3(0, 0, step))


func _pan(delta: Vector3) -> void:
	var yaw := deg_to_rad(_yaw)
	_focus += delta.rotated(Vector3.UP, yaw)
	_apply_camera()


func _place_cursor(tile: Vector2i) -> void:
	var inside := World.in_bounds(tile)
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
