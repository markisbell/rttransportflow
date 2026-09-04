extends GdUnitTestSuite
## C8 — The Hydrogen Loop: the gas→H2 convert mechanic (World.convert_to_h2
## gates + sets fuel/store), the retrofit fee (its own §4.7 category), the
## save-load round-trips, and the h2_retrofit unlock gate. Autoload state is
## snapshotted in before/after — Economy is a singleton shared across suites.

var _econ_snapshot := {}
var _cfg_snapshot := {}


func before_test() -> void:
	_econ_snapshot = Economy.to_dict()
	_cfg_snapshot = Economy.cfg.duplicate(true)


func after_test() -> void:
	Economy.from_dict(_econ_snapshot)
	Economy.cfg = _cfg_snapshot
	World.plants.clear()


## The retrofit fee (D-C8-2): frac × gas catalog capex[€/kW] × p_max × 1000,
## its own books category (not a fine, not the retirement sliver), treasury
## debited by exactly that.
func test_retrofit_fee_and_debit() -> void:
	Economy.cfg = {"capex_eur_per_kw": {"gas_ccgt": 950.0},
		"h2_retrofit_frac_capex": 0.20}
	var r0: float = Economy.retrofit_cost
	var t0: float = Economy.treasury_eur
	var ret0: float = Economy.retirement_cost
	Economy.book_retrofit("gas_ccgt", 600.0)
	var expect := 0.20 * 950.0 * 600.0 * 1000.0  # 114 M€
	assert_float(Economy.retrofit_cost - r0).is_equal(expect)
	assert_float(t0 - Economy.treasury_eur).is_equal(expect)
	# retrofit is NOT retirement — a distinct axis
	assert_float(Economy.retirement_cost - ret0).is_equal(0.0)


func test_retrofit_cost_round_trips() -> void:
	Economy.retrofit_cost = 987_654.0
	var state := Economy.to_dict()
	Economy.retrofit_cost = 0.0
	Economy.from_dict(state)
	assert_float(Economy.retrofit_cost).is_equal(987_654.0)


func test_economy_json_has_c8_key() -> void:
	var cfg: Dictionary = BuildSession.load_repo_json("data/catalogs/economy.json")
	assert_bool(cfg.has("h2_retrofit_frac_capex")).is_true()
	assert_float(float(cfg["h2_retrofit_frac_capex"])).is_between(0.0, 1.0)


## World.convert_to_h2 gates on the gas_ prefix — a coal plant can't retrofit
## to hydrogen (it has no gas turbine to re-fire).
func test_convert_gates_gas_only() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var coal := World.place_plant("coal", DemoBuild.find_site(World, "coal", anchor, 10))
	var cav := World.place_plant("h2_cavern", DemoBuild.find_site(World, "h2_cavern", anchor, 60))
	assert_str(coal).is_not_empty()
	assert_str(cav).is_not_empty()
	assert_bool(World.convert_to_h2(coal, cav)).is_false()  # coal is not gas
	assert_bool(World.plants[coal].has("fuel")).is_false()
	World.clear_build()


## Converting a gas plant sets fuel="h2" + h2_store_id, and h2_converted_mw()
## rises by its capacity — the M6 grading criterion.
func test_convert_sets_fuel_store_and_grades() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var gas := World.place_plant("gas_ccgt", DemoBuild.find_site(World, "gas_ccgt", anchor, 10))
	var cav := World.place_plant("h2_cavern", DemoBuild.find_site(World, "h2_cavern", anchor, 60))
	assert_str(gas).is_not_empty()
	assert_str(cav).is_not_empty()
	var before := Campaign.h2_converted_mw()
	assert_bool(World.convert_to_h2(gas, cav)).is_true()
	assert_str(str(World.plants[gas]["fuel"])).is_equal("h2")
	assert_str(str(World.plants[gas]["h2_store_id"])).is_equal(cav)
	assert_float(Campaign.h2_converted_mw() - before) \
		.is_equal(float(World.plants[gas]["p_max_mw"]))
	World.clear_build()


## A gas plant can only convert against an actual cavern (not a random pid).
func test_convert_requires_cavern() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var gas := World.place_plant("gas_ccgt", DemoBuild.find_site(World, "gas_ccgt", anchor, 10))
	var gas2 := World.place_plant("gas_ocgt", DemoBuild.find_site(World, "gas_ocgt", anchor, 12))
	assert_bool(World.convert_to_h2(gas, gas2)).is_false()  # gas2 is not a cavern
	World.clear_build()


