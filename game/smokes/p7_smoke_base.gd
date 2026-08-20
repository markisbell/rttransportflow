class_name P7SmokeBase
extends SmokeBase
## Shared plumbing for the P7+ device/flexibility smokes. These boot the
## GridCo stack exactly like dispatch_day but each on its OWN sidecar port
## (assigned from main.gd's SMOKE_PORTS registry) so the set can run
## CONCURRENTLY without adopting a stale backend — two runs on one port make
## the loser silently report someone else's grid (CLAUDE.md §8).

const P7_PORT := 8034

## PARAMETERS §1.16 HVDC path-loss model — mirrors dynamics/hvdc.py
## (path_loss_frac). The P7 smokes cross-check the ENGINE against these, so
## a §1.16 retune must land in hvdc.py and here together — a lone edit makes
## the smoke assert the old model against itself.
const HVDC_CONVERTER_LOSS_FRAC := 0.01  # per station, two stations per path
const HVDC_CABLE_LOSS_FRAC_PER_100KM := 0.003


static func hvdc_path_loss_frac(length_km: float) -> float:
	return 2.0 * HVDC_CONVERTER_LOSS_FRAC \
		+ HVDC_CABLE_LOSS_FRAC_PER_100KM * length_km / 100.0


## Fallback only — main.gd assigns the per-smoke port from SMOKE_PORTS.
## Stays clear of the reserved family ranges (8000-8002, 8010-8016,
## 8020-8029) and of 8030-8033 (game / acceptance smokes / contract tests /
## freeze smoke).
var p7_port := P7_PORT


func p7_boot(tag: String) -> bool:
	return await gridco_boot(tag, p7_port)


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


## Historical alias for step_checked (SmokeBase) — P7 smokes call it p7_step.
func p7_step(dt_s: float, tag: String = "") -> Dictionary:
	return await step_checked(dt_s, tag)


## Step ONE 15-min dispatch block as three 300 s slices.
##
## The old start-sampling bug (a dt = 900 s step commanded the PREVIOUS
## block's schedule) is FIXED — the ramp blend now samples at the step
## midpoint (P9). Slicing is still required for a different reason:
## zone_demand is sample-and-hold per wire step, so a single 900 s step
## lands a whole demand ramp as one instantaneous multi-GW jump the fleet
## can only slew after (the 49.60 Hz morning-ramp artifact in the P9 log).
## Slicing is also simply what the game does — it steps at 0.1-6 s, never
## a block at a time.
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


## Hand-lay an `hvdc` corridor from `from_tile` to `to_tile` (inclusive):
## BFS over tiles a DC corridor may occupy, path replayed via the parent map.
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
