extends Node
## Campaign — GAME_DESIGN §5 as data (data/campaign/campaign_v1.json is the
## authority): the representative-day calendar (ledger 15), era CO2/tariff
## script, unlock years, milestone tracker with the §4.7 star rubric, the
## three failure states, and the scripted-event table (trips, staircased
## Dunkelflauten). Sandbox (active == false, the default) leaves every
## unlock open and evaluates nothing — §5.4 "sandbox is also where smokes
## run".
##
## KPI accumulation subscribes to Orchestrator.step_completed; era changes
## rewrite Dispatch.economy_cfg / Economy.cfg and clear the marginal-cost
## cache (it memoizes kind|fuel → €/MWh — a stale cache would price a whole
## era at the old CO2). All state round-trips through to_dict/from_dict
## (save/load, P9).

signal milestone_passed(id: String, stars: int)
signal milestone_failed(id: String, reason: String)
signal campaign_failed(reason: String)
signal era_changed(era: Dictionary)

const CAMPAIGN_PATH := "data/campaign/campaign_v1.json"
const START_STATE_PATH := "data/campaign/start_2025.json"

## The inherited backbone is CONTINENTAL (§5.1; ledger 41) — the metro list
## that defines the product's start world lives HERE with its owner, not in
## a smoke (regenerating the shipped world used to require knowing that a
## test file was the authoring tool). Order is geographic: the trunk is
## laid along this chain, so a scrambled list would zig-zag the backbone.
## Mainland only: the islanded centres (london, stockholm, oslo, athens,
## lisbon, Iberia) join via the links the player unlocks.
const CONTINENTAL_CORE: Array[String] = [
	"randstad", "ruhr", "hamburg", "berlin", "prague", "silesia", "warsaw",
	"vienna", "munich", "stuttgart", "frankfurt", "brussels", "paris",
	"lyon", "zurich", "milan",
]


## Build the inherited-2025 world (deterministic; author_start verifies it
## against the shipped golden and start_2025.json restores it at boot).
## Since the realistic-grid re-baseline (ledger 46) the world is the
## EUROPEAN PLAN: real named substations and corridors from the curated
## seed, every core metro fed from its real stations, the adequacy fleet
## laddered at those stations — the meshed real topology is also what
## retired the L116/L108 evening-peak duty trips (the ledger-45 pocket).
## The renewable BASE is inherited 2025 reality (owner decision, bdae36f):
## named GPPD wind/solar parks placed WEB-ADJACENT, PHS behind the reach
## fence — the flex journey (batteries, electrolysis, caverns) stays the
## player's. The earlier no-pre-placed-renewables rule existed because
## scattered parks shifted mesh flows past a 120 % duty threshold (four
## event-log hunts); web-adjacent placement plus the campaign smoke's
## day-2 guard retired it.
static func build_inherited_world(world: Node) -> bool:
	return GridPlan.author_start(world)
const BLOCK_DAYS := 1.0 / 96.0

var active := false
var data: Dictionary = {}
var era_index := -1
var milestone_index := 0
var replay_viewed := false
var fired_events: Dictionary = {}  # scripted id -> true
var milestone_results: Array = []  # [{id, passed, stars}]
var failed_reason := ""
## per-milestone-window accumulators
var acc := {}
## failure-state trackers
var insolvent_since_day := -1.0
var blackout_days: Array = []  # sim-day stamps of blackout events
var ufls_days: Array = []
var coal_fine_months_billed := 0

var _last_eval_block := -1


func _ready() -> void:
	Orchestrator.step_completed.connect(_on_step)


func load_data() -> bool:
	data = BuildSession.load_repo_json(CAMPAIGN_PATH)
	return not data.is_empty()


## Enter campaign mode (sandbox stays the default outside this call).
func start_campaign() -> void:
	if data.is_empty() and not load_data():
		push_error("Campaign: cannot load " + CAMPAIGN_PATH)
		return
	active = true
	era_index = -1
	milestone_index = 0
	replay_viewed = false
	fired_events = {}
	milestone_results = []
	failed_reason = ""
	insolvent_since_day = -1.0
	blackout_days = []
	ufls_days = []
	coal_fine_months_billed = 0
	_reset_acc()
	_apply_era(day_now())


