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
## You can never zoom out to the whole continent. At 5 km tiles this is a
## ~600 km tall window — a REGION, France-or-Germany sized — and the fog
## closes in before its edge, so the world reads as continuing past the
## horizon rather than stopping at a rendered boundary.
##
## This is a performance contract as much as a look: the resident chunk set
## is proportional to the visible area, so an unbounded zoom is an unbounded
## streaming load. At 1200 the camera framed all 771 840 tiles, every jump
## queued a continent of chunks, and the renderer ran out of RIDs and died.
## Navigation across Europe is the minimap and jump list's job, not the
## camera's.
const MAX_ZOOM := 120.0

## Camera geometry, NAMED because twice now a fog band silently encoded it
## as bare numbers and broke when the other number moved (see fog_band).
## The camera stands STANDOFF world units from the focus point along the
## view direction — so the focus plane sits at depth ≈ STANDOFF, and any
## depth-based effect must be expressed relative to it, never absolutely.
const STANDOFF := 700.0
## Vertical component of the (unnormalized) view direction; the horizontal
## component has magnitude 1, so tan(pitch) = PITCH_RATIO and the ground
## depth visible in a frame of ortho size z spans STANDOFF ± 0.5·z/PITCH_RATIO.
const PITCH_RATIO := 0.92

## Streaming constants. CHUNK is a compromise: smaller chunks stream more
## smoothly but multiply node count and per-chunk overhead.
const CHUNK := 32
## visible half-extent multiplier — the loaded ring must reach PAST the
## frustum so its boundary is never on screen (that, plus the coarse
## backdrop, is why no popping edge is visible)
const VIEW_MARGIN := 1.15
## chunks are dropped only past this multiple of the load radius, so panning
## back and forth across a boundary does not thrash
const EVICT_MARGIN := 1.9
const MAX_LOADED_CHUNKS := 120
const BUILD_PER_FRAME := 3
## Trees and rocks are the per-frame cost, not terrain: a forest chunk
## carries ~2 000 instances, and the whole ring carries six figures of them.
## They are only legible near the camera, so beyond this radius a chunk
## keeps its ground and hides its cover (a visibility flag, so coming back
## costs nothing).
const DECO_RADIUS := 45.0
## chunks built synchronously when the camera JUMPS (nav widget, boot)
const FOCUS_BUILD_BUDGET := 60
## Above this ortho size the detail layer would be dropped for the coarse
## backdrop alone. With MAX_ZOOM bounded it is never reached — kept as a
## backstop so a future zoom change cannot silently reintroduce the
## build-and-drop-everything cliff at the threshold.
const DETAIL_MAX_SIZE := MAX_ZOOM + 1.0
## one coarse quad per COARSE_STEP tiles
const COARSE_STEP := 8
## Past this ortho size component MODELS (city clusters, plant models,
## corridor pylons) are dropped chunk-wise and rebuilt on the way back in;
## the strategic ribbon layer carries the grid above the band. Deliberately
## LOW (user direction): models are legible only up close anyway, and a
## continental web at ~90 nodes per corridor tile is minutes of build work
## for sub-pixel geometry — rendering the small portion you can actually
## see is most of the smoothness budget.
const MODEL_DETAIL_MAX_SIZE := 34.0

## site notes: cities (always) and plants (below PLANT_TAG_MAX_ZOOM)
## carry a location pin + name so the player can orient; CLICKING a pin
## toggles that site's weekly graph open above it (charts were in the way
## when automatic — player report). Tags are cheap Label3Ds; a chart is a
## SubViewport that renders once per block.
const PLANT_TAG_MAX_ZOOM := 60.0
const TAG_PLANT_CAP := 16

## The tool the HUD has armed (a WorldModel kind, "corridor_*" or "") —
## drives the ghost preview and what a click builds.
var tool_id := "":
	set(value):
		tool_id = value
		_refresh_ghost()

var camera: Camera3D
var hover_tile := Vector2i(-1, -1)

## Right-drag rotation feel: degrees of yaw per pixel of horizontal drag
## (a full sweep across a 1280 px window is ~1.25 turns).
const ROTATE_DEG_PER_PX := 0.35

