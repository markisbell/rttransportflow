class_name P7SmokeBase
extends SmokeBase
## Shared plumbing for the P7 flexibility smokes (hydrogen_chain,
## battery_response, hvdc_link, north_sea_hub). These boot the GridCo stack
## exactly like dispatch_day but on their OWN sidecar port (8034) so they can
## run beside the 8031 acceptance set without adopting a stale backend.

const P7_PORT := 8034

## Each P7 smoke owns a port so the set can run CONCURRENTLY without
## adopting each other's backend (they take minutes apiece on the 5 km map).
## Stays clear of the reserved family ranges (8000-8002, 8010-8016,
## 8020-8029) and of 8030-8032 (game / acceptance smokes / contract tests).
var p7_port := P7_PORT


func p7_boot(tag: String) -> bool:
	SidecarManager.configure(p7_port)
	SidecarManager.start_all()
	if not await _wait_healthy(120.0):
		_fail(tag, "health timeout")
		return false
	if not BuildSession.load_map():
		_fail(tag, "map load failed")
		return false
	Weather.setup(42)
	Demand.setup(42)
	Demand.weather = Weather
	Dispatch.setup(BuildSession.load_repo_json("data/catalogs/economy.json"),
		BuildSession.load_repo_json("data/catalogs/plant_types.json").get("kinds", {}))
	Economy.setup(BuildSession.load_repo_json("data/catalogs/economy.json"))
	BuildSession.use_gridco = true
	if not await CosimBridge.handshake(Orchestrator.ID):
		_fail(tag, "handshake failed")
		return false
	return true


## Rebuild the current WorldModel and register it; returns last_build
## ({} after _fail). Callers step manually — the orchestrator stays stopped.
func p7_register(tag: String) -> Dictionary:
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	if not bool(status[0]):
		_fail(tag, "build failed: %s" % str(status[1]))
		return {}
	Orchestrator.stop()
	return BuildSession.last_build


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


## Step and SAY SO when the backend refuses. Smokes that `continue` past a
## non-200 turn a dead backend into a silently wrong assertion (hydrogen_chain
## skipped 140 blocks and reported "cavern never filled").
func p7_step(dt_s: float, tag: String = "") -> Dictionary:
	var result: Dictionary = await Orchestrator.step_once(dt_s)
	var status := int(result.get("_status", 0))
	if status != 200 and _step_faults < 6:
		_step_faults += 1
		print("P7STEP ", tag, " status=", status, " error=",
			result.get("_error", result.get("error", "?")),
			" body=", JSON.stringify(result).substr(0, 300))
	return result


var _step_faults := 0

## Step ONE 15-min dispatch block as three 300 s slices.
##
## The dispatcher ramps a new schedule in over Dispatch.RAMP_S (300 s) and the
## blend is sampled at the step's START time — so a single dt = 900 s step
## always samples progress 0 and commands the PREVIOUS block's schedule for
## the whole block. On a declining night curve that leaves the island a few
## hundred MW long: it parks around 50.3 Hz, aFRR saturates, and a trip test
## on top of it measures nothing (battery_response reported a "nadir" of
## 50.27 Hz). Slicing lets the ramp actually run, which is also what the game
## does — it steps at 0.1-6 s, never a block at a time.
func p7_block(tag: String = "") -> Dictionary:
	var result: Dictionary = {}
	for _i in range(3):
		result = await p7_step(300.0, tag)
	return result


## One-line inventory of what actually reached the backend: placed vs
## registered plants per kind, plus every build warning.
func p7_report(registered: Dictionary) -> void:
	var placed := {}
	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		placed[kind] = int(placed.get(kind, 0)) + 1
	var native := {}
	for plant: Dictionary in registered.get("native", {}).get("plants", {}).get("plants", []):
		var kind := str(plant.get("kind", "?"))
		native[kind] = int(native.get(kind, 0)) + 1
	print("P7BUILD placed=", placed, " native=", native,
		" buses=", (registered.get("native", {}).get("grid", {}).get("buses", []) as Array).size(),
		" lines=", (registered.get("native", {}).get("lines", {}).get("lines", []) as Array).size())
	for warning: String in registered.get("warnings", []):
		print("P7BUILD warn: ", warning)


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


## Hand-lay an `hvdc` corridor from `from_tile` to `to_tile` (inclusive):
## greedy x-then-y walk with a one-tile sidestep around blocked tiles.
## HVDC may cross ANY terrain (incl. deep sea); occupied sites AND existing
## corridors block (one corridor kind per tile — an overwrite would cut the
## AC path it crosses).
func lay_hvdc(from_tile: Vector2i, to_tile: Vector2i) -> bool:
	if not _hvdc_free(from_tile) or not _hvdc_free(to_tile):
		return false
	var queue: Array[Vector2i] = [from_tile]
	var came := {from_tile: from_tile}
	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		if current == to_tile:
			var path: Array[Vector2i] = []
			while current != came[current]:
				path.append(current)
				current = came[current]
			path.append(from_tile)
			for tile: Vector2i in path:
				if not World.place_corridor(tile, "hvdc"):
					return false
			return true
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var n: Vector2i = current + offset
			if not came.has(n) and _hvdc_free(n):
				came[n] = current
				queue.append(n)
	return false


func _hvdc_free(tile: Vector2i) -> bool:
	return not World.corridors.has(tile) \
		and World.can_place_corridor(tile, "hvdc")


## First neighbor a DC corridor can START from (free_neighbor may hand back
## the tile the AC tap already occupies — corridors are one kind per tile).
func hvdc_neighbor(tile: Vector2i) -> Vector2i:
	for offset: Vector2i in GridTopology.NEIGHBORS:
		var n: Vector2i = tile + offset
		if _hvdc_free(n):
			return n
	return Vector2i(-1, -1)


## First free LAND neighbor of a site (for converter AC taps).
func free_neighbor(tile: Vector2i) -> Vector2i:
	for offset: Vector2i in GridTopology.NEIGHBORS:
		var n := tile + offset
		if World.can_place_corridor(n):
			return n
	return Vector2i(-1, -1)
