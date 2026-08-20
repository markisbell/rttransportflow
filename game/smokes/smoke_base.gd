class_name SmokeBase
extends Node
## Shared plumbing for the acceptance smokes (family pattern). Each smoke
## lives in res://smokes/<name>.gd as `func run()` over this base; main.gd
## only dispatches. Smokes print ONE machine-readable JSON line and quit
## 0/1 — that CLI contract is frozen (CI + wrappers grep it).

const SMOKE_PORT := 8031

var _checks := {}
var _step_faults := 0


func run() -> void:
	push_error("SmokeBase.run() not overridden")
	get_tree().quit(1)


## Boot the sidecar on `port`, wait healthy, load the bundle, handshake,
## register europe_mini. Returns false (after _fail) on any failure.
func _boot_and_register(tag: String, port: int = SMOKE_PORT) -> bool:
	SidecarManager.configure(port)
	SidecarManager.start_all()
	if not await _wait_healthy(120.0):
		_fail(tag, "health timeout")
		return false
	if not Boundary.load_bundle():
		_fail(tag, "bundle load failed")
		return false
	if not await CosimBridge.handshake(Orchestrator.ID):
		_fail(tag, "handshake failed")
		return false
	if not await Orchestrator.register(Boundary.reset_doc()):
		_fail(tag, "register failed")
		return false
	return true


## Boot the full GridCo stack on `port`: sidecar, map, seeded models,
## handshake. The ONE boot path — it was copy-pasted across two bases, three
## smokes and main.gd, so a boot-ordering fix had to be replicated everywhere.
## Order is load-bearing: map before the model setup, handshake last.
func gridco_boot(tag: String, port: int = SMOKE_PORT) -> bool:
	SidecarManager.configure(port)
	SidecarManager.start_all()
	if not await _wait_healthy(120.0):
		_fail(tag, "health timeout")
		return false
	if not BuildSession.load_map():
		_fail(tag, "map load failed")
		return false
	GridcoBoot.setup_models()
	BuildSession.use_gridco = true
	if not await CosimBridge.handshake(Orchestrator.ID):
		_fail(tag, "handshake failed")
		return false
	return true