var _zoom := 44.0
var _focus := Vector3(480.0, 0, 400.0)  # central Europe; re-centred on load
var _yaw := 0.0
var _yaw_target := 0.0
var _rotating := false  # right mouse button held — drag rotates the view
var _panning := false  # middle mouse button held — drag moves the map
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
var _evict_queue: Array[Vector2i] = []
var _dragging := false
var _map_ready := false
var _stream_dirty := false
var _components_dirty := false
## chunks awaiting component population (nearest-first), drained under the
## frame budget — see _sync_components for why this is never done inline
var _populate_queue: Array[Vector2i] = []
## floating site notes (city / plant weekly graphs) keyed "z:<id>"/"p:<pid>"
var _notes_root: Node3D
var _notes: Dictionary = {}
var _note_accum := 0.0
var _note_block := -1
var _chart_open := {}  # note key -> true; toggled by clicking the pin
var _zone_anchor: Dictionary = {}  # zone id -> Vector2 tile centroid
var _models_shown := true
var _strategic: MeshInstance3D
var _strategic_dirty := false
var _sky_material: ProceduralSkyMaterial
var _city_lights: MultiMeshInstance3D
var _city_lights_material: StandardMaterial3D
var _tod_cache := -1.0  # time-of-day fraction the lighting was last set for
## resident wind-turbine rotors -> spin speed (rad/s from the LIVE weather
## at build time). Model-band models are few, so per-frame rotation is
## cheap; a freed chunk's rotors drop out via is_instance_valid.
var _rotors := {}


func _ready() -> void:
	_build_environment()
	_build_camera()
	_chunk_root = Node3D.new()
	add_child(_chunk_root)
	_notes_root = Node3D.new()
	add_child(_notes_root)
	_cursor = MeshInstance3D.new()
	var cursor_mesh := PlaneMesh.new()
	cursor_mesh.size = Vector2(1.0, 1.0)
	_cursor.mesh = cursor_mesh
	_cursor.material_override = PlantModels.flat(Color(1, 1, 1, 0.30), true)
	add_child(_cursor)
	_strategic = MeshInstance3D.new()
	var strategic_material := StandardMaterial3D.new()
	strategic_material.vertex_color_use_as_albedo = true
	strategic_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# the strategic layer must stay legible at the zooms it exists for —
	# aerial haze would wash the thin ribbons out exactly there
	strategic_material.disable_fog = true
	strategic_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_strategic.material_override = strategic_material
	_strategic.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_strategic)
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
	_sky_material = sky_material
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
	# locked pitch isometric: free yaw (right-drag; Q/E step the quarter
	# turns), orthographic zoom
	var yaw := deg_to_rad(_yaw)
	var direction := Vector3(sin(yaw), PITCH_RATIO, cos(yaw)).normalized()
	camera.size = _zoom
	camera.position = _focus + direction * STANDOFF
	camera.look_at(_focus, Vector3.UP)
	if _env != null:
		var band := fog_band(_zoom)
		_env.fog_depth_begin = band.x
		_env.fog_depth_end = band.y
	if _strategic != null:
		# the ribbon layer is the STRATEGIC representation: near the ground
		# the pylon models carry the grid and a tile-wide ribbon would pave
		# the countryside pink; the band overlaps the model band slightly
		# so the handover never shows a gridless frame
		_strategic.visible = _zoom > 30.0
	_stream_dirty = true


## The depth-fog band for an ortho size, DERIVED from the camera geometry —
## returns Vector2(begin, end). This function exists because hand-tuned fog
## constants have now caused two incidents in this file: exponential fog
## bleached the whole continent (see _build_environment), and a rewritten
## depth band that dropped the STANDOFF base fogged 100 % of every frame —
## the ground plane lives at depth ≈ STANDOFF, so a band anchored near zero
## sits entirely in front of the world and everything renders full-haze.
##
## Geometry: the ground depth visible in the frame spans STANDOFF ± half
## where half = 0.5·zoom/PITCH_RATIO. The two fractions are frame-relative,
## so they mean the same thing at every zoom: haze begins 45 % of the way
## up the visible span (a depth cue at the top of the frame — under an
## orthographic camera fog can never be the culling mechanism, the side and
## bottom edges sit at near-focus depth) and reaches full opacity past the
## frame edge but BEFORE the streamed ring's edge, so the detail-to-coarse
## handover is always masked. test_world_view.gd pins these invariants.
static func fog_band(zoom: float) -> Vector2:
	var half := 0.5 * zoom / PITCH_RATIO
	return Vector2(STANDOFF + 0.45 * half, STANDOFF + 1.30 * half)


## Ground displacement of the focus for a middle-drag of `relative` pixels —
## grab-the-ground: the terrain point under the cursor follows the cursor.
## Horizontally one pixel is zoom/viewport_h world units (ortho size is the
## frame's vertical extent); vertically the same pixel spans 1/sin(pitch)
## MORE ground, because the frame's height is a slanted cut across the
## ground plane. Pure so test_world_view.gd can pin it.
static func drag_pan(relative: Vector2, yaw_deg: float, zoom: float,
		viewport_h: float) -> Vector3:
	var per_px := zoom / viewport_h
	var sin_pitch := PITCH_RATIO / sqrt(1.0 + PITCH_RATIO * PITCH_RATIO)
	var yaw := deg_to_rad(yaw_deg)
	var screen_right := Vector3(cos(yaw), 0, -sin(yaw))
	var toward_camera := Vector3(sin(yaw), 0, cos(yaw))
	return -(screen_right * (relative.x * per_px)
		+ toward_camera * (relative.y * per_px / sin_pitch))


