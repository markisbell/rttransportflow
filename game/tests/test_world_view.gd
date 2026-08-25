extends GdUnitTestSuite
## WorldView3D.fog_band() invariants — the structural guard against fog
## incident #3. Two incidents so far: exponential fog veiled the whole ortho
## scene (UI overhaul), and a rewritten depth band that dropped the STANDOFF
## base fogged 100 % of every frame (2026-08-20). Both were hand-tuned
## constants silently encoding camera geometry; fog_band() derives the band
## from the NAMED geometry instead, and these pins state what "correct"
## means at every zoom the camera can reach.

const WorldViewScript := preload("res://views/world_view_3d.gd")

## Boot zoom, the campaign default 44, the city-detail edge, MIN and MAX.
const ZOOMS: Array[float] = [5.0, 17.0, 44.0, 70.0, 120.0]


## C2: the pin hit box derives from projected geometry, never fixed pixels
## (the ±16/−40 px box was 1080p-only and made bird-zoom charts feel
## unclickable on larger viewports). Invariants at representative pin
## screen heights: full pin coverage with padding, finger-size floor.
func test_pin_hit_rect_invariants() -> void:
	for pin_h: float in [8.0, 24.0, 35.0, 47.0, 71.0, 140.0]:
		var anchor := Vector2(500.0, 400.0)
		var rect: Rect2 = WorldViewScript.pin_hit_rect(anchor, anchor.y - pin_h)
		var ctx := "pin_h %.0f" % pin_h
		# the whole pin, tip to head, is inside the box
		assert_bool(rect.has_point(anchor)).override_failure_message(
			"%s: tip not clickable" % ctx).is_true()
		assert_bool(rect.has_point(Vector2(anchor.x, anchor.y - pin_h))) \
			.override_failure_message("%s: head not clickable" % ctx).is_true()
		# never below finger size, in either axis
		assert_bool(rect.size.x >= 24.0 and rect.size.y >= 24.0) \
			.override_failure_message("%s: below finger size" % ctx).is_true()
		# horizontally centred on the pin
		assert_float(rect.get_center().x).is_equal_approx(anchor.x, 0.001)


## C2: the strategic chart scale is 1.0 through the model band, grows
## continuously above it, and caps at 1.7 at MAX_ZOOM.
func test_chart_scale_band() -> void:
	assert_float(WorldViewScript.chart_scale(17.0)).is_equal(1.0)
	assert_float(WorldViewScript.chart_scale(
		WorldViewScript.MODEL_DETAIL_MAX_SIZE)).is_equal(1.0)
	# continuity at the band edge
	assert_float(WorldViewScript.chart_scale(
		WorldViewScript.MODEL_DETAIL_MAX_SIZE + 0.01)).is_equal_approx(1.0, 0.001)
	var mid: float = WorldViewScript.chart_scale(70.0)
	assert_bool(mid > 1.0 and mid < 1.7).is_true()
	assert_float(WorldViewScript.chart_scale(WorldViewScript.MAX_ZOOM)) \
		.is_equal_approx(1.7, 0.001)
	# monotone above the band
	assert_bool(WorldViewScript.chart_scale(110.0) > mid).is_true()