# ---------------------------------------------------------------- calendar

func day_now() -> float:
	return GameClock.t_sim / GameClock.SECONDS_PER_DAY


func year(day: float = -1.0) -> int:
	if day < 0.0:
		day = day_now()
	var cal: Dictionary = data.get("calendar", {})
	return int(cal.get("start_year", 2025)) \
		+ int(floor(day / float(cal.get("days_per_year", 12))))


func month_name(day: float = -1.0) -> String:
	if day < 0.0:
		day = day_now()
	const NAMES: Array[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return NAMES[int(floor(day)) % 12]


# ---------------------------------------------------------------- unlocks

## Build-palette gate. tool ids match build_menu TOOLS + "h2_retrofit".
func unlocked(kind: String) -> bool:
	if not active:
		return true  # §5.4 sandbox: everything open
	var unlocks: Dictionary = data.get("unlocks", {})
	if not unlocks.has(kind):
		return true  # not era-gated (start fleet kinds)
	return year() >= int(unlocks[kind])


func unlock_year(kind: String) -> int:
	return int((data.get("unlocks", {}) as Dictionary).get(kind, 0))


# ---------------------------------------------------------------- eras

func _apply_era(day: float) -> void:
	var eras: Array = data.get("eras", [])
	var target := era_index
	for i in range(eras.size()):
		if day >= float((eras[i] as Dictionary).get("from_day", 0)):
			target = i
	if target == era_index:
		return
	era_index = target
	var era: Dictionary = eras[era_index]
	var co2 := float(era.get("co2_eur_per_t", 30.0))
	var tariff := float(era.get("tariff_eur_per_mwh", 95.0))
	# repriced() invalidates the marginal-cost memo in the same breath
	# (this used to reach into Dispatch._mc_cache directly); the economy
	# dict is loaded once and shared (GridcoBoot), so repricing Dispatch's
	# copy IS repricing Economy's — the second write stays for boots that
	# load the catalogs separately.
	Dispatch.repriced("co2_eur_per_t", co2)
	Economy.cfg["co2_eur_per_t"] = co2
	Economy.cfg["tariff_eur_per_mwh"] = tariff
	era_changed.emit(era)


# ---------------------------------------------------------------- stepping

func _on_step(_t: int, result: Dictionary) -> void:
	if not active or failed_reason != "":
		return
	var day := day_now()
	_apply_era(day)
	_fire_scripted(day)
	_accumulate(result, day)
	_check_failures(day)
	# evaluate once per 15-min block (steps can be shorter during events)
	var block := int(day / BLOCK_DAYS)
	if block != _last_eval_block:
		_last_eval_block = block
		_evaluate_milestone(day)


# ---------------------------------------------------------------- scripted events

func _fire_scripted(day: float) -> void:
	if milestone_index >= (data.get("milestones", []) as Array).size():
		return
	var by_id := {}
	for ev: Dictionary in data.get("scripted_events", []):
		by_id[str(ev["id"])] = ev
	var milestone: Dictionary = data["milestones"][milestone_index]
	for ev_id: String in milestone.get("scripted", []):
		if fired_events.has(ev_id) or not by_id.has(ev_id):
			continue
		var ev: Dictionary = by_id[ev_id]
		if day < float(ev.get("at_day", 0.0)):
			continue
		fired_events[ev_id] = true
		_fire_event(ev, day)


func _fire_event(ev: Dictionary, day: float) -> void:
	match str(ev.get("kind", "")):
		"trip_nearest_mw":
			var victim := _unit_nearest_mw(float(ev.get("mw", 1200.0)))
			if victim != "":
				Orchestrator.inject([{"at_s_rel": 1.0, "kind": "trip",
					"element": victim}])
				acc["scripted_trip_pending"] = true
		"weather_force":
			_staircase_force(str(ev.get("field", "wind_lambda_scale")),
				str(ev.get("region", "")), day, float(ev.get("to_day", day + 1.0)),
				float(ev.get("value", 1.0)), int(ev.get("staircase_blocks", 8)))
		"dunkelflaute_scripted":
			var to_day := day + float(ev.get("days", 5.0))
			for region: Dictionary in Weather.REGIONS:
				var rid := str(region["id"])
				if not (rid in Weather.NW_ZONE):
					continue
				_staircase_force("wind_lambda_scale", rid, day, to_day,
					float(ev.get("wind_scale", 0.35)),
					int(ev.get("staircase_blocks", 8)))
				_staircase_force("clearness_scale", rid, day, to_day,
					float(ev.get("clearness_scale", 0.5)),
					int(ev.get("staircase_blocks", 8)))
		"double_contingency":
			var hub := _largest_hub()
			var unit := _unit_nearest_mw(1e9)  # largest online unit
			var events: Array = []
			if hub != "":
				events.append({"at_s_rel": 1.0, "kind": "trip", "element": hub})
			if unit != "":
				events.append({"at_s_rel": 1.0 + float(ev.get("gap_s", 10.0)),
					"kind": "trip", "element": unit})
			if not events.is_empty():
				Orchestrator.inject(events)
				acc["double_contingency_fired"] = true


## Entry AND exit staircased: instant λ steps relay out wind fleets (the
## calm_week/P7 lesson); the engine's 20 %/min avail slew still wants the
## FORCE itself ramped so the target it chases moves physically.
func _staircase_force(field: String, region: String, from_day: float,
		to_day: float, value: float, blocks: int) -> void:
	var stair_span := BLOCK_DAYS * blocks
	for k in range(blocks):
		var t0 := from_day + k * stair_span / blocks
		var frac := float(k + 1) / blocks
		Weather.force_window(field, region, t0, t0 + stair_span / blocks,
			lerpf(1.0, value, frac))
	Weather.force_window(field, region, from_day + stair_span,
		to_day - stair_span, value)
	for k in range(blocks):
		var t0 := to_day - stair_span + k * stair_span / blocks
		var frac := float(k + 1) / blocks
		Weather.force_window(field, region, t0, t0 + stair_span / blocks,
			lerpf(value, 1.0, frac))


func _unit_nearest_mw(target_mw: float) -> String:
	# FleetQuery keeps the comparator verbatim — scripted-event victim
	# selection feeds the milestone-1 nadir and the star rubric
	return FleetQuery.unit_nearest_mw(
		Orchestrator.latest().get("devices", {}), target_mw)


func _largest_hub() -> String:
	var best := ""
	var best_mw := 0.0
	for dev: Dictionary in Boundary.wire_devices:
		if str(dev.get("kind", "")) == "offshore_hub":
			var p := float((dev.get("params", {}) as Dictionary).get("p_max_mw", 0.0))
			if p > best_mw:
				best_mw = p
				best = str(dev.get("id", ""))
	return best


# ---------------------------------------------------------------- KPI accumulation

func _reset_acc() -> void:
	acc = {
		"ufls_events": 0, "blackouts": 0, "saidi_min": 0.0,
		"episode_saidi_min": 0.0, "final_year_ufls": 0, "final_year_blackouts": 0,
		"trip_f_min": 100.0, "scripted_trip_pending": false,
		"scripted_trip_seen": false, "double_contingency_fired": false,
		"double_contingency_blackout": false,
		"cost_window_start": {}, "redispatch_window_start_eur": -1.0,
	}


func _accumulate(result: Dictionary, day: float) -> void:
	var milestone := current_milestone()
	var window: Array = milestone.get("window_days", [0, 0])
	if day < float(window[0]):
		return
	for event: Dictionary in result.get("events", []):
		var kind := str(event.get("kind", ""))
		if kind == "ufls_stage":
			acc["ufls_events"] = int(acc["ufls_events"]) + 1
			ufls_days.append(day)
			if _in_span(day, milestone.get("final_year_days", [])):
				acc["final_year_ufls"] = int(acc["final_year_ufls"]) + 1
		elif kind == "blackout":
			acc["blackouts"] = int(acc["blackouts"]) + 1
			blackout_days.append(day)
			if _in_span(day, milestone.get("final_year_days", [])):
				acc["final_year_blackouts"] = int(acc["final_year_blackouts"]) + 1
			if bool(acc.get("double_contingency_fired", false)):
				acc["double_contingency_blackout"] = true
		elif kind == "trip" and bool(acc.get("scripted_trip_pending", false)):
			acc["scripted_trip_pending"] = false
			acc["scripted_trip_seen"] = true
	# nadir tracking while the scripted trip's aftermath settles
	if bool(acc.get("scripted_trip_seen", false)):
		for island_id: String in result.get("islands", {}):
			acc["trip_f_min"] = minf(float(acc["trip_f_min"]),
				Wire.numf(result["islands"][island_id], "f_min", 100.0))
	# SAIDI: (1 − mean supplied) × block minutes, dt-weighted
	var zones: Dictionary = result.get("zones", {})
	if not zones.is_empty():
		var supplied_sum := 0.0
		for zone_id: String in zones:
			supplied_sum += Wire.numf(zones[zone_id], "supplied", 1.0)
		var unserved := 1.0 - supplied_sum / zones.size()
		var minutes := float(result.get("dt_done_s", 0.0)) / 60.0
		acc["saidi_min"] = float(acc["saidi_min"]) + unserved * minutes
		if _in_span(day, milestone.get("episode_days", [])):
			acc["episode_saidi_min"] = float(acc["episode_saidi_min"]) \
				+ unserved * minutes
	# cost window: capture the books at window entry, evaluate on deltas
	var cost_span: Array = milestone.get("cost_window_days",
		milestone.get("window_days", []))
	if _in_span(day, cost_span) and (acc["cost_window_start"] as Dictionary).is_empty():
		acc["cost_window_start"] = _books_snapshot()
	if float(acc.get("redispatch_window_start_eur", -1.0)) < 0.0:
		acc["redispatch_window_start_eur"] = Economy.redispatch_cost


func _books_snapshot() -> Dictionary:
	return {"fuel": Economy.fuel_cost, "co2": Economy.co2_cost,
		"vom": Economy.vom_cost, "fom": Economy.fom_cost,
		"voll": Economy.voll_penalty, "redispatch": Economy.redispatch_cost,
		"delivered": Economy.delivered_mwh}


func _window_avg_cost() -> float:
	var start: Dictionary = acc.get("cost_window_start", {})
	if start.is_empty():
		return 0.0
	var delivered: float = Economy.delivered_mwh - float(start["delivered"])
	if delivered <= 0.0:
		return 0.0
	var cost: float = (Economy.fuel_cost - float(start["fuel"])) \
		+ (Economy.co2_cost - float(start["co2"])) \
		+ (Economy.vom_cost - float(start["vom"])) \
		+ (Economy.fom_cost - float(start["fom"])) \
		+ (Economy.voll_penalty - float(start["voll"])) \
		+ (Economy.redispatch_cost - float(start["redispatch"]))
	return cost / delivered


static func _in_span(day: float, span: Array) -> bool:
	return span.size() == 2 and day >= float(span[0]) and day < float(span[1])


# ---------------------------------------------------------------- fleet KPIs

func re_capacity_mw() -> float:
	var total := 0.0
	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		if kind in ["wind_onshore", "wind_offshore", "solar_pv"]:
			total += float(World.plants[pid]["p_max_mw"])
	return total


func hub_offshore_mw() -> float:
	var total := 0.0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == "offshore_platform":
			total += float(World.plants[pid]["p_max_mw"])
	return total


func coal_mw() -> float:
	var total := 0.0
	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		if kind == "coal" or kind == "lignite":
			total += float(World.plants[pid]["p_max_mw"])
	return total


func electrolysis_mw() -> float:
	var total := 0.0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == "electrolyzer":
			total += float(World.plants[pid]["p_max_mw"])
	return total


func cavern_gwh_th() -> float:
	var total_kg := 0.0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == "h2_cavern":
			total_kg += float(World.plants[pid].get("capacity_kg", 0.0))
	return total_kg * 33.33 / 1e6  # LHV kWh/kg → GWh_th


func h2_converted_mw() -> float:
	var total := 0.0
	for pid: String in World.plants:
		var p: Dictionary = World.plants[pid]
		if str(p.get("fuel", "")) == "h2":
			total += float(p["p_max_mw"])
	return total


# ---------------------------------------------------------------- milestones

func current_milestone() -> Dictionary:
	var milestones: Array = data.get("milestones", [])
	if milestone_index >= milestones.size():
		return {}
	return milestones[milestone_index]


func _evaluate_milestone(day: float) -> void:
	var milestone := current_milestone()
	if milestone.is_empty():
		return
	var window: Array = milestone.get("window_days", [0, 0])
	if day < float(window[1]):
		return  # window still open — evaluated at close
	var criteria: Dictionary = milestone.get("pass", {})
	var reason := _first_unmet(criteria)
	if reason == "":
		var stars := _stars(milestone)
		milestone_results.append({"id": str(milestone["id"]),
			"passed": true, "stars": stars})
		milestone_passed.emit(str(milestone["id"]), stars)
	else:
		milestone_results.append({"id": str(milestone["id"]),
			"passed": false, "stars": 0})
		milestone_failed.emit(str(milestone["id"]), reason)
	milestone_index += 1
	_reset_acc()
	_last_eval_block = int(day / BLOCK_DAYS)


## "" when every criterion holds, else the first unmet criterion's name.
func _first_unmet(criteria: Dictionary) -> String:
	for key: String in criteria:
		var v: Variant = criteria[key]
		match key:
			"max_ufls_events":
				if int(acc["ufls_events"]) > int(v):
					return key
			"max_blackouts":
				if int(acc["blackouts"]) > int(v):
					return key
			"final_year_max_ufls_events":
				if int(acc["final_year_ufls"]) > int(v):
					return key
			"final_year_max_blackouts":
				if int(acc["final_year_blackouts"]) > int(v):
					return key
			"replay_viewed":
				if bool(v) and not replay_viewed:
					return key
			"trip_f_min_at_least":
				if float(acc["trip_f_min"]) < float(v):
					return key
			"avg_cost_below_eur_mwh":
				if _window_avg_cost() >= float(v):
					return key
			"episode_saidi_below_min":
				if float(acc["episode_saidi_min"]) >= float(v):
					return key
			"re_capacity_at_least_mw":
				if re_capacity_mw() < float(v):
					return key
			"hub_offshore_at_least_mw":
				if hub_offshore_mw() < float(v):
					return key
			"redispatch_per_year_below_eur":
				var window: Array = current_milestone().get("window_days", [0, 12])
				var years := maxf((float(window[1]) - float(window[0])) / 12.0, 1e-9)
				var spent: float = Economy.redispatch_cost \
					- float(acc.get("redispatch_window_start_eur", 0.0))
				if spent / years >= float(v):
					return key
			"coal_mw_at_most":
				if coal_mw() > float(v):
					return key
			"electrolysis_at_least_mw":
				if electrolysis_mw() < float(v):
					return key
			"cavern_at_least_gwh_th":
				if cavern_gwh_th() < float(v):
					return key
			"h2_converted_at_least_mw":
				if h2_converted_mw() < float(v):
					return key
			"inverter_share_at_least":
				pass  # tracked game-side post-v1: energy-share meter (P10)
			"gco2_per_kwh_below":
				if Economy.g_co2_per_kwh() >= float(v):
					return key
			"double_contingency_survived":
				if bool(acc.get("double_contingency_blackout", false)):
					return key
	return ""


func _stars(milestone: Dictionary) -> int:
	var total := 0
	var rubric: Dictionary = milestone.get("stars", {})
	for axis: String in rubric:
		if axis.begins_with("_"):
			continue
		var tiers: Dictionary = rubric[axis]
		for tier_name: String in ["three", "two", "one"]:
			if not tiers.has(tier_name):
				continue
			if _first_unmet(tiers[tier_name]) == "":
				total += int({"three": 3, "two": 2, "one": 1}[tier_name])
				break
	return total


func notify_replay_viewed() -> void:
	replay_viewed = true


# ---------------------------------------------------------------- failure states

func _check_failures(day: float) -> void:
	var fails: Dictionary = data.get("failure_states", {})
	# insolvency: sustained deep-negative treasury
	var insolvency: Dictionary = fails.get("insolvency", {})
	if Economy.treasury_eur < float(insolvency.get("treasury_below_eur", -2e9)):
		if insolvent_since_day < 0.0:
			insolvent_since_day = day
		elif day - insolvent_since_day >= float(insolvency.get("for_days", 3)):
			_fail("insolvency")
	else:
		insolvent_since_day = -1.0
	# dismissed: blackout / UFLS rates over a rolling year
	var by_black: Dictionary = fails.get("dismissed_blackouts", {})
	blackout_days = blackout_days.filter(
		func(d: float) -> bool: return day - d < float(by_black.get("within_days", 12)))
	if blackout_days.size() >= int(by_black.get("count", 3)):
		_fail("dismissed_blackouts")
	var by_ufls: Dictionary = fails.get("dismissed_ufls", {})
	ufls_days = ufls_days.filter(
		func(d: float) -> bool: return day - d < float(by_ufls.get("within_days", 12)))
	if ufls_days.size() > int(by_ufls.get("count", 12)):
		_fail("dismissed_ufls")
	# coal deadline: monthly fines past the hard date
	var deadline: Dictionary = fails.get("coal_deadline", {})
	if coal_mw() > 0.0 and day >= float(deadline.get("day", 120)):
		var months_over := int(day - float(deadline.get("day", 120))) + 1
		while coal_fine_months_billed < months_over:
			coal_fine_months_billed += 1
			Economy.treasury_eur -= float(deadline.get("fine_eur_per_month", 1e8))


func _fail(reason: String) -> void:
	if failed_reason != "":
		return
	failed_reason = reason
	campaign_failed.emit(reason)


# ---------------------------------------------------------------- save/load

func to_dict() -> Dictionary:
	return {
		"active": active, "era_index": era_index,
		"milestone_index": milestone_index, "replay_viewed": replay_viewed,
		"fired_events": fired_events.keys(),
		"milestone_results": milestone_results.duplicate(true),
		"failed_reason": failed_reason,
		"acc": acc.duplicate(true),
		"insolvent_since_day": insolvent_since_day,
		"blackout_days": blackout_days.duplicate(),
		"ufls_days": ufls_days.duplicate(),
		"coal_fine_months_billed": coal_fine_months_billed,
		"last_eval_block": _last_eval_block,
	}


func from_dict(state: Dictionary) -> void:
	if data.is_empty():
		load_data()
	active = bool(state.get("active", false))
	era_index = -1  # re-applied below so Dispatch/Economy cfg follow
	milestone_index = int(state.get("milestone_index", 0))
	replay_viewed = bool(state.get("replay_viewed", false))
	fired_events = {}
	for ev_id in state.get("fired_events", []):
		fired_events[str(ev_id)] = true
	milestone_results = (state.get("milestone_results", []) as Array).duplicate(true)
	failed_reason = str(state.get("failed_reason", ""))
	_reset_acc()
	var saved_acc: Dictionary = state.get("acc", {})
	for key: String in saved_acc:
		acc[key] = saved_acc[key]
	insolvent_since_day = float(state.get("insolvent_since_day", -1.0))
	blackout_days = (state.get("blackout_days", []) as Array).duplicate()
	ufls_days = (state.get("ufls_days", []) as Array).duplicate()
	coal_fine_months_billed = int(state.get("coal_fine_months_billed", 0))
	_last_eval_block = int(state.get("last_eval_block", -1))
	if active:
		_apply_era(day_now())
