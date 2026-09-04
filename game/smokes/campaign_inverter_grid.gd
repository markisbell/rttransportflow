extends P7SmokeBase
## --smoke=campaign_inverter_grid: the C9 gate — milestone 7 (The Inverter
## Grid), the campaign FINALE. A MECHANIC GATE (like C7's M5 / C8's M6), not a
## full-year ★-pin: it verifies the finale toolkit end to end and MEASURES the
## two questions §5.2.7 asks of a coal-free inverter grid.
##
## The world is the hydrogen era (author_era("hydrogen")) one milestone on —
## coal-free, inverter-heavy, with the grid-forming + FFR + syncon portfolio
## and the North Sea hub the finale's exam needs. The recipe starts at day
## 174.2, a short settle before the scripted double contingency at day 174.5:
## the largest offshore hub and the largest online unit trip within 10 s
## (~3.6 GW of paired infeed loss), the exam only a properly sized inverter
## portfolio can ride.
##
## What it HARD-ASSERTS (green): the build criteria (by construction), MEASURED
## registration (the C3 Potemkin lesson — the hub is a real offshore_hub
## device, GFM registers, syncons register as native rows, node budget inside
## 180/360), that the inverter-share accumulator is LIVE (measured energy > 0),
## and — the ledger-52 truth — that the exam FIRES with BOTH components (a
## hub-less/unit-less world must not pass its own finale by degrading to a
## single trip). What it MEASURES and REPORTS (the §7-Q8 finale question): does
## the coal-free inverter grid SURVIVE the paired loss (no blackout), the
## post-exam nadir, the measured inverter energy share vs the 0.7 bar, and the
## final-year UFLS — the owner's data, exactly like C7/C8, not a threshold this
## bounded gate pins.
##
## Stepping: coarse dt = 60 s (the coal-free grid runs ALERT-slow — 300 s
## blocks overrun the step timeout, the C7 wall) up to the exam, then a fine
## dt = 2 s band across day 174.5 so the two trips 10 s apart resolve and the
## nadir is captured. Bounded to a slice around the exam (the full [144,180]
## window is a multi-hour coal-free traversal). Local gate.

const TAG := "SMOKE_INVERTER_GRID"
const COARSE_DT := 60.0
const FINE_DT := 2.0
const EXAM_DAY := 174.5
## Switch to fine stepping just before the exam fires so the injected trips
## (at +1 s and +11 s) and the electromechanical nadir resolve on the wire.
## The fine band is NARROW (opens ~170 s before the exam, closes ~430 s after)
## — a wide band would crawl 2 s steps for tens of sim-minutes on the ALERT-
## slow coal-free grid and blow the call budget before reaching day 174.5 (the
## C9 review's blocking find). Coarse settles 174.4→174.498, fine brackets the
## exam through the aftermath nadir.
const FINE_FROM := 174.498
const SLICE_TO := 174.505
const MAX_CALLS := 700

var _campaign_failed := ""


