class_name Advisor
extends RefCounted
## Adequacy advisor (GAME_DESIGN §4.6, P8 subset): per-step N-1 assessment
## from the latest wire result. Computes the REFERENCE INCIDENT —
## max(largest online synchronous unit, largest offshore-hub delivery), the
## player's self-made contingency (ledger 27/28) — then checks it against
## (a) committed fleet FCR headroom (the P3 lesson: dispatching at ~P_max
## silently eats the primary-response band) and (b) island inertia (the
## RoCoF that losing it would cause). Never acts — the player is the
## operator. Forward-looking 24 h projection is a campaign (P9) refinement.

const F0 := 50.0
const ROCOF_WARN_HZ_S := 0.5


## Returns at most two short advisory lines ([] = adequate).
static func assess(result: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var devices: Dictionary = result.get("devices", {})
	if devices.is_empty():
		return lines

	# reference incident: largest online sync unit vs largest hub delivery
	var incident := 0.0
	var incident_id := ""
	var headroom := 0.0
	var hub_ids := {}
	for dev: Dictionary in Boundary.wire_devices:
		if str(dev.get("kind", "")) == "offshore_hub":
			hub_ids[str(dev.get("id", ""))] = true
	for pid: String in devices:
		var device: Dictionary = devices[pid]
		if str(device.get("state", "")) != "online":
			continue
		var p := _numf(device, "p_mw", 0.0)
		if device.has("headroom_mw"):  # synchronous units carry headroom
			headroom += _numf(device, "headroom_mw", 0.0)
			if p > incident:
				incident = p
				incident_id = pid
		elif hub_ids.has(pid) and p > incident:
			incident = p
			incident_id = pid + " (hub)"
	if incident < 1.0:
		return lines

	# (a) N-1 headroom: can the surviving fleet even cover the loss?
	if headroom < incident:
		lines.append("ADVISOR under-secured: losing %s (%d MW) exceeds fleet headroom %d MW"
			% [incident_id, int(incident), int(headroom)])

	# (b) inertia: RoCoF the reference incident would cause on its island
	var worst_rocof := 0.0
	for island_id: String in result.get("islands", {}):
		var island: Dictionary = result["islands"][island_id]
		if bool(island.get("blackout", false)):
			continue
		var e_k := _numf(island, "e_k_mj", 0.0)
		if e_k > 1.0:
			worst_rocof = maxf(worst_rocof, incident * F0 / (2.0 * e_k))
	if worst_rocof >= ROCOF_WARN_HZ_S and lines.size() < 2:
		lines.append("ADVISOR low inertia: a %d MW loss ⇒ RoCoF %.2f Hz/s (DG-trip territory)"
			% [int(incident), worst_rocof])
	return lines


static func _numf(data: Dictionary, key: String, default: float) -> float:
	var value: Variant = data.get(key, default)
	return default if value == null else float(value)
