class_name FleetQuery
extends RefCounted
## Wire-device queries over a result frame's devices block. The
## sync-unit-vs-converter convention ("synchronous devices carry
## headroom_mw; converters don't") is a wire-contract fact that was encoded
## in four drifted scans (sandbox button, HUD debug key, campaign scripted
## events, smoke base). ONE rule; ties broken deterministically.


## Online synchronous units, largest-first; ties by pid.
static func online_sync_ranked(devices: Dictionary) -> Array:
	var sync: Array = []
	for pid: String in devices:
		var device: Dictionary = devices[pid]
		if str(device.get("state", "")) == "online" and device.has("headroom_mw"):
			sync.append([Wire.numf(device, "p_mw", 0.0), pid])
	sync.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] > b[0] or (a[0] == b[0] and str(a[1]) < str(b[1])))
	var out: Array = []
	for entry: Array in sync:
		out.append(entry[1])
	return out


## The online sync unit whose output is nearest `target_mw` — campaign
## scripted-event victim selection, comparator VERBATIM (nearest |p−target|,
## ties to the LARGER p, zero-output units excluded): the milestone-1 nadir
## and star rubric hang off this choice staying deterministic.
static func unit_nearest_mw(devices: Dictionary, target_mw: float) -> String:
	var best := ""
	var best_key := INF
	var best_p := -1.0
	for pid: String in devices:
		var device: Dictionary = devices[pid]
		if str(device.get("state", "")) != "online" or not device.has("headroom_mw"):
			continue
		var p: float = Wire.numf(device, "p_mw", 0.0)
		if p <= 0.0:
			continue
		var key := absf(p - target_mw)
		if key < best_key or (key == best_key and p > best_p):
			best_key = key
			best_p = p
			best = pid
	return best