func test_fog_band_invariants() -> void:
	for zoom: float in ZOOMS:
		var band: Vector2 = WorldViewScript.fog_band(zoom)
		# Visible ground depth spans STANDOFF ± half (see PITCH_RATIO doc).
		var half: float = 0.5 * zoom / WorldViewScript.PITCH_RATIO
		# A ground point r world units past the focus along view-forward sits
		# at depth STANDOFF + r·cos(pitch); the streamed ring reaches
		# zoom·VIEW_MARGIN + CHUNK, so its edge sits at this depth.
		var ring_edge: float = WorldViewScript.STANDOFF \
			+ cos(atan(WorldViewScript.PITCH_RATIO)) \
			* (zoom * WorldViewScript.VIEW_MARGIN + WorldViewScript.CHUNK)
		var ctx := "zoom %.0f" % zoom
		# Ordered and open: a degenerate or inverted band is a veil.
		assert_bool(band.x < band.y).override_failure_message(
			"%s: band inverted" % ctx).is_true()
		# The focus plane is NEVER fogged — this is the incident-#2 pin: a
		# band anchored below STANDOFF puts the whole world inside the fog.
		assert_bool(band.x > WorldViewScript.STANDOFF).override_failure_message(
			"%s: fog begins before the focus plane (the 100%%-haze bug)" % ctx
		).is_true()
		# Haze must be VISIBLE: begin inside the frame's ground span…
		assert_bool(band.x < WorldViewScript.STANDOFF + half).override_failure_message(
			"%s: fog begins past the frame edge — no depth cue at all" % ctx
		).is_true()
		# …and full opacity only PAST the frame edge (the frame is never
		# fully fogged)…
		assert_bool(band.y > WorldViewScript.STANDOFF + half).override_failure_message(
			"%s: full opacity inside the frame" % ctx).is_true()
		# …but before the streamed ring's edge, so the detail-to-coarse
		# handover always happens under full fog.
		assert_bool(band.y <= ring_edge).override_failure_message(
			"%s: fog ends past the ring edge (%.1f > %.1f) — the seam shows"
			% [zoom, band.y, ring_edge]).is_true()
		# And inside the camera's depth range (far = 2000 in _build_camera).
		assert_bool(band.y < 2000.0).override_failure_message(
			"%s: band exceeds camera.far" % ctx).is_true()


func test_drag_pan_geometry() -> void:
	var vh := 800.0
	var zoom := 50.0
	# Horizontal: one pixel is zoom/viewport_h world units; cursor right
	# drags the ground right, so the focus moves LEFT (-x at yaw 0).
	var h: Vector3 = WorldViewScript.drag_pan(Vector2(100, 0), 0.0, zoom, vh)
	assert_float(h.x).is_equal_approx(-100.0 * zoom / vh, 1e-4)
	assert_float(h.y).is_equal_approx(0.0, 1e-9)
	assert_float(h.z).is_equal_approx(0.0, 1e-9)
	# Vertical: a full-frame drag (viewport_h px) covers the frame's whole
	# ground span, zoom/sin(pitch) — the slanted-cut factor the fog band's
	# geometry note derives.
	var pr: float = WorldViewScript.PITCH_RATIO
	var sin_pitch := pr / sqrt(1.0 + pr * pr)
	var v: Vector3 = WorldViewScript.drag_pan(Vector2(0, vh), 0.0, zoom, vh)
	assert_float(v.length()).is_equal_approx(zoom / sin_pitch, 1e-4)
	# cursor down -> ground follows toward the camera -> focus moves away
	assert_float(v.z).is_less(0.0)
	assert_float(v.x).is_equal_approx(0.0, 1e-9)


func test_drag_pan_rotates_with_the_view() -> void:
	# The same drag pans the same SCREEN direction at every yaw: magnitude
	# is yaw-invariant, and the yaw-90 result is the yaw-0 result swung a
	# quarter turn about UP.
	var a: Vector3 = WorldViewScript.drag_pan(Vector2(60, -40), 0.0, 30.0, 800.0)
	var b: Vector3 = WorldViewScript.drag_pan(Vector2(60, -40), 90.0, 30.0, 800.0)
	assert_float(b.length()).is_equal_approx(a.length(), 1e-4)
	assert_float((a.rotated(Vector3.UP, deg_to_rad(90.0)) - b).length()) \
		.is_equal_approx(0.0, 1e-4)


func test_fog_band_monotone_in_zoom() -> void:
	# Zooming out widens the visible span, so the band must widen with it —
	# a constant band would re-create the veil at some zoom.
	var prev: Vector2 = WorldViewScript.fog_band(ZOOMS[0])
	for i in range(1, ZOOMS.size()):
		var band: Vector2 = WorldViewScript.fog_band(ZOOMS[i])
		assert_bool(band.x > prev.x and band.y > prev.y).override_failure_message(
			"band not strictly widening from zoom %.0f to %.0f"
			% [ZOOMS[i - 1], ZOOMS[i]]).is_true()
		prev = band
