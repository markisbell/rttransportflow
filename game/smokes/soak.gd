extends P7SmokeBase
## --smoke=soak: the ROADMAP P10 stability gate. 24 in-game hours at max
## speed on the inherited campaign world, watching the three things that
## only show up over hours and never in a 5-minute smoke:
##
##   1. the step budget holds (no slow creep as buffers fill),
##   2. backend memory is FLAT (a leak in the trajectory/telemetry rings or
##      the snapshot ring would show here and nowhere else),
##   3. nothing is left running afterwards (the family's leaked-sidecar
##      gotcha — a killed game that leaves a backend holding port 8030
##      makes the NEXT launch adopt a stale process).
##
## Windows are asserted, never instants (family rule): a single slow step
## behind a GC pause is not a regression, a rising median is.

const TAG := "SMOKE_SOAK"
const BLOCKS := 96  # 96 x 900 s = 24 in-game hours
## Per-step wall budget. MEASURED on the 142-device / 64-bus continental
## world: 1.9-2.1 s per 900 s block off-peak, ~4.9 s averaged over the
## evening peak (more units online, more ALERT excursions). So the game
## sustains roughly 180-450x real time rather than the 900x the top speed
## button asks for — the orchestrator's skip-never-stall absorbs the
## shortfall, and the honest number belongs in the log, not hidden behind a
## loose threshold. This ceiling catches a REGRESSION (something an order of
## magnitude slower); the real assertion is the DRIFT ratio below.
const STEP_BUDGET_MS := 8000.0
## Backend RSS may breathe (numpy scratch, PF factorisations) but must not
## trend: last quarter vs first quarter.
const RSS_GROWTH_MAX := 1.25


func run() -> void:
	# The soak runs the world the PLAYER will actually run for hours: the
	# inherited continental fleet, not the europe_mini fixture. p7_boot
	# brings up the map, seeds and catalogs the dispatcher needs (booting
	# without the map leaves World.load_centers empty and the topology
	# builder rightly refuses: "no load center connected to the source
	# island").
	if not await p7_boot(TAG):
		return
	var start_path := AppPaths.root().path_join(Campaign.START_STATE_PATH)
	if not FileAccess.file_exists(start_path):
		_fail(TAG, "no authored start world — run --smoke=author_start first")
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(start_path))
	if not (parsed is Dictionary) or not World.restore(parsed):
		_fail(TAG, "start world failed to restore")
		return
	if (await p7_register(TAG)).is_empty():
		return

	var pid := SidecarManager.pid_of(Orchestrator.ID)
	var rss: Array[float] = []
	var step_ms: Array[float] = []
	var failures := 0
	var blackouts := 0
	for i in range(BLOCKS):
		var t0 := Time.get_ticks_usec()
		var result: Dictionary = await Orchestrator.step_once(900.0)
		step_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		if int(result.get("_status", 0)) != 200:
			failures += 1
		for island: Dictionary in result.get("islands", {}).values():
			if bool(island.get("blackout", false)):
				blackouts += 1
		rss.append(_rss_kb(pid))
		if i % 24 == 0:
			print("SOAK block ", i, " rss_mb %.1f" % (rss[-1] / 1024.0),
				" step_ms %.0f" % step_ms[-1])

	var quarter: int = maxi(BLOCKS / 4, 1)
	var rss_first := _mean(rss.slice(0, quarter))
	var rss_last := _mean(rss.slice(BLOCKS - quarter))
	# skip block 0: it carries the numba JIT warmup (~11 s vs ~2 s warm) and
	# would inflate the baseline enough to hide a real upward drift
	var ms_first := _mean(step_ms.slice(1, quarter))
	var ms_last := _mean(step_ms.slice(BLOCKS - quarter))

	check("all_steps_ok", failures == 0)
	check("no_blackout", blackouts == 0)
	check("budget_held", ms_last <= STEP_BUDGET_MS)
	# drift, not absolute cost: a doubling means something accumulates
	check("no_step_drift", ms_first <= 0.0 or ms_last / ms_first <= 2.0)
	check("memory_flat", rss_first <= 0.0 or rss_last / rss_first <= RSS_GROWTH_MAX)

	# leak check: after stop_all the process must actually be gone
	SidecarManager.stop_all()
	var gone := false
	for _i in range(40):
		if _rss_kb(pid) <= 0.0:
			gone = true
			break
		await get_tree().create_timer(0.25).timeout
	check("no_leaked_process", gone)

	_finish(TAG, {"blocks": BLOCKS,
		"rss_mb_first": snappedf(rss_first / 1024.0, 0.1),
		"rss_mb_last": snappedf(rss_last / 1024.0, 0.1),
		"step_ms_first": snappedf(ms_first, 0.1),
		"step_ms_last": snappedf(ms_last, 0.1),
		"pf_failures": failures})


## Resident set of a pid in KB, 0.0 when the process is gone. /proc is
## Linux-only; on other platforms the memory gate self-skips (the ratio
## checks read 0 and pass) rather than failing a smoke for the wrong reason.
func _rss_kb(pid: int) -> float:
	if pid <= 0:
		return 0.0
	var status := FileAccess.open("/proc/%d/status" % pid, FileAccess.READ)
	if status == null:
		return 0.0
	while not status.eof_reached():
		var line := status.get_line()
		if line.begins_with("VmRSS:"):
			return float(line.split(":")[1].strip_edges().split(" ")[0])
	return 0.0


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value: float in values:
		total += value
	return total / values.size()
