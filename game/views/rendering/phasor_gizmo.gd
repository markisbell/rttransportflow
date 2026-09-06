extends Object
## Per-machine rotor-angle phasor gizmo (phasor arc P3, ledger 56): a clock
## hand floating above a synchronous plant. Its heading is the machine's rotor
## angle in the island centre-of-inertia frame (delta_rad from the wire); its
## colour is the speed slip from that COI (green when synced, hot while
## slipping). When the grid is STEADY every hand sits still at its equilibrium
## angle; on a trip the hands swing AGAINST each other — high-inertia
## synchronous machines fan slowly and coherently, a low-inertia inverter
## grid's few sync machines snap and oscillate wildly, and storage-backed
## inertia damps the spread. That contrast is the whole point of the arc.
## No class_name (the headless-cache lesson).

const HAND_LEN := 1100.0    # world units (5 km tiles) — a visible needle
const HEIGHT := 2600.0       # float above the plant model
const SLIP_HOT_HZ := 0.4     # |slip| Hz at which the hand reads fully "slipping"
const SYNCED := Color(0.25, 0.9, 0.45)
const SLIPPING := Color(1.0, 0.3, 0.15)


static func make() -> Node3D:
	var pivot := Node3D.new()
	pivot.position = Vector3(0.0, HEIGHT, 0.0)
	var hand := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(HAND_LEN, HAND_LEN * 0.1, HAND_LEN * 0.1)
	hand.mesh = mesh
	hand.position = Vector3(HAND_LEN * 0.5, 0.0, 0.0)  # pivot at one end
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color_for_slip(0.0)
	hand.material_override = mat
	pivot.add_child(hand)
	pivot.set_meta("hand", hand)
	return pivot


## green (synced) -> amber -> red (slipping); |slip| in Hz.
static func color_for_slip(slip_hz: float) -> Color:
	var t := clampf(absf(slip_hz) / SLIP_HOT_HZ, 0.0, 1.0)
	return SYNCED.lerp(SLIPPING, t)


## Point the hand at the rotor angle (the map plane is XZ, so rotate about the
## vertical Y axis) and recolour it by the slip. NaN/null-safe — a machine
## orphaned by a mid-step split may read a null angle on the wire.
static func apply(pivot: Node3D, delta_rad: float, slip_hz: float) -> void:
	if not is_finite(delta_rad):
		return
	pivot.rotation.y = -delta_rad
	var hand: MeshInstance3D = pivot.get_meta("hand")
	if hand != null:
		(hand.material_override as StandardMaterial3D).albedo_color = \
			color_for_slip(slip_hz if is_finite(slip_hz) else 0.0)