func focus_tile(tile: Vector2i, zoom: float = -1.0) -> void:
	_focus = Vector3(tile.x + 0.5, 0.0, tile.y + 0.5)
	if zoom > 0.0:
		_zoom = clampf(zoom, MIN_ZOOM, MAX_ZOOM)
	_apply_camera()
	# a jump must land on built ground rather than stream in after the fact,
	# but only the screenful is urgent — the ring finishes over later frames
	_update_stream()
	_drain_pending(FOCUS_BUILD_BUDGET)


# ─── day / night ──────────────────────────────────────────────────────
# The sun follows the SIM clock (GameClock.t_sim): sunrise ~06:00, noon
# peak, warm dusk, blue-grey night — and after dark the load centres glow
# (a MultiMesh of emissive window-quads over every city tile; the existing
# glow pass blooms them, the satellite-at-night look). Render-only: no
# physics reads the sun.

const DAY_SUN := Color(1.0, 0.965, 0.89)
const DUSK_SUN := Color(1.0, 0.62, 0.38)
const NIGHT_SUN := Color(0.55, 0.62, 0.82)  # moonlight stand-in
const DAY_SKY_TOP := Color(0.33, 0.52, 0.78)
const DAY_SKY_HORIZON := Color(0.74, 0.82, 0.88)
const NIGHT_SKY_TOP := Color(0.015, 0.025, 0.07)
const NIGHT_SKY_HORIZON := Color(0.05, 0.07, 0.13)
const DAY_FOG := Color(0.74, 0.82, 0.90)
const NIGHT_FOG := Color(0.05, 0.06, 0.10)
const CITY_LIGHT := Color(1.0, 0.80, 0.45)


## The sun rotates in DISCRETE steps (infrastruct's SUN_QUANT lesson): a
## continuously creeping light re-fits the shadow map every frame and
## every shadow edge texel crawls. Snapped to a fixed grid the map is
## rock-stable between steps; one 0.75-degree jump is invisible next to
## continuous shimmer. Colors and energy stay continuous.
const SUN_QUANT_DEG := 0.75


func _apply_daylight(tod: float) -> void:
	# solar elevation proxy: -1 (midnight) .. +1 (noon)
	var sun_e := sin((tod - 0.25) * TAU)
	var day_f := smoothstep(-0.10, 0.30, sun_e)
	var dusk_f := 1.0 - clampf(absf(sun_e) / 0.30, 0.0, 1.0)  # peak near horizon
	# the azimuth sweeps a REAL half circle (infrastruct): rise EAST, noon
	# SOUTH, set WEST — shadows tell the time of day; at night the sun
	# parks as faint moonlight wherever it set
	var day_win := clampf((tod * 24.0 - 5.5) / 14.0, 0.0, 1.0)
	_sun.rotation_degrees = Vector3(
		-snappedf(lerpf(10.0, 52.0, clampf(sun_e, 0.0, 1.0)), SUN_QUANT_DEG),
		snappedf(lerpf(-90.0, 90.0, day_win), SUN_QUANT_DEG), 0.0)
	_sun.light_energy = 1.45 * day_f + 0.06
	_sun.light_color = NIGHT_SUN.lerp(DAY_SUN, day_f).lerp(DUSK_SUN, dusk_f * 0.7)
	_sun.shadow_enabled = day_f > 0.05  # moonlight shadows sparkle on iGPUs
	if _env != null:
		_env.ambient_light_energy = 0.72 * day_f + 0.14
		_env.fog_light_color = NIGHT_FOG.lerp(DAY_FOG, day_f)
	if _sky_material != null:
		_sky_material.sky_top_color = NIGHT_SKY_TOP.lerp(DAY_SKY_TOP, day_f)
		_sky_material.sky_horizon_color = NIGHT_SKY_HORIZON.lerp(
			DAY_SKY_HORIZON, day_f)
	if _city_lights != null:
		var night_f := 1.0 - day_f
		_city_lights.visible = night_f > 0.03
		_city_lights_material.emission_energy_multiplier = 1.5 * night_f
	if _strategic != null:
		# unshaded ribbons ignore the sun — dim them with it, or the grid
		# blazes neon at midnight
		var level := 0.25 + 0.75 * day_f
		(_strategic.material_override as StandardMaterial3D).albedo_color = \
			Color(level, level, level)


