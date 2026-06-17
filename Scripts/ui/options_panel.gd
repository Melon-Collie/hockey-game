class_name OptionsPanel
extends VBoxContainer

signal close_requested

var _res_row: HBoxContainer = null
var _res_label: Label = null   # dimmed when fullscreen is on (resolution disabled)
var _fs_check: CheckButton = null
var _mute_check: CheckButton = null
var _volume_slider: HSlider = null
var _sfx_slider: HSlider = null
var _ui_slider: HSlider = null
var _crowd_slider: HSlider = null
var _res_btn: OptionButton = null
var _tab_contents: Array[Control] = []
var _tab_btns: Array[Button] = []
var _vsync_check: CheckButton = null
var _fps_btn: OptionButton = null
var _show_fps_check: CheckButton = null
var _gamma_slider: HSlider = null
var _color_grade_btn: OptionButton = null
var _gi_mode_btn: OptionButton = null
var _crowd_density_btn: OptionButton = null
var _ice_scratches_check: CheckButton = null
var _render_scale_slider: HSlider = null
var _scaling_3d_btn: OptionButton = null
var _aa_btn: OptionButton = null
var _sens_slider: HSlider = null
var _sens_field: LineEdit = null
var _confine_mouse_check: CheckButton = null
var _cursor_style_btn: OptionButton = null
var _cursor_color_btn: ColorPickerButton = null
var _cursor_size_slider: HSlider = null
var _cursor_size_label: Label = null
var _attack_up_check: CheckButton = null
var _colorblind_check: CheckButton = null
var _self_beacon_check: CheckButton = null
var _screen_flash_check: CheckButton = null
var _screen_shake_check: CheckButton = null
var _tilt_slider: HSlider = null
var _tilt_label: Label = null
var _fov_slider: HSlider = null
var _fov_label: Label = null
var _cam_dist_slider: HSlider = null
var _cam_dist_label: Label = null
var _apply_btn: Button = null
var _original: Dictionary = {}
var _listening_action: String = ""
var _pending_bindings: Dictionary = {}
var _binding_btns: Dictionary = {}
var _conflict_label: Label = null
var _export_status_label: Label = null

const _WHITE  := MenuStyle.TEXT_BODY
const _DIM    := MenuStyle.TEXT_DIM
const _MUTED  := MenuStyle.TEXT_MUTED
const _SEP    := MenuStyle.TEXT_SEP

# Two-column row layout: label column left, control(s) right. Every tab uses
# the same widths so labels and controls line up vertically across rows.
const _LABEL_COL_WIDTH := 180
const _LABEL_FONT_SIZE := 17
const _VALUE_FONT_SIZE := 14
const _SECTION_FONT_SIZE := 11
const _VALUE_COL_WIDTH := 56
const _REBINDABLE_ACTIONS: Array = [
	{"action": "move_up",        "label": "Move Up"},
	{"action": "move_down",      "label": "Move Down"},
	{"action": "move_left",      "label": "Move Left"},
	{"action": "move_right",     "label": "Move Right"},
	{"action": "brake",          "label": "Brake"},
	{"action": "shoot",          "label": "Shoot"},
	{"action": "slapshot",       "label": "Slapshot"},
	{"action": "block",          "label": "Block"},
	{"action": "elevation_up",   "label": "Elevation Up"},
	{"action": "elevation_down", "label": "Elevation Down"},
	{"action": "stick_lift",     "label": "Stick Lift"},
]

