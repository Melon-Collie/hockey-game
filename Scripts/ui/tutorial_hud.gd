class_name TutorialHUD
extends CanvasLayer

const _COMPLETE_FLASH_DURATION: float = 0.6
const _HINT_DELAY: float = 8.0

var _step_label: Label = null
var _title_label: Label = null
var _instruction_label: Label = null
var _objective_label: Label = null
var _alert_label: Label = null
var _hint_label: Label = null
var _reset_btn: Button = null
var _skip_btn: Button = null
var _exit_btn: Button = null
var _complete_flash: ColorRect = null
var _complete_label: Label = null
var _complete_panel: Control = null
var _exit_confirm_panel: Control = null

# Set by TutorialManager._ready() so the HUD knows which id to mark complete
# when the player hits the "Exit Tutorial" button. Defaults to basics so older
# callers (or if the setter is missed) still write a valid entry.
var _tutorial_id: String = TutorialRegistry.BASICS_ID

signal skip_pressed
signal reset_pressed


func _init() -> void:
	layer = 50


func _ready() -> void:
	_build()


func _build() -> void:
	# Compact panel pinned to the top-right corner, clear of all bottom HUD elements.
	# anchor_left = anchor_right = 1.0 pins both edges to the right of the screen;
	# grow_horizontal = GROW_DIRECTION_BEGIN makes the panel extend leftward from there.
	var panel_style := MenuStyle.panel(6, 14)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.anchor_left   = 1.0
	panel.anchor_right  = 1.0
	panel.anchor_top    = 0.0
	panel.anchor_bottom = 0.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical   = Control.GROW_DIRECTION_END
	panel.offset_right  = -12.0
	panel.offset_top    = 12.0
	panel.custom_minimum_size = Vector2(360.0, 0.0)
	add_child(panel)

	var inner := MarginContainer.new()
	inner.add_theme_constant_override("margin_left",   14)
	inner.add_theme_constant_override("margin_right",  14)
	inner.add_theme_constant_override("margin_top",    10)
	inner.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(inner)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	inner.add_child(vbox)

	# Row 1: step counter + skip button
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vbox.add_child(header)

	_step_label = Label.new()
	_step_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_step_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_step_label.add_theme_font_size_override("font_size", 11)
	_step_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	header.add_child(_step_label)

	_reset_btn = Button.new()
	_reset_btn.text = "↺ Reset"
	_reset_btn.pressed.connect(func() -> void: reset_pressed.emit())
	SoundManager.wire_button(_reset_btn)
	header.add_child(_reset_btn)

	_skip_btn = Button.new()
	_skip_btn.text = "Skip →"
	_skip_btn.pressed.connect(func() -> void: skip_pressed.emit())
	SoundManager.wire_button(_skip_btn)
	header.add_child(_skip_btn)

	# "Exit Tutorial" sits next to the per-step Skip but is deliberately worded
	# differently so the player doesn't misclick. Opens a confirmation modal
	# (this is a sticky action — it marks the tutorial complete in PlayerPrefs).
	_exit_btn = Button.new()
	_exit_btn.text = "Exit"
	_exit_btn.pressed.connect(_show_exit_confirm)
	SoundManager.wire_button(_exit_btn)
	header.add_child(_exit_btn)

	# Row 2: step title
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(_title_label)

	# Row 3: instruction text (word-wrapped)
	_instruction_label = Label.new()
	_instruction_label.add_theme_font_size_override("font_size", 13)
	_instruction_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	_instruction_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_instruction_label)

	# Row 4: objective / progress line (e.g. "Targets hit — 1 / 3"). Drill steps
	# set it; teaching steps leave it blank. Brighter than the body so the
	# current goal reads at a glance.
	_objective_label = Label.new()
	_objective_label.add_theme_font_size_override("font_size", 14)
	_objective_label.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	_objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_objective_label.visible = false
	vbox.add_child(_objective_label)

	# Row 4b: corrective alert (amber). Unlike the hint, this shows the instant
	# it's set — used to flag a wrong setup the player should fix now (e.g. the
	# elevation toggle left in the wrong position for the current drill).
	_alert_label = Label.new()
	_alert_label.add_theme_font_size_override("font_size", 13)
	_alert_label.add_theme_color_override("font_color", MenuStyle.GOLD)
	_alert_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_alert_label.visible = false
	vbox.add_child(_alert_label)

	# Row 5: hint (hidden until hint delay expires)
	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", 11)
	_hint_label.add_theme_color_override("font_color", MenuStyle.TEAL_DIM)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.visible = false
	vbox.add_child(_hint_label)

	# Step-complete flash overlay (full screen, semi-transparent green)
	_complete_flash = ColorRect.new()
	_complete_flash.color = Color(0.2, 0.8, 0.3, 0.18)
	_complete_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_complete_flash.visible = false
	_complete_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_complete_flash)

	_complete_label = Label.new()
	_complete_label.text = "✓"
	_complete_label.add_theme_font_size_override("font_size", 64)
	_complete_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.45, 0.85))
	_complete_label.set_anchors_preset(Control.PRESET_CENTER)
	_complete_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_complete_label.visible = false
	add_child(_complete_label)

	# Tutorial-complete panel (hidden until end)
	_build_complete_panel()
	_build_exit_confirm_panel()


