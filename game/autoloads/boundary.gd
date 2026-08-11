extends Node
## Boundary — P4 stub boundary provider (ROADMAP P4): replays the
## europe_mini daily profiles as boundary conditions. GridCo's real
## demand/weather/dispatch models replace this in P6.

const SYNC_KINDS: Array[String] = [
	"nuclear", "coal", "lignite", "gas_ccgt", "gas_ocgt", "hydro_ps"]
const CONVERTER_KINDS: Array[String] = [
	"wind_onshore", "wind_offshore", "solar_pv"]

var docs := {}  # grid / lines / plants / load_centers / scenario (verbatim)
var loaded := false


func bundle_dir() -> String:
	return ProjectSettings.globalize_path("res://").rstrip("/").get_base_dir() \
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
	return int(t_sim / 900.0) % steps_per_day()


## Contract reset document: native bundle VERBATIM + zones (+ no device
## overrides at P4 — the backend derives the fleet from native).
func reset_doc() -> Dictionary:
	return {
		"contract": CosimBridge.EXPECTED_CONTRACT,
		"network_kind": "transmission",
		"name": str(docs["scenario"].get("name", "europe_mini")),
		"steps_per_day": steps_per_day(),
		"native": {
			"grid": docs["grid"], "lines": docs["lines"], "plants": docs["plants"],
			"load_centers": docs["load_centers"], "scenario": docs["scenario"],
		},
		"zones": docs["grid"].get("zones", []).map(
			func(zone: Dictionary) -> Dictionary:
				return {"id": zone["id"], "node": zone["bus"]}),
		"devices": wire_devices,
	}


## "profiles": replay the bundle's authored profiles (P4 smokes, standalone
## parity). "gridco": the live models — Demand/Weather/Dispatch (P6+).
var mode := "profiles"

var _line_buses: Dictionary = {}
var _plant_bus: Dictionary = {}
var _decided_block := -1
var _gridco: Dictionary = {"device_commands": {}, "avail_mw": {}}


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
	Dispatch.wire_devices = wire_devices
	Dispatch.hub_farms = hub_farms
	Economy.set_fleet(docs["plants"].get("plants", []), wire_devices)


func _zone_ids() -> Array:
	var out: Array = []
	for zone: Dictionary in docs["grid"].get("zones", []):
		out.append(str(zone["id"]))
	return out


## One dispatcher decision per 15-min block (GAME_DESIGN §3.3 cadence).
func _ensure_decided(t_sim: float) -> void:
	var block := int(t_sim / 900.0)
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
		if CONVERTER_KINDS.has(str(plant["kind"])):
			out[plant["id"]] = float(plant["profile_p_mw"][idx])
	return out


func device_commands(t_sim: float) -> Dictionary:
	if mode == "gridco":
		_ensure_decided(t_sim)
		return _gridco["device_commands"]
	var idx := _step_index(t_sim)
	var out := {}
	for plant: Dictionary in docs["plants"].get("plants", []):
		if SYNC_KINDS.has(str(plant["kind"])):
			out[plant["id"]] = {"dispatch_mw": float(plant["profile_p_mw"][idx])}
	return out
