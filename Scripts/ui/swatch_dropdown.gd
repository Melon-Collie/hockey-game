class_name SwatchDropdown
extends Control

# Compact color picker: closed state is a single chip showing the current
# pick; clicking opens a popup grid of every palette color. PaletteDropdown's
# interaction model (button chip + PopupPanel grid, D-pad left/right cycling
# for controllers) over a plain caller-supplied palette instead of the team
# registry — the stick editor uses it for tape colors.
#
# Owns no domain state. Caller supplies colors + tooltip names via
# set_palette (re-supply on open to re-resolve live entries like the TEAM
# accent), listens to `selected`, and maps the index itself.

signal selected(index: int)

const _CHIP_CORNER: int = 4
const _POPUP_SWATCH_SIZE: Vector2 = Vector2(40, 32)
const _POPUP_COLUMNS: int = 6
const _POPUP_SEPARATION: int = 6

var _colors: Array[Color] = []
var _names: Array[String] = []
# Short text drawn ON a chip (closed state and popup swatch alike). Empty =
# color only; the tape palette labels its TEAM entry so players know that
# chip tracks the team color rather than being one more fixed pick.
var _chip_labels: Array[String] = []
var _selected_index: int = 0
var _disabled: bool = false
var _closed_btn: Button = null
var _closed_style: StyleBoxFlat = null
var _popup: PopupPanel = null


func _init(min_size: Vector2 = Vector2(96, 36)) -> void:
	custom_minimum_size = min_size
	_closed_btn = Button.new()
	_closed_btn.custom_minimum_size = min_size
	_closed_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_closed_btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_closed_btn.pressed.connect(_on_closed_pressed)
	SoundManager.wire_button(_closed_btn)
	add_child(_closed_btn)

	_closed_style = StyleBoxFlat.new()
	_closed_style.set_corner_radius_all(_CHIP_CORNER)
	_closed_style.set_border_width_all(1)
	_closed_style.border_color = MenuStyle.TEAL_DIM
	for state: String in ["normal", "hover", "pressed", "focus"]:
		_closed_btn.add_theme_stylebox_override(state, _closed_style)
	# Controller: the focus stylebox IS the chip (no ring) — brighten the
	# border as the focus indicator, like PaletteDropdown.
	if ControllerNav.active():
		_closed_btn.focus_entered.connect(func() -> void:
			_closed_style.border_color = MenuStyle.TEAL
			_closed_style.set_border_width_all(2))
		_closed_btn.focus_exited.connect(func() -> void:
			_closed_style.border_color = MenuStyle.TEAL_DIM
			_closed_style.set_border_width_all(1))


# ── Public API ───────────────────────────────────────────────────────────────

# The control that actually takes focus and hover. This wrapper is FOCUS_NONE
# and its closed button covers it edge to edge, so a caller that wants to react
# to the row being reached — by pad or by pointer — has to watch the button,
# not the wrapper, whose own signals never fire.
func focus_target() -> Control:
	return _closed_btn

# `names` are tooltip strings, index-aligned with `colors`; `chip_labels`
# (optional, same alignment) draw short text on a chip — empty string for
# color-only entries. Re-supply whenever a live entry (the TEAM accent) may
# have changed.
func set_palette(colors: Array[Color], names: Array[String],
		chip_labels: Array[String] = []) -> void:
	_colors = colors
	_names = names
	_chip_labels = chip_labels
	_selected_index = clampi(_selected_index, 0, maxi(colors.size() - 1, 0))
	_apply_closed_chip()


func set_selected(index: int) -> void:
	_selected_index = clampi(index, 0, maxi(_colors.size() - 1, 0))
	_apply_closed_chip()


func set_disabled(b: bool) -> void:
	_disabled = b
	_closed_btn.disabled = b
	modulate = Color(1, 1, 1, 0.5) if b else Color(1, 1, 1, 1)


