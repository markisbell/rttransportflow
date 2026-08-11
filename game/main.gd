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
}


func _ready() -> void:
	var smoke := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--smoke="):
			smoke = arg.trim_prefix("--smoke=")
	if SMOKES.has(smoke):
		_run_smoke(smoke)
	else:
		_boot_game()


func _run_smoke(smoke_name: String) -> void:
	var runner: SmokeBase = (load(SMOKES[smoke_name]) as GDScript).new()
	add_child(runner)
	runner.run()


func _boot_game() -> void:
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
	var view := preload("res://views/build_view.gd").new()
	add_child(view)
	var hud := preload("res://views/hud.gd").new()
	add_child(hud)
	_boot_async()


func _boot_async() -> void:
	SidecarManager.configure(SidecarManager.GAME_PORT)
	SidecarManager.start_all()
	while not SidecarManager.all_healthy():
		await get_tree().create_timer(0.5).timeout
	GameClock.speed = 60.0
