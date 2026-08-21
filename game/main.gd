extends Node2D
## Entry scene: normal game (map + frequency instrument + HUD + supervised
## sidecar) plus the headless acceptance smokes. The smoke CLI is frozen
## (family rule): --smoke=<name>, ONE machine-readable JSON line, exit 0/1.

const SMOKES := {
	"boot_and_day": "res://smokes/boot_and_day.gd",
	"trip_reaction": "res://smokes/trip_reaction.gd",
	"sidecar_crash": "res://smokes/sidecar_crash.gd",
	"trip_key": "res://smokes/trip_key.gd",
	"build_and_supply": "res://smokes/build_and_supply.gd",
	"island_cut": "res://smokes/island_cut.gd",
	"dispatch_day": "res://smokes/dispatch_day.gd",
	"economy": "res://smokes/economy.gd",
	"calm_week": "res://smokes/calm_week.gd",
	"probe": "res://smokes/probe.gd",
	"buildcheck": "res://smokes/buildcheck.gd",
	"hydrogen_chain": "res://smokes/hydrogen_chain.gd",
	"battery_response": "res://smokes/battery_response.gd",
	"hvdc_link": "res://smokes/hvdc_link.gd",
	"north_sea_hub": "res://smokes/north_sea_hub.gd",
	"cascade_low_inertia": "res://smokes/cascade_low_inertia.gd",
	"ride_through": "res://smokes/ride_through.gd",
	"replay_panel": "res://smokes/replay_panel.gd",
	"author_start": "res://smokes/author_start.gd",
	"campaign_take_the_reins": "res://smokes/campaign_take_the_reins.gd",
	"save_load_replay": "res://smokes/save_load_replay.gd",
	"model_gallery": "res://smokes/model_gallery.gd",
	"soak": "res://smokes/soak.gd",
	"scenarios": "res://smokes/scenarios.gd",
	"ui_boot": "res://smokes/ui_boot.gd",
}

## ONE port per backend-driving smoke (previously six inline assignments plus
## four smokes silently sharing 8034 — two runs on one port make the loser
## adopt the winner's backend and report someone else's grid, CLAUDE.md §8).
## Reserved elsewhere: 8000-8002, 8010-8016, 8020-8029 (family), 8030 game,
## 8031 acceptance set (sequential by design), 8032 contract tests, 8033
## freeze smoke. RTTF_PORT_OFFSET still composes on top for parallel sweeps.
const SMOKE_PORTS := {
	"hydrogen_chain": 8034,
	"battery_response": 8035,
	"hvdc_link": 8036,
	"north_sea_hub": 8037,
	"ride_through": 8038,
	"cascade_low_inertia": 8039,
	"replay_panel": 8040,
	"save_load_replay": 8041,
	"campaign_take_the_reins": 8042,
	"soak": 8043,
}


var _screenshot_path := ""


func _ready() -> void:
	var smoke := ""
	var campaign := false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--smoke="):
			smoke = arg.trim_prefix("--smoke=")
		elif arg == "--campaign":
			campaign = true
		elif arg.begins_with("--screenshot="):
			_screenshot_path = arg.trim_prefix("--screenshot=")
	if SMOKES.has(smoke):
		_run_smoke(smoke)
	elif _screenshot_path != "":
		_take_screenshot()
	else:
		_boot_game(campaign)


