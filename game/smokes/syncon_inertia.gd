extends P7SmokeBase
## --smoke=syncon_inertia: the C6 gate — the SAME infeed loss on the SAME
## island, three ways, proving both inertia buildables ADD inertia. The
## discriminator is RoCoF, not nadir (P3: GFM/inertia change the initial
## rate of fall, not what the fleet eventually arrests to). Run A: a lean
## thermal island, trip its biggest unit, record windowed RoCoF. Run B:
## identical + 4 GRID-FORMING batteries (virtual H_v = 4 s into E_k).
## Run C: identical + 4 SYNCONS (real spinning mass, H = 3 s on S_n, zero
## power). Both B and C must lower |RoCoF| vs A; the syncon does it with
## no energy and no power, purely as steel. The builds are deterministic
## (clear_build resets the pid counter; the extra units are placed LAST).

const TAG := "SMOKE_SYNCON_INERTIA"
const THERMAL := 6  # coal units — lean enough that one trip is felt

var _syncon_p_max := -1.0


func run() -> void:
	if not await p7_boot(TAG):
		return
	var base := await _leg("base", "", 0)
	if base.is_empty():
		return
	var gfm := await _leg("gfm", "grid_forming", 4)
	if gfm.is_empty():
		return
	var syn := await _leg("syncon", "syncon", 4)
	if syn.is_empty():
		return
	print("SYNCON base nadir=%.3f rocof=%.4f | gfm nadir=%.3f rocof=%.4f | syncon nadir=%.3f rocof=%.4f"
		% [base["nadir"], base["rocof"], gfm["nadir"], gfm["rocof"],
		syn["nadir"], syn["rocof"]])
	# The pedagogy, measured: INERTIA (RoCoF) and PRIMARY RESPONSE (nadir)
	# are different services. A syncon is pure inertia — it slows the
	# initial fall (RoCoF) but has no governor, so the nadir barely moves.
	# A grid-forming battery adds BOTH: virtual inertia AND FFR power, so
	# it lowers RoCoF and arrests the nadir a full Hz. This is the whole
	# C6 lesson — "you need inertia AND reserve" (the finale's portfolio).
	# Base 48.57 / 1.074, GFM 49.48 / 0.801, syncon 48.59 / 0.797.
	check("syncon_lowers_rocof", syn["rocof"] < base["rocof"] * 0.9)
	check("syncon_is_inertia_only", syn["nadir"] < base["nadir"] + 0.2)
	check("gfm_lowers_rocof", gfm["rocof"] < base["rocof"] * 0.9)
	check("gfm_also_arrests_nadir", gfm["nadir"] > base["nadir"] + 0.5)
	check("syncon_delivers_no_power", _syncon_p_max <= 0.001)
	_finish(TAG, {"base_nadir": base["nadir"], "gfm_nadir": gfm["nadir"],
		"syncon_nadir": syn["nadir"], "base_rocof": base["rocof"],
		"gfm_rocof": gfm["rocof"], "syncon_rocof": syn["rocof"],
		"syncon_p_max": _syncon_p_max})


## One leg: build the thermal island plus `count` extra `extra_kind`
## units, register, settle, trip the biggest online unit, chase the
## aftermath. Returns {nadir, rocof} ({} on failure).
func _leg(name: String, extra_kind: String, count: int) -> Dictionary:
	if not _build(extra_kind, count):
		return {}
	var reg := await p7_register(TAG)
	if reg.is_empty():
		return {}
	p7_report(reg)
	if extra_kind == "syncon":
		_syncon_p_max = 0.0
		for row: Dictionary in reg.get("native", {}).get("plants", {}).get("plants", []):
			if str(row.get("kind", "")) == "syncon":
				_syncon_p_max = maxf(_syncon_p_max, float(row.get("p_max_mw", 0.0)))
	var settle := await _settle()
	var ranked: Array = FleetQuery.online_sync_ranked(settle.get("devices", {}))
	if ranked.is_empty():
		_fail(TAG, "%s: no online unit to trip" % name)
		return {}
	var victim: String = str(ranked.front())
	# trip 1 s in, then chase the aftermath in 1 s steps — the fine
	# cadence the 500 ms windowed RoCoF needs (chase_event accumulates
	# f_min and rocof_max across the window)
	Orchestrator.inject([{"at_s_rel": 1.0, "kind": "trip", "element": victim}])
	var chased := await chase_event(2.0, 60, TAG)
	print("SYNCON leg %s victim=%s nadir=%.3f rocof=%.4f"
		% [name, victim, float(chased["f_min"]), float(chased["rocof_max"])])
	return {"nadir": float(chased["f_min"]), "rocof": float(chased["rocof_max"])}


func _settle() -> Dictionary:
	var result := {}
	for _i in range(3):
		result = await p7_block(TAG)
	return result


## Hamburg island: coal ring (identical every leg — clear_build resets the
## pid counter) plus `count` extra units placed LAST so the coal pids stay
## identical and the trip victim is the same machine across legs.
func _build(extra_kind: String, count: int) -> bool:
	World.clear_build()
	Dispatch.plant_mode.clear()
	if not World.load_centers.has("hamburg"):
		_fail(TAG, "map has no hamburg")
		return false
	var lc: Dictionary = World.load_centers["hamburg"]
	var anchor: Vector2i = lc["tiles"][0]
	var avoid := foreign_avoid(["hamburg"])
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"], avoid)
	World.place_corridor(lc_tap)
	var coal: Array[String] = place_ring("coal", THERMAL, anchor, lc_tap, avoid)
	if coal.size() < THERMAL:
		_fail(TAG, "site exhaustion: coal=%d" % coal.size())
		return false
	for pid: String in coal:
		Dispatch.plant_mode[pid] = "must_run"
	if count > 0:
		var extra: Array[String] = place_ring(extra_kind, count, anchor, lc_tap, avoid)
		if extra.size() < count:
			_fail(TAG, "site exhaustion: %s=%d" % [extra_kind, extra.size()])
			return false
	return true
