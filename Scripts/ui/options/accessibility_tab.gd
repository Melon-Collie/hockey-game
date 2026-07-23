class_name OptionsAccessibilityTab
extends OptionsTab

# Accessibility tab — the colorblind / motion-comfort / readability settings that
# were previously scattered across the Game and Input tabs, gathered into one
# home: flash & shake toggles, HUD scale, on-ice ring colors, and cursor look.

var _screen_flash_check: CheckButton = null
var _screen_shake_check: CheckButton = null
var _hit_stop_check: CheckButton = null
var _hud_scale_slider: HSlider = null
var _hud_scale_label: Label = null
var _ring_preset_btn: OptionButton = null
var _ring_self_color_btn: ColorPickerButton = null
var _ring_team_color_btn: ColorPickerButton = null
var _ring_enemy_color_btn: ColorPickerButton = null
var _cursor_style_btn: OptionButton = null
var _cursor_color_btn: ColorPickerButton = null
var _cursor_size_slider: HSlider = null
var _cursor_size_label: Label = null
var _suppress_ring_sync: bool = false   # guards re-entrancy while a preset writes the pickers

func _build_content() -> void:
	add_child(_section_header("Visual"))

	_screen_flash_check = CheckButton.new()
	_screen_flash_check.set_pressed_no_signal(PlayerPrefs.screen_flash)
	SoundManager.wire_button(_screen_flash_check)
	_screen_flash_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Screen Flash Effects", _screen_flash_check))

	_screen_shake_check = CheckButton.new()
	_screen_shake_check.set_pressed_no_signal(PlayerPrefs.screen_shake)
	SoundManager.wire_button(_screen_shake_check)
	_screen_shake_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Camera Shake", _screen_shake_check))

	_hit_stop_check = CheckButton.new()
	_hit_stop_check.set_pressed_no_signal(PlayerPrefs.hit_stop)
	SoundManager.wire_button(_hit_stop_check)
	_hit_stop_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Hit Stop (offline)", _hit_stop_check))

	_hud_scale_slider = HSlider.new()
	_hud_scale_slider.min_value = PlayerPrefs.HUD_SCALE_MIN
	_hud_scale_slider.max_value = PlayerPrefs.HUD_SCALE_MAX
	_hud_scale_slider.step = 0.05
	_hud_scale_slider.value = PlayerPrefs.hud_scale
	_hud_scale_slider.value_changed.connect(func(_v: float) -> void: _notify_changed())
	_hud_scale_label = _value_label("%d%%" % roundi(PlayerPrefs.hud_scale * 100.0))
	_hud_scale_slider.value_changed.connect(func(v: float) -> void: _hud_scale_label.text = "%d%%" % roundi(v * 100.0))
	add_child(_slider_row("HUD Scale", _hud_scale_slider, _hud_scale_label))

	add_child(_section_spacer())
	add_child(_section_header("Ring Colors"))

	# Colorblind preset picker. Item 0 is "Custom"; items 1..n apply a curated
	# self / ally / enemy palette to the three pickers below. The pickers stay
	# fully editable — tweaking any of them flips this back to "Custom".
	_ring_preset_btn = OptionButton.new()
	_ring_preset_btn.custom_minimum_size = Vector2(180, 36)
	_ring_preset_btn.add_theme_font_size_override("font_size", 15)
	_ring_preset_btn.add_item("Custom")
	for p: Dictionary in _ring_presets():
		_ring_preset_btn.add_item(p.name)
	_ring_preset_btn.item_selected.connect(_on_ring_preset_selected)
	add_child(_field_row("Preset", _ring_preset_btn))

	_ring_self_color_btn = _make_ring_picker(PlayerPrefs.ring_color_self)
	add_child(_field_row("Your Ring", _ring_self_color_btn))

	_ring_team_color_btn = _make_ring_picker(PlayerPrefs.ring_color_team)
	add_child(_field_row("Ally Rings", _ring_team_color_btn))

	_ring_enemy_color_btn = _make_ring_picker(PlayerPrefs.ring_color_enemy)
	add_child(_field_row("Enemy Rings", _ring_enemy_color_btn))
	_sync_ring_preset_selection()

	add_child(_section_spacer())
	add_child(_section_header("Cursor"))

	_cursor_style_btn = OptionButton.new()
	_cursor_style_btn.custom_minimum_size = Vector2(160, 40)
	_cursor_style_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.CURSOR_STYLE_LABELS.size():
		_cursor_style_btn.add_item(PlayerPrefs.CURSOR_STYLE_LABELS[i], i)
	_cursor_style_btn.selected = PlayerPrefs.cursor_style
	_cursor_style_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Style", _cursor_style_btn))

	_cursor_color_btn = ColorPickerButton.new()
	_cursor_color_btn.custom_minimum_size = Vector2(160, 36)
	_cursor_color_btn.color = PlayerPrefs.cursor_color
	_cursor_color_btn.edit_alpha = false
	SoundManager.wire_button(_cursor_color_btn)
	_cursor_color_btn.color_changed.connect(func(_c: Color) -> void: _notify_changed())
	add_child(_field_row("Color", _cursor_color_btn))

	_cursor_size_slider = HSlider.new()
	_cursor_size_slider.min_value = PlayerPrefs.CURSOR_SIZE_MIN
	_cursor_size_slider.max_value = PlayerPrefs.CURSOR_SIZE_MAX
	_cursor_size_slider.step = 2.0
	_cursor_size_slider.value = PlayerPrefs.cursor_size
	_cursor_size_slider.value_changed.connect(func(_v: float) -> void: _notify_changed())
	_cursor_size_label = _value_label("%dpx" % PlayerPrefs.cursor_size)
	_cursor_size_slider.value_changed.connect(func(v: float) -> void: _cursor_size_label.text = "%dpx" % int(v))
	add_child(_slider_row("Size", _cursor_size_slider, _cursor_size_label))

