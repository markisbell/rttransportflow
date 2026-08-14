extends P7SmokeBase
## --smoke=save_load_replay: the ROADMAP P9 save→load→continue determinism
## gate. A calm thermal island runs 6 blocks, SAVES (quiesced, snapshot in
## the envelope), continues 4 CONTROL blocks recording the wire frequency
## and a device's output, then LOADS the save in-process and replays the
## same 4 blocks — every f_hz and p_mw must be BIT-IDENTICAL (the backend
## restores bit-exact and every game-side stochastic state round-trips) and
## the restore must be exact (status ok, NOT refused_snapshot).

const TAG := "SMOKE_SAVE_LOAD"
const SETTLE_BLOCKS := 6
const REPLAY_BLOCKS := 4
const SAVE_PATH := "user://save_load_replay_smoke.json"


func run() -> void:
	if not await p7_boot(TAG):
		return
	# calm thermal island: the cascade smoke's PROVEN stable recipe — all
	# 600 MW CCGT (a 1600 MW nuclear on a single spur overloads it and the
	# P8 duty protection splits the island — found by this smoke's first run)
	World.clear_build()
	Dispatch.plant_mode.clear()
	var lc: Dictionary = World.load_centers["hamburg"]
	var anchor: Vector2i = lc["tiles"][0]
	var avoid := foreign_avoid(["hamburg"])
	var lc_tap := tap_avoiding(lc["tiles"], avoid)
	if lc_tap == Vector2i(-1, -1):
		_fail(TAG, "no tap")
		return
	World.place_corridor(lc_tap)
	var gas: Array[String] = place_ring("gas_ccgt", 10, anchor, lc_tap, avoid)
	if gas.size() < 10:
		_fail(TAG, "site exhaustion: gas=%d" % gas.size())
		return
	for pid: String in gas:
		Dispatch.plant_mode[pid] = "must_run"
	var built := await p7_register(TAG)
	if built.is_empty():
		return

	for _i in range(SETTLE_BLOCKS):
		var result: Dictionary = await Orchestrator.step_once(900.0)
		if result.get("_status", 0) != 200:
			_fail(TAG, "settle step failed")
			return

	print("SLR pre-save islands: ", JSON.stringify(
		Orchestrator.latest().get("islands", {})))
	var saved: Dictionary = await SaveLoad.save_game(SAVE_PATH)
	check("saved", bool(saved["ok"]))
	if not bool(saved["ok"]):
		_fail(TAG, "save failed: %s" % str(saved["reason"]))
		return
	var t_sim_at_save := GameClock.t_sim

	# CONTROL: the uninterrupted continuation
	var control_f: Array[float] = []
	var control_p: Array[float] = []
	var probe_pid := _first_sync_pid()
	for _i in range(REPLAY_BLOCKS):
		var result: Dictionary = await Orchestrator.step_once(900.0)
		control_f.append(numf(result.get("islands", {}).get("0", {}), "f_hz", -1.0))
		control_p.append(numf(result.get("devices", {}).get(probe_pid, {}),
			"p_mw", -1.0))

	# LOAD back to the save point and replay the same 4 blocks
	var loaded: Dictionary = await SaveLoad.load_game(SAVE_PATH)
	check("loaded", bool(loaded["ok"]))
	check("exact_restore_not_refused",
		not bool(loaded.get("refused_snapshot", true)))
	check("clock_rewound", is_equal_approx(GameClock.t_sim, t_sim_at_save))
	Orchestrator.stop()  # the load's re-register auto-started the scheduler
	GameClock.pause()  # stepping is manual below

	var replay_f: Array[float] = []
	var replay_p: Array[float] = []
	for _i in range(REPLAY_BLOCKS):
		var result: Dictionary = await Orchestrator.step_once(900.0)
		replay_f.append(numf(result.get("islands", {}).get("0", {}), "f_hz", -2.0))
		replay_p.append(numf(result.get("devices", {}).get(probe_pid, {}),
			"p_mw", -2.0))

	var f_identical := true
	var p_identical := true
	for i in range(REPLAY_BLOCKS):
		if control_f[i] != replay_f[i]:  # BIT-identical, no tolerance
			f_identical = false
			print("MISMATCH f block ", i, ": ", control_f[i], " vs ", replay_f[i])
		if control_p[i] != replay_p[i]:
			p_identical = false
			print("MISMATCH p block ", i, ": ", control_p[i], " vs ", replay_p[i])
	check("f_bit_identical", f_identical)
	check("p_bit_identical", p_identical)
	_finish(TAG, {"f_control": control_f, "f_replay": replay_f,
		"probe": probe_pid})


func _first_sync_pid() -> String:
	var devices: Dictionary = Orchestrator.latest().get("devices", {})
	var pids: Array = devices.keys()
	pids.sort()
	for pid: String in pids:
		if (devices[pid] as Dictionary).has("headroom_mw"):
			return pid
	return ""