func _ready() -> void:
	add_theme_constant_override("separation", 16)
	alignment = BoxContainer.ALIGNMENT_CENTER

	var close_row := HBoxContainer.new()
	var close_spacer := Control.new()
	close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(close_spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(_on_cancel_pressed)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	add_child(close_row)
	var title := Label.new()
	title.text = "Options"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	add_child(title)

	add_child(_build_tab_switcher())

	_original = _snapshot()

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	add_child(btn_row)

	_apply_btn = _make_small_button("Apply")
	_apply_btn.theme_type_variation = &"ButtonPrimary"
	_apply_btn.pressed.connect(_on_apply_pressed)
	_apply_btn.disabled = true
	btn_row.add_child(_apply_btn)

	var cancel_btn := _make_small_button("Cancel")
	cancel_btn.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(cancel_btn)

func _snapshot() -> Dictionary:
	return {
		"fullscreen": PlayerPrefs.is_fullscreen,
		"resolution_index": PlayerPrefs.resolution_index,
		"vsync_enabled": PlayerPrefs.vsync_enabled,
		"fps_cap_index": PlayerPrefs.fps_cap_index,
		"show_fps": PlayerPrefs.show_fps,
		"gamma": PlayerPrefs.gamma,
		"color_grade_preset": PlayerPrefs.color_grade_preset,
		"gi_mode": PlayerPrefs.gi_mode,
		"crowd_density": PlayerPrefs.crowd_density,
		"ice_scratches_enabled": PlayerPrefs.ice_scratches_enabled,
		"render_scale": PlayerPrefs.render_scale,
		"scaling_3d_mode": PlayerPrefs.scaling_3d_mode,
		"anti_aliasing_mode": PlayerPrefs.anti_aliasing_mode,
		"master_volume": PlayerPrefs.master_volume,
		"sfx_volume": PlayerPrefs.sfx_volume,
		"ui_volume": PlayerPrefs.ui_volume,
		"crowd_volume": PlayerPrefs.crowd_volume,
		"master_muted": PlayerPrefs.master_muted,
		"mouse_sensitivity": PlayerPrefs.mouse_sensitivity,
		"confine_mouse": PlayerPrefs.confine_mouse,
		"cursor_style": PlayerPrefs.cursor_style,
		"cursor_color": PlayerPrefs.cursor_color,
		"cursor_size": PlayerPrefs.cursor_size,
		"attack_up": PlayerPrefs.attack_up,
		"colorblind_rings": PlayerPrefs.colorblind_rings,
		"self_beacon_enabled": PlayerPrefs.self_beacon_enabled,
		"screen_flash": PlayerPrefs.screen_flash,
		"screen_shake": PlayerPrefs.screen_shake,
		"camera_tilt_deg": PlayerPrefs.camera_tilt_deg,
		"fov": PlayerPrefs.fov,
		"camera_distance": PlayerPrefs.camera_distance,
		"bindings": PlayerPrefs.bindings.duplicate(true),
	}

func _read_controls() -> Dictionary:
	return {
		"fullscreen": _fs_check.button_pressed,
		"resolution_index": _res_btn.selected,
		"vsync_enabled": _vsync_check.button_pressed,
		"fps_cap_index": _fps_btn.selected,
		"show_fps": _show_fps_check.button_pressed,
		"gamma": _gamma_slider.value,
		"color_grade_preset": _color_grade_btn.selected,
		"gi_mode": _gi_mode_btn.selected,
		"crowd_density": _crowd_density_btn.selected,
		"ice_scratches_enabled": _ice_scratches_check.button_pressed,
		"render_scale": _render_scale_slider.value,
		"scaling_3d_mode": _scaling_3d_btn.selected,
		"anti_aliasing_mode": _aa_btn.selected,
		"master_volume": _volume_slider.value,
		"sfx_volume": _sfx_slider.value,
		"ui_volume": _ui_slider.value,
		"crowd_volume": _crowd_slider.value,
		"master_muted": _mute_check.button_pressed,
		"mouse_sensitivity": _sens_slider.value,
		"confine_mouse": _confine_mouse_check.button_pressed,
		"cursor_style": _cursor_style_btn.selected,
		"cursor_color": _cursor_color_btn.color,
		"cursor_size": int(_cursor_size_slider.value),
		"attack_up": _attack_up_check.button_pressed,
		"colorblind_rings": _colorblind_check.button_pressed,
		"self_beacon_enabled": _self_beacon_check.button_pressed,
		"screen_flash": _screen_flash_check.button_pressed,
		"screen_shake": _screen_shake_check.button_pressed,
		"camera_tilt_deg": _tilt_slider.value,
		"fov": _fov_slider.value,
		"camera_distance": _cam_dist_slider.value,
		"bindings": _pending_bindings.duplicate(true),
	}

func _update_apply_state() -> void:
	if _apply_btn != null:
		var changed: bool = _read_controls() != _original
		_apply_btn.disabled = not changed or _has_conflicts()

func _build_tab_switcher() -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 0)
	wrapper.custom_minimum_size = Vector2(340, 0)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 0)
	wrapper.add_child(bar)

	var sep := ColorRect.new()
	sep.color = _SEP
	sep.custom_minimum_size = Vector2(0, 1)
	wrapper.add_child(sep)

	# Pin the tab-content viewport so the popup doesn't resize when switching
	# between tabs of different heights. Sized to fit the tallest tab (Input —
	# 10 rebind rows + sensitivity + sticky). Bump if a tab outgrows it.
	var content_margin := MarginContainer.new()
	content_margin.custom_minimum_size = Vector2(500, 520)
	content_margin.add_theme_constant_override("margin_top", 16)
	content_margin.add_theme_constant_override("margin_bottom", 8)
	content_margin.add_theme_constant_override("margin_left", 0)
	content_margin.add_theme_constant_override("margin_right", 0)
	wrapper.add_child(content_margin)

	var game_tab := _build_game_tab()
	var video_tab := _build_video_tab()
	var audio_tab := _build_audio_tab()
	var input_tab := _build_input_tab()
	_tab_contents = [game_tab, video_tab, audio_tab, input_tab]
	content_margin.add_child(game_tab)
	content_margin.add_child(video_tab)
	content_margin.add_child(audio_tab)
	content_margin.add_child(input_tab)

	for i: int in ["Game", "Video", "Audio", "Input"].size():
		var btn := Button.new()
		btn.text = ["Game", "Video", "Audio", "Input"][i]
		btn.flat = true
		btn.custom_minimum_size = Vector2(0, 40)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 17)
		bar.add_child(btn)
		_tab_btns.append(btn)
		SoundManager.wire_button(btn)
		btn.pressed.connect(_activate_tab.bind(i))

	_activate_tab(0)
	return wrapper

