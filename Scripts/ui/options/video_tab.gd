class_name OptionsVideoTab
extends OptionsTab

# Video tab — display mode, image adjustments, and performance/quality knobs.
# Owns the resolution/monitor population logic, the upscaling/AA compatibility
# gating, and resync_display_from_prefs() (called by the parent's revert dialog).

var _res_row: HBoxContainer = null
var _res_label: Label = null   # dimmed in fullscreen modes (resolution disabled)
var _window_mode_btn: OptionButton = null
var _monitor_btn: OptionButton = null
var _res_btn: OptionButton = null
var _res_values: Array[Vector2i] = []   # parallel to _res_btn items
var _windowed_res_idx: int = 0          # the committed windowed pick (survives fullscreen display swap)
var _native_res_idx: int = 0            # the monitor's native entry, shown (greyed) in fullscreen modes
var _vsync_btn: OptionButton = null
var _fps_btn: OptionButton = null
var _show_fps_check: CheckButton = null
var _gamma_slider: HSlider = null
var _color_grade_btn: OptionButton = null
var _gi_mode_btn: OptionButton = null
var _shadow_quality_btn: OptionButton = null
var _crowd_density_btn: OptionButton = null
var _ice_scratches_check: CheckButton = null
var _puck_shadow_check: CheckButton = null
var _fog_check: CheckButton = null
var _reflections_check: CheckButton = null
var _ao_check: CheckButton = null
var _render_scale_slider: HSlider = null
var _scaling_3d_btn: OptionButton = null
var _aa_btn: OptionButton = null

