class_name OptionsPanel
extends VBoxContainer

signal close_requested

var _res_row: HBoxContainer = null
var _res_label: Label = null   # dimmed in fullscreen modes (resolution disabled)
var _window_mode_btn: OptionButton = null
var _monitor_btn: OptionButton = null
var _mute_check: CheckButton = null
var _mute_unfocused_check: CheckButton = null
var _volume_slider: HSlider = null
var _sfx_slider: HSlider = null
var _ui_slider: HSlider = null
var _arena_slider: HSlider = null
var _res_btn: OptionButton = null
var _res_values: Array[Vector2i] = []   # parallel to _res_btn items
var _windowed_res_idx: int = 0          # the committed windowed pick (survives fullscreen display swap)
var _native_res_idx: int = 0            # the monitor's native entry, shown (greyed) in fullscreen modes
var _suppress_ring_sync: bool = false   # guards re-entrancy while a ring preset writes the pickers
var _tab_contents: Array[Control] = []
var _tab_btns: Array[Button] = []
var _vsync_btn: OptionButton = null
var _fps_btn: OptionButton = null
var _show_fps_check: CheckButton = null
var _gamma_slider: HSlider = null
var _color_grade_btn: OptionButton = null
var _gi_mode_btn: OptionButton = null
var _crowd_density_btn: OptionButton = null
var _ice_scratches_check: CheckButton = null
var _puck_shadow_check: CheckButton = null
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
var _ring_preset_btn: OptionButton = null
var _ring_self_color_btn: ColorPickerButton = null
var _ring_team_color_btn: ColorPickerButton = null
var _ring_enemy_color_btn: ColorPickerButton = null
var _hud_scale_slider: HSlider = null
var _hud_scale_label: Label = null
var _share_stats_check: CheckButton = null
var _self_beacon_mode_btn: OptionButton = null
var _freeplay_goalie_btn: OptionButton = null
var _screen_flash_check: CheckButton = null
var _screen_shake_check: CheckButton = null
var _camera_mode_btn: OptionButton = null
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
var _bot_export_status_label: Label = null

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
# Hard cap on the tab-content viewport. Each tab is wrapped in a fixed-height
# ScrollContainer of this size, so every tab is identically tall (the popup
# never resizes when switching) and any tab whose content exceeds the cap
# scrolls instead of overflowing. Sized to fit comfortably inside the smallest
# supported window with room for the popup chrome (title + tab bar + buttons).
const _TAB_VIEWPORT_SIZE := Vector2(500, 500)
const _SCROLLBAR_GUTTER := 12   # reserved on every tab so columns line up scroll-or-not
const _INPUT_TAB_IDX := 3       # index into the tab list (Game, Video, Audio, Input)
const _REBINDABLE_ACTIONS: Array = [
	{"action": "move_up",        "label": "Move Up"},
	{"action": "move_down",      "label": "Move Down"},
	{"action": "move_left",      "label": "Move Left"},
	{"action": "move_right",     "label": "Move Right"},
	{"action": "sprint",         "label": "Sprint"},
	{"action": "brake",          "label": "Brake"},
	{"action": "shoot",          "label": "Shoot"},
	{"action": "quick_shot",     "label": "Quick Shot / Pass"},
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

	var reset_btn := _make_small_button("Defaults")
	reset_btn.tooltip_text = "Reset all options to their defaults (preview — applies on Apply)"
	reset_btn.pressed.connect(_on_reset_pressed)
	btn_row.add_child(reset_btn)

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
		"window_mode": PlayerPrefs.window_mode,
		"resolution": PlayerPrefs.resolution,
		"display_monitor": PlayerPrefs.display_monitor,
		"vsync_mode": PlayerPrefs.vsync_mode,
		"fps_cap_index": PlayerPrefs.fps_cap_index,
		"show_fps": PlayerPrefs.show_fps,
		"gamma": PlayerPrefs.gamma,
		"color_grade_preset": PlayerPrefs.color_grade_preset,
		"gi_mode": PlayerPrefs.gi_mode,
		"crowd_density": PlayerPrefs.crowd_density,
		"ice_scratches_enabled": PlayerPrefs.ice_scratches_enabled,
		"puck_shadow_enabled": PlayerPrefs.puck_shadow_enabled,
		"render_scale": PlayerPrefs.render_scale,
		"scaling_3d_mode": PlayerPrefs.scaling_3d_mode,
		"anti_aliasing_mode": PlayerPrefs.anti_aliasing_mode,
		"master_volume": PlayerPrefs.master_volume,
		"sfx_volume": PlayerPrefs.sfx_volume,
		"ui_volume": PlayerPrefs.ui_volume,
		"arena_volume": PlayerPrefs.arena_volume,
		"master_muted": PlayerPrefs.master_muted,
		"mute_when_unfocused": PlayerPrefs.mute_when_unfocused,
		"mouse_sensitivity": PlayerPrefs.mouse_sensitivity,
		"confine_mouse": PlayerPrefs.confine_mouse,
		"cursor_style": PlayerPrefs.cursor_style,
		"cursor_color": PlayerPrefs.cursor_color,
		"cursor_size": PlayerPrefs.cursor_size,
		"attack_up": PlayerPrefs.attack_up,
		"ring_color_self": PlayerPrefs.ring_color_self,
		"ring_color_team": PlayerPrefs.ring_color_team,
		"ring_color_enemy": PlayerPrefs.ring_color_enemy,
		"self_beacon_mode": PlayerPrefs.self_beacon_mode,
		"freeplay_goalie_difficulty": PlayerPrefs.freeplay_goalie_difficulty,
		"screen_flash": PlayerPrefs.screen_flash,
		"screen_shake": PlayerPrefs.screen_shake,
		"camera_tilt_deg": PlayerPrefs.camera_tilt_deg,
		"fov": PlayerPrefs.fov,
		"camera_distance": PlayerPrefs.camera_distance,
		"camera_mode": PlayerPrefs.camera_mode,
		"hud_scale": PlayerPrefs.hud_scale,
		"share_gameplay_stats": PlayerPrefs.share_gameplay_stats,
		"bindings": PlayerPrefs.bindings.duplicate(true),
	}