## One emissive quad per lit tile — built once per map. With the urban
## layer the lights trace the REAL city footprints (the satellite-at-night
## shapes); without it they fall back to the load-centre tiles.
func _build_city_lights() -> void:
	if _city_lights != null:
		_city_lights.queue_free()
	var tiles: Array[Vector2i] = World.urban_tiles(0.12)
	var from_urban := not tiles.is_empty()
	if not from_urban:
		for lc_id: String in World.load_centers:
			for tile: Vector2i in World.load_centers[lc_id]["tiles"]:
				tiles.append(tile)
	if tiles.is_empty():
		return
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	var quad := PlaneMesh.new()
	# oversized so neighbouring glows overlap into one continuous blob —
	# hard per-tile squares read as a checkerboard, not a city at night
	quad.size = Vector2(2.6, 2.6)
	multi.mesh = quad
	multi.instance_count = tiles.size()
	for i in tiles.size():
		var tile := tiles[i]
		# a village glows smaller and dimmer than a metro core
		var glow_scale := 0.45 + 0.6 * World.urban_at(tile) if from_urban else 0.7
		multi.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3(glow_scale, 1.0, glow_scale)),
			Vector3(tile.x + 0.5, ground_y(tile) + 0.055, tile.y + 0.5)))
	_city_lights = MultiMeshInstance3D.new()
	_city_lights.multimesh = multi
	_city_lights_material = StandardMaterial3D.new()
	_city_lights_material.albedo_color = CITY_LIGHT
	_city_lights_material.emission_enabled = true
	_city_lights_material.emission = CITY_LIGHT
	_city_lights_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# radial falloff + additive blending: overlapping glows sum into the
	# soft satellite-at-night blobs instead of tiling as opaque squares
	var falloff := Gradient.new()
	falloff.set_color(0, Color(1, 1, 1, 0.42))  # gentle: overlaps ACCUMULATE
	falloff.set_color(1, Color(1, 1, 1, 0.0))
	falloff.add_point(0.45, Color(1, 1, 1, 0.16))
	var falloff_tex := GradientTexture2D.new()
	falloff_tex.gradient = falloff
	falloff_tex.fill = GradientTexture2D.FILL_RADIAL
	falloff_tex.fill_from = Vector2(0.5, 0.5)
	falloff_tex.fill_to = Vector2(0.5, 0.0)
	_city_lights_material.albedo_texture = falloff_tex
	_city_lights_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_city_lights_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_city_lights.material_override = _city_lights_material
	_city_lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_city_lights.visible = false
	add_child(_city_lights)


func _process(delta: float) -> void:
	# UNTYPED on purpose: chunk eviction frees rotor nodes while their keys
	# are still here, and assigning a freed instance to a TYPED loop variable
	# throws at the for-statement itself — aborting _process before the
	# validity guard below can erase the stale key. That error then repeats
	# every frame forever (freeze #3: 47 errors/s of backtrace formatting
	# read as a frozen game). A Variant accepts the freed ref; the guard runs.
	for rotor in _rotors.keys():
		if is_instance_valid(rotor):
			rotor.rotate_z(float(_rotors[rotor]) * delta)
		else:
			_rotors.erase(rotor)
	var tod := fmod(GameClock.t_sim, GameClock.SECONDS_PER_DAY) \
		/ GameClock.SECONDS_PER_DAY
	if absf(tod - _tod_cache) > 0.0003:  # ~26 sim-seconds; cheap either way
		_tod_cache = tod
		_apply_daylight(tod)
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
	var want_models := _models_wanted()
	if want_models != _models_shown:
		_models_shown = want_models
		if want_models:
			_components_dirty = true
		else:
			_drop_models()
	if _components_dirty:
		_components_dirty = false
		_sync_components()
	if _strategic_dirty and _strategic != null:
		_strategic_dirty = false
		_strategic.mesh = StrategicGrid.build_mesh(World)
	_note_accum += delta
	if _note_accum >= 0.4:
		_note_accum = 0.0
		_sync_notes()
	_drain_pending_budgeted()


## Build chunks until the frame budget is spent (at least one): a fixed
## chunks-per-frame count stuttered whenever chunks were expensive — the
## budget makes streaming cost a bounded slice of every frame instead.
const BUILD_BUDGET_MS := 6.0
## ...raised while the queue is deep: healing a zoom transition fast
## matters more than a perfectly even frame right then
const BUILD_BUDGET_DEEP_MS := 14.0
const EVICTS_PER_FRAME := 12