## fuel/h2_store_id survive serialize/restore (a converted world must reload
## as converted, or h2_converted_mw() drops on load).
func test_fuel_and_store_round_trip() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var gas := World.place_plant("gas_ccgt", DemoBuild.find_site(World, "gas_ccgt", anchor, 10))
	var cav := World.place_plant("h2_cavern", DemoBuild.find_site(World, "h2_cavern", anchor, 60))
	assert_bool(World.convert_to_h2(gas, cav)).is_true()
	var envelope := World.serialize()
	World.clear_build()
	assert_bool(World.restore(envelope)).is_true()
	assert_str(str(World.plants[gas].get("fuel", ""))).is_equal("h2")
	assert_str(str(World.plants[gas].get("h2_store_id", ""))).is_equal(cav)
	World.clear_build()


## author_era("hydrogen") builds the full H2 chain to M6's pass floors by
## construction (≥5 GW electrolysis, ≥400 GWh_th cavern, ≥4 GW converted),
## and — the recon's arithmetic trap — 4 caverns (533 GWh) not 3 (399.96).
func test_author_era_hydrogen_builds_chain() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "hydrogen")).is_true()
	assert_float(Campaign.electrolysis_mw()).is_greater_equal(5000.0)
	assert_float(Campaign.cavern_gwh_th()).is_greater_equal(400.0)
	assert_float(Campaign.h2_converted_mw()).is_greater_equal(4000.0)
	# the hydrogen era is COAL-FREE (a post-M5 world, §5.2.6): the coal is
	# retired during authoring, cleanly (no play-time rebuild transient)
	assert_float(Campaign.coal_mw()).is_equal(0.0)
	# gas remains (it fires the H2, and residual gas backs the drought)
	assert_float(Campaign.h2_converted_mw()).is_greater(0.0)
	World.clear_build()


## The electrolyzers must ELECTRICALLY connect (anchored on thermal corridors)
## — the criterion counts placed MW, but they only fill the caverns if live,
## and the wire DROPS an electrolyzer that reaches no cavern. Build the
## topology and assert electrolyzer devices survive; check the node budget.
func test_author_era_hydrogen_connects_within_budget() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "hydrogen")).is_true()
	var built := GridTopology.build(World)
	assert_bool(bool(built.get("ok", false))).override_failure_message(
		"build refused: %s" % str(built.get("error", ""))).is_true()
	var buses: int = (built.get("native", {}).get("grid", {}).get("buses", []) as Array).size()
	assert_int(buses).override_failure_message(
		"hydrogen era at %d buses — over the 180 budget" % buses).is_less_equal(180)
	var electro := 0
	var stores := 0
	for dev: Dictionary in built.get("devices", []):
		match str(dev.get("kind", "")):
			"electrolyzer": electro += 1
			"h2_store": stores += 1
	assert_int(electro).override_failure_message(
		"only %d electrolyzers connected — the H2 chain is stranded" % electro) \
		.is_greater_equal(10)
	assert_int(stores).is_equal(GridPlan.ERA_H2_CAVERNS)
	World.clear_build()


## The era world's caverns start near FULL (a day-120 player has filled them
## over years), and the wire carries that level_kg — so the episode has H2 to
## burn without a multi-hour in-smoke fill traversal.
func test_hydrogen_caverns_prefilled_on_wire() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "hydrogen")).is_true()
	var built := GridTopology.build(World)
	var stores := 0
	for dev: Dictionary in built.get("devices", []):
		if str(dev.get("kind", "")) == "h2_store":
			stores += 1
			var params: Dictionary = dev.get("params", {})
			var level := float(params.get("level_kg", 0.0))
			var cap := float(params.get("capacity_kg", 1.0))
			assert_float(level / cap).override_failure_message(
				"cavern only %.0f%% full on the wire — episode would starve" \
				% (100.0 * level / cap)).is_greater(0.5)
	assert_int(stores).is_equal(GridPlan.ERA_H2_CAVERNS)
	World.clear_build()


## level_kg survives serialize/restore (a saved filled cavern must reload
## filled, or a save/load empties the H2 buffer — the C6 sn_mva lesson).
func test_cavern_level_round_trips() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var cav := World.place_plant("h2_cavern", DemoBuild.find_site(World, "h2_cavern", anchor, 60))
	assert_str(cav).is_not_empty()
	World.plants[cav]["level_kg"] = 3_600_000.0
	var envelope := World.serialize()
	World.clear_build()
	assert_bool(World.restore(envelope)).is_true()
	assert_float(float(World.plants[cav].get("level_kg", 0.0))).is_equal(3_600_000.0)
	World.clear_build()


## The h2_retrofit unlock is era-gated to 2033 (day 96 = M6 window open) —
## the tool layer greys the verb before then (C1 rule).
func test_h2_retrofit_unlocks_2033() -> void:
	Campaign.load_data()
	Campaign.start_campaign()
	GameClock.t_sim = 0.0  # 2025
	assert_bool(Campaign.unlocked("h2_retrofit")).is_false()
	GameClock.t_sim = 96.0 * 86400.0  # day 96 -> 2033
	assert_bool(Campaign.unlocked("h2_retrofit")).is_true()
	Campaign.active = false
