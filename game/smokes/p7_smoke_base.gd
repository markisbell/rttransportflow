class_name P7SmokeBase
extends SmokeBase
## Shared plumbing for the P7 flexibility smokes (hydrogen_chain,
## battery_response, hvdc_link, north_sea_hub). These boot the GridCo stack
## exactly like dispatch_day but on their OWN sidecar port (8034) so they can
## run beside the 8031 acceptance set without adopting a stale backend.

const P7_PORT := 8034


func p7_boot(tag: String) -> bool:
	SidecarManager.configure(P7_PORT)
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
## network at `lc_tap`. Returns the placed pids (in placement order).
## Sites AND taps honor `avoid` — a tap inside a foreign city's ring quietly
## connected Copenhagen to the Hamburg island and doubled its load (found by
## battery_response: 2.2 GW instant deficit, fleet-wide f-window trip at 1.2 s).
func place_ring(kind: String, count: int, anchor: Vector2i, lc_tap: Vector2i,
		avoid: Dictionary = {}) -> Array[String]:
	var pids: Array[String] = []
	for _i in range(count):
		var site := DemoBuild.find_site(World, kind, anchor, 10, avoid)
		if site == Vector2i(-1, -1):
			break
		var pid: String = World.place_plant(kind, site)
		if pid == "":
			continue
		var tap := tap_avoiding([site], avoid)
		if tap == Vector2i(-1, -1):
			continue
		for tile: Vector2i in DemoBuild.route(World, tap, lc_tap, true, avoid):
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