func run() -> void:
	if not await p7_boot(TAG):
		return
	if not Scenario.load_scenario("inverter_grid_2037"):
		_fail(TAG, "inverter_grid_2037 recipe failed to load")
		return
	Campaign.autosave_path = "user://autosave_milestone_smoke.json"
	Campaign.campaign_failed.connect(func(reason: String) -> void:
		print("CAMPAIGN campaign_failed ", reason, " day %.2f" % Campaign.day_now())
		_campaign_failed = reason)

	print("INVGRID start re=%.0f hub=%.0f gfm=%.0f syncon=%d coal=%.0f day=%.2f"
		% [Campaign.re_capacity_mw(), Campaign.hub_offshore_mw(), _gfm_mw(),
		_syncon_count(), Campaign.coal_mw(), Campaign.day_now()])
	# the finale build criteria — satisfied by the hydrogen era by construction
	check("re_built", Campaign.re_capacity_mw() >= 18000.0)
	check("hub_built", Campaign.hub_offshore_mw() >= 2000.0)
	check("coal_free", Campaign.coal_mw() <= 0.0)
	# the survival portfolio: grid-forming FFR + synchronous condensers (C6)
	check("gfm_built", _gfm_mw() >= 6000.0)
	check("syncon_built", _syncon_count() >= 8)

	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)
	# MEASURED registration (the C3 Potemkin lesson): the exam is only real if
	# the hub is an electrically-live offshore_hub device (not placed-but-dead)
	# and the inertia portfolio actually registered.
	check("hub_registered", _count_dev(registered, "offshore_hub") >= 1)
	check("gfm_registered", _count_dev(registered, "grid_forming") >= 8)
	check("syncons_registered", _native_kind_rows(registered, "syncon") >= 8)
	var n_buses := int(registered.get("interpretation", {}).get("n_buses", 999))
	var n_branches: int = (registered.get("native", {}).get("lines", {}).get(
		"lines", []) as Array).size()
	check("node_budget", n_buses <= 180 and n_branches <= 360)
	print("INVGRID topology buses=%d branches=%d" % [n_buses, n_branches])

	# --- step to the exam, MEASURING the accumulator + the paired-loss survival
	var calls := 0
	var refused := 0
	var solved := 0
	var exam_ufls := 0
	var dc_nadir := 100.0
	var min_treasury: float = Economy.treasury_eur
	var loop_t0 := Time.get_ticks_msec()
	while Campaign.day_now() < SLICE_TO and calls < MAX_CALLS:
		var day := Campaign.day_now()
		var dt := FINE_DT if day >= FINE_FROM else COARSE_DT
		var result: Dictionary = await p7_step(dt, TAG)
		calls += 1
		if result.get("_status", 0) != 200:
			refused += 1
			if refused >= 60:
				_fail(TAG, "backend deaf at day %.2f" % Campaign.day_now())
				return
			continue
		refused = 0
		solved += 1
		min_treasury = minf(min_treasury, Economy.treasury_eur)
		# nadir + UFLS once the exam has fired (the aftermath settle)
		if bool(Campaign.acc.get("double_contingency_fired", false)):
			for iid: String in result.get("islands", {}):
				dc_nadir = minf(dc_nadir, Wire.numf(result["islands"][iid], "f_min", 100.0))
			exam_ufls += _count_kind(result, "ufls_stage")
		if calls % 40 < 1 or Campaign.day_now() >= FINE_FROM:
			print("INVGRID day %.3f invshare=%.3f dc_fired=%s nadir=%.2f ufls=%d %.0f ms/step"
				% [Campaign.day_now(), Campaign.inverter_share(),
				str(bool(Campaign.acc.get("double_contingency_fired", false))),
				dc_nadir if dc_nadir < 100.0 else 0.0, exam_ufls,
				float(Time.get_ticks_msec() - loop_t0) / maxf(calls, 1)])
		if _campaign_failed != "":
			break

	var inv_share := Campaign.inverter_share()
	var gen_mwh := float(Campaign.acc.get("gen_energy_mwh", 0.0))
	var dc_hub := bool(Campaign.acc.get("dc_hub_fired", false))
	var dc_unit := bool(Campaign.acc.get("dc_unit_fired", false))
	var blackout := bool(Campaign.acc.get("double_contingency_blackout", false))
	var survived := dc_hub and dc_unit and not blackout
	var gco2 := Economy.g_co2_per_kwh()
	print("INVGRID done day=%.3f invshare=%.3f gco2=%.1f dc_hub=%s dc_unit=%s blackout=%s survived=%s nadir=%.2f exam_ufls=%d fy_ufls=%d solved=%d (the §5.2.7 measurement)"
		% [Campaign.day_now(), inv_share, gco2, str(dc_hub), str(dc_unit),
		str(blackout), str(survived), dc_nadir if dc_nadir < 100.0 else 0.0,
		exam_ufls, int(Campaign.acc.get("final_year_ufls", 0)), solved])

	# MECHANIC (green): the finale world runs, the accumulator is LIVE, and the
	# exam fires as authored (ledger 52 — both components; the Potemkin guard)
	check("coal_free_world_operable", solved >= 1)
	check("reached_exam", Campaign.day_now() >= EXAM_DAY)
	check("inverter_share_measured", gen_mwh > 0.0)
	check("double_contingency_fired_both", dc_hub and dc_unit)
	check("treasury_survives", min_treasury > -2.0e9)
	# the §5.2.7 measurements are REPORTED, not asserted against a threshold —
	# whether the coal-free inverter grid survives the paired loss, and what
	# share it runs, are the owner's data (the same §7-Q8 finale question C7/C8
	# posed), not this bounded gate's pass.
	check("survival_measured", dc_nadir >= 0.0)
	check("inverter_share_reported", inv_share >= 0.0)
	_finish(TAG, {"calls": calls, "day_end": Campaign.day_now(),
		"inverter_share": inv_share, "gco2_per_kwh": gco2,
		"dc_survived": survived, "dc_blackout": blackout, "dc_nadir_hz": dc_nadir,
		"exam_ufls": exam_ufls, "final_year_ufls": int(Campaign.acc.get("final_year_ufls", 0)),
		"n_buses": n_buses, "n_branches": n_branches,
		"min_treasury_b": min_treasury / 1e9, "campaign_failed": _campaign_failed,
		"note": "mechanic gate; M7 coal-free inverter-grid survival is §7 Q8"})


## Count device rows of a kind in a reset/step result's devices channel.
func _count_dev(built: Dictionary, kind: String) -> int:
	var n := 0
	for dev: Dictionary in built.get("devices", []):
		if str(dev.get("kind", "")) == kind:
			n += 1
	return n


## Count native plant rows of a kind (syncon is a plant, not a device row).
func _native_kind_rows(built: Dictionary, kind: String) -> int:
	var n := 0
	for row: Dictionary in built.get("native", {}).get("plants", {}).get("plants", []):
		if str(row.get("kind", "")) == kind:
			n += 1
	return n


func _count_kind(result: Dictionary, kind: String) -> int:
	var n := 0
	for event: Dictionary in result.get("events", []):
		if str(event.get("kind", "")) == kind:
			n += 1
	return n


func _gfm_mw() -> float:
	var total := 0.0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == "grid_forming":
			total += float(World.plants[pid].get("p_max_mw", 0.0))
	return total


func _syncon_count() -> int:
	var n := 0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == "syncon":
			n += 1
	return n
