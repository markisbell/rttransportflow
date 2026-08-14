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
	"calm_probe": "res://smokes/calm_probe.gd",
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
	"start_check": "res://smokes/start_check.gd",
	"model_gallery": "res://smokes/model_gallery.gd",
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
	Weather.setup(42)
	Demand.setup(42)
	Demand.weather = Weather
	Dispatch.setup(BuildSession.load_repo_json("data/catalogs/economy.json"),
		BuildSession.load_repo_json("data/catalogs/plant_types.json").get("kinds", {}))
	Economy.setup(BuildSession.load_repo_json("data/catalogs/economy.json"))
	var view := WorldView3D.new()
	add_child(view)
	var hud := preload("res://views/hud.gd").new()
	hud.view = view
	add_child(hud)
	DemoBuild.auto_build(World)
	# a few of the P7 buildables so the palette's newer kinds appear on the map
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	for kind: String in ["battery", "electrolyzer", "hvdc_converter"]:
		var site := DemoBuild.find_site(World, kind, anchor, 8)
		if site != Vector2i(-1, -1):
			World.place_plant(kind, site)
	view.redraw()
	var focus: Vector2i = (World.load_centers["berlin"]["tiles"] as Array)[0]
	view.focus_tile(focus, float(OS.get_environment("SHOT_ZOOM")) \
		if OS.get_environment("SHOT_ZOOM") != "" else 17.0)
	await get_tree().create_timer(1.5).timeout
	get_viewport().get_texture().get_image().save_png(_screenshot_path)
	print("SCREENSHOT saved to ", _screenshot_path)
	get_tree().quit(0)


func _run_smoke(smoke_name: String) -> void:
	var runner: SmokeBase = (load(SMOKES[smoke_name]) as GDScript).new()
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
	Weather.setup(42)
	Demand.setup(42)
	Demand.weather = Weather
	Dispatch.setup(BuildSession.load_repo_json("data/catalogs/economy.json"),
		BuildSession.load_repo_json("data/catalogs/plant_types.json").get("kinds", {}))
	Economy.setup(BuildSession.load_repo_json("data/catalogs/economy.json"))
	BuildSession.use_gridco = true
	var view := WorldView3D.new()
	add_child(view)
	var hud := preload("res://views/hud.gd").new()
	hud.view = view
	add_child(hud)
	if campaign:
		_boot_campaign()
	_boot_async()


## `--campaign` boots the inherited-2025 world and arms the milestone
## tracker (sandbox — the default — leaves everything open, §5.4).
func _boot_campaign() -> void:
	var repo := ProjectSettings.globalize_path("res://").rstrip("/").get_base_dir()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		repo + "/" + Campaign.START_STATE_PATH))
	if parsed is Dictionary and World.restore(parsed):
		Campaign.start_campaign()
	else:
		push_error("campaign start state missing/invalid — sandbox boot")


func _boot_async() -> void:
	SidecarManager.configure(SidecarManager.GAME_PORT)
	SidecarManager.start_all()
	while not SidecarManager.all_healthy():
		await get_tree().create_timer(0.5).timeout
	GameClock.speed = 60.0
