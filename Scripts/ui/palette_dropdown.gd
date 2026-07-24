class_name PaletteDropdown
extends Control

# Visual color picker that replaces the fruit-name OptionButton. Closed state
# shows the currently-selected swatch styled like a lobby card — primary bg
# with a thin left stripe in the secondary color, rounded outside corners
# only. Clicking opens a popup grid of every preset's swatch. The selected
# swatch in the popup carries a TEAL border so the choice is unambiguous.
#
# Owns no domain state. Caller supplies the initial slot, listens to the
# `selected` signal, and translates the int into PlayerPrefs / RPC writes.

signal selected(slot: int)

const _STRIPE_WIDTH: int = 8
const _CARD_CORNER: int = 4
# Popup grid swatch dimensions. Slightly wider than the closed state so the
# stripe-on-primary read carries at this size.
const _POPUP_SWATCH_SIZE: Vector2 = Vector2(48, 36)
const _POPUP_COLUMNS: int = 4
const _POPUP_SEPARATION: int = 6

var _selected_slot: int = 0
var _disabled: bool = false
var _closed_btn: Button = null
var _closed_stripe_style: StyleBoxFlat = null
var _closed_panel_style: StyleBoxFlat = null
var _popup: PopupPanel = null


func _init(initial_slot: int = 0, min_size: Vector2 = Vector2(180, 36)) -> void:
	_selected_slot = initial_slot
	custom_minimum_size = min_size
	_build_closed_state(min_size)


func _build_closed_state(min_size: Vector2) -> void:
	# The closed state is a Button so it carries focus / hover / pressed
	# states and pipes through SoundManager.wire_button. The panel + stripe
	# live underneath as a stylebox so they re-render alongside the button's
	# theme styles. Mouse_filter STOP keeps clicks off the underlying row.
	_closed_btn = Button.new()
	_closed_btn.custom_minimum_size = min_size
	_closed_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_closed_btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_closed_btn.pressed.connect(_on_closed_pressed)
	SoundManager.wire_button(_closed_btn)
	add_child(_closed_btn)

	_closed_panel_style = StyleBoxFlat.new()
	_closed_panel_style.set_corner_radius_all(_CARD_CORNER)
	_closed_panel_style.set_border_width_all(1)
	_closed_panel_style.border_color = MenuStyle.TEAL_DIM
	# Content margin pushes the (empty) button label off the stripe.
	_closed_panel_style.set_content_margin_all(8)
	_closed_panel_style.set_content_margin(SIDE_LEFT, 8 + _STRIPE_WIDTH)
	_closed_btn.add_theme_stylebox_override("normal", _closed_panel_style)
	_closed_btn.add_theme_stylebox_override("hover", _closed_panel_style)
	_closed_btn.add_theme_stylebox_override("pressed", _closed_panel_style)
	_closed_btn.add_theme_stylebox_override("focus", _closed_panel_style)
	# Controller: the focus stylebox IS the color panel (no ring), so brighten its
	# border while focused as the focus indicator.
	if ControllerNav.active():
		_closed_btn.focus_entered.connect(func() -> void:
			_closed_panel_style.border_color = MenuStyle.TEAL
			_closed_panel_style.set_border_width_all(2))
		_closed_btn.focus_exited.connect(func() -> void:
			_closed_panel_style.border_color = MenuStyle.TEAL_DIM
			_closed_panel_style.set_border_width_all(1))

	# Left stripe — same recipe as the lobby card stripe in slot_grid_panel.gd:
	# rounded outside corners, flat inside corners, negative offsets escape
	# the parent's content margin so the band touches the card's outer edge.
	_closed_stripe_style = StyleBoxFlat.new()
	_closed_stripe_style.corner_radius_top_left = _CARD_CORNER
	_closed_stripe_style.corner_radius_bottom_left = _CARD_CORNER
	_closed_stripe_style.corner_radius_top_right = 0
	_closed_stripe_style.corner_radius_bottom_right = 0
	var stripe := Panel.new()
	stripe.add_theme_stylebox_override("panel", _closed_stripe_style)
	stripe.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	stripe.offset_left = 0
	stripe.offset_right = _STRIPE_WIDTH
	stripe.offset_top = 0
	stripe.offset_bottom = 0
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stripe)

	_apply_closed_colors()


func _apply_closed_colors() -> void:
	var preset: Dictionary = TeamColorRegistry.get_preset(_selected_slot)
	_closed_panel_style.bg_color = preset.get("primary", MenuStyle.PANEL_BG)
	_closed_stripe_style.bg_color = preset.get("secondary", MenuStyle.TEXT_SEP)


# Public API ─────────────────────────────────────────────────────────────────

func set_selected(slot: int) -> void:
	_selected_slot = slot
	_apply_closed_colors()


func get_selected() -> int:
	return _selected_slot


func set_disabled(b: bool) -> void:
	_disabled = b
	if _closed_btn != null:
		_closed_btn.disabled = b
	modulate = Color(1, 1, 1, 0.5) if b else Color(1, 1, 1, 1)


# Popup ──────────────────────────────────────────────────────────────────────

