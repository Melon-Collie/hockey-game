class_name OptionsControlsTab
extends OptionsTab

# Controls tab — mouse behavior and the key-binding grid. Owns the rebind
# listen state; is_valid() is false while two actions share a binding.

const _REBINDABLE_ACTIONS: Array = [
	{"action": "move_up",        "label": "Move Up"},
	{"action": "move_down",      "label": "Move Down"},
	{"action": "move_left",      "label": "Move Left"},
	{"action": "move_right",     "label": "Move Right"},
	{"action": "sprint",         "label": "Sprint"},
	{"action": "brake",          "label": "Brake"},
	{"action": "shoot",          "label": "Shoot"},
	{"action": "quick_shot",     "label": "Quick Pass"},
	{"action": "slapshot",       "label": "Slapshot"},
	{"action": "block",          "label": "Block"},
	{"action": "elevation_up",   "label": "Elevation Up"},
	{"action": "elevation_down", "label": "Elevation Down"},
	{"action": "stick_lift",     "label": "Deflect / Lift"},
	{"action": "smart_ping",     "label": "Smart Ping"},
]

var _shot_power_slider: HSlider = null
var _shot_power_field: LineEdit = null
var _confine_mouse_check: CheckButton = null
var _listening_action: String = ""
var _pending_bindings: Dictionary = {}
var _binding_btns: Dictionary = {}
var _conflict_label: Label = null

func _build_content() -> void:
	add_child(_section_header("Mouse"))

	# Shot Power Sensitivity — calibrates how hard you flick for a full-power
	# wrister to your mouse DPI (higher = full power from a gentler flick).
	_shot_power_slider = HSlider.new()
	_shot_power_slider.min_value = 0.25
	_shot_power_slider.max_value = 4.0
	_shot_power_slider.step = 0.05
	_shot_power_slider.value = PlayerPrefs.shot_power_sensitivity
	_shot_power_slider.value_changed.connect(_on_shot_power_changed)
	_shot_power_field = LineEdit.new()
	_shot_power_field.text = "%.2f" % PlayerPrefs.shot_power_sensitivity
	_shot_power_field.custom_minimum_size = Vector2(_VALUE_COL_WIDTH, 32)
	_shot_power_field.add_theme_font_size_override("font_size", _VALUE_FONT_SIZE)
	_shot_power_field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_shot_power_field.text_submitted.connect(_on_shot_power_typed)
	_shot_power_field.focus_exited.connect(func() -> void: _on_shot_power_typed(_shot_power_field.text))
	add_child(_slider_row("Shot Power Sensitivity", _shot_power_slider, _shot_power_field))

	_confine_mouse_check = CheckButton.new()
	_confine_mouse_check.set_pressed_no_signal(PlayerPrefs.confine_mouse)
	SoundManager.wire_button(_confine_mouse_check)
	_confine_mouse_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Confine Cursor to Window", _confine_mouse_check))

	add_child(_section_spacer())
	add_child(_section_header("Key Bindings"))

	_pending_bindings = PlayerPrefs.bindings.duplicate(true)

	# No inner scroll here — the whole tab scrolls via the parent's viewport, so
	# the rebind list just flows into the page.
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(grid)

	for entry: Dictionary in _REBINDABLE_ACTIONS:
		var action: String = entry.action
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(140, 36)
		btn.add_theme_font_size_override("font_size", 14)
		btn.text = _binding_display(_pending_bindings.get(action, {}))
		btn.pressed.connect(_on_bind_btn_pressed.bind(action))
		SoundManager.wire_button(btn)
		_binding_btns[action] = btn
		grid.add_child(_field_row(entry.label, btn))

	_conflict_label = Label.new()
	_conflict_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_conflict_label.add_theme_font_size_override("font_size", 13)
	_conflict_label.add_theme_color_override("font_color", MenuStyle.DANGER)
	_conflict_label.text = ""
	add_child(_conflict_label)

