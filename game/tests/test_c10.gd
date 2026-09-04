extends GdUnitTestSuite
## C10 — the campaign-completion / closing-screen path (§5.2.7). The finale
## (last milestone) evaluating emits campaign_complete once with the aggregate
## stars, and latches the campaign TERMINAL — a completed campaign no longer
## accumulates and can no longer be dismissed/insolvent/coal-fined. This path
## had never executed before C10. Autoloads are singletons — snapshot/restore.

const IDS := ["take_the_reins", "merit_order", "green_gigawatts",
	"dunkelflaute", "coal_exit", "hydrogen_loop"]  # M1..M6 (M7 added by eval)
const STARS := [3, 5, 6, 3, 0, 0]  # as shipped: M2 ★5 / M3 ★6 / M4 ★3; M5/M6 mechanic

var _econ_snapshot := {}
var _completes: Array = []


func before_test() -> void:
	_econ_snapshot = Economy.to_dict()
	_completes = []
	Campaign.campaign_complete.connect(_on_complete)


func after_test() -> void:
	if Campaign.campaign_complete.is_connected(_on_complete):
		Campaign.campaign_complete.disconnect(_on_complete)
	Economy.from_dict(_econ_snapshot)
	Campaign.active = false
	Campaign.failed_reason = ""
	Campaign._complete = false
	Campaign.milestone_results = []
	World.plants.clear()
	GameClock.t_sim = 0.0


func _on_complete(results: Array, total: int, maxs: int) -> void:
	_completes.append({"n": results.size(), "total": total, "max": maxs})


## Drive the campaign to its finale (M7 window close) with M1–M6 already
## recorded; the completion signal fires once with the aggregate stars, the
## index lands past the last milestone, and the campaign latches terminal.
func _seed_at_finale() -> void:
	Campaign.load_data()
	Campaign.start_campaign()
	Campaign.milestone_index = 6  # M7 (inverter_grid), window [144,180]
	Campaign._reset_acc()
	Campaign.milestone_results = []
	for i in IDS.size():
		Campaign.milestone_results.append(
			{"id": IDS[i], "passed": STARS[i] > 0, "stars": STARS[i]})
	GameClock.t_sim = 180.0 * 86400.0  # M7 window closes at day 180


func test_campaign_complete_fires_on_finale() -> void:
	_seed_at_finale()
	Campaign._evaluate_milestone(180.0)
	assert_int(_completes.size()).is_equal(1)
	# M7 (inverter_grid) fails its own rubric → 0 stars, appended as the 7th
	assert_int(int(_completes[0]["n"])).is_equal(7)
	assert_int(int(_completes[0]["total"])).is_equal(3 + 5 + 6 + 3)  # 17
	var expect_max := 0
	for id: String in IDS + ["inverter_grid"]:
		expect_max += Campaign.stars_max(id)
	assert_int(int(_completes[0]["max"])).is_equal(expect_max)
	assert_bool(Campaign._complete).is_true()
	assert_int(Campaign.milestone_index).is_equal(7)


## Re-evaluating past the finale does not re-emit (current_milestone() empty).
func test_completion_no_double_fire() -> void:
	_seed_at_finale()
	Campaign._evaluate_milestone(180.0)
	Campaign._evaluate_milestone(180.0)
	Campaign._evaluate_milestone(181.0)
	assert_int(_completes.size()).is_equal(1)


## A completed campaign is TERMINAL: _check_failures early-returns, so a
## post-finale insolvency cannot dismiss it; _complete round-trips a save.
func test_completed_campaign_is_terminal() -> void:
	_seed_at_finale()
	Campaign._evaluate_milestone(180.0)
	Campaign.failed_reason = ""
	Economy.treasury_eur = -5.0e9  # well past the -2 B€ insolvency line
	Campaign.insolvent_since_day = 100.0  # already "insolvent" for 80 days
	Campaign._check_failures(180.0)
	assert_str(Campaign.failed_reason).is_equal("")  # terminal — not dismissed
	# _complete survives save/load (else a reload resumes a finished campaign)
	var state := Campaign.to_dict()
	Campaign._complete = false
	Campaign.from_dict(state)
	assert_bool(Campaign._complete).is_true()


## Every step-driven path is safe with milestone_index past the last milestone,
## and none spuriously emits completion.
func test_out_of_range_milestone_index_safe() -> void:
	Campaign.load_data()
	Campaign.start_campaign()
	Campaign.milestone_index = 7  # == milestones.size()
	Campaign._reset_acc()
	assert_bool(Campaign.current_milestone().is_empty()).is_true()
	Campaign._fire_scripted(180.0)
	Campaign._maybe_autosave(180.0)
	Campaign._evaluate_milestone(180.0)
	Campaign._accumulate({"events": [], "zones": {}, "islands": {},
		"devices": {}, "dt_done_s": 60.0}, 180.0)
	assert_int(_completes.size()).is_equal(0)  # no spurious emit


## stars_max is the ONE source (panel + completion aggregate both read it):
## M7 grades two axes (clean + reliability) → 6.
func test_stars_max_single_source() -> void:
	Campaign.load_data()
	assert_int(Campaign.stars_max("inverter_grid")).is_equal(6)
	assert_int(Campaign.stars_max("take_the_reins")).is_greater(0)
	assert_int(Campaign.stars_max("nonexistent")).is_equal(3)  # safe default