# Controller: LEFT/RIGHT on the focused closed state cycle the color directly — the
# reliable path (the popup is a separate window, which controller focus handles
# poorly). Handled at _input so it cycles instead of moving focus off the widget.
func _input(event: InputEvent) -> void:
	if _disabled or _closed_btn == null or not _closed_btn.has_focus() or not ControllerNav.active():
		return
	if event.is_action_pressed(&"ui_left"):
		_cycle_slot(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_right"):
		_cycle_slot(1)
		get_viewport().set_input_as_handled()


func _cycle_slot(dir: int) -> void:
	var slots: Array[int] = TeamColorRegistry.get_all_slots()
	if slots.is_empty():
		return
	var idx: int = slots.find(_selected_slot)
	if idx < 0:
		idx = 0
	var next: int = slots[(idx + dir + slots.size()) % slots.size()]
	set_selected(next)
	selected.emit(next)


func _on_closed_pressed() -> void:
	if _disabled:
		return
	_ensure_popup()
	# Anchor the popup directly under the closed state. Godot's PopupPanel
	# expects a screen-space rect, so translate the closed-state's global
	# position into screen coords via the viewport transform.
	var screen_pos: Vector2 = get_screen_position() + Vector2(0, size.y + 4)
	_popup.position = screen_pos
	_popup.popup()
	# Controller: best-effort focus into the popup grid so a pad can pick a swatch
	# (LEFT/RIGHT on the closed state is the reliable fallback if window focus balks).
	if ControllerNav.active() and _popup.get_child_count() > 0:
		var grid: Node = _popup.get_child(_popup.get_child_count() - 1)
		if grid.get_child_count() > 0:
			ControllerNav.grab_focus(grid.get_child(0) as Control)


func _ensure_popup() -> void:
	if _popup != null:
		# Rebuild swatches each time so a mid-session reload of
		# user://team_colors.json (or a re-skin) reflects in the next open.
		# Cheap — 8 swatches, no allocation pressure.
		for child: Node in _popup.get_children():
			child.queue_free()
		_popup.add_child(_build_popup_grid())
		return
	_popup = PopupPanel.new()
	var panel_style := MenuStyle.panel(_CARD_CORNER, _POPUP_SEPARATION)
	_popup.add_theme_stylebox_override("panel", panel_style)
	_popup.add_child(_build_popup_grid())
	# Parent to the top-level viewport so the popup floats above other UI
	# panels. add_child(_popup) on `self` would clip it inside the dropdown.
	get_tree().root.add_child(_popup)


func _build_popup_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = _POPUP_COLUMNS
	grid.add_theme_constant_override("h_separation", _POPUP_SEPARATION)
	grid.add_theme_constant_override("v_separation", _POPUP_SEPARATION)
	var slots: Array[int] = TeamColorRegistry.get_all_slots()
	for slot: int in slots:
		grid.add_child(_build_swatch(slot))
	return grid


func _build_swatch(slot: int) -> Button:
	var preset: Dictionary = TeamColorRegistry.get_preset(slot)
	var primary: Color = preset.get("primary", MenuStyle.PANEL_BG)
	var secondary: Color = preset.get("secondary", MenuStyle.TEXT_SEP)

	var btn := Button.new()
	btn.custom_minimum_size = _POPUP_SWATCH_SIZE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(_on_swatch_pressed.bind(slot))
	SoundManager.wire_button(btn)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = primary
	panel_style.set_corner_radius_all(_CARD_CORNER)
	panel_style.set_border_width_all(1)
	# Selected swatch reads with a brighter ring than the others.
	panel_style.border_color = MenuStyle.TEAL if slot == _selected_slot else MenuStyle.TEAL_DIM
	panel_style.set_content_margin_all(0)
	btn.add_theme_stylebox_override("normal", panel_style)
	btn.add_theme_stylebox_override("hover", panel_style)
	btn.add_theme_stylebox_override("pressed", panel_style)
	btn.add_theme_stylebox_override("focus", panel_style)

	# Stripe overlay sitting on the swatch's left edge. mouse_filter IGNORE
	# so clicks pass through to the button.
	var stripe_style := StyleBoxFlat.new()
	stripe_style.bg_color = secondary
	stripe_style.corner_radius_top_left = _CARD_CORNER
	stripe_style.corner_radius_bottom_left = _CARD_CORNER
	stripe_style.corner_radius_top_right = 0
	stripe_style.corner_radius_bottom_right = 0
	var stripe := Panel.new()
	stripe.add_theme_stylebox_override("panel", stripe_style)
	stripe.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	stripe.offset_left = 0
	stripe.offset_right = _STRIPE_WIDTH
	stripe.offset_top = 0
	stripe.offset_bottom = 0
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(stripe)
	return btn


func _on_swatch_pressed(slot: int) -> void:
	set_selected(slot)
	if _popup != null:
		_popup.hide()
	selected.emit(slot)


func _exit_tree() -> void:
	# Popup is parented to the scene root, not to `self`, so it survives our
	# free unless we tear it down explicitly.
	if _popup != null and is_instance_valid(_popup):
		_popup.queue_free()
		_popup = null
