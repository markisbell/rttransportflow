class_name SiteNote
extends Node3D
## A floating note anchored above a city or plant: name + the weekly
## ZoneChart, rendered into a SubViewport once per refresh and shown as a
## billboarded sprite. The viewport renders ONCE per refresh (UPDATE_ONCE),
## so a resident note costs nothing per frame; the world view refreshes
## visible notes when the 15-min block advances.

const ZONE_SIZE := Vector2i(460, 260)
const PLANT_SIZE := Vector2i(360, 200)

var chart: ZoneChart
var _viewport: SubViewport
var _sprite: Sprite3D


static func for_zone(zone_id: String) -> SiteNote:
	var note := SiteNote.new()
	note._setup(ZONE_SIZE)
	note.chart.zone_id = zone_id
	return note


static func for_plant(pid: String, kind: String) -> SiteNote:
	var note := SiteNote.new()
	note._setup(PLANT_SIZE)
	note.chart.pid = pid
	note.chart.plant_kind = kind
	return note


func _setup(view_size: Vector2i) -> void:
	_viewport = SubViewport.new()
	_viewport.size = view_size
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_viewport)
	chart = ZoneChart.new()
	chart.size = Vector2(view_size)
	_viewport.add_child(chart)
	_sprite = Sprite3D.new()
	_sprite.texture = _viewport.get_texture()
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.no_depth_test = true
	_sprite.shaded = false
	_sprite.render_priority = 20
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	# bottom-center sits on this node's origin, so the anchor "points" at
	# the site and scaling never sinks the note into the terrain
	_sprite.offset = Vector2(0, view_size.y / 2.0)
	add_child(_sprite)


func refresh() -> void:
	chart.refresh()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Keep the note a constant SCREEN size: world size tracks the ortho zoom.
func apply_zoom(zoom: float) -> void:
	_sprite.pixel_size = zoom * 0.00082
