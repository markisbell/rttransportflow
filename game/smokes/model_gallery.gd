extends SmokeBase
## --smoke=model_gallery: renders every PlantModels component on a labelled
## grid and saves a PNG (--shot=<path>). No backend, no sidecar — this is
## the LOOK harness: the model library is only "done" when the picture
## reads at a glance, so the gallery is how it gets reviewed.

const TAG := "SMOKE_MODEL_GALLERY"
const DEFAULT_SHOT := "user://gallery.png"  # override with --shot=<path>

## Grid order: thermal row, renewable row, storage/H2 row, grid/HVDC row —
## neighbours in a row are the ones a player compares.
const ROWS: Array = [
	["nuclear", "coal", "lignite", "gas_ccgt", "gas_ocgt"],
	["hydro_ps", "wind_onshore", "wind_offshore", "solar_pv", "battery"],
	["electrolyzer", "h2_cavern", "hvdc_converter", "offshore_platform", "substation"],
	["line_400", "line_220", "hvdc", "load_center_small", "load_center_large"],
]
const SPACING := 1.5


func run() -> void:
	var shot := DEFAULT_SHOT
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.trim_prefix("--shot=")

	var root := Node3D.new()
	get_tree().root.add_child(root)
	_build_environment(root)

	var cols := (ROWS[0] as Array).size()
	for r in ROWS.size():
		var row: Array = ROWS[r]
		for c in row.size():
			var kind: String = row[c]
			var spot := Vector3((c - (cols - 1) / 2.0) * SPACING, 0,
				(r - (ROWS.size() - 1) / 2.0) * SPACING)
			root.add_child(_ground_tile(spot))
			var model := _model_for(kind)
			if model == null:
				continue
			model.position = spot
			root.add_child(model)
			root.add_child(_label(kind, spot))

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 8.6
	# the game's isometric angle: 45 deg yaw, ~35 deg pitch
	cam.position = Vector3(6.0, 6.5, 6.0)
	cam.look_at(Vector3(0, 0.3, 0), Vector3.UP)
	root.add_child(cam)
	cam.make_current()

	# let the renderer settle (shadows + sky need a couple of frames)
	for _i in 6:
		await RenderingServer.frame_post_draw
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(shot)
	print("GALLERY saved to ", shot)
	check("rendered", FileAccess.file_exists(shot))
	_finish(TAG, {"shot": shot, "models": ROWS.size() * cols})


func _model_for(kind: String) -> Node3D:
	if kind.begins_with("load_center_"):
		return PlantModels.load_center(kind.trim_prefix("load_center_"), 2)
	if kind in ["line_400", "line_220", "hvdc"]:
		var neighbors: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0),
			Vector2i(0, 1)]
		return PlantModels.corridor(kind, neighbors)
	return PlantModels.make(kind)


## Each model stands on its own tile so the 1.0-unit footprint is visible.
func _ground_tile(spot: Vector3) -> MeshInstance3D:
	var tile := PlantModels.box(Vector3(1.0, 0.02, 1.0),
		Color(0.42, 0.52, 0.32), spot + Vector3(0, -0.01, 0))
	return tile


func _label(text: String, spot: Vector3) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = 48
	label.pixel_size = 0.0022
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1, 1, 1)
	label.outline_size = 14
	label.outline_modulate = Color(0.05, 0.06, 0.08)
	label.position = spot + Vector3(0, 0.02, 0.62)
	label.no_depth_test = true
	return label


## The infrastruct environment recipe: warm sun with soft shadows, sky
## ambient, SSAO and filmic tonemapping — the models must be reviewed under
## the lighting they will actually ship in.
func _build_environment(root: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -32, 0)
	sun.shadow_enabled = true
	sun.light_color = Color(1.0, 0.965, 0.89)
	sun.light_energy = 1.5
	sun.shadow_blur = 0.75
	sun.shadow_normal_bias = 2.5
	root.add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.33, 0.52, 0.78)
	sky_material.sky_horizon_color = Color(0.74, 0.82, 0.88)
	sky_material.ground_bottom_color = Color(0.32, 0.38, 0.3)
	sky_material.ground_horizon_color = Color(0.68, 0.72, 0.72)
	var sky := Sky.new()
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.ssao_enabled = true
	env.ssao_intensity = 1.4
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)
