extends GdUnitTestSuite
## C9 — The Inverter Grid (finale): the measured inverter-energy-share
## accumulator (§5.2.7) that replaces the pre-C9 `pass` no-op, its kind
## taxonomy and charging/transfer exclusions (ledger 44 — measured, not
## commanded), the criterion gate, the save/grandfather round-trip, the recipe,
## and the finale unlock year. The double-contingency two-component exam is
## already pinned by test_campaign.test_hubless_double_contingency_is_unmet.
## Autoloads are singletons — snapshot/restore in before/after.

var _econ_snapshot := {}
var _cfg_snapshot := {}


func before_test() -> void:
	_econ_snapshot = Economy.to_dict()
	_cfg_snapshot = Economy.cfg.duplicate(true)


func after_test() -> void:
	Economy.from_dict(_econ_snapshot)
	Economy.cfg = _cfg_snapshot
	World.plants.clear()
	Campaign.active = false
	Campaign.failed_reason = ""
	GameClock.t_sim = 0.0


## A synthetic step result carrying a devices channel + dt for the accumulator.
func _dev_result(devices: Dictionary, dt_s: float) -> Dictionary:
	return {"events": [], "zones": {}, "islands": {},
		"devices": devices, "dt_done_s": dt_s, "t_sim_end": 0.0}


func _m7() -> void:
	Campaign.load_data()
	Campaign.start_campaign()
	Campaign.milestone_index = 6  # M7, window [144,180]
	Campaign._reset_acc()


## One inverter source + one synchronous machine, equal power over one hour →
## a measured 50 % share. The energy is DELIVERED power (p_mw × dt), not
## nameplate (ledger 44).
func test_inverter_share_accumulator_math() -> void:
	_m7()
	World.plants["w1"] = {"kind": "wind_offshore"}
	World.plants["n1"] = {"kind": "nuclear"}
	Campaign._accumulate(_dev_result(
		{"w1": {"p_mw": 100.0}, "n1": {"p_mw": 100.0}}, 3600.0), 175.0)
	assert_float(Campaign.inverter_share()).is_equal(0.5)
	assert_float(float(Campaign.acc["inv_energy_mwh"])).is_equal(100.0)
	assert_float(float(Campaign.acc["gen_energy_mwh"])).is_equal(200.0)
	# a battery discharging (no energy_mwh_step on the wire, p_mw only) counts
	# as inverter generation via p_mw × dt
	World.plants["b1"] = {"kind": "battery"}
	Campaign._accumulate(_dev_result({"b1": {"p_mw": 100.0}}, 3600.0), 175.5)
	assert_float(Campaign.inverter_share()).is_equal_approx(200.0 / 300.0, 1e-6)


## The kind taxonomy: hydro_ps→synchronous; grid_forming/offshore_platform→
## inverter; syncon (p_max 0, inertia not energy), electrolyzer (load),
## h2_cavern, hvdc_converter (transfer, ledger 28) contribute to NEITHER term.
func test_kind_mapping() -> void:
	_m7()
	World.plants["h1"] = {"kind": "hydro_ps"}
	World.plants["g1"] = {"kind": "grid_forming"}
	World.plants["p1"] = {"kind": "offshore_platform"}
	World.plants["s1"] = {"kind": "syncon"}
	World.plants["e1"] = {"kind": "electrolyzer"}
	World.plants["c1"] = {"kind": "h2_cavern"}
	World.plants["x1"] = {"kind": "hvdc_converter"}
	Campaign._accumulate(_dev_result({
		"h1": {"p_mw": 100.0}, "g1": {"p_mw": 100.0}, "p1": {"p_mw": 100.0},
		"s1": {"p_mw": 50.0}, "e1": {"p_mw": -100.0}, "c1": {},
		"x1": {"p_mw": 300.0}}, 3600.0), 175.0)
	# inverter = grid_forming + offshore_platform = 200; sync = hydro = 100;
	# syncon/electrolyzer/cavern/hvdc excluded → gen = 300
	assert_float(float(Campaign.acc["inv_energy_mwh"])).is_equal(200.0)
	assert_float(float(Campaign.acc["gen_energy_mwh"])).is_equal(300.0)
	assert_float(Campaign.inverter_share()).is_equal_approx(2.0 / 3.0, 1e-6)