func _activate_tab(idx: int) -> void:
	if idx != 2 and not _listening_action.is_empty():
		_listening_action = ""
		_update_binding_btns()
	for i: int in _tab_contents.size():
		_tab_contents[i].visible = (i == idx)
	for i: int in _tab_btns.size():
		_apply_tab_style(_tab_btns[i], i == idx)

func _apply_tab_style(btn: Button, active: bool) -> void:
	MenuStyle.apply_tab_button(btn, active)

func _build_video_tab() -> Control:
	var box := _tab_box()

	box.add_child(_section_header("Display"))

	_fs_check = CheckButton.new()
	_fs_check.set_pressed_no_signal(PlayerPrefs.is_fullscreen)
	SoundManager.wire_button(_fs_check)
	_fs_check.toggled.connect(_on_fullscreen_toggled)
	box.add_child(_field_row("Fullscreen", _fs_check))

	_res_btn = OptionButton.new()
	_res_btn.custom_minimum_size = Vector2(180, 40)
	_res_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.RESOLUTIONS.size():
		var r: Vector2i = PlayerPrefs.RESOLUTIONS[i]
		_res_btn.add_item("%dx%d" % [r.x, r.y], i)
	_res_btn.selected = PlayerPrefs.resolution_index
	_res_btn.item_selected.connect(_on_resolution_selected)
	_res_row = _field_row("Resolution", _res_btn)
	# Cache the label so we can dim it when the resolution row is disabled.
	_res_label = _res_row.get_child(0) as Label
	box.add_child(_res_row)
	_apply_res_disabled_state(PlayerPrefs.is_fullscreen)

	_vsync_check = CheckButton.new()
	_vsync_check.set_pressed_no_signal(PlayerPrefs.vsync_enabled)
	SoundManager.wire_button(_vsync_check)
	_vsync_check.toggled.connect(_on_vsync_toggled)
	box.add_child(_field_row("VSync", _vsync_check))

	_fps_btn = OptionButton.new()
	_fps_btn.custom_minimum_size = Vector2(140, 40)
	_fps_btn.add_theme_font_size_override("font_size", 15)
	for label: String in ["30", "60", "120", "144", "240", "Unlimited"]:
		_fps_btn.add_item(label)
	_fps_btn.selected = PlayerPrefs.fps_cap_index
	_fps_btn.item_selected.connect(_on_fps_cap_selected)
	box.add_child(_field_row("FPS Cap", _fps_btn))

	_show_fps_check = CheckButton.new()
	_show_fps_check.set_pressed_no_signal(PlayerPrefs.show_fps)
	SoundManager.wire_button(_show_fps_check)
	_show_fps_check.toggled.connect(_on_show_fps_toggled)
	box.add_child(_field_row("Show FPS", _show_fps_check))

	box.add_child(_section_spacer())
	box.add_child(_section_header("Image"))

	_gamma_slider = HSlider.new()
	_gamma_slider.min_value = 0.5
	_gamma_slider.max_value = 2.0
	_gamma_slider.step = 0.05
	_gamma_slider.value = PlayerPrefs.gamma
	_gamma_slider.value_changed.connect(_on_gamma_changed)
	var gamma_val := _value_label("%.2f" % PlayerPrefs.gamma)
	_gamma_slider.value_changed.connect(func(v: float) -> void: gamma_val.text = "%.2f" % v)
	box.add_child(_slider_row("Gamma", _gamma_slider, gamma_val))

	_color_grade_btn = OptionButton.new()
	_color_grade_btn.custom_minimum_size = Vector2(220, 40)
	_color_grade_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.COLOR_GRADE_LABELS.size():
		_color_grade_btn.add_item(PlayerPrefs.COLOR_GRADE_LABELS[i], i)
	_color_grade_btn.selected = PlayerPrefs.color_grade_preset
	_color_grade_btn.item_selected.connect(_on_color_grade_selected)
	box.add_child(_field_row("Color Grade", _color_grade_btn))

	box.add_child(_section_spacer())
	box.add_child(_section_header("Performance"))

	_render_scale_slider = HSlider.new()
	_render_scale_slider.min_value = PlayerPrefs.RENDER_SCALE_MIN
	_render_scale_slider.max_value = PlayerPrefs.RENDER_SCALE_MAX
	_render_scale_slider.step = PlayerPrefs.RENDER_SCALE_STEP
	_render_scale_slider.value = PlayerPrefs.render_scale
	_render_scale_slider.value_changed.connect(_on_render_scale_changed)
	var rs_val := _value_label("%d%%" % roundi(PlayerPrefs.render_scale * 100.0))
	_render_scale_slider.value_changed.connect(
		func(v: float) -> void: rs_val.text = "%d%%" % roundi(v * 100.0))
	box.add_child(_slider_row("Render Scale", _render_scale_slider, rs_val))

	_scaling_3d_btn = OptionButton.new()
	_scaling_3d_btn.custom_minimum_size = Vector2(180, 40)
	_scaling_3d_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.SCALING_3D_LABELS.size():
		_scaling_3d_btn.add_item(PlayerPrefs.SCALING_3D_LABELS[i], i)
	_scaling_3d_btn.selected = PlayerPrefs.scaling_3d_mode
	_scaling_3d_btn.item_selected.connect(_on_scaling_3d_selected)
	box.add_child(_field_row("Upscaling", _scaling_3d_btn))
	_update_upscaling_enabled()

	_aa_btn = OptionButton.new()
	_aa_btn.custom_minimum_size = Vector2(180, 40)
	_aa_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.AA_LABELS.size():
		_aa_btn.add_item(PlayerPrefs.AA_LABELS[i], i)
	_aa_btn.selected = PlayerPrefs.anti_aliasing_mode
	_aa_btn.item_selected.connect(_on_aa_selected)
	box.add_child(_field_row("Anti-Aliasing", _aa_btn))
	_update_aa_compatibility()

	_gi_mode_btn = OptionButton.new()
	_gi_mode_btn.custom_minimum_size = Vector2(180, 40)
	_gi_mode_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.GI_MODE_LABELS.size():
		_gi_mode_btn.add_item(PlayerPrefs.GI_MODE_LABELS[i], i)
	_gi_mode_btn.selected = PlayerPrefs.gi_mode
	_gi_mode_btn.item_selected.connect(_on_gi_mode_selected)
	box.add_child(_field_row("Global Illumination", _gi_mode_btn))

	_crowd_density_btn = OptionButton.new()
	_crowd_density_btn.custom_minimum_size = Vector2(180, 40)
	_crowd_density_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.CROWD_DENSITY_LABELS.size():
		_crowd_density_btn.add_item(PlayerPrefs.CROWD_DENSITY_LABELS[i], i)
	_crowd_density_btn.selected = PlayerPrefs.crowd_density
	_crowd_density_btn.item_selected.connect(_on_crowd_density_selected)
	box.add_child(_field_row("Crowd Density", _crowd_density_btn))

	_ice_scratches_check = CheckButton.new()
	_ice_scratches_check.set_pressed_no_signal(PlayerPrefs.ice_scratches_enabled)
	SoundManager.wire_button(_ice_scratches_check)
	_ice_scratches_check.toggled.connect(_on_ice_scratches_toggled)
	box.add_child(_field_row("Ice Scratches", _ice_scratches_check))

	return box