func _drain_pending_budgeted() -> void:
	var freed := 0
	while not _evict_queue.is_empty() and freed < EVICTS_PER_FRAME:
		var key: Vector2i = _evict_queue.pop_front()
		if _chunks.has(key):
			_free_chunk(key)
		freed += 1
	if _pending.is_empty() and _populate_queue.is_empty():
		return
	var budget := BUILD_BUDGET_DEEP_MS if _pending.size() > 12 else BUILD_BUDGET_MS
	var t0 := Time.get_ticks_usec()
	var built := 0
	while not _pending.is_empty():
		if built > 0 and (Time.get_ticks_usec() - t0) / 1000.0 > budget:
			break
		_build_chunk(_pending.pop_front())
		built += 1
	# component population shares the same frame budget (guaranteed ≥1 per
	# frame so chunk builds can never starve it); a queued key whose chunk
	# was evicted meanwhile is skipped by _populate_chunk's guard
	var populated := 0
	while not _populate_queue.is_empty():
		if populated > 0 and (Time.get_ticks_usec() - t0) / 1000.0 > budget:
			break
		_populate_chunk(_populate_queue.pop_front())
		populated += 1


## Turbine rotors spin IN THE WIND: speed from the live weather at the
## tile's region, sampled when the model is built (a resident chunk's
## weather does not change fast enough to matter).
func _collect_rotors(model: Node3D, tile: Vector2i) -> void:
	for rotor: Node3D in model.find_children("*", "Node3D", true, false):
		if rotor.has_meta("rotor"):
			var wind := 7.0
			if Weather != null and Weather.has_method("wind_speed"):
				var region: String = Weather.region_of_tile(tile,
					BuildSession.map_projection())
				if region != "":
					wind = Weather.wind_speed(region,
						World.terrain_at(tile) in ["s", "S"])
			# 4 m/s barely turns, 12+ m/s is a busy 2 rad/s
			_rotors[rotor] = clampf((wind - 3.0) * 0.22, 0.05, 2.2)


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
	_water.position = Vector3(World.width / 2.0, EuropeTerrain.water_level(World),
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
	# cover follows the camera: cheap flag, no rebuild
	for key: Vector2i in _chunks:
		var deco := (_chunks[key] as Dictionary).get("deco") as Node3D
		if deco != null:
			deco.visible = _deco_visible(key)
	# evict what fell well outside the ring (hysteresis: EVICT_MARGIN) —
	# QUEUED, not inline: a birdview->close-zoom transition marks ~70
	# chunks at once and freeing them in one frame was a multi-hundred-ms
	# hitch right when the player is zooming (the "torn map" report)
	var radius := _zoom * VIEW_MARGIN + CHUNK
	for key: Vector2i in _chunks.keys():
		if keep.has(key):
			_evict_queue.erase(key)
			continue
		var centre := Vector2((key.x + 0.5) * CHUNK, (key.y + 0.5) * CHUNK)
		if _zoom > DETAIL_MAX_SIZE \
				or centre.distance_to(Vector2(_focus.x, _focus.z)) \
					> radius * EVICT_MARGIN:
			if not _evict_queue.has(key):
				_evict_queue.append(key)


## Is this chunk close enough to be worth its trees? Zoomed far out the
## cover is sub-pixel anyway, so the radius shrinks with the view rather
## than being a fixed ring.
func _deco_visible(key: Vector2i) -> bool:
	if _zoom > MODEL_DETAIL_MAX_SIZE:
		return false
	var centre := Vector2((key.x + 0.5) * CHUNK, (key.y + 0.5) * CHUNK)
	return centre.distance_to(Vector2(_focus.x, _focus.z)) <= DECO_RADIUS + CHUNK


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

	# cover lives under its own node so the whole lot can be hidden by
	# distance without touching the ground mesh (see DECO_RADIUS)
	var deco := Node3D.new()
	root.add_child(deco)
	var placements := DecoScatter.placements_region(World, x0, y0, x1, y1)
	for prop: String in placements:
		for node: MultiMeshInstance3D in DecoScatter.build_multimeshes(
				prop, placements[prop]):
			deco.add_child(node)
	deco.visible = _deco_visible(key)

	_chunks[key] = {"root": root, "deco": deco, "plants": {}, "corridors": {},
		"corridor_keys": {}, "cities": {}}
	_populate_chunk(key)


## Free NOW, not at end of frame. `queue_free()` defers, while
## `_drain_pending` builds synchronously in the same frame — so every jump
## allocated a screenful of meshes while the evicted ones were still alive.
## Repeat that a few times from the jump list and Godot's RID allocator hits
## its element limit, `_mesh_from` starts returning null and the renderer
## dies ("Element limit reached", then "Parameter mem is null"). Freeing in
## place keeps peak allocation equal to the resident set instead of the
## resident set times the jump rate.
func _free_chunk(key: Vector2i) -> void:
	var chunk: Dictionary = _chunks[key]
	var root := chunk["root"] as Node3D
	_chunk_root.remove_child(root)
	root.free()
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
	if not _models_wanted():
		return  # above the model band the strategic layer is the grid
	if not _chunks.has(key):
		return  # queued for population, evicted before its turn
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
					_collect_rotors(model, tile)
			if World.corridors.has(tile):
				_build_corridor(key, tile)
			var lc_id := World.load_center_at(tile)
			if lc_id != "" and not cities.has(tile):
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
	if World.diag_fillers.has(tile):
		# a diagonal-span corner filler carries no mast — its neighbours
		# draw the conductors cutting across it
		var stale := chunk["corridors"] as Dictionary
		if stale.has(tile):
			(stale[tile] as Node3D).queue_free()
			stale.erase(tile)
			(chunk["corridor_keys"] as Dictionary).erase(tile)
		return
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
func _models_wanted() -> bool:
	return _zoom <= MODEL_DETAIL_MAX_SIZE


## Drop every resident component model (called when the zoom leaves the
## band where individual buildings and pylons are legible — the strategic
## ribbon layer carries the grid above it).
func _drop_models() -> void:
	_populate_queue.clear()
	for key: Vector2i in _chunks:
		var chunk: Dictionary = _chunks[key]
		for group: String in ["cities", "corridors", "plants"]:
			var nodes := chunk[group] as Dictionary
			for k: Variant in nodes.keys():
				(nodes[k] as Node3D).queue_free()
			nodes.clear()
		(chunk["corridor_keys"] as Dictionary).clear()


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
	# Population is QUEUED, never inline, and only for chunks the CURRENT
	# view wants. Crossing the model band after birdview left ~120 resident
	# chunks spanning central Europe, ~95 of them already queued for
	# eviction — populating all of them synchronously built the whole
	# continental grid's pylons, conductors and city blocks in ONE frame
	# (a minutes-long stall, freeze #4) and then threw most of it away.
	# _wanted_chunks() is nearest-first, so visible ground fills in first;
	# evicted or re-dirtied keys fall out harmlessly in the drain.
	_populate_queue.clear()
	for key: Vector2i in _wanted_chunks():
		if _chunks.has(key):
			_populate_queue.append(key)


# ─── site notes (city / plant weekly graphs) ──────────────────────────

## Reconcile the floating notes with the camera: cities inside the view
## get one below NOTE_ZONE_MAX_ZOOM, individual plants join below
## NOTE_PLANT_MAX_ZOOM, nearest-first under a hard cap. Charts refresh
## when the 15-min block advances (ZoneHistory records per block), and a
## note's viewport renders only on refresh — resident notes are free.
func _sync_notes() -> void:
	if not _map_ready:
		return
	var wanted := {}
	var fp := Vector2(_focus.x, _focus.z)
	# cities at every zoom — the tags are how the player orients; a city
	# whose pin was clicked carries its chart instead
	for zone: String in World.load_centers:
		var key := "z:" + zone
		wanted[key] = {"z": zone, "a": _anchor_of(zone),
			"mode": "chart" if _chart_open.has(key) else "tag"}
	if _zoom <= PLANT_TAG_MAX_ZOOM:
		var pscored: Array = []
		for pid: String in World.plants:
			var kind := str(World.plants[pid]["kind"])
			if kind == "h2_cavern":
				continue  # no power trace to graph
			var t: Vector2i = World.plants[pid]["tile"]
			var a := Vector2(t.x + 0.5, t.y + 0.5)
			var d := a.distance_to(fp)
			if d <= _zoom * 1.6 + 6.0:
				pscored.append({"p": pid, "kind": kind, "d": d, "a": a})
		pscored.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
			return float(x["d"]) < float(y["d"]))
		for k in mini(pscored.size(), TAG_PLANT_CAP):
			var e: Dictionary = pscored[k]
			var key := "p:" + str(e["p"])
			e["mode"] = "chart" if _chart_open.has(key) else "tag"
			wanted[key] = e
	var block := int(GameClock.t_sim / Dispatch.BLOCK_S)
	var block_changed := block != _note_block
	_note_block = block
	for key: String in _notes.keys():
		var have: Dictionary = _notes[key]
		if not wanted.has(key) \
				or str((wanted[key] as Dictionary)["mode"]) != str(have["mode"]):
			(have["node"] as Node3D).queue_free()
			_notes.erase(key)
	for key: String in wanted:
		var e: Dictionary = wanted[key]
		var mode := str(e["mode"])
		var fresh := not _notes.has(key)
		if fresh:
			var node := _make_tag(key, e) if mode == "tag" \
				else _make_chart(key, e)
			_notes_root.add_child(node)
			_notes[key] = {"node": node, "mode": mode}
		var n := (_notes[key] as Dictionary)["node"] as Node3D
		var a: Vector2 = e["a"]
		var tile := Vector2i(int(a.x), int(a.y))
		# SAME lift in both modes — the pin is the chart's toggle, and a
		# toggle that jumps when clicked reads as broken (the old
		# three-height stagger applied only in chart mode, so opening a
		# chart hoisted its own pin; player report)
		n.position = Vector3(a.x, ground_y(tile) + 1.0 + _zoom * 0.03, a.y)
		if mode == "tag":
			_scale_tag(n, _zoom)
		else:
			var pin := n.get_node("pin") as Sprite3D
			pin.pixel_size = _zoom * 0.0001
			var note := n.get_node("note") as SiteNote
			note.apply_zoom(_zoom)
			note.position.y = PIN_TEX_H * pin.pixel_size
			if fresh or block_changed:
				note.refresh()


