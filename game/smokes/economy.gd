extends SmokeBase
## --smoke=economy: one simulated day of books — revenue on DELIVERED MWh,
## fuel/CO2 from engine meters, sane cost KPIs — and the measured windows
## are REGENERATED into tools/balancing/economy_windows.csv (family rule:
## change a constant → rerun this smoke → commit both).

const TAG := "SMOKE_ECONOMY"


func run() -> void:
	if not await gridco_boot(TAG):
		return
	DemoBuild.auto_build(World)
	var capex_after_build := Economy.capex_spent
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	if not check("build_registered", bool(status[0])):
		_fail(TAG, "build failed: %s" % str(status[1]))
		return
	Orchestrator.stop()

	var treasury_at_start := Economy.treasury_eur
	var failures := 0
	for _block in range(96):
		var result: Dictionary = await Orchestrator.step_once(900.0)
		if result.get("_status", 0) != 200:
			failures += 1
	check("no_transport_failures", failures == 0)

	check("capex_charged", capex_after_build > 1e8)  # a real grid costs billions
	check("revenue_flows", Economy.revenue > 1e5)
	check("delivered_energy", Economy.delivered_mwh > 1e4)
	check("fuel_and_co2_costed", Economy.fuel_cost > 0.0 and Economy.co2_cost > 0.0)
	var avg_cost := Economy.avg_cost_eur_per_mwh()
	check("avg_cost_sane", avg_cost > 10.0 and avg_cost < 300.0)
	var co2 := Economy.g_co2_per_kwh()
	check("co2_intensity_sane", co2 > 20.0 and co2 < 900.0)
	# ledger consistency: Δtreasury = revenue + reserve − opex − capex − voll
	var expected: float = treasury_at_start + Economy.revenue + Economy.reserve_income \
		- Economy.fuel_cost - Economy.co2_cost - Economy.vom_cost - Economy.fom_cost \
		- Economy.voll_penalty - Economy.redispatch_cost - Economy.loan_eur
	check("ledger_consistent", absf(expected - Economy.treasury_eur) < 1.0)

	_write_windows(avg_cost, co2)
	check("windows_written", FileAccess.file_exists(_csv_path()))
	_finish(TAG, {"avg_cost": avg_cost, "co2_g_kwh": co2,
		"revenue_meur": Economy.revenue / 1e6,
		"delivered_gwh": Economy.delivered_mwh / 1e3})


func _csv_path() -> String:
	return AppPaths.root() \
		+ "/tools/balancing/economy_windows.csv"


func _write_windows(avg_cost: float, co2: float) -> void:
	var lines: Array[String] = [
		"metric,value,unit",
		"delivered,%f,MWh" % Economy.delivered_mwh,
		"unserved,%f,MWh" % Economy.unserved_mwh,
		"revenue,%f,EUR" % Economy.revenue,
		"fuel_cost,%f,EUR" % Economy.fuel_cost,
		"co2_cost,%f,EUR" % Economy.co2_cost,
		"vom_cost,%f,EUR" % Economy.vom_cost,
		"fom_cost,%f,EUR" % Economy.fom_cost,
		"capex,%f,EUR" % Economy.capex_spent,
		"reserve_income,%f,EUR" % Economy.reserve_income,
		"avg_cost,%f,EUR/MWh" % avg_cost,
		"co2_intensity,%f,g/kWh" % co2,
	]
	var file := FileAccess.open(_csv_path(), FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