func _build_content() -> void:
	add_child(_section_header("Display"))

	_window_mode_btn = OptionButton.new()
	_window_mode_btn.custom_minimum_size = Vector2(220, 40)
	_window_mode_btn.add_theme_font_size_override("font_size", 15)
	for label: String in PlayerPrefs.WINDOW_MODE_LABELS:
		_window_mode_btn.add_item(label)
	_window_mode_btn.selected = PlayerPrefs.window_mode
	_window_mode_btn.item_selected.connect(_on_window_mode_selected)
	add_child(_field_row("Window Mode", _window_mode_btn))

	# Monitor selector — only meaningful with more than one screen, so the row is
	# added only on multi-monitor rigs. Item 0 = Automatic (follow the window);
	# items 1..n target screen index 0..n-1.
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
		add_child(_field_row("Monitor", _monitor_btn))

	_res_btn = OptionButton.new()
	_res_btn.custom_minimum_size = Vector2(220, 40)
	_res_btn.add_theme_font_size_override("font_size", 15)
	_populate_resolutions()
	_res_btn.item_selected.connect(_on_resolution_selected)
	_res_row = _field_row("Resolution", _res_btn)
	# Cache the label so we can dim it when the resolution row is disabled.
	_res_label = _res_row.get_child(0) as Label
	add_child(_res_row)
	_apply_res_disabled_state(PlayerPrefs.window_mode != PlayerPrefs.WINDOW_MODE_WINDOWED)

	_vsync_btn = OptionButton.new()
	_vsync_btn.custom_minimum_size = Vector2(160, 40)
	_vsync_btn.add_theme_font_size_override("font_size", 15)
	for label: String in PlayerPrefs.VSYNC_LABELS:
		_vsync_btn.add_item(label)
	_vsync_btn.selected = PlayerPrefs.vsync_mode
	_vsync_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("VSync", _vsync_btn))

	_fps_btn = OptionButton.new()
	_fps_btn.custom_minimum_size = Vector2(140, 40)
	_fps_btn.add_theme_font_size_override("font_size", 15)
	for label: String in ["30", "60", "120", "144", "240", "Unlimited"]:
		_fps_btn.add_item(label)
	_fps_btn.selected = PlayerPrefs.fps_cap_index
	_fps_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("FPS Cap", _fps_btn))

	_show_fps_check = CheckButton.new()
	_show_fps_check.set_pressed_no_signal(PlayerPrefs.show_fps)
	SoundManager.wire_button(_show_fps_check)
	_show_fps_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Show FPS", _show_fps_check))

	add_child(_section_spacer())
	add_child(_section_header("Image"))

	_gamma_slider = HSlider.new()
	_gamma_slider.min_value = 0.5
	_gamma_slider.max_value = 2.0
	_gamma_slider.step = 0.05
	_gamma_slider.value = PlayerPrefs.gamma
	_gamma_slider.value_changed.connect(func(_v: float) -> void: _notify_changed())
	var gamma_val := _value_label("%.2f" % PlayerPrefs.gamma)
	_gamma_slider.value_changed.connect(func(v: float) -> void: gamma_val.text = "%.2f" % v)
	add_child(_slider_row("Gamma", _gamma_slider, gamma_val))

	_color_grade_btn = OptionButton.new()
	_color_grade_btn.custom_minimum_size = Vector2(220, 40)
	_color_grade_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.COLOR_GRADE_LABELS.size():
		_color_grade_btn.add_item(PlayerPrefs.COLOR_GRADE_LABELS[i], i)
	_color_grade_btn.selected = PlayerPrefs.color_grade_preset
	_color_grade_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Color Grade", _color_grade_btn))

	add_child(_section_spacer())
	add_child(_section_header("Performance"))

	_render_scale_slider = HSlider.new()
	_render_scale_slider.min_value = PlayerPrefs.RENDER_SCALE_MIN
	_render_scale_slider.max_value = PlayerPrefs.RENDER_SCALE_MAX
	_render_scale_slider.step = PlayerPrefs.RENDER_SCALE_STEP
	_render_scale_slider.value = PlayerPrefs.render_scale
	_render_scale_slider.value_changed.connect(_on_render_scale_changed)
	var rs_val := _value_label("%d%%" % roundi(PlayerPrefs.render_scale * 100.0))
	_render_scale_slider.value_changed.connect(
		func(v: float) -> void: rs_val.text = "%d%%" % roundi(v * 100.0))
	add_child(_slider_row("Render Scale", _render_scale_slider, rs_val))

	_scaling_3d_btn = OptionButton.new()
	_scaling_3d_btn.custom_minimum_size = Vector2(180, 40)
	_scaling_3d_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.SCALING_3D_LABELS.size():
		_scaling_3d_btn.add_item(PlayerPrefs.SCALING_3D_LABELS[i], i)
	_scaling_3d_btn.selected = PlayerPrefs.scaling_3d_mode
	_scaling_3d_btn.item_selected.connect(_on_scaling_3d_selected)
	add_child(_field_row("Upscaling", _scaling_3d_btn))
	_update_upscaling_enabled()

	_aa_btn = OptionButton.new()
	_aa_btn.custom_minimum_size = Vector2(180, 40)
	_aa_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.AA_LABELS.size():
		_aa_btn.add_item(PlayerPrefs.AA_LABELS[i], i)
	_aa_btn.selected = PlayerPrefs.anti_aliasing_mode
	_aa_btn.item_selected.connect(_on_aa_selected)
	add_child(_field_row("Anti-Aliasing", _aa_btn))
	_update_aa_compatibility()

	_gi_mode_btn = OptionButton.new()
	_gi_mode_btn.custom_minimum_size = Vector2(180, 40)
	_gi_mode_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.GI_MODE_LABELS.size():
		_gi_mode_btn.add_item(PlayerPrefs.GI_MODE_LABELS[i], i)
	_gi_mode_btn.selected = PlayerPrefs.gi_mode
	_gi_mode_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Global Illumination", _gi_mode_btn))

	_shadow_quality_btn = OptionButton.new()
	_shadow_quality_btn.custom_minimum_size = Vector2(180, 40)
	_shadow_quality_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.SHADOW_QUALITY_LABELS.size():
		_shadow_quality_btn.add_item(PlayerPrefs.SHADOW_QUALITY_LABELS[i], i)
	_shadow_quality_btn.selected = PlayerPrefs.shadow_quality
	_shadow_quality_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Shadow Quality", _shadow_quality_btn))

	_crowd_density_btn = OptionButton.new()
	_crowd_density_btn.custom_minimum_size = Vector2(180, 40)
	_crowd_density_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.CROWD_DENSITY_LABELS.size():
		_crowd_density_btn.add_item(PlayerPrefs.CROWD_DENSITY_LABELS[i], i)
	_crowd_density_btn.selected = PlayerPrefs.crowd_density
	_crowd_density_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Crowd Density", _crowd_density_btn))

	_ice_scratches_check = CheckButton.new()
	_ice_scratches_check.set_pressed_no_signal(PlayerPrefs.ice_scratches_enabled)
	SoundManager.wire_button(_ice_scratches_check)
	_ice_scratches_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Ice Scratches", _ice_scratches_check))

	_puck_shadow_check = CheckButton.new()
	_puck_shadow_check.set_pressed_no_signal(PlayerPrefs.puck_shadow_enabled)
	SoundManager.wire_button(_puck_shadow_check)
	_puck_shadow_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Puck Shadow", _puck_shadow_check))

	# Atmosphere passes, heaviest first. Fog and reflections are the GPU-costly
	# ones; ambient occlusion is cheap. All default on (the intended arena look).
	_fog_check = CheckButton.new()
	_fog_check.set_pressed_no_signal(PlayerPrefs.volumetric_fog_enabled)
	SoundManager.wire_button(_fog_check)
	_fog_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Volumetric Fog", _fog_check))

	_reflections_check = CheckButton.new()
	_reflections_check.set_pressed_no_signal(PlayerPrefs.reflections_enabled)
	SoundManager.wire_button(_reflections_check)
	_reflections_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Reflections", _reflections_check))

	_ao_check = CheckButton.new()
	_ao_check.set_pressed_no_signal(PlayerPrefs.ambient_occlusion_enabled)
	SoundManager.wire_button(_ao_check)
	_ao_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Ambient Occlusion", _ao_check))

