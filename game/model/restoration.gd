extends Node
## Restoration — the game side of the ledger-34 black-start doctrine (C5).
## The backend has carried the full wire surface since P8
## (`black_start` on device_commands, `zone_commands.restore_load`,
## the 5-min-healthy gate and 1 %/10 s reload ramp); UFLS-class sheds
## auto-restore engine-side since C2 (ledger 54). What was missing is the
## COMMAND side: this state machine drives one manual black start from
## the player's single verb (`begin(pid)`, the inspector button) through
## crank → energize → staged reload, and the dispatcher's need ledger
## keeps every other plant honest meanwhile (see Dispatch.decide's
## supplied-scaling: at re-energization w ≈ 0 means need ≈ 0, so the
## merit order itself stages the fleet's return as load ramps — the
## mass-restart trap dissolves instead of being fenced).
##
## Both ledger-34 failure modes stay guarded from the game side:
## restart-into-load cannot happen (need scaling + the engine ramp), and
## sync-into-no-load is survived because the unit sustains only a small
## house-load floor until measured supplied recovers.

signal restoration_started(pid: String, zones: Array)
signal restoration_done(zones: Array)

## Small sustain setpoint for the black-start unit while the island
## carries house load only — enough to regulate, nowhere near enough to
## over-frequency a zero-load system (the engine syncs at p_min = 0).
const CRANK_FLOOR_MW := 30.0
## Measured supplied fraction above which a zone leaves the active set
## (load_restored fires at w = 1.0; the threshold guards against a save/
## reload eating the event).
const DONE_SUPPLIED := 0.999
## One restore_load block per wire block once healthy (the §2.2
## convention: one command = one 10 % block; the engine ramp is the real
## pacing and re-gates itself on every dip).
const RESTORE_BLOCK := 0.10

enum Phase { IDLE, CRANK, RELOAD }

var phase: int = Phase.IDLE
var unit_pid := ""
## zones under manual restoration: zone id -> true. Consulted by
## Dispatch.decide (need scaling) until restoration completes.
var active_zones: Dictionary = {}
var _last_block := -1


func _ready() -> void:
	Orchestrator.step_completed.connect(_on_step)


## The player verb: black-start `pid` into its dead island. Marks every
## currently-black zone active (a second dead pocket's zones ride along
## harmlessly — the backend routes restore_load per zone to ITS island,
## and a still-black island ignores the target until cranked).
func begin(pid: String) -> bool:
	if phase != Phase.IDLE:
		print("RESTORATION busy (phase %d) — one black start at a time" % phase)
		return false
	if not World.plants.has(pid):
		return false
	var zones := _black_zones()
	if zones.is_empty():
		print("RESTORATION refused: no black zones on the wire")
		return false
	unit_pid = pid
	active_zones = {}
	for zone_id: String in zones:
		active_zones[zone_id] = true
	phase = Phase.CRANK
	_last_block = int(GameClock.t_sim / Dispatch.BLOCK_S)
	# ONE-shot: breaker close + black_start bypasses the sick-island hold
	# (fleet.poll_commitment); the unit syncs at house load when its lead
	# time completes. The overlay OVERRIDES the dispatcher's entry.
	Boundary.pending_device_commands[pid] = {
		"breaker": "close", "black_start": true, "dispatch_mw": 0.0}
	print("RESTORATION crank: %s -> black start into zones %s"
		% [pid, str(zones)])
	restoration_started.emit(pid, zones)
	return true


