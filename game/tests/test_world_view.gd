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
