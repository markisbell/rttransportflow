extends P7SmokeBase
## --smoke=black_start: the C5 gate — the ledger-34 doctrine driven from
## the PLAYER's side. A single-city island (the cascade build shape, gas
## must-run) is killed by tripping its whole synchronous fleet at once;
## the smoke then recovers it through the exact calls the inspector
## button makes: `Restoration.begin(best candidate)` → crank
## (black_start bypasses the sick-island hold, syncs at house load) →
## the 5-min-healthy gate → staged reload (restore_load blocks while
## the dispatcher's supplied-scaled need re-commits the fleet as w
## ramps). Windowed assertions: re-energized near 50 Hz onto the
## unloaded system, load restored through the gate, NO re-collapse —
## and both ledger-34 failure modes guarded from the game side (the
## black-start unit's command stays at the house-load floor until
## measured supplied recovers; nothing schedules the dead zone's demand
## while it is dark).

const TAG := "SMOKE_BLACK_START"
## Fleet sizing (run 1's lesson): the reload can only finish if the sync
## fleet covers the island's LIVE demand — 1.6 GW of OCGT against
## hamburg's 4 GW peak stalled forever. 2 OCGT crank units (900 s start
## from any state) + 9 CCGT (hot start 45 min, 5.4 GW) ≈ 5.8 GW
## ≥ 1.35 × map peak, the standing build margin.
const OCGT_UNITS := 2
const CCGT_UNITS := 9

var _blackout_seen := false
var _black_start_seen := false
var _load_restored := false
var _recollapse := false


func run() -> void:
	if not await p7_boot(TAG):
		return
	if not _build():
		return
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)

	# settle, then kill the island: trip EVERY online sync unit at once
	for _i in range(4):
		await p7_block("settle")
	var victims := FleetQuery.online_sync_ranked(
		Orchestrator.latest().get("devices", {}))
	if victims.is_empty():
		_fail(TAG, "nothing online to trip")
		return
	var events: Array = []
	for pid: String in victims:
		events.append({"at_s_rel": 1.0, "kind": "trip", "element": pid})
	Orchestrator.inject(events)
	var chased := await chase_event(600.0, 30, "blackout",
		func(result: Dictionary) -> void:
			for event: Dictionary in result.get("events", []):
				if str(event.get("kind", "")) == "blackout":
					_blackout_seen = true)
	var dead_supplied := numf((Orchestrator.latest().get("zones", {})
		as Dictionary).get("hamburg", {}), "supplied", 1.0)
	print("BLACKSTART island killed: blackout_seen=", _blackout_seen,
		" supplied=", dead_supplied, " f_min=", chased.get("f_min"))
	check("island_blacked_out", _blackout_seen and dead_supplied == 0.0)

	# the advisor names the way back; the candidate list is the button's
	var hint := Advisor.black_start_hint(Orchestrator.latest())
	print("BLACKSTART ", hint)
	check("advisor_names_blackout", hint.contains("BLACKOUT hamburg"))
	var candidates := FleetQuery.black_start_candidates(
		Orchestrator.latest().get("devices", {}), {"hamburg": true})
	check("candidates_found", not candidates.is_empty())
	if candidates.is_empty():
		_fail(TAG, "no black-start candidate")
		return

	# ---- the player action (the inspector's call, verbatim) -----------
	Orchestrator.step_completed.connect(func(_t: int, result: Dictionary) -> void:
		for event: Dictionary in result.get("events", []):
			var kind := str(event.get("kind", ""))
			if kind == "black_start":
				_black_start_seen = true
			elif kind == "load_restored":
				_load_restored = true
			elif kind == "blackout" and _black_start_seen:
				_recollapse = true)
	var unit: String = candidates[0]
	check("begin_accepted", Restoration.begin(unit))

	# crank: the OCGT hot-start is minutes; step fine until re-energized
	var crank_steps := 0
	var unit_cmd_max := 0.0
	while not _black_start_seen and crank_steps < 60:
		var result: Dictionary = await p7_step(60.0, TAG)
		crank_steps += 1
		if result.get("_status", 0) != 200:
			continue
		unit_cmd_max = maxf(unit_cmd_max, _commanded_mw(unit))
	check("re_energized", _black_start_seen)
	if not _black_start_seen:
		_fail(TAG, "no black_start event after %d crank steps" % crank_steps)
		return
	var island_f := numf((Orchestrator.latest().get("islands", {})
		as Dictionary).get("0", {}), "f_hz", 0.0)
	var supplied_at_sync := numf((Orchestrator.latest().get("zones", {})
		as Dictionary).get("hamburg", {}), "supplied", 1.0)
	print("BLACKSTART re-energized: f=", island_f, " supplied=", supplied_at_sync,
		" unit_cmd_max=", unit_cmd_max)
	# ledger-34 mode 2 guarded: synced onto the UNLOADED system near 50 Hz
	check("synced_near_50", absf(island_f - 50.0) < 0.5)
	check("synced_unloaded", supplied_at_sync < 0.05)

	# ---- staged reload through the healthy gate ------------------------
	# capacity-gated blocks + CCGT hot starts (45 min) + the engine's
	# gated ramp: give it generous sim time (60 blocks = 15 h)
	var reload_blocks := 0
	var supplied := supplied_at_sync
	var dark_cmd_max := unit_cmd_max  # commanded while supplied == 0.0
	while supplied < 0.999 and reload_blocks < 60 and not _recollapse:
		await p7_block(TAG)
		reload_blocks += 1
		supplied = numf((Orchestrator.latest().get("zones", {})
			as Dictionary).get("hamburg", {}), "supplied", 0.0)
		# ledger-34 mode 2's game-side guard: while the island carries NO
		# load at all, nothing schedules the black-start unit past its
		# house-load floor (once load returns, following it is correct)
		if supplied == 0.0:
			dark_cmd_max = maxf(dark_cmd_max, _commanded_mw(unit))
		if reload_blocks % 4 == 0:
			print("BLACKSTART reload block %d supplied=%.3f f=%.3f" % [reload_blocks,
				supplied, numf((Orchestrator.latest().get("islands", {})
				as Dictionary).get("0", {}), "f_hz", 0.0)])
	print("BLACKSTART reload done: supplied=%.3f blocks=%d restored_event=%s recollapse=%s dark_cmd_max=%.1f"
		% [supplied, reload_blocks, str(_load_restored), str(_recollapse), dark_cmd_max])
	check("no_recollapse", not _recollapse)
	check("load_fully_restored", supplied >= 0.999 and _load_restored)
	check("restoration_machine_idle", Restoration.phase == Restoration.Phase.IDLE)
	check("unit_held_at_floor_while_dark", dark_cmd_max <= 100.0)
	var f_end := numf((Orchestrator.latest().get("islands", {})
		as Dictionary).get("0", {}), "f_hz", 0.0)
	check("healthy_at_end", absf(f_end - 50.0) < 0.2)
	_finish(TAG, {"crank_steps": crank_steps, "reload_blocks": reload_blocks,
		"supplied": supplied, "f_end": f_end, "unit_cmd_early_max": unit_cmd_max,
		"unit": unit})


