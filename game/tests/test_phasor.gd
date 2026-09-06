extends GdUnitTestSuite
## Phasor gizmo logic (arc P3, ledger 56): the rotor-angle hand's rotation
## follows delta_rad, its colour follows the slip, and it's NaN/null-safe.

const PhasorGizmo := preload("res://views/rendering/phasor_gizmo.gd")


func test_make_has_a_hand() -> void:
	var pivot: Node3D = PhasorGizmo.make()
	assert_bool(pivot.has_meta("hand")).is_true()
	assert_object(pivot.get_meta("hand")).is_instanceof(MeshInstance3D)
	pivot.free()


func test_color_for_slip_ramps_synced_to_slipping() -> void:
	# synced -> the SYNCED colour; hot slip -> the SLIPPING colour; monotone red
	assert_bool(PhasorGizmo.color_for_slip(0.0).is_equal_approx(
		PhasorGizmo.SYNCED)).is_true()
	assert_bool(PhasorGizmo.color_for_slip(5.0).is_equal_approx(
		PhasorGizmo.SLIPPING)).is_true()
	assert_float(PhasorGizmo.color_for_slip(0.2).r).is_greater(
		PhasorGizmo.color_for_slip(0.05).r)
	# sign-agnostic (|slip|)
	assert_bool(PhasorGizmo.color_for_slip(-0.3).is_equal_approx(
		PhasorGizmo.color_for_slip(0.3))).is_true()


func test_apply_points_the_hand_and_recolours() -> void:
	var pivot: Node3D = PhasorGizmo.make()
	PhasorGizmo.apply(pivot, 0.75, 0.4)
	assert_float(pivot.rotation.y).is_equal_approx(-0.75, 1e-5)
	var hand: MeshInstance3D = pivot.get_meta("hand")
	var col := (hand.material_override as StandardMaterial3D).albedo_color
	assert_bool(col.is_equal_approx(PhasorGizmo.color_for_slip(0.4))).is_true()
	pivot.free()


func test_apply_is_nan_safe() -> void:
	var pivot: Node3D = PhasorGizmo.make()
	pivot.rotation.y = 0.5
	PhasorGizmo.apply(pivot, NAN, 0.1)          # bad angle: no rotation change
	assert_float(pivot.rotation.y).is_equal_approx(0.5, 1e-5)
	PhasorGizmo.apply(pivot, 0.3, NAN)          # bad slip: treated as 0, no crash
	assert_float(pivot.rotation.y).is_equal_approx(-0.3, 1e-5)
	pivot.free()
