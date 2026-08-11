extends SmokeBase
## --smoke=buildcheck: FAST build diagnostics — no backend, no stepping.
## Prints the auto-build's topology report, capacity ladder and the LIVE
## demand model's per-zone peaks (map peak vs weather-amplified reality).
## Debug tool for sizing/collapse hunts; asserts only that the build forms.

const TAG := "SMOKE_BUILDCHECK"


func run() -> void:
	if not BuildSession.load_map():
		_fail(TAG, "map load failed")
		return
	Weather.setup(42)
	Demand.setup(42)
	Demand.weather = Weather
	DemoBuild.auto_build(World)
	var sampler := func(lc_id: String, step: int) -> float:
		return Demand.zone_mw_forecast(lc_id, step / 96.0)
	var built := GridTopology.build(World, sampler)
	print("BUILDCHECK ok=", built.get("ok"), " error=", built.get("error", ""))
	for warning: String in built.get("warnings", []):
		print("BUILDCHECK warn: ", warning)
	var cap_by_kind := {}
	var total_cap := 0.0
	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		cap_by_kind[kind] = float(cap_by_kind.get(kind, 0.0)) \
			+ float(World.plants[pid]["p_max_mw"])
		total_cap += float(World.plants[pid]["p_max_mw"])
	print("BUILDCHECK capacity_by_kind=", cap_by_kind, " total=", int(total_cap))
	if not built.get("ok", false):
		_fail(TAG, str(built.get("error")))
		return
	var native_cap := 0.0
	for plant: Dictionary in built["native"]["plants"]["plants"]:
		native_cap += float(plant["p_max_mw"])
	print("BUILDCHECK native_plants=", (built["native"]["plants"]["plants"] as Array).size(),
		" native_cap=", int(native_cap),
		" buses=", built["interpretation"]["n_buses"],
		" zones=", (built["zones"] as Array).size())
	var peak_total := 0.0
	for zone: Dictionary in built["zones"]:
		var zid := str(zone["id"])
		var peak := 0.0
		for step in range(96):
			peak = maxf(peak, Demand.zone_mw_forecast(zid, step / 96.0))
		peak_total += peak
		print("BUILDCHECK zone=", zid, " live_peak=", int(peak),
			" map_peak=", int(World.load_centers[zid]["peak_mw"]))
	print("BUILDCHECK live_peak_total=", int(peak_total),
		" cap_over_peak=", snappedf(native_cap / maxf(peak_total, 1.0), 0.01))
	check("build_forms", true)
	_finish(TAG, {"native_cap": native_cap, "live_peak": peak_total})
