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
	"probe6": "res://smokes/probe6.gd",
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
	if campaign:
		_boot_campaign()
	_boot_async()


func _load_start_world() -> void:
	if not World.plants.is_empty() or not World.corridors.is_empty():
		return
	var repo := AppPaths.root()
	var path := repo + "/data/campaign/start_2025.json"
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) \
		if FileAccess.file_exists(path) else null
	if parsed is Dictionary and World.restore(parsed):
		BuildSession.rebuild_now()
		return
	# no authored start state: fall back to the scripted demo build so the
	# map is never empty on first run
	DemoBuild.auto_build(World)
	BuildSession.rebuild_now()


## `--campaign` boots the inherited-2025 world and arms the milestone
## tracker (sandbox — the default — leaves everything open, §5.4).
func _boot_campaign() -> void:
	var repo := AppPaths.root()
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
	# Only NOW build the opening world. Building first meant rebuild_now()
	# called _register_async against a backend that did not exist yet, which
	# then raced the debounce timer's second rebuild — two registrations
	# interleaving while the clock ran. (You inherit a grid, you do not
	# start on empty land — GAME_DESIGN §5.1.)
	BuildSession.enabled = false  # the scripted build must not arm the debounce
	_load_start_world()
	var status: Array = await BuildSession.build_status
	if OS.get_environment("BOOT_TRACE") != "":
		print("TRACE build ok=", status[0], " msg=", status[1],
			" plants=", World.plants.size(), " corridors=", World.corridors.size())
	BuildSession.enabled = true
	if OS.get_environment("BOOT_TRACE") != "":
		var seen := [0]
		Orchestrator.step_completed.connect(
			func(t: int, result: Dictionary) -> void:
				seen[0] += 1
				if seen[0] > 40:
					return
				var isl: Dictionary = result.get("islands", {}).get("0", {})
				if seen[0] == 1:
					var lines: Dictionary = result.get("pf", {}).get("latest", {}).get("lines", {})
					var ranked: Array = lines.keys()
					ranked.sort_custom(func(a: String, b: String) -> bool:
						return float(lines[a].get("loading_percent", 0.0)) \
							> float(lines[b].get("loading_percent", 0.0)))
					for lid: String in ranked.slice(0, 4):
						var spec := {}
						for l: Dictionary in Boundary.docs["lines"]["lines"]:
							if str(l["id"]) == lid:
								spec = l
						print("TRACE line ", lid, " ", spec.get("from_bus"), "->",
							spec.get("to_bus"), " km=", spec.get("length_km"),
							" par=", spec.get("parallel"),
							" load=", lines[lid].get("loading_percent"),
							" p=", lines[lid].get("p_from_mw"))
					for pid: String in result.get("devices", {}):
						var d: Dictionary = result["devices"][pid]
						if float(d.get("p_mw", 0.0) if d.get("p_mw") != null else 0.0) > 700.0:
							print("TRACE big ", pid, " p=", d.get("p_mw"))
				print("TRACE t=", t, " status=", result.get("status"),
					" f=", isl.get("f_hz"), " n_isl=", (result.get("islands", {}) as Dictionary).size(),
					" load=", result.get("pf", {}).get("latest", {}).get("max_loading_pct"),
					" ev=", (result.get("events", []) as Array).map(
						func(e: Dictionary) -> String: return str(e.get("kind")) + ":" + str(e.get("element")))))
	GameClock.speed = 60.0
