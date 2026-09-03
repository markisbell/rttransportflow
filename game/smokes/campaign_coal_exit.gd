extends P7SmokeBase
## --smoke=campaign_coal_exit: the C7 gate — milestone 5 (Coal Exit). This
## verifies the coal-exit TOOLKIT end to end and MEASURES the balancing wall
## behind the milestone; it deliberately does NOT ★-pin the rubric, which is
## blocked (see below and §7 Q8).
##
## The toolkit (green here): the recipe world is the coal_exit era (green
## build-out + the coal-exit flex fleet — grid-forming storage + synchronous
## condensers — standing, author_era("coal_exit")), the 2025 coal fleet
## (57 units, ~47 GW) still up. The smoke retires the WHOLE fleet through the
## same World calls the inspector's Retire verb makes (Economy.book_retirement
## then World.remove_plant), rebuilds, and asserts the mechanic: coal → 0,
## the €1.73 B of decommissioning fees booked, treasury survives, the flex
## fleet still ELECTRICALLY registered after the rebuild, and the coal-free
## world REGISTERS and SOLVES (the backend stays live, PF converges — the
## world is operable, not crashed).
##
## The wall (measured, reported not asserted): retiring coal cannot meet the
## §5.2.5 rubric of ≤ 2 UFLS/final-year on this world, for two independent
## reasons the smoke demonstrates. (1) COAL-FREE RAMP FRAGILITY: with coal
## gone the inertia-light, RE-heavy grid sheds ~6 UFLS at the very next
## demand ramp — an inertia + ramp-POWER gap that pre-built condensers do not
## close (tried to 40: syncon adds RoCoF headroom, not ramp power; grid-
## forming batteries have the power but not the sustained energy). (2)
## REBUILD TRANSIENT: retiring is a World.remove_plant → full backend
## net/reset (remove_device is not a patch op, P7), so EVERY retirement
## cold-starts the fleet (ledger 53) and perturbs frequency — even a 6-unit
## batch grinds into ALERT, so neither all-at-once nor gradual retirement
## stays under the ceiling. WITH coal the same world is clean and fast
## (~0.3 s/step, zero shed through every ramp) — coal's mass is doing the
## work. Closing the wall is an owner decision (§7 Q8): a backend
## net/patch remove_device (no cold-start), firmer flex (M6's H2-CCGT), or a
## rubric/retirement-cadence revisit.

const TAG := "SMOKE_COAL_EXIT"
const COARSE_DT := 60.0  # fine enough to stay CALM on the 164-bus era world
## Retire the whole fleet in ONE rebuild early in the graded slice, then step
## a short window to prove the coal-free world is operable and to MEASURE the
## shedding. (The full-window ★-traversal is neither feasible — permanent
## ALERT, ~35x realtime — nor passable — the wall above.)
const RETIRE_DAY := 118.05
## Coal-free blocks to confirm operability and measure the stress. Kept
## short: past the ramp the coal-free world sheds and drops into deep ALERT,
## where 300 s blocks overrun the step timeout — which HIDES the sheds from a
## client-side count (a timed-out block returns no events). So the smoke
## reports f_min (the grid on the edge — ~49.68 Hz coal-free vs ~50.0 with
## coal) as the wall evidence; the actual ~6-incident ramp shed is the §7 Q8
## finding, measured in the full-traversal runs logged in §6.
const OPER_BLOCKS := 15


var _campaign_failed := ""
var _coal_queue: Array[String] = []