func _on_step(_t: int, result: Dictionary) -> void:
	if phase == Phase.IDLE:
		return
	# Completion against the MEASURED wire, any phase. Three zone classes:
	# done (≥ DONE_SUPPLIED), mid (reloading), black (exactly 0). The
	# machine completes when nothing is mid and something is done — the
	# still-black leftovers are a DIFFERENT pocket begin() swept up (the
	# review's deadlock: completion as AND over all zones waited forever
	# on a pocket the crank never reached); they are released for their
	# own black start. The same check self-heals a machine orphaned by a
	# rebuild (the world comes back healthy, every zone reads done — the
	# wedged-CRANK blocking find).
	var zones: Dictionary = result.get("zones", {})
	var done_zones: Array[String] = []
	var mid := false
	var still_black: Array[String] = []
	for zone_id: String in active_zones:
		var supplied := Wire.numf(zones.get(zone_id, {}), "supplied", 1.0)
		if supplied >= DONE_SUPPLIED:
			done_zones.append(zone_id)
		elif supplied > 0.0:
			mid = true
		else:
			still_black.append(zone_id)
	if not mid and not done_zones.is_empty():
		if still_black.is_empty():
			print("RESTORATION done: every active zone measured at full supply")
		else:
			print("RESTORATION done for %s — %s still BLACK (a separate pocket: black-start it on its own)"
				% [str(done_zones), str(still_black)])
		reset()
		restoration_done.emit(done_zones)
		return
	for event: Dictionary in result.get("events", []):
		var kind := str(event.get("kind", ""))
		if kind == "black_start" and phase == Phase.CRANK:
			phase = Phase.RELOAD
			print("RESTORATION energized (%s) — holding %s at %.0f MW through the healthy gate"
				% [str(event.get("element", "")), unit_pid, CRANK_FLOOR_MW])
		elif kind == "blackout" and phase == Phase.RELOAD:
			# re-collapse: back to crank — the unit's start must be re-issued
			print("RESTORATION re-collapse (%s) — back to crank" % str(event.get("element", "")))
			phase = Phase.CRANK
	match phase:
		Phase.CRANK:
			# RE-ARM the crank once per block: the one-shot can be lost to
			# a re-register, and a start refusal (a lockout note) is
			# invisible to the game — re-issuing is idempotent backend-side
			# (command_start no-ops on a STARTING row, the black_start flag
			# is simply re-added) and converts every transient refusal into
			# an eventual start (the C5 review's wedge finds).
			var block := int(GameClock.t_sim / Dispatch.BLOCK_S)
			if block != _last_block:
				_last_block = block
				Boundary.pending_device_commands[unit_pid] = {
					"breaker": "close", "black_start": true, "dispatch_mw": 0.0}
		Phase.RELOAD:
			_drive_reload(result)


