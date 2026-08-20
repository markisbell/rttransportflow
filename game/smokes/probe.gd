extends SmokeBase
const TAG := "SMOKE_PROBE"

func run() -> void:
	if not await gridco_boot(TAG):
		return
	var t0 := Time.get_ticks_msec()
	DemoBuild.auto_build(World)
	print("PROBE auto_build_ms=", Time.get_ticks_msec() - t0)
	t0 = Time.get_ticks_msec()
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	print("PROBE register_ms=", Time.get_ticks_msec() - t0, " ok=", status[0], " msg=", status[1])
	Orchestrator.stop()
	for i in range(6):
		t0 = Time.get_ticks_msec()
		var result: Dictionary = await Orchestrator.step_once(900.0)
		var gen_sum := 0.0
		for pid: String in result.get("devices", {}):
			gen_sum += numf(result["devices"][pid], "p_mw", 0.0)
		var demand_sum := 0.0
		for zid: String in Boundary.zone_demand(GameClock.t_sim):
			demand_sum += float(Boundary.zone_demand(GameClock.t_sim)[zid]["value_mw"])
		var cmd_sum := 0.0
		for pid: String in Dispatch.last_commands:
			cmd_sum += float(Dispatch.last_commands[pid].get("dispatch_mw", 0.0))
		var isl0: Dictionary = result.get("islands", {}).get("0", {})
		print("PROBE step=", i, " wall_ms=", Time.get_ticks_msec() - t0,
			" f=", isl0.get("f_hz"),
			" afrr=", isl0.get("afrr_used_mw"),
			" room_up=", isl0.get("afrr_headroom_up_mw"),
			" fcr=", isl0.get("fcr_used_mw"),
			" mode=", result.get("mode"), " load=", result.get("pf",{}).get("latest",{}).get("max_loading_pct"),
			" f_max=", isl0.get("f_max"),
			" gen=", gen_sum, " demand=", demand_sum, " cmds=", cmd_sum,
			" events=", (result.get("events", []) as Array).size())
		for event: Dictionary in result.get("events", []):
			print("PROBE event t=", event.get("t_sim"), " ", event.get("kind"),
				" ", event.get("element"), " ", event.get("data"))
		if i == 0:
			for pid: String in result.get("devices", {}):
				print("PROBE dev ", pid, " p=", numf(result["devices"][pid], "p_mw", -1.0),
					" state=", result["devices"][pid].get("state"))
	_finish(TAG, {})