# Leaving the tab mid-rebind cancels the pending key-listen (replaces the old
# panel's leave-Input-tab check). The tab is shown/hidden via its scroll-wrapper
# ancestor, so its own `visible` stays true — test visibility in the tree.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree() \
			and not _listening_action.is_empty():
		_listening_action = ""
		_update_binding_btns()

func _on_shot_power_changed(value: float) -> void:
	if _shot_power_field != null:
		_shot_power_field.text = "%.2f" % value
	_notify_changed()

func _on_shot_power_typed(text: String) -> void:
	var value: float = clampf(text.to_float(), 0.25, 4.0)
	if _shot_power_slider != null:
		_shot_power_slider.value = value

func _on_bind_btn_pressed(action: String) -> void:
	_listening_action = action
	_update_binding_btns()

func _input(event: InputEvent) -> void:
	if _listening_action.is_empty():
		return
	if event is InputEventKey:
		if not (event as InputEventKey).pressed:
			return
		if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
			_listening_action = ""
			_update_binding_btns()
			get_viewport().set_input_as_handled()
			return
		_pending_bindings[_listening_action] = {
			"type": "key",
			"physical_keycode": int((event as InputEventKey).physical_keycode),
		}
		_listening_action = ""
		_update_binding_btns()
		_update_conflict_label()
		_notify_changed()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		if not (event as InputEventMouseButton).pressed:
			return
		_pending_bindings[_listening_action] = {
			"type": "mouse",
			"button_index": int((event as InputEventMouseButton).button_index),
		}
		_listening_action = ""
		_update_binding_btns()
		_update_conflict_label()
		_notify_changed()
		get_viewport().set_input_as_handled()

func _update_binding_btns() -> void:
	for action: String in _binding_btns:
		var btn: Button = _binding_btns[action]
		if action == _listening_action:
			btn.text = "..."
		else:
			btn.text = _binding_display(_pending_bindings.get(action, {}))

func _update_conflict_label() -> void:
	if _conflict_label == null:
		return
	_conflict_label.text = "Conflicting bindings — cannot apply" if _has_conflicts() else ""

func _has_conflicts() -> bool:
	var seen: Dictionary = {}
	for action: String in _pending_bindings:
		var fp: String = _binding_fingerprint(_pending_bindings[action])
		if fp.is_empty():
			continue
		if seen.has(fp):
			return true
		seen[fp] = true
	return false

func _binding_fingerprint(b: Dictionary) -> String:
	if b.get("type") == "key":
		return "k:%d" % b.physical_keycode
	elif b.get("type") == "mouse":
		return "m:%d" % b.button_index
	return ""

func _binding_display(b: Dictionary) -> String:
	if b.is_empty():
		return "—"
	if b.get("type") == "key":
		return OS.get_keycode_string(b.physical_keycode as Key)
	elif b.get("type") == "mouse":
		match int(b.button_index):
			MOUSE_BUTTON_LEFT:       return "LMB"
			MOUSE_BUTTON_RIGHT:      return "RMB"
			MOUSE_BUTTON_MIDDLE:     return "MMB"
			MOUSE_BUTTON_WHEEL_UP:   return "Scroll Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Scroll Down"
			_: return "Mouse %d" % b.button_index
	return "—"

func is_valid() -> bool:
	return not _has_conflicts()

func read_controls() -> Dictionary:
	return {
		"shot_power_sensitivity": _shot_power_slider.value,
		"confine_mouse": _confine_mouse_check.button_pressed,
		"bindings": _pending_bindings.duplicate(true),
	}

func apply_values(v: Dictionary) -> void:
	_shot_power_slider.value = v.shot_power_sensitivity
	_confine_mouse_check.set_pressed_no_signal(v.confine_mouse)
	_listening_action = ""
	_pending_bindings = (v.get("bindings", {}) as Dictionary).duplicate(true)
	_update_binding_btns()
	if _conflict_label != null:
		_conflict_label.text = ""