# --- Display handlers --------------------------------------------------------

func _on_window_mode_selected(_idx: int) -> void:
	_apply_res_disabled_state(_window_mode_btn.selected != PlayerPrefs.WINDOW_MODE_WINDOWED)
	_refresh_res_display()
	_notify_changed()

func _on_monitor_selected(_idx: int) -> void:
	# A different monitor can support a different resolution set; rebuild the
	# dropdown against the newly chosen screen (preview only — no prefs write).
	_populate_resolutions()
	_notify_changed()

func _on_resolution_selected(_idx: int) -> void:
	# Only fires when the box is enabled (windowed); record the new windowed pick.
	_windowed_res_idx = _res_btn.selected
	_notify_changed()

func _on_render_scale_changed(_value: float) -> void:
	_update_upscaling_enabled()
	_notify_changed()

func _on_scaling_3d_selected(_idx: int) -> void:
	_update_aa_compatibility()
	_notify_changed()

func _on_aa_selected(_idx: int) -> void:
	_notify_changed()

func _update_upscaling_enabled() -> void:
	if _scaling_3d_btn != null and _render_scale_slider != null:
		_scaling_3d_btn.disabled = is_equal_approx(_render_scale_slider.value, 1.0)

# FSR2 has its own temporal reconstruction and Godot disallows TAA on top. Grey
# out the TAA item in the AA dropdown whenever FSR2 is the upscaling mode; if TAA
# happened to be selected, fall back to MSAA 2x so the dropdown reflects what
# will actually render.
func _update_aa_compatibility() -> void:
	if _aa_btn == null or _scaling_3d_btn == null:
		return
	var fsr2: bool = _scaling_3d_btn.selected == PlayerPrefs.SCALING_3D_FSR2
	_aa_btn.set_item_disabled(PlayerPrefs.AA_TAA, fsr2)
	if fsr2 and _aa_btn.selected == PlayerPrefs.AA_TAA:
		_aa_btn.selected = PlayerPrefs.AA_MSAA_2X

# Resolution only matters in windowed mode. We disable rather than hide the row
# so changing window mode doesn't change the panel's height.
func _apply_res_disabled_state(disabled: bool) -> void:
	if _res_btn != null:
		_res_btn.disabled = disabled
	if _res_label != null:
		_res_label.add_theme_color_override("font_color",
			MenuStyle.TEXT_MUTED if disabled else _WHITE)

# Builds the resolution dropdown from the monitor-filtered list. Records the entry
# nearest the saved resolution (_windowed_res_idx — the committed windowed pick)
# and the monitor's native entry (_native_res_idx, tagged "(Native)"). In
# fullscreen modes the box is greyed and shows the native entry, since that IS
# what those modes render at; windowed modes show the picked size.
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
# the native resolution while fullscreen — what the GPU actually renders — or the
# committed windowed pick otherwise. Programmatic, so it never disturbs
# _windowed_res_idx.
func _refresh_res_display() -> void:
	if _window_mode_btn.selected == PlayerPrefs.WINDOW_MODE_WINDOWED:
		_res_btn.selected = _windowed_res_idx
	else:
		_res_btn.selected = _native_res_idx