## Location-pin colors: one glance separates a city from a plant.
const PIN_CITY := Color(0.55, 0.82, 1.0)   # ice blue, the HUD accent family
const PIN_PLANT := Color(1.0, 0.66, 0.22)  # amber
const PIN_TEXTURE := preload("res://assets/icons/location_pin.svg")
const PIN_TEX_H := 328.0  # texture height in px (icons/location_pin.svg)


## The far-zoom orientation tag: the openclipart location pin (CC0,
## assets/icons) with its tip on the site, category-tinted, the name
## floating above. Constant screen size via _scale_tag in the sync.
func _make_pin(is_city: bool) -> Sprite3D:
	var pin := Sprite3D.new()
	pin.name = "pin"
	pin.texture = PIN_TEXTURE
	pin.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	pin.no_depth_test = true
	pin.shaded = false
	pin.render_priority = 17
	# centered sprite, shifted half a height up: the TIP marks the site
	pin.offset = Vector2(0, PIN_TEX_H / 2.0)
	pin.modulate = PIN_CITY if is_city else PIN_PLANT
	return pin


## Clicked pin -> its site's chart opens above it (pin stays: click again
## to close). The chart replaces the name label — its title carries it.
func _make_chart(key: String, e: Dictionary) -> Node3D:
	var holder := Node3D.new()
	holder.add_child(_make_pin(key.begins_with("z:")))
	var note: SiteNote
	if key.begins_with("z:"):
		note = SiteNote.for_zone(str(e["z"]))
	else:
		note = SiteNote.for_plant(str(e["p"]), str(e["kind"]))
	note.name = "note"
	holder.add_child(note)
	return holder


