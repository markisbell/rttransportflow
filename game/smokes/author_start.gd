extends SmokeBase
## --smoke=author_start: PROGRAMMATIC author of the campaign's inherited-2025
## world (golden-style: writes data/campaign/start_2025.json only when the
## file is absent; delete it to re-baseline, then commit both). The build is
## fully deterministic: the trio auto-build plus a wind ring, one pilot
## battery (rationale in campaign_v1.json) and corridors — the salt-cavern
## H2 sites stay EMPTY (the cavern unlock is 2029).

const TAG := "SMOKE_AUTHOR_START"

## The inherited backbone is CONTINENTAL (§5.1: "GridCo Europa inherits the
## continent's backbone"), not a three-city cluster. This is not cosmetic —
## it is what makes milestone 1 physically honest. A 12 GW trio island holds
## ~500 MW of FCR (bands are per-kind fractions of P_n and nuclear does not
## participate by default, ledger 9), so §5.2.1's scripted 1.2 GW trip drove
## it straight through 49.0 Hz into UFLS: the tutorial taught "your grid
## collapses when a unit trips", which is the opposite of the lesson. On the
## ~95 GW mainland the same incident is the 1.3 % event it is meant to be,
## and the FCR/RoCoF numbers the replay panel shows are the ones a real
## interconnected system produces.
##
## Mainland only: the islanded centres (london, stockholm, oslo, athens,
## lisbon, plus Iberia behind the Pyrenees) need submarine/HVDC links, which
## the player unlocks later — they join the synchronous area then.
## Order is geographic: the trunk is laid along this chain, so a scrambled
## list would zig-zag the backbone across the continent.
const CONTINENTAL_CORE: Array[String] = [
	"randstad", "ruhr", "hamburg", "berlin", "prague", "silesia", "warsaw",
	"vienna", "munich", "stuttgart", "frankfurt", "brussels", "paris",
	"lyon", "zurich", "milan",
]


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
	check("no_prebuilt_flex", _count_kind("battery") == 0
		and _count_kind("wind_onshore") == 0)
	check("no_cavern", _count_kind("h2_cavern") == 0)
	_finish(TAG, {"plants": World.plants.size(),
		"corridors": World.corridors.size()})


func _build() -> bool:
	# No pre-placed wind or batteries: they shift mesh flows and pushed a
	# nuclear export spur past the 120 % duty threshold within the first
	# block (found by four event-log hunts). The "modest inherited renewable
	# fleet" of §5.1 is narrative until the corridor-upgrade tool exists;
	# wind and batteries arrive through their unlock years instead.
	return DemoBuild.auto_build(World, CONTINENTAL_CORE)


func _count_kind(kind: String) -> int:
	var count := 0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) == kind:
			count += 1
	return count
