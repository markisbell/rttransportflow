class_name AppPaths
extends RefCounted
## Where the data the game reads from the FILESYSTEM lives — `data/` (map,
## grids, campaign, catalogs) and `orchestration/`.
##
## These are read through absolute paths rather than `res://` because the
## backend must read the same bundles, and a PCK is not a filesystem. In the
## repo they sit beside `game/`; in an exported build they sit beside the
## executable.
##
## The naive idiom `globalize_path("res://").get_base_dir()` is correct in
## the editor and WRONG in an export, where res:// is the PCK — it yielded a
## bare "/data/grids/…" and the packaged game booted to an empty world
## (caught by the P10 package verification, which plays the bundle instead
## of just listing its files). One helper, used everywhere, so the two cases
## cannot drift apart again.
static func root() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").rstrip("/").get_base_dir()
	return OS.get_executable_path().get_base_dir()