func _apply_closed_chip() -> void:
	if _colors.is_empty():
		return
	_closed_style.bg_color = _colors[_selected_index]
	_closed_btn.tooltip_text = _names[_selected_index] if _selected_index < _names.size() else ""
	_set_chip_text(_closed_btn, _selected_index, 14)


func _chip_label(index: int) -> String:
	return _chip_labels[index] if index < _chip_labels.size() else ""


# Draws an entry's short label on a chip button in whichever of black/white
# reads against that chip's color.
func _set_chip_text(btn: Button, index: int, font_size: int) -> void:
	btn.text = _chip_label(index)
	if btn.text.is_empty():
		return
	btn.add_theme_font_size_override("font_size", font_size)
	var text_color: Color = Color.BLACK if _colors[index].get_luminance() > 0.55 else Color.WHITE
	for state: String in ["font_color", "font_hover_color", "font_pressed_color",
			"font_focus_color"]:
		btn.add_theme_color_override(state, text_color)


# ── Popup ────────────────────────────────────────────────────────────────────

# Controller: LEFT/RIGHT on the focused chip cycle the pick directly (popup
# windows and pad focus don't mix — same fallback as PaletteDropdown).
func _input(event: InputEvent) -> void:
	if _disabled or not _closed_btn.has_focus() or not ControllerNav.active():
		return
	if event.is_action_pressed(&"ui_left"):
		_cycle(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_right"):
		_cycle(1)
		get_viewport().set_input_as_handled()


func _cycle(dir: int) -> void:
	if _colors.is_empty():
		return
	set_selected((_selected_index + dir + _colors.size()) % _colors.size())
	selected.emit(_selected_index)


func _on_closed_pressed() -> void:
	if _disabled or _colors.is_empty():
		return
	_ensure_popup()
	_popup.position = Vector2i(get_screen_position() + Vector2(0, size.y + 4))
	_popup.popup()
	if ControllerNav.active() and _popup.get_child_count() > 0:
		var grid: Node = _popup.get_child(_popup.get_child_count() - 1)
		if grid.get_child_count() > 0:
			ControllerNav.grab_focus(grid.get_child(0) as Control)


func _ensure_popup() -> void:
	if _popup == null:
		_popup = PopupPanel.new()
		_popup.add_theme_stylebox_override("panel", MenuStyle.panel(_CHIP_CORNER, _POPUP_SEPARATION))
		# Parent to the top-level viewport so the popup floats above the modal
		# rather than clipping inside this widget.
		get_tree().root.add_child(_popup)
	else:
		for child: Node in _popup.get_children():
			child.queue_free()
	var grid := GridContainer.new()
	grid.columns = _POPUP_COLUMNS
	grid.add_theme_constant_override("h_separation", _POPUP_SEPARATION)
	grid.add_theme_constant_override("v_separation", _POPUP_SEPARATION)
	for i: int in _colors.size():
		grid.add_child(_build_swatch(i))
	_popup.add_child(grid)


func _build_swatch(index: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = _POPUP_SWATCH_SIZE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.tooltip_text = _names[index] if index < _names.size() else ""
	btn.pressed.connect(_on_swatch_pressed.bind(index))
	SoundManager.wire_button(btn)
	_set_chip_text(btn, index, 12)
	var style := StyleBoxFlat.new()
	style.bg_color = _colors[index]
	style.set_corner_radius_all(_CHIP_CORNER)
	style.set_border_width_all(2 if index == _selected_index else 1)
	style.border_color = MenuStyle.TEAL if index == _selected_index else MenuStyle.TEAL_DIM
	style.set_content_margin_all(0)
	for state: String in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(state, style)
	return btn


func _on_swatch_pressed(index: int) -> void:
	set_selected(index)
	if _popup != null:
		_popup.hide()
	selected.emit(index)


func _exit_tree() -> void:
	# Popup lives on the scene root, not under `self`, so it must be torn
	# down explicitly.
	if _popup != null and is_instance_valid(_popup):
		_popup.queue_free()
		_popup = null
