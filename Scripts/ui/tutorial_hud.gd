class_name TutorialHUD
extends CanvasLayer

const _COMPLETE_FLASH_DURATION: float = 0.6
const _HINT_DELAY: float = 8.0

var _step_label: Label = null
var _title_label: Label = null
var _instruction_label: Label = null
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

	# Row 4: hint (hidden until hint delay expires)
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

	var heading := Label.new()
	heading.text = "Tutorial Complete!"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 36)
	heading.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	vbox.add_child(heading)

	var sub := Label.new()
	sub.text = "You know the ropes — now get out there."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	vbox.add_child(sub)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	# Primary action: continue into the next tutorial when there is one.
	# Goes first so it's the obvious default after finishing Basics.
	var next_id: String = TutorialRegistry.get_next_id(_tutorial_id)
	if next_id != "":
		var next_btn := Button.new()
		next_btn.text = "Next: %s" % TutorialRegistry.get_display_name(next_id)
		next_btn.pressed.connect(func() -> void: _on_continue_to_tutorial(next_id))
		SoundManager.wire_button(next_btn)
		btn_row.add_child(next_btn)

	# "Free Play" IS the main menu in this game — Escape from free play opens
	# the SideMenu, where the player picks their next activity. One button.
	var free_play_btn := Button.new()
	free_play_btn.text = "Free Play"
	free_play_btn.pressed.connect(_exit_to_free_play)
	SoundManager.wire_button(free_play_btn)
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
