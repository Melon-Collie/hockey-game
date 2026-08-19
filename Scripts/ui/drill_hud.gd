class_name DrillHUD
extends CanvasLayer

# Shared code-built overlay for the offline drills (mirrors TutorialHUD's
# approach so there's no scene file to hand-edit): a compact top-right tracker
# shows the shot count and score; a centre flash calls the result after each
# attempt; a results card at the end offers Try Again or Exit. Subclasses
# supply only the strings — title, hint, flash calls, score noun, verdict —
# and may insert extra tracker rows via _add_tracker_rows (the accuracy
# drill's called-target line). The drill manager drives everything through
# the public API below.

signal retry_pressed
signal exit_pressed
# The in-play "Skip" control: abandon the current attempt and move on. Opt-in
# (hidden until enable_skip()) so drills that want an escape hatch — e.g. the
# passing drill, where a fumbled rep can leave the puck out of reach — surface
# one without forcing it on every drill.
signal skip_pressed

var _shot_label: Label = null
var _score_label: Label = null
var _flash_label: Label = null
var _flash_card: Control = null
var _results_panel: Control = null
var _results_heading: Label = null
var _results_sub: Label = null
var _skip_btn: Button = null
var _skip_enabled: bool = false

const _GREEN: Color = Color(0.3, 1.0, 0.45, 0.9)
const _RED: Color = Color(1.0, 0.42, 0.4, 0.9)


func _init() -> void:
	layer = 50


func _ready() -> void:
	_build_tracker()
	_build_flash()
	_build_results_panel()


# ── Subclass hooks ────────────────────────────────────────────────────────────
# The strings that make each drill's HUD its own. Every drill overrides these;
# the defaults exist only so a bare DrillHUD still renders something sensible.

# Tracker heading, e.g. "PENALTY SHOTS".
func _title() -> String:
	return "DRILL"


# One-line coaching hint under the tracker; "" hides the row.
func _hint() -> String:
	return ""


# Score-row noun: "<noun>: 3" while staging, "<noun>: 3 / 5" after a result.
func _score_noun() -> String:
	return "Scored"


func _success_flash() -> String:
	return "GOAL!"


func _fail_flash() -> String:
	return "MISS"


# A little flavour line for the results card, scaled to the score.
func _verdict(makes: int, total: int) -> String:
	return "%d of %d." % [makes, total]


# Extra tracker rows inserted between the title and the shot counter (e.g.
# the accuracy drill's called-target line). Default: none.
func _add_tracker_rows(_vbox: VBoxContainer) -> void:
	pass


# ── Construction ──────────────────────────────────────────────────────────────

func _build_tracker() -> void:
	# Compact panel pinned top-right, clear of the bottom HUD (same placement
	# as TutorialHUD).
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
	title.text = _title()
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	vbox.add_child(title)

	_add_tracker_rows(vbox)

	_shot_label = Label.new()
	_shot_label.add_theme_font_size_override("font_size", 20)
	_shot_label.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(_shot_label)

	_score_label = Label.new()
	_score_label.add_theme_font_size_override("font_size", 15)
	_score_label.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	vbox.add_child(_score_label)

	if _hint() != "":
		var hint := Label.new()
		hint.text = _hint()
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(hint)

	# In-play escape hatch, hidden until enable_skip(). Sits under the tracker so
	# it's reachable during play but out of the way; toggled off while the
	# results card is up (that card owns its own buttons).
	_skip_btn = Button.new()
	_skip_btn.text = "Skip ▸"
	_skip_btn.add_theme_font_size_override("font_size", 12)
	_skip_btn.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_skip_btn.visible = false
	_skip_btn.pressed.connect(func() -> void: skip_pressed.emit())
	SoundManager.wire_button(_skip_btn)
	vbox.add_child(_skip_btn)


func _build_flash() -> void:
	# A broadcast-style verdict card in the same visual language as the faceoff
	# "2 → 1 → DROP!" countdown chyron: a BROADCAST_BG panel with 4px rounded
	# corners, sat in the lower-centre so it doesn't cover the net — a result
	# reads as HUD chrome, not stray text.
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(4)
	style.anti_aliasing = false
	style.set_content_margin(SIDE_LEFT, 40)
	style.set_content_margin(SIDE_RIGHT, 40)
	style.set_content_margin(SIDE_TOP, 16)
	style.set_content_margin(SIDE_BOTTOM, 16)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)

	_flash_label = Label.new()
	_flash_label.add_theme_font_size_override("font_size", 60)
	_flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_flash_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(_flash_label)

	# Bottom-centre band, mirroring the faceoff banner's placement (clear of the
	# top-right tracker and the goal mouth).
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	root.offset_top = -260.0
	root.offset_bottom = -100.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centering.add_child(MenuStyle.wrap_drop_shadow(panel, Vector2(5, 5)))
	root.add_child(centering)

	_flash_card = root
	_flash_card.visible = false
	add_child(_flash_card)


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

# Reveal the in-play Skip button (opt-in per drill). Idempotent.
func enable_skip() -> void:
	_skip_enabled = true
	if _skip_btn != null:
		_skip_btn.visible = true


func set_progress(attempt_number: int, total: int, makes: int) -> void:
	_flash_card.visible = false
	_shot_label.text = "Shot %d / %d" % [attempt_number, total]
	_score_label.text = "%s: %d" % [_score_noun(), makes]
	if _skip_btn != null:
		_skip_btn.visible = _skip_enabled


func flash_result(made: bool, makes: int, attempts_taken: int) -> void:
	_flash_label.text = _success_flash() if made else _fail_flash()
	_flash_label.add_theme_color_override("font_color", _GREEN if made else _RED)
	_flash_card.visible = true
	_score_label.text = "%s: %d / %d" % [_score_noun(), makes, attempts_taken]


func show_results(makes: int, total: int) -> void:
	_flash_card.visible = false
	_results_heading.text = "%d / %d" % [makes, total]
	_results_sub.text = _verdict(makes, total)
	_results_panel.visible = true
	# The results card owns Try Again / Exit; the in-play Skip would just clutter.
	if _skip_btn != null:
		_skip_btn.visible = false
	# Controller: land on Try Again (the card's first focusable). Skip is hidden
	# above, so nothing behind the card can take focus and no wall is needed.
	ControllerNav.focus_first(_results_panel)


func hide_results() -> void:
	_results_panel.visible = false
	if _skip_btn != null:
		_skip_btn.visible = _skip_enabled


func _unhandled_input(event: InputEvent) -> void:
	# All popups must close on Escape; here Escape on the results card bails to
	# free play (the same as the Exit button).
	if _results_panel != null and _results_panel.visible and event.is_action_pressed("ui_cancel"):
		exit_pressed.emit()
		get_viewport().set_input_as_handled()
