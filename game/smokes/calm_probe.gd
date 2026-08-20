extends SmokeBase
## TEMP debug probe: calm_week's build, first 8 blocks with full telemetry.
const TAG := "SMOKE_CALM_PROBE"


func run() -> void:
	if not await gridco_boot(TAG):
		return
	var cw := preload("res://smokes/calm_week.gd").new()
	add_child(cw)
	cw._renewables_heavy_build()
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	print("CP registered=", status[0], " msg=", status[1])
	Orchestrator.stop()
	for i in range(8):
		var r: Dictionary = await Orchestrator.step_once(900.0)
		var isl: Dictionary = r.get("islands", {}).get("0", {})
		print("CP step=", i, " status=", r.get("_status"), " f=", isl.get("f_hz"),
			" fmin=", isl.get("f_min"), " ek=", isl.get("e_k_mj"),
			" black=", isl.get("blackout"))
		for e: Dictionary in r.get("events", []):
			print("CP ev t=", e.get("t_sim"), " ", e.get("kind"), " ", e.get("element"))
		var gen := 0.0
		var wind_avail := 0.0
		var online := 0
		for pid: String in r.get("devices", {}):
			gen += numf(r["devices"][pid], "p_mw", 0.0)
			if str(r["devices"][pid].get("state", "")) == "online":
				online += 1
			if pid.begins_with("wind"):
				wind_avail += numf(r["devices"][pid], "avail_mw", 0.0)
		print("CP gen=", gen, " online=", online, " wind_avail=", wind_avail,
			" price=", Dispatch.wholesale_price, " scarcity=", Dispatch.scarcity)
	_finish(TAG, {})
