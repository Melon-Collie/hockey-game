class_name PenaltyDrillHUD
extends CanvasLayer

# Code-built overlay for the penalty-shot drill (mirrors TutorialHUD's approach
# so there's no scene file to hand-edit). A compact top-right tracker shows the
# shot count and makes; a centre flash calls GOAL! / NO GOAL after each attempt;
# a results card at the end offers Try Again or Exit. PenaltyDrillManager drives
# all of it.

signal retry_pressed
signal exit_pressed

var _shot_label: Label = null
var _scored_label: Label = null
var _flash_label: Label = null
var _results_panel: Control = null
var _results_heading: Label = null
var _results_sub: Label = null

const _GREEN: Color = Color(0.3, 1.0, 0.45, 0.9)
const _RED: Color = Color(1.0, 0.42, 0.4, 0.9)


func _init() -> void:
	layer = 50


func _ready() -> void:
	_build_tracker()
	_build_flash()
	_build_results_panel()


func _build_tracker() -> void:
	# Compact panel pinned top-right, clear of the bottom HUD (same placement as
	# TutorialHUD).
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(6, 14))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_END
	panel.offset_right = -12.0
	panel.offset_top = 12.0
	panel.custom_minimum_size = Vector2(260.0, 0.0)
	add_child(panel)

	var inner := MarginContainer.new()
	inner.add_theme_constant_override("margin_left", 14)
	inner.add_theme_constant_override("margin_right", 14)
	inner.add_theme_constant_override("margin_top", 10)
	inner.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(inner)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	inner.add_child(vbox)

	var title := Label.new()
	title.text = "PENALTY SHOTS"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	vbox.add_child(title)

	_shot_label = Label.new()
	_shot_label.add_theme_font_size_override("font_size", 20)
	_shot_label.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(_shot_label)

	_scored_label = Label.new()
	_scored_label.add_theme_font_size_override("font_size", 15)
	_scored_label.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	vbox.add_child(_scored_label)

	var hint := Label.new()
	hint.text = "Skate in and beat the goalie."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)


func _build_flash() -> void:
	_flash_label = Label.new()
	_flash_label.add_theme_font_size_override("font_size", 72)
	_flash_label.set_anchors_preset(Control.PRESET_CENTER)
	_flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_flash_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_label.visible = false
	add_child(_flash_label)


func _build_results_panel() -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.7)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(8, 40))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	panel.add_child(vbox)

	_results_heading = Label.new()
	_results_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_results_heading.add_theme_font_size_override("font_size", 48)
	_results_heading.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	vbox.add_child(_results_heading)

	_results_sub = Label.new()
	_results_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_results_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_results_sub.custom_minimum_size = Vector2(420, 0)
	_results_sub.add_theme_font_size_override("font_size", 16)
	_results_sub.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	vbox.add_child(_results_sub)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var retry_btn := MenuStyle.popup_button("Try Again")
	retry_btn.pressed.connect(func() -> void: retry_pressed.emit())
	btn_row.add_child(retry_btn)

	var exit_btn := Button.new()
	exit_btn.text = "Exit to Free Play"
	exit_btn.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	exit_btn.pressed.connect(func() -> void: exit_pressed.emit())
	SoundManager.wire_button(exit_btn)
	btn_row.add_child(exit_btn)

	_results_panel = Control.new()
	_results_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_results_panel.visible = false
	_results_panel.add_child(overlay)
	_results_panel.add_child(panel)
	add_child(_results_panel)


# ── Public API ────────────────────────────────────────────────────────────────

func set_progress(attempt_number: int, total: int, makes: int) -> void:
	_flash_label.visible = false
	_shot_label.text = "Shot %d / %d" % [attempt_number, total]
	_scored_label.text = "Scored: %d" % makes


func flash_result(made: bool, makes: int, attempts_taken: int) -> void:
	_flash_label.text = "GOAL!" if made else "NO GOAL"
	_flash_label.add_theme_color_override("font_color", _GREEN if made else _RED)
	_flash_label.visible = true
	_scored_label.text = "Scored: %d / %d" % [makes, attempts_taken]


func show_results(makes: int, total: int) -> void:
	_flash_label.visible = false
	_results_heading.text = "%d / %d" % [makes, total]
	_results_sub.text = _verdict(makes, total)
	_results_panel.visible = true


func hide_results() -> void:
	_results_panel.visible = false


# A little flavour line scaled to how many went in.
func _verdict(makes: int, total: int) -> String:
	if makes == total:
		return "Perfect — you buried every one. Lights out."
	if makes == 0:
		return "Robbed every time. The goalie wins this round."
	if makes * 2 >= total:
		return "Solid shooting. The goalie got a few of them."
	return "A few found the net. Run it back and sharpen up."


func _unhandled_input(event: InputEvent) -> void:
	# All popups must close on Escape; here Escape on the results card bails to
	# free play (the same as the Exit button).
	if _results_panel != null and _results_panel.visible and event.is_action_pressed("ui_cancel"):
		exit_pressed.emit()
		get_viewport().set_input_as_handled()