func _build_audio_tab() -> Control:
	var box := _tab_box()

	box.add_child(_section_header("Volume"))

	_volume_slider = _make_volume_slider(PlayerPrefs.master_volume)
	var master_val := _value_label("%d%%" % int(PlayerPrefs.master_volume * 100))
	_volume_slider.value_changed.connect(func(v: float) -> void: master_val.text = "%d%%" % int(v * 100))
	box.add_child(_slider_row("Master", _volume_slider, master_val))

	_sfx_slider = _make_volume_slider(PlayerPrefs.sfx_volume)
	var sfx_val := _value_label("%d%%" % int(PlayerPrefs.sfx_volume * 100))
	_sfx_slider.value_changed.connect(func(v: float) -> void: sfx_val.text = "%d%%" % int(v * 100))
	box.add_child(_slider_row("SFX", _sfx_slider, sfx_val))

	_ui_slider = _make_volume_slider(PlayerPrefs.ui_volume)
	var ui_val := _value_label("%d%%" % int(PlayerPrefs.ui_volume * 100))
	_ui_slider.value_changed.connect(func(v: float) -> void: ui_val.text = "%d%%" % int(v * 100))
	box.add_child(_slider_row("UI", _ui_slider, ui_val))

	_crowd_slider = _make_volume_slider(PlayerPrefs.crowd_volume)
	var crowd_val := _value_label("%d%%" % int(PlayerPrefs.crowd_volume * 100))
	_crowd_slider.value_changed.connect(func(v: float) -> void: crowd_val.text = "%d%%" % int(v * 100))
	box.add_child(_slider_row("Crowd", _crowd_slider, crowd_val))

	box.add_child(_section_spacer())

	_mute_check = CheckButton.new()
	_mute_check.set_pressed_no_signal(PlayerPrefs.master_muted)
	SoundManager.wire_button(_mute_check)
	_mute_check.toggled.connect(_on_mute_toggled)
	box.add_child(_field_row("Mute All", _mute_check))

	return box


