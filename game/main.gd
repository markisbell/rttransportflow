extends Node2D
## Entry scene: normal game (map + frequency instrument + HUD + supervised
## sidecar) plus the headless acceptance smokes. The smoke CLI is frozen
## (family rule): --smoke=<name>, ONE machine-readable JSON line, exit 0/1.

const SMOKES := {
	"boot_and_day": "res://smokes/boot_and_day.gd",
	"trip_reaction": "res://smokes/trip_reaction.gd",
	"sidecar_crash": "res://smokes/sidecar_crash.gd",
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
	var map := preload("res://views/map_view.gd").new()
	add_child(map)
	var hud := preload("res://views/hud.gd").new()
	add_child(hud)
	_boot_async()


func _boot_async() -> void:
	SidecarManager.configure(SidecarManager.GAME_PORT)
	SidecarManager.start_all()
	while not SidecarManager.all_healthy():
		await get_tree().create_timer(0.5).timeout
	if not Boundary.load_bundle():
		push_error("europe_mini bundle missing — cannot boot")
		return
	if not await CosimBridge.handshake(Orchestrator.ID):
		push_error("handshake failed — backend contract mismatch")
		return
	if not await Orchestrator.register(Boundary.reset_doc()):
		return
	GameClock.speed = 60.0
	Orchestrator.start()