func _build_complete_panel() -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.7)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel_style := MenuStyle.panel(8, 40)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	# When there's a follow-up tutorial (finishing Basics), the modal pushes
	# hard into it: the heading names what was just done, the subtitle pitches
	# the next part as part of the same course, and the continue button is the
	# big primary CTA with Free Play demoted to a secondary "skip" link.
	var next_id: String = TutorialRegistry.get_next_id(_tutorial_id)

	var heading := Label.new()
	heading.text = ("%s Complete!" % TutorialRegistry.get_display_name(_tutorial_id)) \
		if next_id != "" else "Tutorial Complete!"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 36)
	heading.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	vbox.add_child(heading)

	var sub := Label.new()
	if next_id != "":
		sub.text = "That's %s done. Up next — %s: %s. Finish the set before you hit the ice." % [
			TutorialRegistry.get_display_name(_tutorial_id),
			TutorialRegistry.get_sequence_label(next_id),
			TutorialRegistry.get_display_name(next_id)]
	else:
		sub.text = "You know the ropes — now get out there."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(440, 0)
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	vbox.add_child(sub)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	if next_id != "":
		# Primary CTA: the big, hover-scaled popup_button so continuing reads as
		# the expected path, not an optional extra the player can overlook.
		var next_btn := MenuStyle.popup_button("Continue → %s: %s" % [
			TutorialRegistry.get_sequence_label(next_id),
			TutorialRegistry.get_display_name(next_id)])
		next_btn.pressed.connect(func() -> void: _on_continue_to_tutorial(next_id))
		btn_row.add_child(next_btn)

		# Demoted bail-out. "Free Play" IS the main menu in this game — Escape
		# from free play opens the SideMenu — so this is the skip-the-rest link.
		var skip_btn := Button.new()
		skip_btn.text = "Skip to Free Play"
		skip_btn.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		skip_btn.pressed.connect(_exit_to_free_play)
		SoundManager.wire_button(skip_btn)
		btn_row.add_child(skip_btn)
	else:
		# Last tutorial in the set — Free Play is the only, primary action.
		var free_play_btn := MenuStyle.popup_button("Free Play")
		free_play_btn.pressed.connect(_exit_to_free_play)
		btn_row.add_child(free_play_btn)

	_complete_panel = Control.new()
	_complete_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_complete_panel.visible = false
	_complete_panel.add_child(overlay)
	_complete_panel.add_child(panel)
	add_child(_complete_panel)


func _build_exit_confirm_panel() -> void:
	# Modal confirmation for the Exit Tutorial button. Mirrors _complete_panel's
	# structure (overlay + centered panel) so the visual treatment matches.
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.7)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(8, 32))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	panel.add_child(vbox)

	var heading := Label.new()
	heading.text = "Exit Tutorial?"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 26)
	heading.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(heading)

	var sub := Label.new()
	sub.text = "You can replay it any time from the menu."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	vbox.add_child(sub)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var keep_btn := Button.new()
	keep_btn.text = "Keep Learning"
	keep_btn.pressed.connect(_on_keep_learning)
	SoundManager.wire_button(keep_btn)
	btn_row.add_child(keep_btn)

	var exit_btn := Button.new()
	exit_btn.text = "Exit"
	exit_btn.pressed.connect(_on_exit_confirmed)
	SoundManager.wire_button(exit_btn)
	btn_row.add_child(exit_btn)

	_exit_confirm_panel = Control.new()
	_exit_confirm_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_exit_confirm_panel.visible = false
	_exit_confirm_panel.add_child(overlay)
	_exit_confirm_panel.add_child(panel)
	add_child(_exit_confirm_panel)


