extends GdUnitTestSuite
## C7 — Coal Exit: the retirement fee (its own §4.7 cost category, no
## refund), the mothball FOM discount, save-load of the new books axis, and
## the coal_exit era world (green build-out + inertia replacement, coal
## still standing). Autoload state is snapshotted in before()/restored in
## after() — Economy is a singleton shared across suites.

var _econ_snapshot := {}
var _cfg_snapshot := {}


func before_test() -> void:
	_econ_snapshot = Economy.to_dict()
	_cfg_snapshot = Economy.cfg.duplicate(true)


func after_test() -> void:
	Economy.from_dict(_econ_snapshot)
	Economy.cfg = _cfg_snapshot
	World.plants.clear()
	Dispatch.plant_mode.clear()


## The fee formula (D6): frac × catalog capex[€/kW] × p_max[MW] × 1000, and
## it debits treasury by exactly that — its own category, never a fine.
func test_book_retirement_fee_and_debit() -> void:
	Economy.cfg = {"capex_eur_per_kw": {"coal": 1800.0},
		"retirement_fee_frac_capex": 0.02}
	var r0: float = Economy.retirement_cost
	var t0: float = Economy.treasury_eur
	var p0: float = Economy.penalty_cost
	Economy.book_retirement("coal", 800.0)
	var expect := 0.02 * 1800.0 * 800.0 * 1000.0  # 28.8 M€
	assert_float(Economy.retirement_cost - r0).is_equal(expect)
	assert_float(t0 - Economy.treasury_eur).is_equal(expect)
	# retirement is NOT a penalty — retiring on schedule is the milestone
	assert_float(Economy.penalty_cost - p0).is_equal(0.0)


## Retiring is not free but removing the plant gives no refund — a credit
## would invite retire-rebuild arbitrage (remove_plant is economy-blind).
func test_remove_plant_gives_no_refund() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var pid := World.place_plant("coal", DemoBuild.find_site(World, "coal", anchor, 10))
	assert_str(pid).is_not_empty()
	var t0: float = Economy.treasury_eur
	World.remove_plant(pid)
	assert_bool(World.plants.has(pid)).is_false()
	assert_float(Economy.treasury_eur).is_equal(t0)  # no credit on removal
	World.clear_build()


## A mothballed plant bills only 0.3× FOM (preservation staffing) — the
## strategy that lets a player idle a unit instead of scrapping it.
func test_mothball_bills_reduced_fom() -> void:
	Economy.cfg = BuildSession.load_repo_json("data/catalogs/economy.json")
	Economy.treasury_eur = 1.0e12  # keep positive so loan interest stays out
	var pid := "coal_moth_test"
	World.plants[pid] = {"kind": "coal", "p_max_mw": 800.0, "name": "t"}
	Economy.set_fleet([{"id": pid, "kind": "coal"}])
	# auto: full FOM for one day
	Dispatch.plant_mode.erase(pid)
	var f0: float = Economy.fom_cost
	Economy._bill_fom(1)
	var auto_fom: float = Economy.fom_cost - f0
	assert_float(auto_fom).is_greater(0.0)
	# mothballed: 0.3×
	Dispatch.plant_mode[pid] = "mothballed"
	var f1: float = Economy.fom_cost
	Economy._bill_fom(1)
	var moth_fom: float = Economy.fom_cost - f1
	assert_float(moth_fom).is_equal_approx(auto_fom * 0.3, 1.0)


## The new books axis survives to_dict/from_dict (a saved coal-exit run must
## reload with its decommissioning spend intact, or the cost window drifts).
func test_retirement_cost_round_trips() -> void:
	Economy.retirement_cost = 1_234_567.0
	var state := Economy.to_dict()
	Economy.retirement_cost = 0.0
	Economy.from_dict(state)
	assert_float(Economy.retirement_cost).is_equal(1_234_567.0)


func test_economy_json_has_c7_keys() -> void:
	var cfg: Dictionary = BuildSession.load_repo_json("data/catalogs/economy.json")
	assert_bool(cfg.has("retirement_fee_frac_capex")).is_true()
	assert_bool(cfg.has("fom_mothball_mult")).is_true()
	assert_float(float(cfg["retirement_fee_frac_capex"])).is_between(0.0, 0.2)
	assert_float(float(cfg["fom_mothball_mult"])).is_between(0.0, 1.0)
	# every retirable thermal kind must have a capex so the fee is nonzero
	for kind: String in ["coal", "lignite", "gas_ccgt", "gas_ocgt", "nuclear"]:
		assert_float(float((cfg["capex_eur_per_kw"] as Dictionary).get(kind, 0.0))) \
			.override_failure_message("no capex for %s" % kind).is_greater(0.0)


## The coal_exit era: green build-out + the inertia replacement standing,
## the 2025 coal fleet STILL up (the smoke/player retires it).
func test_author_era_coal_exit_builds_inertia() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "coal_exit")).is_true()
	var syncon := 0
	var gfm := 0.0
	var coal := 0.0
	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		if kind == "syncon":
			syncon += 1
		elif kind == "grid_forming":
			gfm += float(World.plants[pid]["p_max_mw"])
		elif kind == "coal" or kind == "lignite":
			coal += float(World.plants[pid]["p_max_mw"])
	assert_int(syncon).is_greater_equal(GridPlan.ERA_SYNCON_UNITS / 2)
	assert_float(gfm).is_greater_equal(1200.0)
	assert_float(coal).is_greater(40000.0)  # coal is still standing
	World.clear_build()


## The inertia fleet joins EXISTING buses (its anchors are bus tiles the RE
## program left with free sides) — the era world must build inside the
## ledger-55 budget (≤ 180 buses), coal fleet and all.
func test_author_era_coal_exit_within_budget() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "coal_exit")).is_true()
	var built := GridTopology.build(World)
	assert_bool(bool(built.get("ok", false))).override_failure_message(
		"build refused: %s" % str(built.get("error", ""))).is_true()
	var buses: int = (built.get("native", {}).get("grid", {}).get("buses", []) as Array).size()
	assert_int(buses).override_failure_message(
		"era world at %d buses — over the 180 budget" % buses).is_less_equal(180)
	# the inertia fleet must ELECTRICALLY CONNECT, not just be placed — a
	# machine that registers but joins no bus contributes zero inertia (the
	# ledger-44/C3 Potemkin trap; the placed-count check above cannot see it)
	var native_syncon := 0
	for row: Dictionary in built.get("native", {}).get("plants", {}).get("plants", []):
		if str(row.get("kind", "")) == "syncon":
			native_syncon += 1
	var dev_gfm := 0
	for dev: Dictionary in built.get("devices", []):
		if str(dev.get("kind", "")) == "grid_forming":
			dev_gfm += 1
	assert_int(native_syncon).override_failure_message(
		"only %d syncon connected — inertia fleet is stranded" % native_syncon) \
		.is_greater_equal(GridPlan.ERA_SYNCON_UNITS / 2)
	assert_int(dev_gfm).override_failure_message(
		"only %d grid_forming connected — reserve fleet is stranded" % dev_gfm) \
		.is_greater_equal(3)
	World.clear_build()


func test_author_era_rejects_unknown() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "no_such_era")).is_false()
	World.clear_build()
