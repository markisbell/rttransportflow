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
	var repo := AppPaths.root()
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
## v3 ONLY (5 km Natural Earth grid, ledger 38) — the old v1/v2 fallbacks
## were a trap, not a safety net: campaign saves and every km-radius
## constant assume the 5 km grid, so falling back to a 10× coarser map
## would restore a world with silently wrong geometry instead of failing
## loudly. The archived grids live in tools/map_authoring/archive/.
static func map_path() -> String:
	var europe := AppPaths.root() + "/data/map/europe_v3.json"
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
	# The MAP's projection block is the one truth for tile->lat/lon. Demand
	# kept the europe_v1 numbers as its live default and nothing ever
	# assigned the real block, so on the 10x-finer v3 grid every zone's
	# weather region resolved from garbage coordinates (deterministic — and
	# wrong; Dispatch used the live projection, so the two disagreed). The
	# sixth instance of the ledger-38 resolution trap, as a stale default.
	if _map_doc.has("projection"):
		Demand.projection = _map_doc["projection"]
	if not World.load_map(_map_doc):
		return false
	# Render-only relief sidecar (<map>_relief.json) — optional by design:
	# fixture maps render on the class fallback, and a size mismatch is
	# rejected inside load_relief rather than rendering garbage.
	var relief_path := map_path().trim_suffix(".json") + "_relief.json"
	if FileAccess.file_exists(relief_path):
		var relief: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(relief_path))
		if relief is Dictionary and not World.load_relief(relief):
			push_warning("BuildSession: relief sidecar rejected: " + relief_path)
	return true


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
	# EVERY failure below must RESTART the orchestrator: the previous
	# registration is still live backend-side, so play continues on the
	# old grid exactly as it does when GridTopology refuses a build. A
	# bare return after stop() froze the clock FOREVER with a healthy
	# backend and zero errors — three player-reported freezes, finally
	# named by the heartbeat (its trail ends the moment the timer stops).
	var deadline := Time.get_ticks_msec() + 120_000
	while not SidecarManager.all_healthy():
		if Time.get_ticks_msec() > deadline:
			print("REGISTER FAILED: backend not healthy — resuming old grid")
			Orchestrator.start()
			_emit_status(false, "backend not healthy", built["warnings"])
			return
		await get_tree().create_timer(0.5).timeout
	if not CosimBridge.info.has(Orchestrator.ID) \
			and not await CosimBridge.handshake(Orchestrator.ID):
		print("REGISTER FAILED: handshake — resuming old grid")
		Orchestrator.start()
		_emit_status(false, "contract handshake failed", built["warnings"])
		return
	if not await Orchestrator.register(Boundary.reset_doc()):
		print("REGISTER FAILED: backend rejected the build — resuming old grid")
		Orchestrator.start()
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