func _read_controls() -> Dictionary:
	return {
		"window_mode": _window_mode_btn.selected,
		"resolution": _selected_resolution(),
		"display_monitor": _selected_monitor(),
		"vsync_mode": _vsync_btn.selected,
		"fps_cap_index": _fps_btn.selected,
		"show_fps": _show_fps_check.button_pressed,
		"gamma": _gamma_slider.value,
		"color_grade_preset": _color_grade_btn.selected,
		"gi_mode": _gi_mode_btn.selected,
		"crowd_density": _crowd_density_btn.selected,
		"ice_scratches_enabled": _ice_scratches_check.button_pressed,
		"puck_shadow_enabled": _puck_shadow_check.button_pressed,
		"render_scale": _render_scale_slider.value,
		"scaling_3d_mode": _scaling_3d_btn.selected,
		"anti_aliasing_mode": _aa_btn.selected,
		"master_volume": _volume_slider.value,
		"sfx_volume": _sfx_slider.value,
		"ui_volume": _ui_slider.value,
		"arena_volume": _arena_slider.value,
		"master_muted": _mute_check.button_pressed,
		"mute_when_unfocused": _mute_unfocused_check.button_pressed,
		"mouse_sensitivity": _sens_slider.value,
		"confine_mouse": _confine_mouse_check.button_pressed,
		"cursor_style": _cursor_style_btn.selected,
		"cursor_color": _cursor_color_btn.color,
		"cursor_size": int(_cursor_size_slider.value),
		"attack_up": _attack_up_check.button_pressed,
		"ring_color_self": _ring_self_color_btn.color,
		"ring_color_team": _ring_team_color_btn.color,
		"ring_color_enemy": _ring_enemy_color_btn.color,
		"self_beacon_mode": _self_beacon_mode_btn.selected,
		"freeplay_goalie_difficulty": _freeplay_goalie_btn.selected,
		"screen_flash": _screen_flash_check.button_pressed,
		"screen_shake": _screen_shake_check.button_pressed,
		"camera_tilt_deg": _tilt_slider.value,
		"fov": _fov_slider.value,
		"camera_distance": _cam_dist_slider.value,
		"camera_mode": _camera_mode_btn.selected,
		"hud_scale": _hud_scale_slider.value,
		"share_gameplay_stats": _share_stats_check.button_pressed,
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

	# Pin the tab-content viewport to a fixed cap so the popup never resizes when
	# switching between tabs of different heights. Each tab is wrapped in a
	# fixed-height scroll viewport (see _scroll_wrap), so short tabs simply leave
	# headroom and tall tabs scroll rather than overflowing the popup.
	var content_margin := MarginContainer.new()
	content_margin.custom_minimum_size = _TAB_VIEWPORT_SIZE
	content_margin.add_theme_constant_override("margin_top", 16)
	content_margin.add_theme_constant_override("margin_bottom", 8)
	content_margin.add_theme_constant_override("margin_left", 0)
	content_margin.add_theme_constant_override("margin_right", 0)
	wrapper.add_child(content_margin)

	# _tab_contents holds the scroll wrappers — those are the nodes whose
	# visibility _activate_tab toggles.
	for tab: Control in [_build_game_tab(), _build_video_tab(), _build_audio_tab(), _build_input_tab()]:
		var scroll := _scroll_wrap(tab)
		_tab_contents.append(scroll)
		content_margin.add_child(scroll)

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
	# Leaving the Input tab mid-rebind cancels the pending key-listen.
	if idx != _INPUT_TAB_IDX and not _listening_action.is_empty():
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

	_window_mode_btn = OptionButton.new()
	_window_mode_btn.custom_minimum_size = Vector2(220, 40)
	_window_mode_btn.add_theme_font_size_override("font_size", 15)
	for label: String in PlayerPrefs.WINDOW_MODE_LABELS:
		_window_mode_btn.add_item(label)
	_window_mode_btn.selected = PlayerPrefs.window_mode
	_window_mode_btn.item_selected.connect(_on_window_mode_selected)
	box.add_child(_field_row("Window Mode", _window_mode_btn))

	# Monitor selector — only meaningful with more than one screen, so the row
	# is added only on multi-monitor rigs. Item 0 = Automatic (follow the
	# window); items 1..n target screen index 0..n-1.
	_monitor_btn = OptionButton.new()
	_monitor_btn.custom_minimum_size = Vector2(220, 40)
	_monitor_btn.add_theme_font_size_override("font_size", 15)
	_monitor_btn.add_item("Automatic")
	var screen_count: int = DisplayServer.get_screen_count()
	for s: int in screen_count:
		_monitor_btn.add_item("Monitor %d" % (s + 1))
	_monitor_btn.selected = clampi(PlayerPrefs.display_monitor + 1, 0, screen_count)
	_monitor_btn.item_selected.connect(_on_monitor_selected)
	if screen_count > 1:
		box.add_child(_field_row("Monitor", _monitor_btn))

	_res_btn = OptionButton.new()
	_res_btn.custom_minimum_size = Vector2(220, 40)
	_res_btn.add_theme_font_size_override("font_size", 15)
	_populate_resolutions()
	_res_btn.item_selected.connect(_on_resolution_selected)
	_res_row = _field_row("Resolution", _res_btn)
	# Cache the label so we can dim it when the resolution row is disabled.
	_res_label = _res_row.get_child(0) as Label
	box.add_child(_res_row)
	_apply_res_disabled_state(PlayerPrefs.window_mode != PlayerPrefs.WINDOW_MODE_WINDOWED)

	_vsync_btn = OptionButton.new()
	_vsync_btn.custom_minimum_size = Vector2(160, 40)
	_vsync_btn.add_theme_font_size_override("font_size", 15)
	for label: String in PlayerPrefs.VSYNC_LABELS:
		_vsync_btn.add_item(label)
	_vsync_btn.selected = PlayerPrefs.vsync_mode
	_vsync_btn.item_selected.connect(_on_vsync_selected)
	box.add_child(_field_row("VSync", _vsync_btn))

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

	_puck_shadow_check = CheckButton.new()
	_puck_shadow_check.set_pressed_no_signal(PlayerPrefs.puck_shadow_enabled)
	SoundManager.wire_button(_puck_shadow_check)
	_puck_shadow_check.toggled.connect(_on_puck_shadow_toggled)
	box.add_child(_field_row("Puck Shadow", _puck_shadow_check))

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

	_arena_slider = _make_volume_slider(PlayerPrefs.arena_volume)
	var arena_val := _value_label("%d%%" % int(PlayerPrefs.arena_volume * 100))
	_arena_slider.value_changed.connect(func(v: float) -> void: arena_val.text = "%d%%" % int(v * 100))
	box.add_child(_slider_row("Arena", _arena_slider, arena_val))

	box.add_child(_section_spacer())

	_mute_check = CheckButton.new()
	_mute_check.set_pressed_no_signal(PlayerPrefs.master_muted)
	SoundManager.wire_button(_mute_check)
	_mute_check.toggled.connect(_on_mute_toggled)
	box.add_child(_field_row("Mute All", _mute_check))

	_mute_unfocused_check = CheckButton.new()
	_mute_unfocused_check.set_pressed_no_signal(PlayerPrefs.mute_when_unfocused)
	SoundManager.wire_button(_mute_unfocused_check)
	_mute_unfocused_check.toggled.connect(_on_mute_unfocused_toggled)
	box.add_child(_field_row("Mute When Unfocused", _mute_unfocused_check))

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

	# No inner scroll here — the whole tab scrolls via the _scroll_wrap viewport,
	# so the rebind list just flows into the page.
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(grid)

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

	_self_beacon_mode_btn = OptionButton.new()
	_self_beacon_mode_btn.custom_minimum_size = Vector2(160, 40)
	_self_beacon_mode_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.BEACON_MODE_LABELS.size():
		_self_beacon_mode_btn.add_item(PlayerPrefs.BEACON_MODE_LABELS[i], i)
	_self_beacon_mode_btn.selected = PlayerPrefs.self_beacon_mode
	_self_beacon_mode_btn.item_selected.connect(_on_self_beacon_mode_selected)
	box.add_child(_field_row("Self Marker", _self_beacon_mode_btn))

	# Free-play goalie difficulty — a personal-sandbox knob, separate from the
	# hosted/lobby goalie setting (which lives in the lobby settings panel). Applies
	# live to the running free-play goalies on Apply (no match reload needed).
	_freeplay_goalie_btn = OptionButton.new()
	_freeplay_goalie_btn.custom_minimum_size = Vector2(160, 40)
	_freeplay_goalie_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.GOALIE_DIFFICULTY_LABELS.size():
		_freeplay_goalie_btn.add_item(PlayerPrefs.GOALIE_DIFFICULTY_LABELS[i], i)
	_freeplay_goalie_btn.selected = PlayerPrefs.freeplay_goalie_difficulty
	SoundManager.wire_button(_freeplay_goalie_btn)
	_freeplay_goalie_btn.item_selected.connect(_on_freeplay_goalie_selected)
	box.add_child(_field_row("Free Play Goalie", _freeplay_goalie_btn))

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
	box.add_child(_section_header("Ring Colors"))

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
	box.add_child(_field_row("Preset", _ring_preset_btn))

	_ring_self_color_btn = ColorPickerButton.new()
	_ring_self_color_btn.custom_minimum_size = Vector2(160, 36)
	_ring_self_color_btn.color = PlayerPrefs.ring_color_self
	_ring_self_color_btn.edit_alpha = false
	SoundManager.wire_button(_ring_self_color_btn)
	_ring_self_color_btn.color_changed.connect(_on_ring_color_changed)
	box.add_child(_field_row("Your Ring", _ring_self_color_btn))

	_ring_team_color_btn = ColorPickerButton.new()
	_ring_team_color_btn.custom_minimum_size = Vector2(160, 36)
	_ring_team_color_btn.color = PlayerPrefs.ring_color_team
	_ring_team_color_btn.edit_alpha = false
	SoundManager.wire_button(_ring_team_color_btn)
	_ring_team_color_btn.color_changed.connect(_on_ring_color_changed)
	box.add_child(_field_row("Ally Rings", _ring_team_color_btn))

	_ring_enemy_color_btn = ColorPickerButton.new()
	_ring_enemy_color_btn.custom_minimum_size = Vector2(160, 36)
	_ring_enemy_color_btn.color = PlayerPrefs.ring_color_enemy
	_ring_enemy_color_btn.edit_alpha = false
	SoundManager.wire_button(_ring_enemy_color_btn)
	_ring_enemy_color_btn.color_changed.connect(_on_ring_color_changed)
	box.add_child(_field_row("Enemy Rings", _ring_enemy_color_btn))
	_sync_ring_preset_selection()

	box.add_child(_section_spacer())
	box.add_child(_section_header("Camera"))

	_camera_mode_btn = OptionButton.new()
	_camera_mode_btn.custom_minimum_size = Vector2(160, 40)
	_camera_mode_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.CAMERA_MODE_LABELS.size():
		_camera_mode_btn.add_item(PlayerPrefs.CAMERA_MODE_LABELS[i], i)
	_camera_mode_btn.selected = PlayerPrefs.camera_mode
	_camera_mode_btn.item_selected.connect(_on_camera_mode_selected)
	box.add_child(_field_row("Mode", _camera_mode_btn))

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

	_hud_scale_slider = HSlider.new()
	_hud_scale_slider.min_value = PlayerPrefs.HUD_SCALE_MIN
	_hud_scale_slider.max_value = PlayerPrefs.HUD_SCALE_MAX
	_hud_scale_slider.step = 0.05
	_hud_scale_slider.value = PlayerPrefs.hud_scale
	_hud_scale_slider.value_changed.connect(_on_hud_scale_changed)
	_hud_scale_label = _value_label("%d%%" % roundi(PlayerPrefs.hud_scale * 100.0))
	_hud_scale_slider.value_changed.connect(func(v: float) -> void: _hud_scale_label.text = "%d%%" % roundi(v * 100.0))
	box.add_child(_slider_row("HUD Scale", _hud_scale_slider, _hud_scale_label))

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

	box.add_child(_section_spacer())
	box.add_child(_section_header("Bot Roster"))

	var bots_hint := Label.new()
	bots_hint.add_theme_font_size_override("font_size", 12)
	bots_hint.add_theme_color_override("font_color", _MUTED)
	bots_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bots_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bots_hint.text = "Edit AI bot names, numbers, and attributes. As host, your roster is used for the whole lobby. Builds over the point-buy budget reset to medium."
	box.add_child(bots_hint)

	var bots_export_btn := _make_button("Export Bots File...")
	bots_export_btn.custom_minimum_size = Vector2(260, 40)
	bots_export_btn.add_theme_font_size_override("font_size", 16)
	bots_export_btn.pressed.connect(_on_export_bots_pressed)
	box.add_child(_field_row("Custom bots", bots_export_btn))

	_bot_export_status_label = Label.new()
	_bot_export_status_label.add_theme_font_size_override("font_size", 12)
	_bot_export_status_label.add_theme_color_override("font_color", _MUTED)
	_bot_export_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bot_export_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bot_export_status_label.custom_minimum_size = Vector2(0, 0)
	box.add_child(_bot_export_status_label)

	box.add_child(_section_spacer())
	box.add_child(_section_header("Data Sharing"))

	_share_stats_check = CheckButton.new()
	_share_stats_check.set_pressed_no_signal(PlayerPrefs.share_gameplay_stats)
	SoundManager.wire_button(_share_stats_check)
	_share_stats_check.toggled.connect(_on_share_stats_toggled)
	box.add_child(_field_row("Share Gameplay Stats", _share_stats_check))

	var stats_notice := Label.new()
	stats_notice.text = "Uploads match results so you can track your career. " \
		+ "With this off, the Career menu and replay playback are unavailable — " \
		+ "both are built from your uploaded games."
	stats_notice.add_theme_font_size_override("font_size", 12)
	stats_notice.add_theme_color_override("font_color", _MUTED)
	stats_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_notice.custom_minimum_size = Vector2(380, 0)
	box.add_child(stats_notice)

	return box

# ---------------------------------------------------------------------------
# Signal handlers — controls only; no PlayerPrefs writes until Apply
# ---------------------------------------------------------------------------

func _on_window_mode_selected(_idx: int) -> void:
	_apply_res_disabled_state(_window_mode_btn.selected != PlayerPrefs.WINDOW_MODE_WINDOWED)
	_refresh_res_display()
	_update_apply_state()

func _on_monitor_selected(_idx: int) -> void:
	# A different monitor can support a different resolution set; rebuild the
	# dropdown against the newly chosen screen (preview only — no prefs write).
	_populate_resolutions()
	_update_apply_state()

# Resolution only matters in windowed mode. We disable rather than hide the
# row so changing window mode doesn't change the panel's height.
func _apply_res_disabled_state(disabled: bool) -> void:
	if _res_btn != null:
		_res_btn.disabled = disabled
	if _res_label != null:
		_res_label.add_theme_color_override("font_color",
			MenuStyle.TEXT_MUTED if disabled else _WHITE)

# Builds the resolution dropdown from the monitor-filtered list. Records the
# entry nearest the saved resolution (_windowed_res_idx — the committed windowed
# pick) and the monitor's native entry (_native_res_idx, tagged "(Native)").
# In fullscreen modes the box is greyed and shows the native entry, since that
# IS what those modes render at; windowed modes show the picked size.
func _populate_resolutions() -> void:
	var screen: int = _query_screen()
	_res_values = PlayerPrefs.get_available_resolutions(screen)
	var native: Vector2i = DisplayServer.screen_get_size(screen)
	var target: int = PlayerPrefs.resolution.x * PlayerPrefs.resolution.y
	_res_btn.clear()
	var best_idx: int = 0
	var best_delta: int = 1 << 62
	_native_res_idx = 0
	for i: int in _res_values.size():
		var r: Vector2i = _res_values[i]
		var label: String = "%d x %d" % [r.x, r.y]
		if r == native:
			label += "  (Native)"
			_native_res_idx = i
		_res_btn.add_item(label, i)
		var delta: int = absi(r.x * r.y - target)
		if delta < best_delta:
			best_delta = delta
			best_idx = i
	_windowed_res_idx = best_idx
	_refresh_res_display()

# Points the (possibly greyed) dropdown at the right entry for the current mode:
# the native resolution while fullscreen — what the GPU actually renders — or
# the committed windowed pick otherwise. Programmatic, so it never disturbs
# _windowed_res_idx.
func _refresh_res_display() -> void:
	if _window_mode_btn.selected == PlayerPrefs.WINDOW_MODE_WINDOWED:
		_res_btn.selected = _windowed_res_idx
	else:
		_res_btn.selected = _native_res_idx

# Screen the resolution list should be queried against: the monitor picked in
# the dropdown, or the current window's screen when set to Automatic.
func _query_screen() -> int:
	var sel: int = _selected_monitor()
	if sel >= 0 and sel < DisplayServer.get_screen_count():
		return sel
	return DisplayServer.window_get_current_screen()

# The committed windowed resolution — driven by _windowed_res_idx, NOT the
# greyed native size shown in fullscreen — so applying in fullscreen leaves the
# saved windowed size intact.
func _selected_resolution() -> Vector2i:
	if _windowed_res_idx >= 0 and _windowed_res_idx < _res_values.size():
		return _res_values[_windowed_res_idx]
	return PlayerPrefs.resolution

# Item 0 is "Automatic" → -1; items 1..n map to screen index 0..n-1.
func _selected_monitor() -> int:
	return _monitor_btn.selected - 1

func _on_resolution_selected(_idx: int) -> void:
	# Only fires when the box is enabled (windowed); record the new windowed pick.
	_windowed_res_idx = _res_btn.selected
	_update_apply_state()

func _on_volume_changed(_value: float) -> void:
	_update_apply_state()

func _on_mute_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_mute_unfocused_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_vsync_selected(_idx: int) -> void:
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

func _on_puck_shadow_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_attack_up_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_freeplay_goalie_selected(_idx: int) -> void:
	_update_apply_state()

func _on_ring_color_changed(_color: Color) -> void:
	# A manual tweak (not a preset write) means the palette is no longer one of
	# the curated sets — reflect that as "Custom".
	if not _suppress_ring_sync:
		_sync_ring_preset_selection()
	_update_apply_state()

# Curated self / ally / enemy ring palettes. "Default" restores the canonical
# green/blue/red; the three deficiency presets are starting points the player
# can fine-tune with the pickers (they're built around hues that stay separable
# under each common form of color blindness — light/neutral self, cool ally,
# warm enemy). Not persisted: the selection is re-derived from the live colors
# whenever the panel opens (see _sync_ring_preset_selection).
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
	_update_apply_state()

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

func _on_hud_scale_changed(_value: float) -> void:
	_update_apply_state()

func _on_share_stats_toggled(_pressed: bool) -> void:
	_update_apply_state()

func _on_self_beacon_mode_selected(_idx: int) -> void:
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

func _on_camera_mode_selected(_idx: int) -> void:
	_update_apply_state()

func _on_export_colors_pressed() -> void:
	_export_user_file("res://data/team_colors.json", "user://team_colors.json", _export_status_label)


func _on_export_bots_pressed() -> void:
	_export_user_file("res://data/bot_identities.json", "user://bot_identities.json", _bot_export_status_label)


# Copies a bundled res:// data file to its editable user:// counterpart and
# reports the absolute path (via the given status label) so the player can find
# and edit it. Shared by the Team Colors and Bot Roster export buttons.
func _export_user_file(src_path: String, dst_path: String, status_label: Label) -> void:
	var src_file := FileAccess.open(src_path, FileAccess.READ)
	if src_file == null:
		status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
		status_label.text = "Error: bundled file not found."
		return
	var content: String = src_file.get_as_text()
	src_file.close()
	var existed: bool = FileAccess.file_exists(dst_path)
	var dst_file := FileAccess.open(dst_path, FileAccess.WRITE)
	if dst_file == null:
		status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
		status_label.text = "Error: could not write to user data folder."
		return
	dst_file.store_string(content)
	dst_file.close()
	var global_path: String = ProjectSettings.globalize_path(dst_path)
	status_label.add_theme_color_override("font_color", _DIM)
	# Both rosters are read once and cached for the process lifetime (the
	# registries' static `_loaded` guard), so an edit only takes effect on the
	# next launch — tell the player so they don't think their changes were lost.
	status_label.text = "%s:\n%s\nEdit it, then restart the game to apply your changes." % [
			"Overwrote" if existed else "Saved", global_path]

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
	# Capture the pre-apply display state so a revert dialog can roll back a
	# window mode / resolution / monitor change that left the screen unusable.
	var display_changed: bool = (
		c.window_mode != _original.window_mode
		or c.resolution != _original.resolution
		or c.display_monitor != _original.display_monitor)
	var prev_mode: int = _original.window_mode
	var prev_res: Vector2i = _original.resolution
	var prev_mon: int = _original.display_monitor
	PlayerPrefs.window_mode = c.window_mode
	PlayerPrefs.resolution = c.resolution
	PlayerPrefs.display_monitor = c.display_monitor
	PlayerPrefs.vsync_mode = c.vsync_mode
	PlayerPrefs.fps_cap_index = c.fps_cap_index
	PlayerPrefs.show_fps = c.show_fps
	PlayerPrefs.gamma = c.gamma
	PlayerPrefs.color_grade_preset = c.color_grade_preset
	PlayerPrefs.gi_mode = c.gi_mode
	PlayerPrefs.crowd_density = c.crowd_density
	PlayerPrefs.ice_scratches_enabled = c.ice_scratches_enabled
	PlayerPrefs.puck_shadow_enabled = c.puck_shadow_enabled
	PlayerPrefs.render_scale = c.render_scale
	PlayerPrefs.scaling_3d_mode = c.scaling_3d_mode
	PlayerPrefs.anti_aliasing_mode = c.anti_aliasing_mode
	PlayerPrefs.master_volume = c.master_volume
	PlayerPrefs.sfx_volume = c.sfx_volume
	PlayerPrefs.ui_volume = c.ui_volume
	PlayerPrefs.arena_volume = c.arena_volume
	PlayerPrefs.master_muted = c.master_muted
	PlayerPrefs.mute_when_unfocused = c.mute_when_unfocused
	PlayerPrefs.mouse_sensitivity = c.mouse_sensitivity
	PlayerPrefs.confine_mouse = c.confine_mouse
	PlayerPrefs.cursor_style = c.cursor_style
	PlayerPrefs.cursor_color = c.cursor_color
	PlayerPrefs.cursor_size = c.cursor_size
	PlayerPrefs.attack_up = c.attack_up
	PlayerPrefs.ring_color_self = c.ring_color_self
	PlayerPrefs.ring_color_team = c.ring_color_team
	PlayerPrefs.ring_color_enemy = c.ring_color_enemy
	PlayerPrefs.self_beacon_mode = c.self_beacon_mode
	PlayerPrefs.freeplay_goalie_difficulty = c.freeplay_goalie_difficulty
	PlayerPrefs.screen_flash = c.screen_flash
	PlayerPrefs.screen_shake = c.screen_shake
	PlayerPrefs.camera_tilt_deg = c.camera_tilt_deg
	PlayerPrefs.fov = c.fov
	PlayerPrefs.camera_distance = c.camera_distance
	PlayerPrefs.camera_mode = c.camera_mode
	PlayerPrefs.hud_scale = c.hud_scale
	PlayerPrefs.share_gameplay_stats = c.share_gameplay_stats
	PlayerPrefs.bindings = (_pending_bindings as Dictionary).duplicate(true)
	PlayerPrefs.apply_audio()
	PlayerPrefs.apply_video()
	PlayerPrefs.apply_input()
	PlayerPrefs.apply_cursor()
	PlayerPrefs.apply_bindings()
	PlayerPrefs.save()
	# Live-apply the free-play goalie tier to the running goalies — free play has
	# no match reload, so this is how the dropdown takes effect (no-op elsewhere).
	GameManager.refresh_freeplay_goalie_difficulty()
	_original = _snapshot()
	_apply_btn.disabled = true
	if display_changed:
		_show_display_revert_dialog(prev_mode, prev_res, prev_mon)

# Spawns a 15-second "Keep these display settings?" confirmation after a window
# mode / resolution / monitor change. Lives at the scene-tree root so it stays
# reachable regardless of the Options overlay; on timeout or "Revert" it restores
# the prior display values, re-applies, and resyncs the panel so the still-open
# (or later reopened) panel doesn't show stale settings.
func _show_display_revert_dialog(prev_mode: int, prev_res: Vector2i, prev_mon: int) -> void:
	var dialog := DisplayRevertDialog.new()
	var revert := func() -> void:
		PlayerPrefs.window_mode = prev_mode
		PlayerPrefs.resolution = prev_res
		PlayerPrefs.display_monitor = prev_mon
		PlayerPrefs.apply_video()
		PlayerPrefs.save()
		_resync_display_from_prefs()
	get_tree().root.add_child(dialog)
	dialog.open(15.0, revert)

# Rebuilds the Video tab's display controls from the live PlayerPrefs values and
# re-baselines _original, so the panel reflects a reverted state cleanly.
func _resync_display_from_prefs() -> void:
	if _window_mode_btn == null:
		return
	_window_mode_btn.selected = PlayerPrefs.window_mode
	_apply_res_disabled_state(PlayerPrefs.window_mode != PlayerPrefs.WINDOW_MODE_WINDOWED)
	_monitor_btn.selected = clampi(PlayerPrefs.display_monitor + 1, 0, _monitor_btn.item_count - 1)
	_populate_resolutions()
	_original = _read_controls()
	_update_apply_state()

func _on_cancel_pressed() -> void:
	_apply_values_to_controls(_original)
	close_requested.emit()

# Reverts every control to its factory default (the same values PlayerPrefs
# initializes to), as a preview only — nothing is written until Apply, and
# Cancel still restores the pre-open state. Bindings reset to the project
# defaults captured at load.
func _on_reset_pressed() -> void:
	_apply_values_to_controls(_defaults())

# The factory-default control values. Mirrors the var initializers in
# PlayerPrefs — keep the two in sync when a default changes.
func _defaults() -> Dictionary:
	return {
		"window_mode": PlayerPrefs.WINDOW_MODE_BORDERLESS,
		"resolution": PlayerPrefs.RESOLUTION_DEFAULT,
		"display_monitor": -1,
		"vsync_mode": PlayerPrefs.VSYNC_ENABLED,
		"fps_cap_index": 5,
		"show_fps": false,
		"gamma": 1.0,
		"color_grade_preset": PlayerPrefs.COLOR_GRADE_BROADCAST,
		"gi_mode": PlayerPrefs.GI_MODE_OFF,
		"crowd_density": PlayerPrefs.CROWD_DENSITY_HIGH,
		"ice_scratches_enabled": true,
		"puck_shadow_enabled": true,
		"render_scale": 1.0,
		"scaling_3d_mode": PlayerPrefs.SCALING_3D_BILINEAR,
		"anti_aliasing_mode": PlayerPrefs.AA_MSAA_2X,
		"master_volume": 0.5,
		"sfx_volume": 1.0,
		"ui_volume": 1.0,
		"arena_volume": 1.0,
		"master_muted": false,
		"mute_when_unfocused": true,
		"mouse_sensitivity": 1.0,
		"confine_mouse": true,
		"cursor_style": PlayerPrefs.CURSOR_STYLE_DOT,
		"cursor_color": Color(1.0, 0.45, 0.1),
		"cursor_size": 28,
		"attack_up": false,
		"ring_color_self": MenuStyle.HUD_RING_SELF,
		"ring_color_team": MenuStyle.HUD_RING_TEAM,
		"ring_color_enemy": MenuStyle.HUD_RING_ENEMY,
		"self_beacon_mode": PlayerPrefs.BEACON_MODE_SMART,
		"freeplay_goalie_difficulty": GoalieSkillProfile.Difficulty.EASY,
		"screen_flash": true,
		"screen_shake": true,
		"camera_tilt_deg": PlayerPrefs.CAMERA_TILT_DEFAULT,
		"fov": 50.0,
		"camera_distance": 1.0,
		"camera_mode": PlayerPrefs.CAMERA_MODE_DYNAMIC,
		"hud_scale": 1.0,
		"share_gameplay_stats": true,
		"bindings": PlayerPrefs.default_bindings.duplicate(true),
	}

# Pushes a values dictionary (shaped like _snapshot / _read_controls) into every
# control. Shared by Cancel (restores _original) and Reset (loads _defaults).
func _apply_values_to_controls(v: Dictionary) -> void:
	_window_mode_btn.selected = v.window_mode
	_apply_res_disabled_state(int(v.window_mode) != PlayerPrefs.WINDOW_MODE_WINDOWED)
	_monitor_btn.selected = clampi(int(v.display_monitor) + 1, 0, _monitor_btn.item_count - 1)
	_populate_resolutions()
	_select_windowed_resolution(v.resolution)
	_vsync_btn.selected = v.vsync_mode
	_fps_btn.selected = v.fps_cap_index
	if _show_fps_check != null:
		_show_fps_check.set_pressed_no_signal(v.show_fps)
	_gamma_slider.value = v.gamma
	if _color_grade_btn != null:
		_color_grade_btn.selected = v.color_grade_preset
	if _gi_mode_btn != null:
		_gi_mode_btn.selected = v.gi_mode
	if _crowd_density_btn != null:
		_crowd_density_btn.selected = v.crowd_density
	if _ice_scratches_check != null:
		_ice_scratches_check.set_pressed_no_signal(v.ice_scratches_enabled)
	if _puck_shadow_check != null:
		_puck_shadow_check.set_pressed_no_signal(v.puck_shadow_enabled)
	if _render_scale_slider != null:
		_render_scale_slider.value = v.render_scale
	if _scaling_3d_btn != null:
		_scaling_3d_btn.selected = v.scaling_3d_mode
	if _aa_btn != null:
		_aa_btn.selected = v.anti_aliasing_mode
	_update_aa_compatibility()
	_volume_slider.value = v.master_volume
	_sfx_slider.value = v.sfx_volume
	_ui_slider.value = v.ui_volume
	_arena_slider.value = v.arena_volume
	_mute_check.set_pressed_no_signal(v.master_muted)
	if _mute_unfocused_check != null:
		_mute_unfocused_check.set_pressed_no_signal(v.mute_when_unfocused)
	_sens_slider.value = v.mouse_sensitivity
	if _confine_mouse_check != null:
		_confine_mouse_check.set_pressed_no_signal(v.confine_mouse)
	if _cursor_style_btn != null:
		_cursor_style_btn.selected = v.cursor_style
	if _cursor_color_btn != null:
		_cursor_color_btn.color = v.cursor_color
	if _cursor_size_slider != null:
		_cursor_size_slider.value = v.cursor_size
	_attack_up_check.set_pressed_no_signal(v.attack_up)
	if _ring_self_color_btn != null:
		_ring_self_color_btn.color = v.ring_color_self
	if _ring_team_color_btn != null:
		_ring_team_color_btn.color = v.ring_color_team
	if _ring_enemy_color_btn != null:
		_ring_enemy_color_btn.color = v.ring_color_enemy
	_sync_ring_preset_selection()
	if _self_beacon_mode_btn != null:
		_self_beacon_mode_btn.selected = v.self_beacon_mode
	if _freeplay_goalie_btn != null:
		_freeplay_goalie_btn.selected = v.freeplay_goalie_difficulty
	if _screen_flash_check != null:
		_screen_flash_check.set_pressed_no_signal(v.screen_flash)
	if _screen_shake_check != null:
		_screen_shake_check.set_pressed_no_signal(v.screen_shake)
	if _tilt_slider != null:
		_tilt_slider.value = v.camera_tilt_deg
	if _fov_slider != null:
		_fov_slider.value = v.fov
	if _cam_dist_slider != null:
		_cam_dist_slider.value = v.camera_distance
	if _camera_mode_btn != null:
		_camera_mode_btn.selected = v.camera_mode
	if _hud_scale_slider != null:
		_hud_scale_slider.value = v.hud_scale
	if _share_stats_check != null:
		_share_stats_check.set_pressed_no_signal(v.share_gameplay_stats)
	_listening_action = ""
	_pending_bindings = (v.get("bindings", {}) as Dictionary).duplicate(true)
	_update_binding_btns()
	if _conflict_label != null:
		_conflict_label.text = ""
	_update_apply_state()

# Points the resolution dropdown at the entry matching `res` (the committed
# windowed pick), leaving the nearest-match from _populate_resolutions if the
# exact size isn't offered on the current monitor.
func _select_windowed_resolution(res: Vector2i) -> void:
	for i: int in _res_values.size():
		if _res_values[i] == res:
			_windowed_res_idx = i
			break
	_refresh_res_display()

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


# Wraps a tab's content box in a fixed-height scroll viewport. Horizontal scroll
# is disabled (content fills the width), and the scrollbar gutter is reserved on
# every tab via margin_right so the two-column layout lines up identically
# whether or not a given tab is tall enough to actually scroll.
func _scroll_wrap(content: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_right", _SCROLLBAR_GUTTER)
	margin.add_child(content)
	scroll.add_child(margin)
	return scroll


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