# ── Public API ────────────────────────────────────────────────────────────────


# Called by TutorialManager._ready() so the HUD knows which tutorial id to
# write to PlayerPrefs.mark_tutorial_complete when the player hits Exit.
func set_tutorial_id(id: String) -> void:
	_tutorial_id = id

func set_step(index: int, total: int, title: String, instruction: String, hint: String) -> void:
	_step_label.text = "STEP %d / %d" % [index + 1, total]
	_title_label.text = title
	_instruction_label.text = instruction
	_hint_label.text = hint
	_hint_label.visible = false
	_complete_flash.visible = false
	_complete_label.visible = false
	clear_objective()
	clear_alert()


# Drill steps set a progress / goal line under the instruction (e.g.
# "Targets hit — 1 / 3" or "Score on the open net"). Cleared on every new step.
func set_objective(text: String) -> void:
	if _objective_label == null:
		return
	_objective_label.text = text
	_objective_label.visible = text != ""


func clear_objective() -> void:
	if _objective_label != null:
		_objective_label.text = ""
		_objective_label.visible = false


# Amber corrective prompt shown immediately (vs. the time-delayed hint). Setting
# the same text repeatedly is a no-op-ish cheap write; pass "" / call clear_alert
# to hide it.
func set_alert(text: String) -> void:
	if _alert_label == null:
		return
	_alert_label.text = text
	_alert_label.visible = text != ""


func clear_alert() -> void:
	if _alert_label != null:
		_alert_label.text = ""
		_alert_label.visible = false


func show_hint() -> void:
	_hint_label.visible = true


func flash_complete() -> void:
	_complete_flash.visible = true
	_complete_label.visible = true


func hide_complete_flash() -> void:
	_complete_flash.visible = false
	_complete_label.visible = false


func show_tutorial_complete() -> void:
	_complete_panel.visible = true


# ── Button handlers ───────────────────────────────────────────────────────────

# Tear down the tutorial and drop the player back on the ice in free play.
# Free play is also where Escape opens the SideMenu, so this doubles as the
# "return to main menu" path — there is no separate menu scene.
func _exit_to_free_play() -> void:
	NetworkManager.is_tutorial_mode = false
	GameManager.return_to_free_play()


# One-click continuation into the next tutorial in TutorialRegistry order.
# Same teardown shape as _exit_to_free_play but re-enters Hockey.tscn with
# the new tutorial id staged on NetworkManager.
func _on_continue_to_tutorial(next_id: String) -> void:
	NetworkManager.is_tutorial_mode = false
	GameManager.on_scene_exit()
	NetworkManager.reset()
	NetworkManager.start_tutorial(next_id)
	get_tree().change_scene_to_file(Constants.SCENE_HOCKEY)


# ── Exit-tutorial confirmation handlers ───────────────────────────────────────

func _show_exit_confirm() -> void:
	if _exit_confirm_panel != null:
		_exit_confirm_panel.visible = true


func _on_keep_learning() -> void:
	if _exit_confirm_panel != null:
		_exit_confirm_panel.visible = false


func _on_exit_confirmed() -> void:
	# Sticky: marking complete here means the player won't be auto-routed back
	# into this tutorial on next launch. They can still re-enter from the menu.
	PlayerPrefs.mark_tutorial_complete(_tutorial_id)
	_exit_to_free_play()


func _unhandled_input(event: InputEvent) -> void:
	if _complete_panel.visible and event.is_action_pressed("ui_cancel"):
		_exit_to_free_play()
		get_viewport().set_input_as_handled()
		return
	if _exit_confirm_panel != null and _exit_confirm_panel.visible \
			and event.is_action_pressed("ui_cancel"):
		_on_keep_learning()
		get_viewport().set_input_as_handled()
