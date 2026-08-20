extends Node
## Boundary — the wire-boundary provider. Two modes behind `mode`:
## "profiles" replays the bundle's authored daily profiles (P4 smokes,
## standalone parity); "gridco" runs the live models (Weather/Demand/
## Dispatch, P6+) — one dispatcher decision per 15-min block, the schedule
## RAMPED across the boundary (ledger 39). Also owns the reset-document
## assembly (native bundle + devices channel) and the one-shot save/load
## snapshot handoff. (Its header claimed "P4 stub" for five phases.)

var docs := {}  # grid / lines / plants / load_centers / scenario (verbatim)
var loaded := false


func bundle_dir() -> String:
	return AppPaths.root() \
		+ "/data/grids/europe_mini"


func load_bundle() -> bool:
	docs.clear()
	for name: String in ["grid", "lines", "plants", "load_centers", "scenario"]:
		var path := bundle_dir() + "/%s.json" % name
		if not FileAccess.file_exists(path):
			push_error("Boundary: missing " + path)
			return false
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary):
			push_error("Boundary: invalid JSON in " + path)
			return false
		docs[name] = parsed
	loaded = true
	return true


## P5 build mode: adopt a topology-builder native bundle (same shape as the
## file bundle — every replay function below works unchanged on it).
## `devices`/`hub_farms` are the P7 wire-device channel (empty pre-P7).
var wire_devices: Array = []
var hub_farms: Dictionary = {}


func set_native(native: Dictionary, devices: Array = [],
		farms: Dictionary = {}) -> void:
	docs = {
		"grid": native["grid"], "lines": native["lines"],
		"plants": native["plants"], "load_centers": native["load_centers"],
		"scenario": native["scenario"],
	}
	wire_devices = devices
	hub_farms = farms
	loaded = true


func steps_per_day() -> int:
	return int(docs["scenario"].get("steps_per_day", 96))


func _step_index(t_sim: float) -> int:
	return int(t_sim / Dispatch.BLOCK_S) % steps_per_day()


## Contract reset document: native bundle VERBATIM (+ the devices channel).
## Armed by SaveLoad before the load's re-register; consumed by ONE reset.
var pending_snapshot: Dictionary = {}


## SaveLoad seam: arm the exact-state restore for the NEXT reset (one-shot).
func arm_snapshot(snap: Dictionary) -> void:
	pending_snapshot = snap


## SaveLoad seam: force a fresh dispatch decision at the next boundary read
## (the restore rewinds the clock; a stale block id would skip the decision).
func invalidate_schedule() -> void:
	_decided_block = -1


func reset_doc() -> Dictionary:
	var doc := {
		"contract": CosimBridge.EXPECTED_CONTRACT,
		"network_kind": "transmission",
		"name": str(docs["scenario"].get("name", "europe_mini")),
		"steps_per_day": steps_per_day(),
		"native": {
			"grid": docs["grid"], "lines": docs["lines"], "plants": docs["plants"],
			"load_centers": docs["load_centers"], "scenario": docs["scenario"],
		},
		"devices": wire_devices,
	}
	# (no top-level "zones": the channel is accepted-and-ignored in 2.0 —
	# zone binding is authoritative in native.grid.zones; see v2.md)
	if not pending_snapshot.is_empty():
		doc["snapshot"] = pending_snapshot
		pending_snapshot = {}  # one-shot: only the load's reset restores
	return doc


## "profiles": replay the bundle's authored profiles (P4 smokes, standalone
## parity). "gridco": the live models — Demand/Weather/Dispatch (P6+).
var mode := "profiles"

var _line_buses: Dictionary = {}
var _plant_bus: Dictionary = {}
var _decided_block := -1
var _gridco: Dictionary = {"device_commands": {}, "avail_mw": {}}
## the previous block's commands, held so the new schedule can be ramped in
var _ramp_from: Dictionary = {}


func enable_gridco() -> void:
	mode = "gridco"
	_decided_block = -1
	_line_buses.clear()
	_plant_bus.clear()
	for line: Dictionary in docs["lines"].get("lines", []):
		_line_buses[str(line["id"])] = {"from": str(line["from_bus"]),
			"to": str(line["to_bus"])}
	for plant: Dictionary in docs["plants"].get("plants", []):
		_plant_bus[str(plant["id"])] = str(plant["bus"])
	# Nearest-metro assignment for locality-first dispatch. DEVICES get one
	# too, not just plants: an HVDC terminal draws or injects real MW in a
	# real metro, and the dispatcher cannot net that against the zone unless
	# it knows which zone the terminal stands in.
	var home := {}
	for plant: Dictionary in docs["plants"].get("plants", []):
		home[str(plant["id"])] = _nearest_zone(str(plant["id"]))
	for device: Dictionary in wire_devices:
		home[str(device.get("id", ""))] = _nearest_zone(str(device.get("id", "")))
	Dispatch.home_zone = home
	Dispatch.wire_devices = wire_devices
	Dispatch.hub_farms = hub_farms
	Economy.set_fleet(docs["plants"].get("plants", []), wire_devices)