## The pins are the chart TOGGLES: hit-test a click against every visible
## pin's screen box (billboards have no collision shapes to pick).
func _pin_hit(mouse: Vector2) -> String:
	for key: String in _notes:
		var node := (_notes[key] as Dictionary)["node"] as Node3D
		if not is_instance_valid(node):
			continue
		var anchor := camera.unproject_position(node.global_position)
		if absf(mouse.x - anchor.x) < 16.0 \
				and mouse.y > anchor.y - 40.0 and mouse.y < anchor.y + 6.0:
			return key
	return ""


func _make_tag(key: String, e: Dictionary) -> Node3D:
	var tag := Node3D.new()
	tag.add_child(_make_pin(key.begins_with("z:")))
	var label := Label3D.new()
	label.name = "tag_name"
	if key.begins_with("z:"):
		var zone := str(e["z"])
		label.text = str((World.load_centers[zone] as Dictionary) \
			.get("name", zone))
		label.modulate = Color(0.96, 0.97, 1.0)
		label.font_size = 64
	else:
		var kind := str(e["kind"])
		label.text = "%s\n%s" % [
			str((World.plants.get(str(e["p"]), {}) as Dictionary) \
				.get("name", e["p"])),
			str(World.KIND_LABELS.get(kind, kind))]
		var group := str(ZoneHistory.GROUP_OF_KIND.get(kind, ""))
		label.modulate = (ZoneChart.GROUP_COLORS.get(group,
			Color(0.9, 0.92, 0.95)) as Color).lightened(0.45)
		label.font_size = 44
	label.outline_size = 16
	label.outline_modulate = Color(0.05, 0.07, 0.10, 0.9)
	# BOTTOM-aligned: the text block GROWS UPWARD from the node origin, so
	# the lift below needs no guess about line count or outline height
	# (the half-height estimate left two-line plant names on the pin)
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 18
	tag.add_child(label)
	return tag