# All three volume sliders share the same range / step / handler — factory
# keeps the audio tab tidy.
func _make_volume_slider(initial: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.value = initial
	s.value_changed.connect(_on_volume_changed)
	return s

func _build_input_tab() -> Control:
	var box := _tab_box()

	box.add_child(_section_header("Mouse"))

	_sens_slider = HSlider.new()
	_sens_slider.min_value = 0.5
	_sens_slider.max_value = 3.0
	_sens_slider.step = 0.05
	_sens_slider.value = PlayerPrefs.mouse_sensitivity
	_sens_slider.value_changed.connect(_on_sensitivity_changed)
	_sens_field = LineEdit.new()
	_sens_field.text = "%.2f" % PlayerPrefs.mouse_sensitivity
	_sens_field.custom_minimum_size = Vector2(_VALUE_COL_WIDTH, 32)
	_sens_field.add_theme_font_size_override("font_size", _VALUE_FONT_SIZE)
	_sens_field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_sens_field.text_submitted.connect(_on_sensitivity_typed)
	_sens_field.focus_exited.connect(func() -> void: _on_sensitivity_typed(_sens_field.text))
	box.add_child(_slider_row("Sensitivity", _sens_slider, _sens_field))

	_confine_mouse_check = CheckButton.new()
	_confine_mouse_check.set_pressed_no_signal(PlayerPrefs.confine_mouse)
	SoundManager.wire_button(_confine_mouse_check)
	_confine_mouse_check.toggled.connect(_on_confine_mouse_toggled)
	box.add_child(_field_row("Confine Cursor to Window", _confine_mouse_check))

	box.add_child(_section_spacer())
	box.add_child(_section_header("Cursor"))

	_cursor_style_btn = OptionButton.new()
	_cursor_style_btn.custom_minimum_size = Vector2(160, 40)
	_cursor_style_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.CURSOR_STYLE_LABELS.size():
		_cursor_style_btn.add_item(PlayerPrefs.CURSOR_STYLE_LABELS[i], i)
	_cursor_style_btn.selected = PlayerPrefs.cursor_style
	_cursor_style_btn.item_selected.connect(_on_cursor_style_selected)
	box.add_child(_field_row("Style", _cursor_style_btn))

	_cursor_color_btn = ColorPickerButton.new()
	_cursor_color_btn.custom_minimum_size = Vector2(160, 36)
	_cursor_color_btn.color = PlayerPrefs.cursor_color
	_cursor_color_btn.edit_alpha = false
	SoundManager.wire_button(_cursor_color_btn)
	_cursor_color_btn.color_changed.connect(_on_cursor_color_changed)
	box.add_child(_field_row("Color", _cursor_color_btn))

	_cursor_size_slider = HSlider.new()
	_cursor_size_slider.min_value = PlayerPrefs.CURSOR_SIZE_MIN
	_cursor_size_slider.max_value = PlayerPrefs.CURSOR_SIZE_MAX
	_cursor_size_slider.step = 2.0
	_cursor_size_slider.value = PlayerPrefs.cursor_size
	_cursor_size_slider.value_changed.connect(_on_cursor_size_changed)
	_cursor_size_label = _value_label("%dpx" % PlayerPrefs.cursor_size)
	_cursor_size_slider.value_changed.connect(func(v: float) -> void: _cursor_size_label.text = "%dpx" % int(v))
	box.add_child(_slider_row("Size", _cursor_size_slider, _cursor_size_label))

	box.add_child(_section_spacer())
	box.add_child(_section_header("Key Bindings"))

	_pending_bindings = PlayerPrefs.bindings.duplicate(true)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 240)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)

	# Right margin keeps the rebind buttons from butting against the scrollbar.
	var scroll_margin := MarginContainer.new()
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_theme_constant_override("margin_right", 12)
	scroll.add_child(scroll_margin)

	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_child(grid)

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
	box.add_child(_conflict_label)

	return box