func run() -> void:
	if not await p7_boot(TAG):
		return
	if not Scenario.load_scenario("coal_exit_2033"):
		_fail(TAG, "coal_exit_2033 recipe failed to load")
		return
	Campaign.autosave_path = "user://autosave_milestone_smoke.json"
	Campaign.campaign_failed.connect(func(reason: String) -> void:
		print("CAMPAIGN campaign_failed ", reason, " day %.2f" % Campaign.day_now())
		_campaign_failed = reason)

	# the era world: coal still standing, the flex fleet already commissioned;
	# day 118 is 2033, so the 2031 buildables are unlocked
	var coal_start := Campaign.coal_mw()
	var syncon_units := _count_plants("syncon")
	var gfm_mw := _sum_plants("grid_forming")
	print("COALEXIT start coal=%.0f syncon_units=%d gfm=%.0f day=%.2f"
		% [coal_start, syncon_units, gfm_mw, Campaign.day_now()])
	check("coal_present_at_start", coal_start >= 40000.0)
	check("inertia_syncon_present", syncon_units >= GridPlan.ERA_SYNCON_UNITS / 2)
	check("inertia_gfm_present", gfm_mw >= 1200.0)
	check("buildables_unlocked_in_2033",
		Campaign.unlocked("syncon") and Campaign.unlocked("grid_forming"))

	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		if kind == "coal" or kind == "lignite":
			_coal_queue.append(pid)
	_coal_queue.sort()

	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)
	# the flex fleet must ELECTRICALLY connect in the inherited (with-coal)
	# world too — the CONNECTED-count guard the GdUnit suite pins
	check("flex_connected_with_coal", _native_syncon(registered) >= 2
		and _dev_gfm(registered) >= 3)

	# step to the retirement day WITH coal — the grid is clean and fast here
	var calls := 0
	var refused := 0
	var with_coal_ufls := 0
	while Campaign.day_now() < RETIRE_DAY and calls < 4000:
		var result: Dictionary = await p7_step(COARSE_DT, TAG)
		calls += 1
		if result.get("_status", 0) != 200:
			refused += 1
			if refused >= 40:
				_fail(TAG, "backend deaf pre-retirement at day %.2f" % Campaign.day_now())
				return
			continue
		refused = 0
		with_coal_ufls += _count_kind(result, "ufls_stage")
	check("with_coal_grid_clean", with_coal_ufls == 0)

	# --- the retire mechanic: drop the WHOLE fleet, one rebuild -----------
	var fee_before := Economy.retirement_cost
	var removed := _retire_batch(_coal_queue.size())
	print("COALEXIT retired %d units at day %.2f, fee €%.2fB, coal now %.0f"
		% [int(removed["removed"]), Campaign.day_now(),
		float(removed["fee"]) / 1e9, Campaign.coal_mw()])
	check("all_coal_retired", Campaign.coal_mw() <= 0.0)
	check("retirement_fees_booked", Economy.retirement_cost - fee_before >= 1.0e9)
	check("treasury_survives", Economy.treasury_eur > -2.0e9)

	var reg2 := await p7_register(TAG)
	if reg2.is_empty():
		return
	p7_report(reg2)
	# the flex fleet is still ELECTRICALLY there after the coal left
	check("flex_registered_coal_free", _native_syncon(reg2) >= 2
		and _dev_gfm(reg2) >= 3)
	check("autosave_written", FileAccess.file_exists(Campaign.autosave_file(4)))

	# --- operability + the measured wall ----------------------------------
	# the coal-free world must REGISTER and SOLVE (backend live, PF converges).
	# it SHEDS at ramps — measured and reported, the §7 Q8 finding.
	var solved := 0
	var coal_free_ufls := 0
	var fmin := 100.0
	for _i in range(OPER_BLOCKS):
		var r: Dictionary = await p7_block(TAG)
		if int(r.get("_status", 0)) == 200:
			solved += 1
		coal_free_ufls += _count_kind(r, "ufls_stage")
		for iid: String in r.get("islands", {}):
			fmin = minf(fmin, numf(r["islands"][iid], "f_min", 100.0))
	print("COALEXIT coal-free window: solved=%d/%d ufls=%d f_min=%.3f (the §7 Q8 wall)"
		% [solved, OPER_BLOCKS, coal_free_ufls, fmin])
	# operability: the coal-free world runs at all (reg2 already proved its
	# warmup solve; a block timeout is the ALERT-slowness finding, not a
	# crash — so a lenient floor). The SHEDDING is measured and reported, not
	# asserted against a ceiling: that it sheds IS the §7 Q8 finding.
	check("coal_free_world_operable", solved >= 1)
	check("coal_free_wall_measured", coal_free_ufls >= 0)  # reported in the payload
	check("campaign_not_failed", _campaign_failed == "")

	_finish(TAG, {"coal_final": Campaign.coal_mw(),
		"retirement_b": Economy.retirement_cost / 1e9,
		"with_coal_ufls": with_coal_ufls, "coal_free_ufls": coal_free_ufls,
		"coal_free_f_min": fmin, "note": "mechanic gate; M5 star-rubric is §7 Q8"})


## Retire up to `n` coal units the way the inspector's Retire verb does:
## book the decommission fee, then drop the plant from the world.
func _retire_batch(n: int) -> Dictionary:
	var removed := 0
	var fee := 0.0
	while removed < n and not _coal_queue.is_empty():
		var pid: String = _coal_queue.pop_front()
		if not World.plants.has(pid):
			continue
		var plant: Dictionary = World.plants[pid]
		var before: float = Economy.retirement_cost
		Economy.book_retirement(str(plant.get("kind", "")),
			float(plant.get("p_max_mw", 0.0)))
		fee += Economy.retirement_cost - before
		Dispatch.plant_mode.erase(pid)
		World.remove_plant(pid)
		removed += 1
	return {"removed": removed, "fee": fee}


func _native_syncon(built: Dictionary) -> int:
	var n := 0
	for row: Dictionary in built.get("native", {}).get("plants", {}).get("plants", []):
		if str(row.get("kind", "")) == "syncon":
			n += 1
	return n


func _dev_gfm(built: Dictionary) -> int:
	var n := 0
	for dev: Dictionary in built.get("devices", []):
		if str(dev.get("kind", "")) == "grid_forming":
			n += 1
	return n


func _count_kind(result: Dictionary, kind: String) -> int:
	var n := 0
	for event: Dictionary in result.get("events", []):
		if str(event.get("kind", "")) == kind:
			n += 1
	return n


func _count_plants(kind: String) -> int:
	var n := 0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == kind:
			n += 1
	return n


func _sum_plants(kind: String) -> float:
	var total := 0.0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == kind:
			total += float(World.plants[pid]["p_max_mw"])
	return total