## Constant screen size for a tag: pin ~26 px tall, name floating just
## above its head, both scaled from the ortho zoom every sync.
func _scale_tag(tag: Node3D, zoom: float) -> void:
	var pin := tag.get_node("pin") as Sprite3D
	var label := tag.get_node("tag_name") as Label3D
	pin.pixel_size = zoom * 0.0001
	label.pixel_size = zoom * 0.00034
	# bottom-aligned text: its lowest line starts this gap above the pin
	# head and grows upward — fully clear at any line count
	label.position.y = PIN_TEX_H * pin.pixel_size + 26.0 * label.pixel_size


func _anchor_of(zone: String) -> Vector2:
	if _zone_anchor.has(zone):
		return _zone_anchor[zone]
	var tiles: Array = (World.load_centers[zone] as Dictionary).get("tiles", [])
	var c := Vector2.ZERO
	for t: Vector2i in tiles:
		c += Vector2(t.x + 0.5, t.y + 0.5)
	if tiles.size() > 0:
		c /= tiles.size()
	_zone_anchor[zone] = c
	return c


func redraw() -> void:
	if not _map_ready:
		if World.width == 0:
			return
		_build_backdrop()
		_build_city_lights()
		_map_ready = true
		_focus = Vector3(World.width / 2.0, 0.0, World.height / 2.0)
		_apply_camera()
	# never stream or reconcile inline: see _process
	_stream_dirty = true
	_components_dirty = true
	_strategic_dirty = true


func ground_y(tile: Vector2i) -> float:
	return EuropeTerrain.ground_of(World, tile)


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
		if linked and World.diag_fillers.has(n):
			# the neighbour is a diagonal-span corner filler: the span cuts
			# the corner, so the conductors head for the filler's OTHER
			# neighbour instead — that Vector is the diagonal
			var beyond := _filler_partner(n, tile, kind)
			if beyond != Vector2i.ZERO:
				out.append(beyond)
				continue
		if not linked and kind != "hvdc":
			# AC corridors also dress toward what they serve
			linked = World.plant_at(n) != "" or World.load_center_at(n) != ""
		elif not linked:
			linked = World.plant_at(n) != ""
		if linked:
			out.append(offset)
	return out


## The offset (from `tile`) of the filler's other same-kind neighbour —
## the far end of the diagonal span the filler stands in for.
func _filler_partner(filler: Vector2i, tile: Vector2i, kind: String) -> Vector2i:
	for offset: Vector2i in [Vector2i(0, -1), Vector2i(1, 0),
			Vector2i(0, 1), Vector2i(-1, 0)]:
		var n := filler + offset
		if n != tile and str(World.corridors.get(n, "")) == kind:
			return n - tile
	return Vector2i.ZERO


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
		"corridor_cable": return "cable_400"
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
	# intersect the ground: start on the sea-level plane, then refine
	# against the hit tile's real height — on relief slopes a flat-plane
	# pick can land tiles away (fixed-point converges in 2-3 rounds)
	var h := 0.0
	var tile := Vector2i(-1, -1)
	for _pass in 3:
		var t := (h - origin.y) / direction.y
		var hit := origin + direction * t
		var next := Vector2i(int(floor(hit.x)), int(floor(hit.z)))
		if next == tile:
			break
		tile = next
		h = ground_y(tile) if World.in_bounds(tile) else 0.0
	return tile


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _rotating:
			# yaw only — pitch stays locked: the fog band and the whole
			# streaming/LOD geometry are derived from PITCH_RATIO
			_yaw = fposmod(_yaw - motion.relative.x * ROTATE_DEG_PER_PX, 360.0)
			_yaw_target = _yaw
			_apply_camera()
			return
		if _panning:
			_focus += drag_pan(motion.relative, _yaw, _zoom,
				get_viewport().get_visible_rect().size.y)
			_apply_camera()
			return
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
				if button.pressed:
					var hit := _pin_hit(button.position)
					if hit != "":
						if _chart_open.has(hit):
							_chart_open.erase(hit)
						else:
							_chart_open[hit] = true
						_sync_notes()
						return  # a pin click toggles a chart, never builds
				_dragging = button.pressed
				if button.pressed:
					tile_clicked.emit(mouse_tile())
			MOUSE_BUTTON_RIGHT:
				_rotating = button.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = button.pressed
	elif event is InputEventKey and (event as InputEventKey).pressed:
		# camera only — building is menu-driven (no build hotkeys)
		var step := maxf(2.0, _zoom * 0.08)  # pan scales with the zoom level
		match (event as InputEventKey).keycode:
			# step to the NEXT quarter turn (floor/ceil, not +-90): after a
			# free right-drag rotation the keys return the view to the grid
			KEY_Q: _yaw_target = fposmod(
				floorf(_yaw_target / 90.0) * 90.0 + 90.0, 360.0)
			KEY_E: _yaw_target = fposmod(
				ceilf(_yaw_target / 90.0) * 90.0 - 90.0, 360.0)
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