## Charging/pumping/electrolysis loads (negative p_mw) and HVDC transfer never
## enter either term — a max(p_mw,0) filter drops them (ledger 44/28).
func test_charging_and_transfer_excluded() -> void:
	_m7()
	World.plants["e1"] = {"kind": "electrolyzer"}
	World.plants["b1"] = {"kind": "battery"}  # charging
	World.plants["x1"] = {"kind": "hvdc_converter"}  # transfer
	Campaign._accumulate(_dev_result({
		"e1": {"p_mw": -200.0}, "b1": {"p_mw": -150.0}, "x1": {"p_mw": 300.0}},
		3600.0), 175.0)
	assert_float(float(Campaign.acc["inv_energy_mwh"])).is_equal(0.0)
	assert_float(float(Campaign.acc["gen_energy_mwh"])).is_equal(0.0)
	assert_float(Campaign.inverter_share()).is_equal(0.0)


## Pre-window steps do not accumulate — the M7 window opens at day 144.
func test_accumulator_window_guarded() -> void:
	_m7()
	World.plants["w1"] = {"kind": "wind_offshore"}
	Campaign._accumulate(_dev_result({"w1": {"p_mw": 100.0}}, 3600.0), 100.0)
	assert_float(float(Campaign.acc["gen_energy_mwh"])).is_equal(0.0)


## The criterion is now a REAL gate (before C9 it was a `pass` that always
## held): share ≥ threshold passes, below fails.
func test_inverter_share_gate_is_real() -> void:
	_m7()
	Campaign.acc["inv_energy_mwh"] = 80.0
	Campaign.acc["gen_energy_mwh"] = 100.0
	assert_str(Campaign._first_unmet({"inverter_share_at_least": 0.7})).is_equal("")
	Campaign.acc["inv_energy_mwh"] = 60.0
	assert_str(Campaign._first_unmet({"inverter_share_at_least": 0.7})) \
		.is_equal("inverter_share_at_least")


## An unmeasured/dead window (zero denominator) reads share 0.0 and FAILS the
## gate — the correct default (mirrors _window_avg_cost()).
func test_inverter_share_empty_denominator_fails() -> void:
	_m7()
	assert_float(Campaign.inverter_share()).is_equal(0.0)
	assert_str(Campaign._first_unmet({"inverter_share_at_least": 0.7})) \
		.is_equal("inverter_share_at_least")


## The accumulator survives save/load; a pre-C9 save (acc without the energy
## keys) grandfathers to 0.0 without error.
func test_inverter_share_grandfather_and_round_trip() -> void:
	_m7()
	Campaign.acc["inv_energy_mwh"] = 123.0
	Campaign.acc["gen_energy_mwh"] = 456.0
	var state := Campaign.to_dict()
	Campaign._reset_acc()
	Campaign.from_dict(state)
	assert_float(float(Campaign.acc["inv_energy_mwh"])).is_equal(123.0)
	assert_float(float(Campaign.acc["gen_energy_mwh"])).is_equal(456.0)
	assert_float(Campaign.inverter_share()).is_equal_approx(123.0 / 456.0, 1e-6)
	# a pre-C9 save: acc dict without the two keys
	var legacy: Dictionary = state.duplicate(true)
	(legacy["acc"] as Dictionary).erase("inv_energy_mwh")
	(legacy["acc"] as Dictionary).erase("gen_energy_mwh")
	Campaign.from_dict(legacy)
	assert_float(Campaign.inverter_share()).is_equal(0.0)


## The M7 recipe loads as milestone 6, inside the window, on the hydrogen era.
func test_inverter_grid_recipe_shape() -> void:
	var r: Dictionary = BuildSession.load_repo_json(
		"data/scenarios/inverter_grid_2037.json")
	assert_bool(r.is_empty()).is_false()
	assert_int(int((r["campaign"] as Dictionary)["milestone_index"])).is_equal(6)
	assert_str(str(r["author_era"])).is_equal("hydrogen")
	assert_float(float(r["start_day"])).is_between(144.0, 180.0)
	assert_bool((r["economy"] as Dictionary).has("treasury_eur")).is_true()


## The finale portfolio kinds are all unlocked by the M7 window (day 144 =
## 2037): grid_forming/syncon 2031, wind_synthetic_inertia 2035.
func test_finale_portfolio_unlocked_2037() -> void:
	Campaign.load_data()
	Campaign.start_campaign()
	GameClock.t_sim = 143.0 * 86400.0  # still 2036 — a pre-window boundary
	assert_bool(Campaign.unlocked("wind_synthetic_inertia")).is_true()  # 2035
	GameClock.t_sim = 144.0 * 86400.0  # 2037, M7 window open
	assert_bool(Campaign.unlocked("grid_forming")).is_true()
	assert_bool(Campaign.unlocked("syncon")).is_true()
	assert_bool(Campaign.unlocked("wind_synthetic_inertia")).is_true()