# Screen the resolution list should be queried against: the monitor picked in the
# dropdown, or the current window's screen when set to Automatic.
func _query_screen() -> int:
	var sel: int = _selected_monitor()
	if sel >= 0 and sel < DisplayServer.get_screen_count():
		return sel
	return DisplayServer.window_get_current_screen()

# The committed windowed resolution — driven by _windowed_res_idx, NOT the greyed
# native size shown in fullscreen — so applying in fullscreen leaves the saved
# windowed size intact.
func _selected_resolution() -> Vector2i:
	if _windowed_res_idx >= 0 and _windowed_res_idx < _res_values.size():
		return _res_values[_windowed_res_idx]
	return PlayerPrefs.resolution

# Item 0 is "Automatic" → -1; items 1..n map to screen index 0..n-1.
func _selected_monitor() -> int:
	return _monitor_btn.selected - 1

# Points the resolution dropdown at the entry matching `res` (the committed
# windowed pick), leaving the nearest-match from _populate_resolutions if the
# exact size isn't offered on the current monitor.
func _select_windowed_resolution(res: Vector2i) -> void:
	for i: int in _res_values.size():
		if _res_values[i] == res:
			_windowed_res_idx = i
			break
	_refresh_res_display()

# Rebuilds the display controls from the live PlayerPrefs values, so the panel
# reflects a reverted state cleanly. Called by the parent's display-revert dialog;
# the parent re-baselines its snapshot afterward.
func resync_display_from_prefs() -> void:
	if _window_mode_btn == null:
		return
	_window_mode_btn.selected = PlayerPrefs.window_mode
	_apply_res_disabled_state(PlayerPrefs.window_mode != PlayerPrefs.WINDOW_MODE_WINDOWED)
	_monitor_btn.selected = clampi(PlayerPrefs.display_monitor + 1, 0, _monitor_btn.item_count - 1)
	_populate_resolutions()

func read_controls() -> Dictionary:
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
		"shadow_quality": _shadow_quality_btn.selected,
		"crowd_density": _crowd_density_btn.selected,
		"ice_scratches_enabled": _ice_scratches_check.button_pressed,
		"puck_shadow_enabled": _puck_shadow_check.button_pressed,
		"volumetric_fog_enabled": _fog_check.button_pressed,
		"reflections_enabled": _reflections_check.button_pressed,
		"ambient_occlusion_enabled": _ao_check.button_pressed,
		"render_scale": _render_scale_slider.value,
		"scaling_3d_mode": _scaling_3d_btn.selected,
		"anti_aliasing_mode": _aa_btn.selected,
	}

func apply_values(v: Dictionary) -> void:
	_window_mode_btn.selected = v.window_mode
	_apply_res_disabled_state(int(v.window_mode) != PlayerPrefs.WINDOW_MODE_WINDOWED)
	_monitor_btn.selected = clampi(int(v.display_monitor) + 1, 0, _monitor_btn.item_count - 1)
	_populate_resolutions()
	_select_windowed_resolution(v.resolution)
	_vsync_btn.selected = v.vsync_mode
	_fps_btn.selected = v.fps_cap_index
	_show_fps_check.set_pressed_no_signal(v.show_fps)
	_gamma_slider.value = v.gamma
	_color_grade_btn.selected = v.color_grade_preset
	_gi_mode_btn.selected = v.gi_mode
	_shadow_quality_btn.selected = v.shadow_quality
	_crowd_density_btn.selected = v.crowd_density
	_ice_scratches_check.set_pressed_no_signal(v.ice_scratches_enabled)
	_puck_shadow_check.set_pressed_no_signal(v.puck_shadow_enabled)
	_fog_check.set_pressed_no_signal(v.volumetric_fog_enabled)
	_reflections_check.set_pressed_no_signal(v.reflections_enabled)
	_ao_check.set_pressed_no_signal(v.ambient_occlusion_enabled)
	_render_scale_slider.value = v.render_scale
	_scaling_3d_btn.selected = v.scaling_3d_mode
	_aa_btn.selected = v.anti_aliasing_mode
	_update_aa_compatibility()
	_update_upscaling_enabled()
