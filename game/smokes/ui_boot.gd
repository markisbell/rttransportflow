extends SmokeBase
## --smoke=ui_boot: construct the HUD and its panels headlessly.
##
## Every other smoke drives the MODEL; none of them ever builds the HUD, so
## a runtime error in a panel's `_ready()` reached the player and nobody
## else. That is not hypothetical — the sandbox console was added with a
## `class_name` reference that a freshly imported project cannot resolve,
## and only a game boot would have caught it.
##
## No backend and no rendering: Godot's headless server still creates
## Control nodes, so this exercises construction, signal wiring and the
## panels' first `_process`/`_ready` pass, which is where the crashes live.

const TAG := "SMOKE_UI_BOOT"


func run() -> void:
	if not BuildSession.load_map():
		_fail(TAG, "map load failed")
		return
	GridcoBoot.setup_models()

	var hud: CanvasLayer = (load("res://views/hud.gd") as GDScript).new()
	add_child(hud)
	check("hud_built", hud.get_child_count() > 0)
	# let deferred setup and one frame of _process run
	await get_tree().process_frame
	await get_tree().process_frame

	# the panels the HUD owns, by script rather than by class_name (the
	# global class cache is exactly what a fresh import has not built yet)
	var wanted := {
		"res://views/sandbox_panel.gd": false,
		"res://views/build_menu.gd": false,
		"res://views/nav_panel.gd": false,
		"res://views/frequency_cluster.gd": false,
		"res://views/replay_panel.gd": false,
	}
	for child: Node in hud.get_children():
		var script: Script = child.get_script()
		if script != null and wanted.has(script.resource_path):
			wanted[script.resource_path] = true
	for path: String in wanted:
		check(path.get_file().get_basename(), bool(wanted[path]))

	# the classroom console must be INVISIBLE outside sandbox mode (§5.4) —
	# a campaign that offers "trip the largest unit" is not a campaign
	var sandbox_panel: Control = null
	for child: Node in hud.get_children():
		var script: Script = child.get_script()
		if script != null and script.resource_path == "res://views/sandbox_panel.gd":
			sandbox_panel = child as Control
	check("sandbox_hidden_by_default",
		sandbox_panel != null and not sandbox_panel.visible)
	Sandbox.start("normal")
	Sandbox.set_difficulty("demanding")  # emits knobs_changed -> _refresh()
	await get_tree().process_frame
	check("sandbox_shows_in_sandbox_mode",
		sandbox_panel != null and sandbox_panel.visible)
	check("difficulty_applied", is_equal_approx(Sandbox.knob("capex"), 1.15))
	_finish(TAG, {"hud_children": hud.get_child_count()})
