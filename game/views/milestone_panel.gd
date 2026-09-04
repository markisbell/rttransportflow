extends Control
## Milestone summary + era toast (C2). A full-rect mouse-transparent layer
## holding (a) the centered summary panel shown on milestone_passed /
## milestone_failed / campaign_failed — with Retry wired to the §5.3/D7
## window-open autosave — and (b) the top-center era toast that makes the
## CO2 ratchet VISIBLE (a repricing the player cannot see defeats M2's
## lesson). Progression stays non-blocking (D7): Continue just closes.
## No class_name (the sandbox_panel headless-cache lesson).

var _panel: PanelContainer
var _title: Label
var _body: Label
var _retry: Button
var _retry_index := -1  # which milestone's autosave Retry loads
var _toast: Label
var _toast_tween: Tween


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", _style())
	add_child(_panel)

	var stack := VBoxContainer.new()
	stack.custom_minimum_size = Vector2(360, 0)
	stack.add_theme_constant_override("separation", 8)
	_panel.add_child(stack)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_title)
	_body = Label.new()
	_body.add_theme_font_size_override("font_size", 13)
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	stack.add_child(row)
	_retry = Button.new()
	_retry.text = "Retry milestone"
	_retry.focus_mode = Control.FOCUS_NONE
	_retry.pressed.connect(_on_retry)
	row.add_child(_retry)
	var cont := Button.new()
	cont.text = "Continue"
	cont.focus_mode = Control.FOCUS_NONE
	cont.pressed.connect(func() -> void: _panel.visible = false)
	row.add_child(cont)

	_toast = Label.new()
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.anchor_top = 0.0
	_toast.anchor_bottom = 0.0
	_toast.offset_top = 64.0
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.add_theme_font_size_override("font_size", 16)
	_toast.modulate = Color(1.0, 0.85, 0.4, 0.0)
	add_child(_toast)

	Campaign.milestone_passed.connect(_on_passed)
	Campaign.milestone_failed.connect(_on_failed)
	Campaign.campaign_failed.connect(_on_campaign_failed)
	Campaign.campaign_complete.connect(_on_campaign_complete)
	Campaign.era_changed.connect(_on_era)


func _milestone_title(id: String) -> String:
	for milestone: Dictionary in Campaign.data.get("milestones", []):
		if str(milestone.get("id", "")) == id:
			return str(milestone.get("title", id))
	return id


func _stars_max(id: String) -> int:
	return Campaign.stars_max(id)  # ONE source (C10)


func _on_passed(id: String, stars: int) -> void:
	_title.text = _milestone_title(id)
	_body.text = "Milestone passed — %d/%d ★" % [stars, _stars_max(id)]
	_retry.visible = false
	_panel.visible = true


func _on_failed(id: String, reason: String) -> void:
	_title.text = _milestone_title(id)
	_body.text = "Milestone failed — first unmet: %s\n(progression continues; stars are lost)" % reason
	# the FAILED milestone's slot, not the current one — the next window
	# opens (and autosaves) one block after the failure
	_retry_index = Campaign.index_of(id)
	_retry.visible = FileAccess.file_exists(Campaign.autosave_file(_retry_index))
	_panel.visible = true


func _on_campaign_failed(reason: String) -> void:
	_title.text = "Campaign over"
	_body.text = "GridCo Europa: %s" % reason
	_retry_index = Campaign.milestone_index
	_retry.visible = FileAccess.file_exists(Campaign.autosave_file(_retry_index))
	_panel.visible = true


## C10 closing screen (§5.2.7): the finale evaluated — roll up every
## milestone's stars. Honest, not celebratory: it renders whatever was earned
## (M5/M6/M7 ship as mechanic gates and M7 fails its own rubric — the screen
## shows that, it does not hide it). Retry hidden; the star-summary IS the
## closing screen (a replay-driven cinematic is a later look pass, D9).
func _on_campaign_complete(results: Array, total: int, maxs: int) -> void:
	_title.text = "Campaign complete"
	var lines := PackedStringArray()
	for r: Dictionary in results:
		var id := str(r.get("id", ""))
		lines.append("%s — %d/%d ★" % [_milestone_title(id),
			int(r.get("stars", 0)), _stars_max(id)])
	lines.append("")
	lines.append("GridCo Europa — %d/%d ★" % [total, maxs])
	_body.text = "\n".join(lines)
	_retry.visible = false
	_panel.visible = true


func _on_retry() -> void:
	_retry.disabled = true
	var res: Dictionary = await Campaign.retry_from_milestone(_retry_index)
	_retry.disabled = false
	if bool(res.get("ok", false)):
		_panel.visible = false
	else:
		_body.text += "\nretry failed: %s" % str(res.get("reason", ""))


func _on_era(era: Dictionary) -> void:
	_toast.text = "%s — CO2 %.0f €/t · tariff %.0f €/MWh" % [
		str(era.get("id", "era")), float(era.get("co2_eur_per_t", 0.0)),
		float(era.get("tariff_eur_per_mwh", 0.0))]
	if _toast_tween != null:
		_toast_tween.kill()
	_toast.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(5.0)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 1.5)


func _style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.11, 0.14, 0.96)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	style.border_color = Color(0.24, 0.27, 0.33)
	style.set_border_width_all(1)
	return style
