extends SmokeBase
## TEMP: topology analysis of the campaign start world (no backend).
const TAG := "SMOKE_START_CHECK"


func run() -> void:
	if not BuildSession.load_map():
		_fail(TAG, "map")
		return
	Weather.setup(42)
	Demand.setup(42)
	Demand.weather = Weather
	var repo := AppPaths.root()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		repo + "/data/campaign/start_2025.json"))
	if not (parsed is Dictionary) or not World.restore(parsed):
		_fail(TAG, "restore")
		return
	var sampler := func(lc_id: String, step: int) -> float:
		return Demand.zone_mw_forecast(lc_id, step / 96.0)
	var built := GridTopology.build(World, sampler)
	print("SC ok=", built.get("ok"), " warn=", built.get("warnings"))
	var plant_bus: Dictionary = built["interpretation"]["plant_bus"]
	var rename: Dictionary = built["interpretation"]["bus_rename"]
	for pid: String in ["nuclear_1", "nuclear_2", "nuclear_3", "wind_onshore_21",
			"wind_onshore_22", "wind_onshore_23", "battery_24", "battery_23"]:
		if plant_bus.has(pid):
			print("SC ", pid, " kind=", World.plants[pid]["kind"],
				" tile=", World.plants[pid]["tile"],
				" bus=b", rename.get(plant_bus[pid], -99))
	for line: Dictionary in built["native"]["lines"]["lines"]:
		print("SC line ", line["id"], " ", line["from_bus"], "->", line["to_bus"],
			" km=", line["length_km"])
	for plant: Dictionary in built["native"]["plants"]["plants"]:
		print("SC native ", plant["id"], " bus=", plant["bus"],
			" p0=", (plant["profile_p_mw"] as Array)[0])
	_finish(TAG, {})