func _wait_healthy(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not SidecarManager.all_healthy():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _wait_state(state: SidecarManager.State, timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while SidecarManager.state_of(Orchestrator.ID) != state:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.25).timeout
	return true


## Step and SAY SO when the backend refuses. Smokes that `continue` past a
## non-200 turn a dead backend into a silently wrong assertion (hydrogen_chain
## skipped 140 blocks and reported "cavern never filled").
func step_checked(dt_s: float, tag: String = "") -> Dictionary:
	var result: Dictionary = await Orchestrator.step_once(dt_s)
	var status := int(result.get("_status", 0))
	if status != 200 and _step_faults < 6:
		_step_faults += 1
		print("SMOKESTEP ", tag, " status=", status, " error=",
			result.get("_error", result.get("error", "?")),
			" body=", JSON.stringify(result).substr(0, 300))
	return result


## The long-step + 1 s-chase measurement pattern shared by the trip smokes:
## one `pre_dt_s` step (the event usually fires inside it via
## Orchestrator.inject), then `chase_steps` × 1 s follow-ups, then an
## optional `tail_dt_s` step. Folds f_min / |rocof|_max / events over every
## 200-OK result and hands each result to `on_result` for smoke-specific
## sampling. Injects nothing itself; per-smoke step counts stay parameters
## (30/40/45 differ deliberately across the suite).
func chase_event(pre_dt_s: float, chase_steps: int, tag: String = "",
		on_result: Callable = Callable(), tail_dt_s: float = 0.0) -> Dictionary:
	var out := {"f_min": 100.0, "rocof_max": 0.0, "events": [], "tail": {}}
	var dts: Array[float] = [pre_dt_s]
	for _i in range(chase_steps):
		dts.append(1.0)
	if tail_dt_s > 0.0:
		dts.append(tail_dt_s)
	for dt: float in dts:
		var result: Dictionary = await step_checked(dt, tag)
		if int(result.get("_status", 0)) != 200:
			continue
		out["tail"] = result
		for island_id: String in result.get("islands", {}):
			var island: Dictionary = result["islands"][island_id]
			out["f_min"] = minf(float(out["f_min"]), numf(island, "f_min", 100.0))
			out["rocof_max"] = maxf(float(out["rocof_max"]),
				absf(numf(island, "rocof_max", 0.0)))
		(out["events"] as Array).append_array(result.get("events", []))
		if on_result.is_valid():
			on_result.call(result)
	return out


## Online synchronous units, largest-first (`headroom_mw` is the wire's sync
## marker — converters don't carry it), ties broken by pid for determinism.
## The ONE victim-selection rule (it existed in three drifted copies; the
## unguarded variant would have picked a wind farm in a changed fixture).
func online_sync_ranked(devices: Dictionary) -> Array:
	return FleetQuery.online_sync_ranked(devices)


## Foreign-footprint avoid set (the P5 lesson: corridors that brush another
## city's tiles connect its load with zero generation).
func foreign_avoid(keep_ids: Array[String]) -> Dictionary:
	var avoid := {}
	for lc_id: String in World.load_centers:
		if lc_id in keep_ids:
			continue
		for tile: Vector2i in World.load_centers[lc_id]["tiles"]:
			avoid[tile] = true
			for offset: Vector2i in GridTopology.NEIGHBORS:
				avoid[tile + offset] = true
	return avoid


## Place `count` plants of `kind` around `anchor`, each spurred into the AC
## network at `lc_tap`. Returns the pids that are actually CONNECTED.
## Sites AND taps honor `avoid` — a tap inside a foreign city's ring quietly
## connected Copenhagen to the Hamburg island and doubled its load (found by
## battery_response: 2.2 GW instant deficit, fleet-wide f-window trip at 1.2 s).
##
## Connect-or-remove (auto_build's rule, ledger 29): a plant whose spur does
## not route is an ORPHAN — the topology builder drops it with a warning and
## the smoke still counted it as built. On the 5 km grid that silently
## deleted whole fleets (ride_through registered 10 wind farms and got an
## island with none). Failed sites are banned so the ring search moves on
## instead of re-offering the same doomed tile.
func place_ring(kind: String, count: int, anchor: Vector2i, lc_tap: Vector2i,
		avoid: Dictionary = {}) -> Array[String]:
	var pids: Array[String] = []
	var banned := avoid.duplicate()
	# 300 km, not 200: on a crowded ring the later units of a big fleet fight
	# for tiles whose spur cannot route, and every failed route is a BFS that
	# floods the entire 772 000-tile map. Open ground is cheaper than a
	# retry. The attempt budget is tight for the same reason — a fleet that
	# cannot be placed must fail the smoke in seconds, not wedge it for
	# twenty minutes (fleet A of cascade_low_inertia did exactly that).
	var search := DemoBuild.tiles_for_km(300.0, World)
	var attempts := 0
	var budget := count + 6
	while pids.size() < count and attempts < budget:
		attempts += 1
		var site := DemoBuild.find_site(World, kind, anchor, search, banned)
		if site == Vector2i(-1, -1):
			break
		var pid: String = World.place_plant(kind, site)
		if pid == "":
			banned[site] = true
			continue
		var tap := tap_avoiding([site], avoid)
		var path: Array[Vector2i] = []
		if tap != Vector2i(-1, -1):
			path = DemoBuild.route(World, tap, lc_tap, true, avoid)
		if path.is_empty():
			World.remove_plant(pid)
			banned[site] = true
			continue
		for tile: Vector2i in path:
			World.place_corridor(tile)
		pids.append(pid)
	return pids


## tap_for, but never inside the avoid set (route() only filters EXPANSION
## tiles — the start tile bypasses it).
func tap_avoiding(tiles: Array, avoid: Dictionary) -> Vector2i:
	for tile: Vector2i in tiles:
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var n: Vector2i = tile + offset
			if not avoid.has(n) and World.can_place_corridor(n) \
					and World.plant_at(n) == "" and World.load_center_at(n) == "":
				return n
	return Vector2i(-1, -1)


## Nameplate MW of a pid list — smokes size fleets against a city's peak
## instead of against a magic unit count (4 GW Hamburg + 7x800 MW coal ran
## the island 1 GW over its own minimum load and parked it at 50.5 Hz).
func fleet_mw(pids: Array) -> float:
	var total := 0.0
	for pid: String in pids:
		total += float((World.plants.get(pid, {}) as Dictionary).get("p_max_mw", 0.0))
	return total


## Units of `kind` needed to cover `mw`.
func units_for(kind: String, mw: float) -> int:
	return maxi(1, int(ceil(mw / maxf(float(World.PLANT_SIZES[kind]), 1.0))))


func _fail(tag: String, reason: String) -> void:
	print(tag, " ", JSON.stringify({"ok": false, "reason": reason,
		"failed": failed_checks()}))
	SidecarManager.stop_all()
	get_tree().quit(1)


func _finish(tag: String, extra: Dictionary = {}) -> void:
	var payload := {"ok": verdict(), "checks": _checks}
	payload.merge(extra)
	print(tag, " ", JSON.stringify(payload))
	SidecarManager.stop_all()
	get_tree().quit(0 if verdict() else 1)


## Named per-assertion reporting (family pattern): failures become
## attributable from the JSON line alone.
func check(check_name: String, passed: bool) -> bool:
	_checks[check_name] = passed
	return passed


func failed_checks() -> Array:
	var failed: Array = []
	for check_name: String in _checks:
		if not _checks[check_name]:
			failed.append(check_name)
	return failed


func verdict() -> bool:
	return failed_checks().is_empty()


## Null-tolerant numeric getter — delegates to the ONE production home
## (model/wire.gd); kept here so no smoke file needs touching.
static func numf(data: Dictionary, key: String, default: float) -> float:
	return Wire.numf(data, key, default)