func _build_game_tab() -> Control:
	var box := _tab_box()

	box.add_child(_section_header("Gameplay"))

	_attack_up_check = CheckButton.new()
	_attack_up_check.set_pressed_no_signal(PlayerPrefs.attack_up)
	SoundManager.wire_button(_attack_up_check)
	_attack_up_check.toggled.connect(_on_attack_up_toggled)
	box.add_child(_field_row("Always Attack Up", _attack_up_check))

	_colorblind_check = CheckButton.new()
	_colorblind_check.set_pressed_no_signal(PlayerPrefs.colorblind_rings)
	SoundManager.wire_button(_colorblind_check)
	_colorblind_check.toggled.connect(_on_colorblind_toggled)
	box.add_child(_field_row("Colorblind Team Colors", _colorblind_check))

	_self_beacon_check = CheckButton.new()
	_self_beacon_check.set_pressed_no_signal(PlayerPrefs.self_beacon_enabled)
	SoundManager.wire_button(_self_beacon_check)
	_self_beacon_check.toggled.connect(_on_self_beacon_toggled)
	box.add_child(_field_row("Self Marker", _self_beacon_check))

	_screen_flash_check = CheckButton.new()
	_screen_flash_check.set_pressed_no_signal(PlayerPrefs.screen_flash)
	SoundManager.wire_button(_screen_flash_check)
	_screen_flash_check.toggled.connect(_on_screen_flash_toggled)
	box.add_child(_field_row("Screen Flash Effects", _screen_flash_check))

	_screen_shake_check = CheckButton.new()
	_screen_shake_check.set_pressed_no_signal(PlayerPrefs.screen_shake)
	SoundManager.wire_button(_screen_shake_check)
	_screen_shake_check.toggled.connect(_on_screen_shake_toggled)
	box.add_child(_field_row("Camera Shake", _screen_shake_check))

	box.add_child(_section_spacer())
	box.add_child(_section_header("Camera"))

	_tilt_slider = HSlider.new()
	_tilt_slider.min_value = PlayerPrefs.CAMERA_TILT_MIN
	_tilt_slider.max_value = PlayerPrefs.CAMERA_TILT_MAX
	_tilt_slider.step = 0.5
	_tilt_slider.value = PlayerPrefs.camera_tilt_deg
	_tilt_slider.value_changed.connect(_on_tilt_changed)
	_tilt_label = _value_label("%.1f°" % PlayerPrefs.camera_tilt_deg)
	_tilt_slider.value_changed.connect(func(v: float) -> void: _tilt_label.text = "%.1f°" % v)
	box.add_child(_slider_row("Tilt", _tilt_slider, _tilt_label))

	_fov_slider = HSlider.new()
	_fov_slider.min_value = PlayerPrefs.FOV_MIN
	_fov_slider.max_value = PlayerPrefs.FOV_MAX
	_fov_slider.step = 1.0
	_fov_slider.value = PlayerPrefs.fov
	_fov_slider.value_changed.connect(_on_fov_changed)
	_fov_label = _value_label("%d°" % int(PlayerPrefs.fov))
	_fov_slider.value_changed.connect(func(v: float) -> void: _fov_label.text = "%d°" % int(v))
	box.add_child(_slider_row("FOV", _fov_slider, _fov_label))

	_cam_dist_slider = HSlider.new()
	_cam_dist_slider.min_value = PlayerPrefs.CAMERA_DISTANCE_MIN
	_cam_dist_slider.max_value = PlayerPrefs.CAMERA_DISTANCE_MAX
	_cam_dist_slider.step = 0.05
	_cam_dist_slider.value = PlayerPrefs.camera_distance
	_cam_dist_slider.value_changed.connect(_on_cam_dist_changed)
	_cam_dist_label = _value_label("%.2fx" % PlayerPrefs.camera_distance)
	_cam_dist_slider.value_changed.connect(func(v: float) -> void: _cam_dist_label.text = "%.2fx" % v)
	box.add_child(_slider_row("Distance", _cam_dist_slider, _cam_dist_label))

	box.add_child(_section_spacer())
	box.add_child(_section_header("Team Colors"))

	var export_btn := _make_button("Export Colors File...")
	export_btn.custom_minimum_size = Vector2(260, 40)
	export_btn.add_theme_font_size_override("font_size", 16)
	export_btn.pressed.connect(_on_export_colors_pressed)
	box.add_child(_field_row("Custom palette", export_btn))

	_export_status_label = Label.new()
	_export_status_label.add_theme_font_size_override("font_size", 12)
	_export_status_label.add_theme_color_override("font_color", _MUTED)
	_export_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_export_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_export_status_label.custom_minimum_size = Vector2(0, 0)
	box.add_child(_export_status_label)

	return box

# ---------------------------------------------------------------------------
# Signal handlers — controls only; no PlayerPrefs writes until Apply
# ---------------------------------------------------------------------------

func _on_fullscreen_toggled(_pressed: bool) -> void:
	_apply_res_disabled_state(_fs_check.button_pressed)
	_update_apply_state()


# Resolution only matters in windowed mode. We disable rather than hide the
# row so toggling fullscreen doesn't change the panel's height.
func _apply_res_disabled_state(fullscreen: bool) -> void:
	if _res_btn != null:
		_res_btn.disabled = fullscreen
	if _res_label != null:
		_res_label.add_theme_color_override("font_color",
			MenuStyle.TEXT_MUTED if fullscreen else _WHITE)

func _on_resolution_selected(_idx: int) -> void:
	_update_apply_state()

func _on_volume_changed(_value: float) -> void:
	_update_apply_state()

func _on_mute_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_vsync_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_fps_cap_selected(_idx: int) -> void:
	_update_apply_state()

func _on_show_fps_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_gamma_changed(_value: float) -> void:
	_update_apply_state()

func _on_color_grade_selected(_idx: int) -> void:
	_update_apply_state()

func _on_render_scale_changed(_value: float) -> void:
	_update_upscaling_enabled()
	_update_apply_state()

func _update_upscaling_enabled() -> void:
	if _scaling_3d_btn != null and _render_scale_slider != null:
		_scaling_3d_btn.disabled = is_equal_approx(_render_scale_slider.value, 1.0)

func _on_scaling_3d_selected(_idx: int) -> void:
	_update_aa_compatibility()
	_update_apply_state()

func _on_aa_selected(_idx: int) -> void:
	_update_apply_state()

# FSR2 has its own temporal reconstruction and Godot disallows TAA on top.
# Grey out the TAA item in the AA dropdown whenever FSR2 is the upscaling
# mode; if TAA happened to be selected, fall back to MSAA 2x so the
# dropdown reflects what will actually render.
func _update_aa_compatibility() -> void:
	if _aa_btn == null or _scaling_3d_btn == null:
		return
	var fsr2: bool = _scaling_3d_btn.selected == PlayerPrefs.SCALING_3D_FSR2
	_aa_btn.set_item_disabled(PlayerPrefs.AA_TAA, fsr2)
	if fsr2 and _aa_btn.selected == PlayerPrefs.AA_TAA:
		_aa_btn.selected = PlayerPrefs.AA_MSAA_2X

