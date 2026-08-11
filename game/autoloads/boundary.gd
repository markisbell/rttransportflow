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
func set_native(native: Dictionary) -> void:
	docs = {
		"grid": native["grid"], "lines": native["lines"],
		"plants": native["plants"], "load_centers": native["load_centers"],
		"scenario": native["scenario"],
	}
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
		"devices": [],
	}


func zone_demand(t_sim: float) -> Dictionary:
	var idx := _step_index(t_sim)
	var out := {}
	for item: Dictionary in docs["load_centers"].get("items", []):
		out[item["zone"]] = {"value_mw": float(item["p_mw"][idx])}
	return out


func avail_mw(t_sim: float) -> Dictionary:
	var idx := _step_index(t_sim)
	var out := {}
	for plant: Dictionary in docs["plants"].get("plants", []):
		if CONVERTER_KINDS.has(str(plant["kind"])):
			out[plant["id"]] = float(plant["profile_p_mw"][idx])
	return out


func device_commands(t_sim: float) -> Dictionary:
	var idx := _step_index(t_sim)
	var out := {}
	for plant: Dictionary in docs["plants"].get("plants", []):
		if SYNC_KINDS.has(str(plant["kind"])):
			out[plant["id"]] = {"dispatch_mw": float(plant["profile_p_mw"][idx])}
	return out
