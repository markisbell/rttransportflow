extends SmokeBase
## --smoke=author_start: PROGRAMMATIC author of the campaign's inherited-2025
## world (golden-style: writes data/campaign/start_2025.json only when the
## file is absent; delete it to re-baseline, then commit both). The build is
## fully deterministic: the trio auto-build plus a wind ring, one pilot
## battery (rationale in campaign_v1.json) and corridors — the salt-cavern
## H2 sites stay EMPTY (the cavern unlock is 2029).

const TAG := "SMOKE_AUTHOR_START"

func run() -> void:
	if not BuildSession.load_map():
		_fail(TAG, "map load failed")
		return
	var repo := AppPaths.root()
	var path := repo + "/" + Campaign.START_STATE_PATH
	check("build_ok", _build())
	var envelope := World.serialize()
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(envelope, "  ", false, true) + "\n")
		file.close()
		print("AUTHOR_START wrote ", path)
	# byte-stable: a rebuild must serialize identically to the shipped file
	var shipped: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check("golden_matches", shipped is Dictionary
		and JSON.stringify(shipped) == JSON.stringify(JSON.parse_string(
			JSON.stringify(envelope, "  ", false, true))))
	# round-trip: the envelope must restore
	World.clear_build()
	check("restores", World.restore(envelope))
	# the renewable BASE (real onshore wind + solar parks, GPPD) is part
	# of the inherited 2025 world by owner direction (2026-08-22); the
	# FLEX journey — batteries, electrolysis, caverns — stays the player's
	check("no_prebuilt_flex", _count_kind("battery") == 0
		and _count_kind("electrolyzer") == 0)
	check("no_cavern", _count_kind("h2_cavern") == 0)
	_finish(TAG, {"plants": World.plants.size(),
		"corridors": World.corridors.size()})


func _build() -> bool:
	# the world author lives with its owner (Campaign, beside
	# START_STATE_PATH); this smoke is verify-plus-baseline only
	return Campaign.build_inherited_world(World)


func _count_kind(kind: String) -> int:
	var count := 0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == kind:
			count += 1
	return count