func _on_gi_mode_selected(_idx: int) -> void:
	_update_apply_state()

func _on_crowd_density_selected(_idx: int) -> void:
	_update_apply_state()

func _on_ice_scratches_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_attack_up_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_colorblind_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_self_beacon_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_screen_flash_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_screen_shake_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_confine_mouse_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_cursor_style_selected(_idx: int) -> void:
	_update_apply_state()

func _on_cursor_color_changed(_color: Color) -> void:
	_update_apply_state()

func _on_cursor_size_changed(_value: float) -> void:
	_update_apply_state()

func _on_tilt_changed(_value: float) -> void:
	_update_apply_state()

func _on_fov_changed(value: float) -> void:
	if _fov_label != null:
		_fov_label.text = "%d°" % int(value)
	_update_apply_state()

func _on_cam_dist_changed(value: float) -> void:
	if _cam_dist_label != null:
		_cam_dist_label.text = "%.2fx" % value
	_update_apply_state()

func _on_export_colors_pressed() -> void:
	const SRC: String = "res://data/team_colors.json"
	const DST: String = "user://team_colors.json"
	var src_file := FileAccess.open(SRC, FileAccess.READ)
	if src_file == null:
		_export_status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
		_export_status_label.text = "Error: bundled colors file not found."
		return
	var content: String = src_file.get_as_text()
	src_file.close()
	var existed: bool = FileAccess.file_exists(DST)
	var dst_file := FileAccess.open(DST, FileAccess.WRITE)
	if dst_file == null:
		_export_status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
		_export_status_label.text = "Error: could not write to user data folder."
		return
	dst_file.store_string(content)
	dst_file.close()
	var global_path: String = ProjectSettings.globalize_path(DST)
	_export_status_label.add_theme_color_override("font_color", _DIM)
	_export_status_label.text = "%s:\n%s" % ["Overwrote" if existed else "Saved", global_path]

func _on_sensitivity_changed(value: float) -> void:
	if _sens_field != null:
		_sens_field.text = "%.2f" % value
	_update_apply_state()

func _on_sensitivity_typed(text: String) -> void:
	var value: float = clampf(text.to_float(), 0.5, 3.0)
	if _sens_slider != null:
		_sens_slider.value = value

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
		_update_apply_state()
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
		_update_apply_state()
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

# ---------------------------------------------------------------------------
# Apply / Cancel
# ---------------------------------------------------------------------------

func _on_apply_pressed() -> void:
	var c: Dictionary = _read_controls()
	PlayerPrefs.is_fullscreen = c.fullscreen
	PlayerPrefs.resolution_index = c.resolution_index
	PlayerPrefs.vsync_enabled = c.vsync_enabled
	PlayerPrefs.fps_cap_index = c.fps_cap_index
	PlayerPrefs.show_fps = c.show_fps
	PlayerPrefs.gamma = c.gamma
	PlayerPrefs.color_grade_preset = c.color_grade_preset
	PlayerPrefs.gi_mode = c.gi_mode
	PlayerPrefs.crowd_density = c.crowd_density
	PlayerPrefs.ice_scratches_enabled = c.ice_scratches_enabled
	PlayerPrefs.render_scale = c.render_scale
	PlayerPrefs.scaling_3d_mode = c.scaling_3d_mode
	PlayerPrefs.anti_aliasing_mode = c.anti_aliasing_mode
	PlayerPrefs.master_volume = c.master_volume
	PlayerPrefs.sfx_volume = c.sfx_volume
	PlayerPrefs.ui_volume = c.ui_volume
	PlayerPrefs.crowd_volume = c.crowd_volume
	PlayerPrefs.master_muted = c.master_muted
	PlayerPrefs.mouse_sensitivity = c.mouse_sensitivity
	PlayerPrefs.confine_mouse = c.confine_mouse
	PlayerPrefs.cursor_style = c.cursor_style
	PlayerPrefs.cursor_color = c.cursor_color
	PlayerPrefs.cursor_size = c.cursor_size
	PlayerPrefs.attack_up = c.attack_up
	PlayerPrefs.colorblind_rings = c.colorblind_rings
	PlayerPrefs.self_beacon_enabled = c.self_beacon_enabled
	PlayerPrefs.screen_flash = c.screen_flash
	PlayerPrefs.screen_shake = c.screen_shake
	PlayerPrefs.camera_tilt_deg = c.camera_tilt_deg
	PlayerPrefs.fov = c.fov
	PlayerPrefs.camera_distance = c.camera_distance
	PlayerPrefs.bindings = (_pending_bindings as Dictionary).duplicate(true)
	PlayerPrefs.apply_audio()
	PlayerPrefs.apply_video()
	PlayerPrefs.apply_input()
	PlayerPrefs.apply_cursor()
	PlayerPrefs.apply_bindings()
	PlayerPrefs.save()
	_original = _snapshot()
	_apply_btn.disabled = true
	close_requested.emit()