## Look probe (the sibling's --screenshot pattern): builds the demo grid on
## the real map, renders one frame and saves it. No sidecar, no stepping —
## this exists so the LOOK can be reviewed without a human at the keyboard.
func _take_screenshot() -> void:
	if not BuildSession.load_map():
		push_error("map load failed")
		get_tree().quit(1)
		return
	GridcoBoot.setup_models()
	var view := WorldView3D.new()
	add_child(view)
	var hud := preload("res://views/hud.gd").new()
	hud.view = view
	add_child(hud)
	if OS.get_environment("SHOT_GRID") != "":
		# a realistic seed grid instead of the demo build: SHOT_GRID=germany
		# (standalone), =europe (the plan alone), =start (full campaign world)
		if OS.get_environment("SHOT_GRID") == "start":
			print("GRIDPLAN start world: ", GridPlan.author_start(World))
		else:
			var seed_path := GridPlan.EUROPE_SEED \
				if OS.get_environment("SHOT_GRID") == "europe" else GridPlan.GERMANY_SEED
			print("GRIDPLAN authoring ", seed_path)
			var stats: Dictionary = GridPlan.author(World,
				BuildSession.map_projection(), seed_path)
			print("GRIDPLAN ", JSON.stringify(stats))
		var topo: Dictionary = GridTopology.build(World)
		if OS.get_environment("SHOT_DUMP") != "" and topo.has("native"):
			var f := FileAccess.open(OS.get_environment("SHOT_DUMP"), FileAccess.WRITE)
			f.store_string(JSON.stringify(topo["native"]))
			f.close()
			print("DUMPED native bundle")
		if bool(topo.get("ok", false)):
			var native: Dictionary = topo["native"]
			print("TOPOLOGY buses=%d branches=%d warnings=%d" % [
				(native["grid"]["buses"] as Array).size(),
				(native["lines"]["lines"] as Array).size(),
				(topo.get("warnings", []) as Array).size()])
		else:
			print("TOPOLOGY refused: ", topo.get("error", "?"))
	else:
		DemoBuild.auto_build(World)
		# a few of the P7 buildables so the palette's newer kinds appear
		var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
		for kind: String in ["battery", "electrolyzer", "hvdc_converter"]:
			var site := DemoBuild.find_site(World, kind, anchor, 8)
			if site != Vector2i(-1, -1):
				World.place_plant(kind, site)
	if OS.get_environment("SHOT_TIME") != "":  # hour of day, e.g. "0" = midnight
		GameClock.t_sim = float(OS.get_environment("SHOT_TIME")) * 3600.0
	else:
		GameClock.t_sim = 12.0 * 3600.0  # canon shots are midday
	view.redraw()
	var focus: Vector2i = (World.load_centers["berlin"]["tiles"] as Array)[0]
	if OS.get_environment("SHOT_TILE") != "":  # "x,y" — aim the probe anywhere
		var parts := OS.get_environment("SHOT_TILE").split(",")
		focus = Vector2i(int(parts[0]), int(parts[1]))
	view.focus_tile(focus, float(OS.get_environment("SHOT_ZOOM")) \
		if OS.get_environment("SHOT_ZOOM") != "" else 17.0)
	print("PROBE focus=", focus, " view_focus=", view._focus, " zoom=", view._zoom)
	await get_tree().create_timer(1.5).timeout
	if OS.get_environment("SHOT_ZOOM2") != "":  # birdview->zoom-in repro
		view.focus_tile(focus, float(OS.get_environment("SHOT_ZOOM2")))
		await get_tree().create_timer(
			float(OS.get_environment("SHOT_SETTLE")) \
			if OS.get_environment("SHOT_SETTLE") != "" else 0.3).timeout
		print("PROBE2 chunks=", view._chunks.size(), " pending=",
			view._pending.size(), " strategic_vis=", view._strategic.visible,
			" cam_size=", view.camera.size, " cam_pos=", view.camera.position,
			" zoom=", view._zoom)
		var focus_key := Vector2i(int(view._focus.x) / 32, int(view._focus.z) / 32)
		if view._chunks.has(focus_key):
			var chunk: Dictionary = view._chunks[focus_key]
			var root2 := chunk["root"] as Node3D
			var terrain := root2.get_child(0) as MeshInstance3D
			print("PROBE3 key=", focus_key, " in_tree=", root2.is_inside_tree(),
				" vis=", terrain.visible, " surfaces=",
				terrain.mesh.get_surface_count() if terrain.mesh != null else -1,
				" aabb=", terrain.get_aabb(), " gpos=", terrain.global_position)
		else:
			print("PROBE3 focus chunk NOT RESIDENT: ", focus_key)
	get_viewport().get_texture().get_image().save_png(_screenshot_path)
	print("SCREENSHOT saved to ", _screenshot_path)
	get_tree().quit(0)


func _run_smoke(smoke_name: String) -> void:
	var runner: SmokeBase = (load(SMOKES[smoke_name]) as GDScript).new()
	if runner is P7SmokeBase and SMOKE_PORTS.has(smoke_name):
		(runner as P7SmokeBase).p7_port = SMOKE_PORTS[smoke_name]
	add_child(runner)
	runner.run()


func _boot_game(campaign: bool = false) -> void:
	# P5 build mode: the player builds the grid; stepping starts after the
	# first successful (debounced) build+register in BuildSession.
	if not BuildSession.load_map():
		push_error("map load failed — cannot boot")
		return
	BuildSession.enabled = true
	# GridCo models (P6): seeded deterministically; the catalogs are the
	# single source of truth for every constant.
	GridcoBoot.setup_models()
	BuildSession.use_gridco = true
	var view := WorldView3D.new()
	add_child(view)
	var hud := preload("res://views/hud.gd").new()
	hud.view = view
	add_child(hud)
	_boot_async(campaign)


## Boot the opening world from the ONE authored start state
## (Campaign.START_STATE_PATH — previously duplicated as a second literal
## path here); `--campaign` additionally arms the milestone tracker
## (sandbox — the default — leaves everything open, §5.4). Registration is
## EXPLICIT for both modes: the campaign world used to be registered by a
## debounce side effect racing sidecar startup.
func _restore_start_world(arm_campaign: bool) -> void:
	if World.plants.is_empty() and World.corridors.is_empty():
		var path := AppPaths.root() + "/" + Campaign.START_STATE_PATH
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) \
			if FileAccess.file_exists(path) else null
		if not (parsed is Dictionary and World.restore(parsed)):
			if arm_campaign:
				push_error("campaign start state missing/invalid — sandbox boot")
				arm_campaign = false
			# no authored start state: fall back to the scripted demo build
			# so the map is never empty on first run
			DemoBuild.auto_build(World)
	BuildSession.rebuild_now()
	if arm_campaign:
		Campaign.start_campaign()


func _boot_async(campaign: bool = false) -> void:
	SidecarManager.configure(SidecarManager.GAME_PORT)
	SidecarManager.start_all()
	while not SidecarManager.all_healthy():
		await get_tree().create_timer(0.5).timeout
	# Only NOW build the opening world. Building first meant rebuild_now()
	# called _register_async against a backend that did not exist yet, which
	# then raced the debounce timer's second rebuild — two registrations
	# interleaving while the clock ran. (You inherit a grid, you do not
	# start on empty land — GAME_DESIGN §5.1.)
	BuildSession.enabled = false  # the scripted build must not arm the debounce
	_restore_start_world(campaign)
	await BuildSession.build_status
	BuildSession.enabled = true
	GameClock.speed = 60.0
