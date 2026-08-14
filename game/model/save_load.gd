extends Node
## SaveLoad — full save/load per SPEC §4.2: the WorldModel envelope is the
## source of truth, the backend snapshot blob rides along for exact dynamic
## resume, and the QUIESCE RULE gates saving (settled-frequency window only —
## a refused snapshot then degrades to a legal cold start).
##
## Determinism notes (the save_load_replay gate asserts bit-identical wire
## frequency after load): every game-side stochastic state serializes
## (Weather OU arrays + RNG state, Demand AR(1) noise per zone), RNG states
## travel as STRINGS (Godot's JSON floats every number — a uint64 would lose
## precision), the file is written with full_precision floats, the backend
## blob is opaque and passes back verbatim, and Orchestrator.last_result is
## restored after re-register so the dispatcher's next decision sees the
## exact pre-save context (register() otherwise clears it).

const SAVE_VERSION := 1
const DEFAULT_PATH := "user://savegame.json"
const QUIESCE_DF_HZ := 0.2

signal save_completed(ok: bool, reason: String)
signal load_completed(ok: bool, reason: String)


func quiesced() -> bool:
	var islands: Dictionary = Orchestrator.latest().get("islands", {})
	if islands.is_empty():
		return false
	for island_id: String in islands:
		var island: Dictionary = islands[island_id]
		if bool(island.get("blackout", false)):
			continue  # a dead island is as settled as it gets
		if absf(SmokeBase.numf(island, "f_hz", 50.0) - 50.0) > QUIESCE_DF_HZ:
			return false
	return true


func save_game(path: String = DEFAULT_PATH, force: bool = false) -> Dictionary:
	if not force and not quiesced():
		save_completed.emit(false, "not_quiesced")
		return {"ok": false, "reason": "not_quiesced"}
	var prev_speed := GameClock.speed
	GameClock.pause()
	while Orchestrator.in_flight:  # quiesce: no half-applied step in the save
		await get_tree().create_timer(0.05).timeout
	var snap: Dictionary = await CosimBridge.snapshot(Orchestrator.ID)
	if snap.get("_status", 0) != 200:
		GameClock.speed = prev_speed
		save_completed.emit(false, "snapshot_failed")
		return {"ok": false, "reason": "snapshot_failed"}
	var envelope := {
		"version": SAVE_VERSION,
		"world": World.serialize(),
		"snapshot": {"model_hash": snap.get("model_hash", ""),
			"version": snap.get("version", 0), "blob": snap.get("blob", {})},
		"clock": GameClock.serialize(),
		"weather": Weather.to_dict(),
		"demand": Demand.to_dict(),
		"economy": Economy.to_dict(),
		"dispatch": {"plant_mode": Dispatch.plant_mode.duplicate(true),
			"link_setpoints": Dispatch.link_setpoints.duplicate(true)},
		"campaign": Campaign.to_dict(),
		"last_result": Orchestrator.last_result.duplicate(true),
		"prev_speed": prev_speed,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		GameClock.speed = prev_speed
		save_completed.emit(false, "write_failed")
		return {"ok": false, "reason": "write_failed"}
	file.store_string(JSON.stringify(envelope, "", false, true))
	file.close()
	GameClock.speed = prev_speed
	save_completed.emit(true, "")
	return {"ok": true, "reason": "", "path": path}


func load_game(path: String = DEFAULT_PATH) -> Dictionary:
	GameClock.pause()
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) \
			or int((parsed as Dictionary).get("version", -1)) != SAVE_VERSION:
		load_completed.emit(false, "bad_file")
		return {"ok": false, "reason": "bad_file"}
	var envelope: Dictionary = parsed
	while Orchestrator.in_flight:
		await get_tree().create_timer(0.05).timeout
	Orchestrator.stop()

	if not World.restore(envelope.get("world", {})):
		load_completed.emit(false, "world_restore_failed")
		return {"ok": false, "reason": "world_restore_failed"}
	Weather.from_dict(envelope.get("weather", {}))
	Demand.from_dict(envelope.get("demand", {}))
	Economy.from_dict(envelope.get("economy", {}))
	var dispatch: Dictionary = envelope.get("dispatch", {})
	Dispatch.plant_mode = (dispatch.get("plant_mode", {}) as Dictionary).duplicate(true)
	Dispatch.link_setpoints = \
		(dispatch.get("link_setpoints", {}) as Dictionary).duplicate(true)
	Campaign.from_dict(envelope.get("campaign", {}))
	GameClock.restore(envelope.get("clock", {}))
	GameClock.pause()  # restore() brings the saved speed; resume explicitly

	# exact dynamic resume: the reset carries the snapshot; refused_snapshot
	# is the legal cold-start fallback (SPEC §4.2)
	Boundary.pending_snapshot = envelope.get("snapshot", {})
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	if not bool(status[0]):
		load_completed.emit(false, "register_failed: %s" % str(status[1]))
		return {"ok": false, "reason": "register_failed"}
	Boundary._decided_block = -1  # force a fresh dispatch decision at resume
	# the dispatcher's first post-load decision must see the exact pre-save
	# device/PF context (register() clears last_result by design — that
	# guard is for CRASH recovery, not for a deliberate restore)
	Orchestrator.last_result = \
		(envelope.get("last_result", {}) as Dictionary).duplicate(true)
	var refused := Orchestrator.last_reset_status == "refused_snapshot"
	GameClock.speed = float(envelope.get("prev_speed", 1.0))
	load_completed.emit(true, "refused_snapshot" if refused else "")
	return {"ok": true, "reason": "refused_snapshot" if refused else "",
		"refused_snapshot": refused}