func _on_cancel_pressed() -> void:
	_fs_check.set_pressed_no_signal(_original.fullscreen)
	_apply_res_disabled_state(_original.fullscreen)
	_res_btn.selected = _original.resolution_index
	_vsync_check.set_pressed_no_signal(_original.vsync_enabled)
	_fps_btn.selected = _original.fps_cap_index
	if _show_fps_check != null:
		_show_fps_check.set_pressed_no_signal(_original.show_fps)
	_gamma_slider.value = _original.gamma
	if _color_grade_btn != null:
		_color_grade_btn.selected = _original.color_grade_preset
	if _gi_mode_btn != null:
		_gi_mode_btn.selected = _original.gi_mode
	if _crowd_density_btn != null:
		_crowd_density_btn.selected = _original.crowd_density
	if _ice_scratches_check != null:
		_ice_scratches_check.set_pressed_no_signal(_original.ice_scratches_enabled)
	if _render_scale_slider != null:
		_render_scale_slider.value = _original.render_scale
	if _scaling_3d_btn != null:
		_scaling_3d_btn.selected = _original.scaling_3d_mode
	if _aa_btn != null:
		_aa_btn.selected = _original.anti_aliasing_mode
	_update_aa_compatibility()
	_volume_slider.value = _original.master_volume
	_sfx_slider.value = _original.sfx_volume
	_ui_slider.value = _original.ui_volume
	_crowd_slider.value = _original.crowd_volume
	_mute_check.set_pressed_no_signal(_original.master_muted)
	_sens_slider.value = _original.mouse_sensitivity
	if _confine_mouse_check != null:
		_confine_mouse_check.set_pressed_no_signal(_original.confine_mouse)
	if _cursor_style_btn != null:
		_cursor_style_btn.selected = _original.cursor_style
	if _cursor_color_btn != null:
		_cursor_color_btn.color = _original.cursor_color
	if _cursor_size_slider != null:
		_cursor_size_slider.value = _original.cursor_size
	_attack_up_check.set_pressed_no_signal(_original.attack_up)
	if _colorblind_check != null:
		_colorblind_check.set_pressed_no_signal(_original.colorblind_rings)
	if _self_beacon_check != null:
		_self_beacon_check.set_pressed_no_signal(_original.self_beacon_enabled)
	if _screen_flash_check != null:
		_screen_flash_check.set_pressed_no_signal(_original.screen_flash)
	if _screen_shake_check != null:
		_screen_shake_check.set_pressed_no_signal(_original.screen_shake)
	if _tilt_slider != null:
		_tilt_slider.value = _original.camera_tilt_deg
	if _fov_slider != null:
		_fov_slider.value = _original.fov
	if _cam_dist_slider != null:
		_cam_dist_slider.value = _original.camera_distance
	_listening_action = ""
	_pending_bindings = (_original.get("bindings", {}) as Dictionary).duplicate(true)
	_update_binding_btns()
	if _conflict_label != null:
		_conflict_label.text = ""
	close_requested.emit()

# ---------------------------------------------------------------------------
# Tab-layout helpers — every tab uses the same building blocks so labels and
# controls line up across rows and between tabs.
# ---------------------------------------------------------------------------

# Outer VBox for a tab's content. 10px between consecutive rows; section
# headers add their own extra top padding via _section_spacer().
func _tab_box() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return box


# Small-caps muted heading used to group rows into named sections.
func _section_header(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", _SECTION_FONT_SIZE)
	l.add_theme_color_override("font_color", _MUTED)
	return l


# Vertical breathing room above a non-first section header.
func _section_spacer() -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, 8)
	return s


# Standard label + control row. Label sits in a fixed-width column on the left
# so controls line up across every row in the tab.
func _field_row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 14)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(_LABEL_COL_WIDTH, 0)
	lbl.add_theme_font_size_override("font_size", _LABEL_FONT_SIZE)
	lbl.add_theme_color_override("font_color", _WHITE)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)
	row.add_child(control)
	return row


# Label + slider that fills + fixed-width value label on the right. Slider
# is set to expand horizontally so its width tracks the row width.
func _slider_row(label_text: String, slider: HSlider, value_control: Control) -> HBoxContainer:
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var pair := HBoxContainer.new()
	pair.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pair.add_theme_constant_override("separation", 12)
	pair.add_child(slider)
	pair.add_child(value_control)

	return _field_row(label_text, pair)


# Right-aligned dim numeric value label shown to the right of a slider.
func _value_label(text: String, min_width: int = _VALUE_COL_WIDTH) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(min_width, 0)
	l.add_theme_font_size_override("font_size", _VALUE_FONT_SIZE)
	l.add_theme_color_override("font_color", _DIM)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l


func _make_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(308, 48)
	btn.add_theme_font_size_override("font_size", 20)
	SoundManager.wire_button(btn)
	return btn

func _make_small_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(148, 48)
	btn.add_theme_font_size_override("font_size", 20)
	SoundManager.wire_button(btn)
	return btn