# The three ring pickers share style + the sync-to-preset handler.
func _make_ring_picker(initial: Color) -> ColorPickerButton:
	var btn := ColorPickerButton.new()
	btn.custom_minimum_size = Vector2(160, 36)
	btn.color = initial
	btn.edit_alpha = false
	SoundManager.wire_button(btn)
	btn.color_changed.connect(_on_ring_color_changed)
	return btn

func _on_ring_color_changed(_color: Color) -> void:
	# A manual tweak (not a preset write) means the palette is no longer one of
	# the curated sets — reflect that as "Custom".
	if not _suppress_ring_sync:
		_sync_ring_preset_selection()
	_notify_changed()

# Curated self / ally / enemy ring palettes. "Default" restores the canonical
# green/blue/red; the three deficiency presets are starting points the player can
# fine-tune with the pickers (hues that stay separable under each common form of
# color blindness — light/neutral self, cool ally, warm enemy). Not persisted:
# the selection is re-derived from the live colors whenever the panel opens.
func _ring_presets() -> Array[Dictionary]:
	var presets: Array[Dictionary] = [
		{"name": "Default",
			"self": MenuStyle.HUD_RING_SELF, "team": MenuStyle.HUD_RING_TEAM, "enemy": MenuStyle.HUD_RING_ENEMY},
		{"name": "Deuteranopia",
			"self": Color(0.95, 0.95, 0.95), "team": Color(0.30, 0.55, 0.95), "enemy": Color(0.95, 0.55, 0.10)},
		{"name": "Protanopia",
			"self": Color(0.97, 0.91, 0.30), "team": Color(0.25, 0.60, 0.95), "enemy": Color(0.90, 0.45, 0.10)},
		{"name": "Tritanopia",
			"self": Color(0.95, 0.95, 0.95), "team": Color(0.10, 0.75, 0.55), "enemy": Color(0.90, 0.20, 0.30)},
	]
	return presets

func _on_ring_preset_selected(idx: int) -> void:
	if idx <= 0:
		return  # "Custom" — leave the pickers as the player has them
	var p: Dictionary = _ring_presets()[idx - 1]
	_suppress_ring_sync = true
	_ring_self_color_btn.color = p["self"]
	_ring_team_color_btn.color = p["team"]
	_ring_enemy_color_btn.color = p["enemy"]
	_suppress_ring_sync = false
	_ring_preset_btn.selected = idx
	_notify_changed()

# Selects the preset whose palette matches the current pickers, else "Custom".
func _sync_ring_preset_selection() -> void:
	if _ring_preset_btn == null:
		return
	var presets: Array[Dictionary] = _ring_presets()
	for i: int in presets.size():
		var p: Dictionary = presets[i]
		if _ring_self_color_btn.color.is_equal_approx(p["self"]) \
				and _ring_team_color_btn.color.is_equal_approx(p["team"]) \
				and _ring_enemy_color_btn.color.is_equal_approx(p["enemy"]):
			_ring_preset_btn.selected = i + 1
			return
	_ring_preset_btn.selected = 0  # Custom

func read_controls() -> Dictionary:
	return {
		"screen_flash": _screen_flash_check.button_pressed,
		"screen_shake": _screen_shake_check.button_pressed,
		"hit_stop": _hit_stop_check.button_pressed,
		"hud_scale": _hud_scale_slider.value,
		"ring_color_self": _ring_self_color_btn.color,
		"ring_color_team": _ring_team_color_btn.color,
		"ring_color_enemy": _ring_enemy_color_btn.color,
		"cursor_style": _cursor_style_btn.selected,
		"cursor_color": _cursor_color_btn.color,
		"cursor_size": int(_cursor_size_slider.value),
	}

func apply_values(v: Dictionary) -> void:
	_screen_flash_check.set_pressed_no_signal(v.screen_flash)
	_screen_shake_check.set_pressed_no_signal(v.screen_shake)
	_hit_stop_check.set_pressed_no_signal(v.hit_stop)
	_hud_scale_slider.value = v.hud_scale
	_ring_self_color_btn.color = v.ring_color_self
	_ring_team_color_btn.color = v.ring_color_team
	_ring_enemy_color_btn.color = v.ring_color_enemy
	_sync_ring_preset_selection()
	_cursor_style_btn.selected = v.cursor_style
	_cursor_color_btn.color = v.cursor_color
	_cursor_size_slider.value = v.cursor_size
