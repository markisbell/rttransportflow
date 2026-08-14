extends Node
## BuildSession — the debounced edit→rebuild→reset pipeline (family rule:
## topology resets MUST be debounced; reset storms froze infrastruct
## playtests). Any WorldModel edit arms a 2.5 s idle timer; on expiry the
## topology builder runs and, when it succeeds, the backend is re-registered
## and stepping (re)starts. The wire `t` sequence continues across resets —
## that is contract-legal.

signal build_status(ok: bool, message: String, warnings: Array)

const DEBOUNCE_S := 2.5

## The debounce pipeline only runs when armed (interactive boot arms it;
## smokes/tests drive rebuild_now() explicitly so edits never spawn
## background registration attempts mid-test).
var enabled := false
## After registration, drive boundaries from the live GridCo models
## (Weather/Demand/Dispatch) instead of profile replay. The interactive boot
## turns this on once the models are seeded; profile-based smokes leave it off.
var use_gridco := false
var last_build: Dictionary = {}
var registered := false
var _timer: Timer
var _map_doc: Dictionary = {}


static func load_repo_json(rel_path: String) -> Dictionary:
	var repo := ProjectSettings.globalize_path("res://").rstrip("/").get_base_dir()
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(repo + "/" + rel_path))
	return parsed if parsed is Dictionary else {}


func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = DEBOUNCE_S
	_timer.timeout.connect(_rebuild)
	add_child(_timer)
	World.world_changed.connect(_on_world_changed)


## Map file: the real Europe map when present, the test fixture otherwise.
static func map_path() -> String:
	var repo := ProjectSettings.globalize_path("res://").rstrip("/").get_base_dir()
	# v3 is the 5 km Natural Earth grid (ledger 38); the coarser grids stay
	# as fallbacks so an older checkout still boots
	for name: String in ["europe_v3.json", "europe_v2.json", "europe_v1.json"]:
		var europe := repo + "/data/map/" + name
		if FileAccess.file_exists(europe):
			return europe
	return ProjectSettings.globalize_path("res://testdata/mini_map.json")


func map_projection() -> Dictionary:
	return _map_doc.get("projection", {})


func load_map() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(map_path()))
	if not (parsed is Dictionary):
		push_error("BuildSession: cannot parse map " + map_path())
		return false
	_map_doc = parsed
	return World.load_map(_map_doc)


func _on_world_changed() -> void:
	if not enabled:
		return
	_timer.stop()
	_timer.start()  # debounce: only 2.5 s of idle triggers the rebuild


## Force an immediate rebuild (smokes; the B demo key).
func rebuild_now() -> void:
	_timer.stop()
	_rebuild()


func _emit_status(ok: bool, message: String, warnings: Array) -> void:
	# ALWAYS deferred: callers do `rebuild_now(); await build_status` — a
	# synchronous emission on the fail path fires before the await exists
	# and deadlocks the caller (found by the europe-map smoke).
	(func() -> void: build_status.emit(ok, message, warnings)).call_deferred()


func _rebuild() -> void:
	var sampler := Callable()
	if use_gridco:
		var day0 := floorf(GameClock.t_sim / 86400.0)
		sampler = func(lc_id: String, step: int) -> float:
			return Demand.zone_mw_forecast(lc_id, day0 + step / 96.0)
	var built := GridTopology.build(World, sampler)
	last_build = built
	if not built["ok"]:
		_emit_status(false, str(built["error"]), built["warnings"])
		return
	Boundary.set_native(built["native"], built.get("devices", []),
		built.get("hub_farms", {}))
	_register_async(built)


func _register_async(built: Dictionary) -> void:
	Orchestrator.stop()
	var deadline := Time.get_ticks_msec() + 120_000
	while not SidecarManager.all_healthy():
		if Time.get_ticks_msec() > deadline:
			_emit_status(false, "backend not healthy", built["warnings"])
			return
		await get_tree().create_timer(0.5).timeout
	if not CosimBridge.info.has(Orchestrator.ID) \
			and not await CosimBridge.handshake(Orchestrator.ID):
		_emit_status(false, "contract handshake failed", built["warnings"])
		return
	if not await Orchestrator.register(Boundary.reset_doc()):
		_emit_status(false, "backend rejected the build", built["warnings"])
		return
	registered = true
	if use_gridco:
		Boundary.enable_gridco()
	Orchestrator.start()
	_emit_status(true, "%d buses, %d lines, %d zones" % [
		built["interpretation"]["n_buses"],
		(built["native"]["lines"]["lines"] as Array).size(),
		(built["zones"] as Array).size(),
	], built["warnings"])