func _drive_reload(result: Dictionary) -> void:
	# the unit's command is ALWAYS overridden to max(floor, raw decided):
	# arming the floor only below it left the RAMP-BLENDED wire value
	# sagging toward zero the block the merit order first allocated (the
	# review's disarm race); a step change on one regulating unit is
	# exactly what the schedule ramp does not need to smooth
	var scheduled := absf(Wire.numf(
		Boundary.decided_command(unit_pid), "dispatch_mw", 0.0))
	Boundary.pending_device_commands[unit_pid] = {
		"dispatch_mw": maxf(CRANK_FLOOR_MW, scheduled)}
	# CAPACITY-GATED restore blocks (run 1: one 10 % block of a 4 GW zone
	# is 400 MW — sent against a lone 200 MW OCGT, the engine's 1 %/10 s
	# ramp outran the online fleet and the island re-collapsed at 20 %).
	# A block is released only when measured ONLINE capacity in the
	# restoring zones covers the next target with margin; the dispatcher's
	# need pre-commitment (decide's supplied+0.15 ambition) is restarting
	# the fleet meanwhile, so capacity grows between blocks.
	var block := int(GameClock.t_sim / Dispatch.BLOCK_S)
	var zones: Dictionary = result.get("zones", {})
	if block != _last_block:
		_last_block = block
		# stage the FLEET's return: up to two breaker-closes per block for
		# offline sync units in the restoring zones (the cranking path —
		# the island is healthy now, so these are ordinary starts with
		# their lead times; the dispatcher cannot do it, because its need
		# ledger honestly reads the not-yet-returned load as ~zero)
		var restarted := 0
		var devices: Dictionary = result.get("devices", {})
		var pids: Array = World.plants.keys()
		pids.sort()
		for pid: String in pids:
			if restarted >= 2 or pid == unit_pid:
				continue
			if not active_zones.has(str(Dispatch.home_zone.get(pid, ""))):
				continue
			if not FleetQuery.START_CLASS_RANK.has(
					str(World.plants[pid].get("kind", ""))):
				continue
			var state := str((devices.get(pid, {}) as Dictionary).get("state", ""))
			if state == "offline" or state == "tripped":
				Boundary.pending_device_commands[pid] = {"breaker": "close"}
				restarted += 1
		# capacity gate over the SUM of every active zone's next target:
		# zones cannot be mapped to islands game-side, so all active zones
		# are treated as one island — exact for the common case, merely
		# conservative when two separate pockets restore together (the
		# review: per-zone gating under-counts a multi-zone island and
		# releases blocks its fleet cannot carry)
		var online_mw := _online_capacity_mw(result)
		var t_days := GameClock.t_sim / 86400.0
		var summed_next := 0.0
		var short_zones: Array[String] = []
		for zone_id: String in active_zones:
			var supplied := Wire.numf(zones.get(zone_id, {}), "supplied", 0.0)
			if supplied >= DONE_SUPPLIED:
				continue
			short_zones.append(zone_id)
			summed_next += minf(supplied + RESTORE_BLOCK, 1.0) \
				* Demand.zone_mw(zone_id, t_days)
		if online_mw < summed_next * 1.1:
			print("RESTORATION hold: online %.0f MW < %.0f needed for the next block"
				% [online_mw, summed_next * 1.1])
		else:
			for zone_id: String in short_zones:
				var zone_cmd: Dictionary = Boundary.pending_zone_commands \
					.get(zone_id, {})
				zone_cmd["restore_load"] = RESTORE_BLOCK
				Boundary.pending_zone_commands[zone_id] = zone_cmd
	# (completion runs at the top of _on_step, over the measured classes)


## Measured deliverable capacity ONLINE in the restoring zones (ledger
## 44: state from the wire, nameplate from the world, the 0.92 FCR
## headroom convention from the dispatcher).
func _online_capacity_mw(result: Dictionary) -> float:
	var devices: Dictionary = result.get("devices", {})
	var total := 0.0
	for pid: String in World.plants:
		if not active_zones.has(str(Dispatch.home_zone.get(pid, ""))):
			continue
		if str((devices.get(pid, {}) as Dictionary).get("state", "")) == "online":
			total += float(World.plants[pid].get("p_max_mw", 0.0)) \
				* Dispatch.headroom_frac
	return total


func _black_zones() -> Array:
	var out: Array = []
	var zones: Dictionary = Orchestrator.latest().get("zones", {})
	for zone_id: String in zones:
		if Wire.numf(zones[zone_id], "supplied", 1.0) == 0.0:
			out.append(zone_id)
	out.sort()
	return out


## The player changed plans: abandon the machine (the engine keeps
## whatever physical state the crank reached — a STARTING unit finishes
## as an ordinary start once the island is healthy).
func cancel() -> void:
	if phase == Phase.IDLE:
		return
	print("RESTORATION cancelled (phase %d, unit %s)" % [phase, unit_pid])
	reset()


## A save mid-restoration is legal; the machine is transient by design —
## after a load the player re-issues the verb (the engine's own state
## rode the snapshot). Reset on scenario/world changes; armed one-shots
## must not leak into the next world (the review's nit).
func reset() -> void:
	if unit_pid != "":
		Boundary.pending_device_commands.erase(unit_pid)
	Boundary.pending_zone_commands = {}
	phase = Phase.IDLE
	unit_pid = ""
	active_zones = {}
	_last_block = int(GameClock.t_sim / Dispatch.BLOCK_S)