func _commanded_mw(pid: String) -> float:
	var decided := absf(numf(Boundary.decided_command(pid), "dispatch_mw", 0.0))
	return maxf(decided, absf(numf(
		Boundary.pending_device_commands.get(pid, {}), "dispatch_mw", 0.0)))


## The cascade build shape: one city, gas must-run ring sized to carry
## the island alone, two batteries (FFR through the reload transients).
func _build() -> bool:
	World.clear_build()
	Dispatch.plant_mode.clear()
	Restoration.reset()
	if not World.load_centers.has("hamburg"):
		_fail(TAG, "map has no hamburg")
		return false
	var lc: Dictionary = World.load_centers["hamburg"]
	var anchor: Vector2i = lc["tiles"][0]
	var avoid := foreign_avoid(["hamburg"])
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"], avoid)
	World.place_corridor(lc_tap)
	var ocgt: Array[String] = place_ring("gas_ocgt", OCGT_UNITS, anchor, lc_tap, avoid)
	var ccgt: Array[String] = place_ring("gas_ccgt", CCGT_UNITS, anchor, lc_tap, avoid)
	if ocgt.size() < OCGT_UNITS or ccgt.size() < CCGT_UNITS:
		_fail(TAG, "site exhaustion: ocgt=%d ccgt=%d" % [ocgt.size(), ccgt.size()])
		return false
	for pid: String in ocgt + ccgt:
		Dispatch.plant_mode[pid] = "must_run"
	var bats: Array[String] = place_ring("battery", 2, anchor, lc_tap, avoid)
	if bats.size() < 2:
		_fail(TAG, "site exhaustion: bats=%d" % bats.size())
		return false
	return true