## The metro a placed thing belongs to — GridTopology.nearest_zone is the
## ONE rule (a private copy here could home a plant to a metro the topology
## no longer served; the all-centres candidate domain is now explicit).
func _nearest_zone(pid: String) -> String:
	var tile: Vector2i = World.plants.get(pid, {}).get("tile", Vector2i.ZERO)
	return GridTopology.nearest_zone(World, tile, World.load_centers.keys())


func _zone_ids() -> Array:
	var out: Array = []
	for zone: Dictionary in docs["grid"].get("zones", []):
		out.append(str(zone["id"]))
	return out


## One dispatcher decision per 15-min block (GAME_DESIGN §3.3 cadence).
func _ensure_decided(t_sim: float) -> void:
	var block := int(t_sim / Dispatch.BLOCK_S)
	if block == _decided_block:
		return
	_decided_block = block
	var latest: Dictionary = Orchestrator.latest()
	_gridco = Dispatch.decide(
		t_sim,
		docs["plants"].get("plants", []),
		latest.get("devices", {}),
		_zone_ids(),
		latest.get("pf", {}).get("latest", {}).get("lines", {}),
		_line_buses,
		_plant_bus,
	)


func zone_demand(t_sim: float) -> Dictionary:
	if mode == "gridco":
		var out := {}
		for zone_id: String in _zone_ids():
			out[zone_id] = {"value_mw": snappedf(
				Demand.zone_mw(zone_id, t_sim / 86400.0), 0.1)}
		return out
	var idx := _step_index(t_sim)
	var out := {}
	for item: Dictionary in docs["load_centers"].get("items", []):
		out[item["zone"]] = {"value_mw": float(item["p_mw"][idx])}
	return out


func avail_mw(t_sim: float) -> Dictionary:
	if mode == "gridco":
		_ensure_decided(t_sim)
		return _gridco["avail_mw"]
	var idx := _step_index(t_sim)
	var out := {}
	for plant: Dictionary in docs["plants"].get("plants", []):
		if World.CONVERTER_KINDS.has(str(plant["kind"])):
			out[plant["id"]] = float(plant["profile_p_mw"][idx])
	return out


## Commands the SCHEDULE across the block instead of stepping it at the
## boundary. A dispatcher decision is a 15-minute schedule, and real systems
## ramp units onto the next setpoint over the boundary rather than jumping
## at :00 — stepping it made the fleet chase a discontinuity every block and
## the frequency wandered +-0.3 Hz, which is also why the save/load gate
## could not find a quiesced moment.
## `dt_s` is the length of the step these commands are FOR. The ramp is
## sampled at the step's midpoint rather than its start: sampled at the
## start, `fmod(t, BLOCK_S)` is 0 on every block boundary, so a step as long
## as a block commands the PREVIOUS block's schedule against the new block's
## demand. At 10 Hz stepping the difference is invisible; at dt = 900 s it
## is a whole schedule out of date, which is what put the morning ramp
## 49.60 Hz deep (pump and electrolyzer shed both fired) and left a test
## island at 50.3 Hz with aFRR saturated on the night decline.
func device_commands(t_sim: float, dt_s: float = 0.0) -> Dictionary:
	if mode == "gridco":
		var previous: Dictionary = _gridco["device_commands"].duplicate(true) \
			if _decided_block >= 0 else {}
		var block_before := _decided_block
		_ensure_decided(t_sim)
		if block_before != _decided_block:
			_ramp_from = previous
		var progress: float = clampf(
			fmod(t_sim + dt_s * 0.5, Dispatch.BLOCK_S) / Dispatch.RAMP_S, 0.0, 1.0)
		if progress >= 1.0 or _ramp_from.is_empty():
			return _gridco["device_commands"]
		var blended := {}
		for pid: String in _gridco["device_commands"]:
			var target: Dictionary = _gridco["device_commands"][pid]
			var command: Dictionary = target.duplicate(true)
			if target.has("dispatch_mw") and _ramp_from.has(pid) \
					and (_ramp_from[pid] as Dictionary).has("dispatch_mw"):
				var from_mw := float((_ramp_from[pid] as Dictionary)["dispatch_mw"])
				var to_mw := float(target["dispatch_mw"])
				command["dispatch_mw"] = snappedf(
					from_mw + (to_mw - from_mw) * progress, 0.1)
			blended[pid] = command
		return blended
	var idx := _step_index(t_sim)
	var out := {}
	for plant: Dictionary in docs["plants"].get("plants", []):
		if World.SYNC_KINDS.has(str(plant["kind"])):
			out[plant["id"]] = {"dispatch_mw": float(plant["profile_p_mw"][idx])}
	return out
