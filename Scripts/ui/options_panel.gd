class_name OptionsPanel
extends VBoxContainer

# Root of the Options overlay. Owns the tab switcher, the Apply/Defaults/Cancel
# footer, and the shared Apply/Cancel/dirty-tracking machinery; each tab
# (OptionsTab subclass under Scripts/ui/options/) owns its own controls and its
# own slice of the settings dict. The parent merges every tab's read_controls()
# into one dictionary, compares it against the on-open snapshot to drive the
# Apply-enabled state, and writes it back to PlayerPrefs on Apply.

signal close_requested

const _SEP := MenuStyle.TEXT_SEP

# Hard cap on the tab-content viewport. Each tab is wrapped in a fixed-height
# ScrollContainer of this size, so every tab is identically tall (the popup never
# resizes when switching) and any tab whose content exceeds the cap scrolls
# instead of overflowing. Widened over the old 4-tab layout to give the 6-tab bar
# room for its longer labels.
const _TAB_VIEWPORT_SIZE := Vector2(560, 500)
const _SCROLLBAR_GUTTER := 12   # reserved on every tab so columns line up scroll-or-not

const _TAB_LABELS: Array[String] = ["Gameplay", "Camera", "Video", "Audio", "Controls", "Accessibility"]

var _tab_contents: Array[Control] = []
var _tab_btns: Array[Button] = []
var _tabs: Array[OptionsTab] = []
var _video_tab: OptionsVideoTab = null   # kept typed for the display-revert resync
var _apply_btn: Button = null
var _original: Dictionary = {}
var _active_idx: int = 0  # active tab, for controller bumper switching + focus

func _ready() -> void:
	add_theme_constant_override("separation", 16)
	alignment = BoxContainer.ALIGNMENT_CENTER
	# Controller mode: give toggles/dropdowns a visible focus ring (CheckButton's
	# default focus is invisible here). Only defines "focus", so all other styling
	# falls through to the project theme. Null (mouse mode) leaves the theme unset.
	var focus_theme: Theme = MenuStyle.controller_focus_theme()
	if focus_theme != null:
		theme = focus_theme

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
	MenuStyle.apply_heading(title)
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
	MenuStyle.apply_primary_cta(_apply_btn)
	_apply_btn.pressed.connect(_on_apply_pressed)
	_apply_btn.disabled = true
	btn_row.add_child(_apply_btn)

	var cancel_btn := _make_small_button("Cancel")
	cancel_btn.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(cancel_btn)

# The live PlayerPrefs values at open time — the baseline the dirty-compare and
# Cancel restore against. Keys must match the union of every tab's read_controls().
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
		"shadow_quality": PlayerPrefs.shadow_quality,
		"crowd_density": PlayerPrefs.crowd_density,
		"ice_scratches_enabled": PlayerPrefs.ice_scratches_enabled,
		"puck_shadow_enabled": PlayerPrefs.puck_shadow_enabled,
		"volumetric_fog_enabled": PlayerPrefs.volumetric_fog_enabled,
		"reflections_enabled": PlayerPrefs.reflections_enabled,
		"ambient_occlusion_enabled": PlayerPrefs.ambient_occlusion_enabled,
		"render_scale": PlayerPrefs.render_scale,
		"scaling_3d_mode": PlayerPrefs.scaling_3d_mode,
		"anti_aliasing_mode": PlayerPrefs.anti_aliasing_mode,
		"master_volume": PlayerPrefs.master_volume,
		"sfx_volume": PlayerPrefs.sfx_volume,
		"ui_volume": PlayerPrefs.ui_volume,
		"arena_volume": PlayerPrefs.arena_volume,
		"master_muted": PlayerPrefs.master_muted,
		"mute_when_unfocused": PlayerPrefs.mute_when_unfocused,
		"shot_power_sensitivity": PlayerPrefs.shot_power_sensitivity,
		"gamepad_enabled": PlayerPrefs.gamepad_enabled,
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
		"locale": PlayerPrefs.locale,
		"screen_flash": PlayerPrefs.screen_flash,
		"screen_shake": PlayerPrefs.screen_shake,
		"camera_tilt_deg": PlayerPrefs.camera_tilt_deg,
		"fov": PlayerPrefs.fov,
		"camera_distance": PlayerPrefs.camera_distance,
		"camera_mode": PlayerPrefs.camera_mode,
		"minimap_enabled": PlayerPrefs.minimap_enabled,
		"hud_scale": PlayerPrefs.hud_scale,
		"share_gameplay_stats": PlayerPrefs.share_gameplay_stats,
		"bindings": PlayerPrefs.bindings.duplicate(true),
		"pad_bindings": PlayerPrefs.pad_bindings.duplicate(true),
	}

# The current control state, merged across every tab. Its key set equals
# _snapshot()'s (the tabs partition the keys), so the two compare directly.
func _read_controls() -> Dictionary:
	var merged: Dictionary = {}
	for tab: OptionsTab in _tabs:
		merged.merge(tab.read_controls())
	return merged

func _update_apply_state() -> void:
	if _apply_btn == null:
		return
	var changed: bool = _read_controls() != _original
	_apply_btn.disabled = not changed or not _all_tabs_valid()

func _all_tabs_valid() -> bool:
	for tab: OptionsTab in _tabs:
		if not tab.is_valid():
			return false
	return true

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

	_video_tab = OptionsVideoTab.new()
	_tabs = [
		OptionsGameplayTab.new(),
		OptionsCameraTab.new(),
		_video_tab,
		OptionsAudioTab.new(),
		OptionsControlsTab.new(),
		OptionsAccessibilityTab.new(),
	]

	# _tab_contents holds the scroll wrappers — those are the nodes whose
	# visibility _activate_tab toggles.
	for tab: OptionsTab in _tabs:
		tab.build()
		tab.changed.connect(_update_apply_state)
		var scroll := _scroll_wrap(tab)
		_tab_contents.append(scroll)
		content_margin.add_child(scroll)

	for i: int in _TAB_LABELS.size():
		var btn := Button.new()
		btn.text = _TAB_LABELS[i]
		btn.flat = true
		btn.custom_minimum_size = Vector2(0, 40)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 15)
		bar.add_child(btn)
		_tab_btns.append(btn)
		SoundManager.wire_button(btn)
		btn.pressed.connect(_activate_tab.bind(i))

	_activate_tab(0)
	return wrapper

func _activate_tab(idx: int) -> void:
	_active_idx = idx
	for i: int in _tab_contents.size():
		_tab_contents[i].visible = (i == idx)
	for i: int in _tab_btns.size():
		_apply_tab_style(_tab_btns[i], i == idx)


# Controller: put focus on the first control of the active tab's page, so a pad
# lands in the settings (not on the close button) when Options opens or a tab
# switches. Called by the Side Menu on open. No-op for mouse (focus_first gates).
func focus_active_tab() -> void:
	if _active_idx >= 0 and _active_idx < _tab_contents.size():
		ControllerNav.focus_first(_tab_contents[_active_idx])


# LB / RB cycle tabs — the console convention — so the pad doesn't have to walk
# the tab bar. Only while the panel is on screen; guarded so it never touches the
# game's LB (hit) during play. Refocuses the new page's first control.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var delta: int = ControllerNav.bumper_tab_delta(event)
	if delta != 0:
		_cycle_tab(delta)
		get_viewport().set_input_as_handled()


func _cycle_tab(dir: int) -> void:
	var n: int = _tab_btns.size()
	if n == 0:
		return
	_activate_tab((_active_idx + dir + n) % n)
	focus_active_tab()

func _apply_tab_style(btn: Button, active: bool) -> void:
	MenuStyle.apply_tab_button(btn, active)

# ---------------------------------------------------------------------------
# Apply / Cancel / Defaults
# ---------------------------------------------------------------------------

func _on_apply_pressed() -> void:
	var c: Dictionary = _read_controls()
	# Capture the pre-apply display state so a revert dialog can roll back a window
	# mode / resolution / monitor change that left the screen unusable.
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
	PlayerPrefs.shadow_quality = c.shadow_quality
	PlayerPrefs.crowd_density = c.crowd_density
	PlayerPrefs.ice_scratches_enabled = c.ice_scratches_enabled
	PlayerPrefs.puck_shadow_enabled = c.puck_shadow_enabled
	PlayerPrefs.volumetric_fog_enabled = c.volumetric_fog_enabled
	PlayerPrefs.reflections_enabled = c.reflections_enabled
	PlayerPrefs.ambient_occlusion_enabled = c.ambient_occlusion_enabled
	PlayerPrefs.render_scale = c.render_scale
	PlayerPrefs.scaling_3d_mode = c.scaling_3d_mode
	PlayerPrefs.anti_aliasing_mode = c.anti_aliasing_mode
	PlayerPrefs.master_volume = c.master_volume
	PlayerPrefs.sfx_volume = c.sfx_volume
	PlayerPrefs.ui_volume = c.ui_volume
	PlayerPrefs.arena_volume = c.arena_volume
	PlayerPrefs.master_muted = c.master_muted
	PlayerPrefs.mute_when_unfocused = c.mute_when_unfocused
	PlayerPrefs.shot_power_sensitivity = c.shot_power_sensitivity
	PlayerPrefs.gamepad_enabled = c.gamepad_enabled
	# The allow gate may have flipped — re-broadcast so device-aware UI (prompts,
	# tutorial copy) reflects it without waiting for the next input.
	InputDeviceTracker.notify_gamepad_allowed_changed()
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
	PlayerPrefs.locale = c.locale
	PlayerPrefs.screen_flash = c.screen_flash
	PlayerPrefs.screen_shake = c.screen_shake
	PlayerPrefs.camera_tilt_deg = c.camera_tilt_deg
	PlayerPrefs.fov = c.fov
	PlayerPrefs.camera_distance = c.camera_distance
	PlayerPrefs.camera_mode = c.camera_mode
	PlayerPrefs.minimap_enabled = c.minimap_enabled
	PlayerPrefs.hud_scale = c.hud_scale
	PlayerPrefs.share_gameplay_stats = c.share_gameplay_stats
	PlayerPrefs.bindings = (c.bindings as Dictionary).duplicate(true)
	PlayerPrefs.pad_bindings = (c.pad_bindings as Dictionary).duplicate(true)
	PlayerPrefs.apply_audio()
	PlayerPrefs.apply_video()
	PlayerPrefs.apply_input()
	PlayerPrefs.apply_cursor()
	PlayerPrefs.apply_bindings()
	PlayerPrefs.apply_locale()
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
		if is_instance_valid(self):
			_video_tab.resync_display_from_prefs()
			_original = _read_controls()
			_update_apply_state()
	get_tree().root.add_child(dialog)
	dialog.open(15.0, revert)

func _on_cancel_pressed() -> void:
	_apply_values_to_controls(_original)
	close_requested.emit()

# Reverts every control to its factory default (the same values PlayerPrefs
# initializes to), as a preview only — nothing is written until Apply, and Cancel
# still restores the pre-open state. Bindings reset to the project defaults
# captured at load.
func _on_reset_pressed() -> void:
	_apply_values_to_controls(_defaults())

# The factory-default control values. Mirrors the var initializers in PlayerPrefs
# — keep the two in sync when a default changes. (No `locale` key by design: the
# language dropdown is never reverted by Cancel/Defaults, matching the original
# panel — see OptionsGameplayTab.apply_values.)
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
		"shadow_quality": PlayerPrefs.SHADOW_QUALITY_HIGH,
		"crowd_density": PlayerPrefs.CROWD_DENSITY_HIGH,
		"ice_scratches_enabled": true,
		"puck_shadow_enabled": true,
		"volumetric_fog_enabled": false,
		"reflections_enabled": true,
		"ambient_occlusion_enabled": true,
		"render_scale": 1.0,
		"scaling_3d_mode": PlayerPrefs.SCALING_3D_BILINEAR,
		"anti_aliasing_mode": PlayerPrefs.AA_MSAA_2X,
		"master_volume": 0.5,
		"sfx_volume": 1.0,
		"ui_volume": 1.0,
		"arena_volume": 1.0,
		"master_muted": false,
		"mute_when_unfocused": true,
		"shot_power_sensitivity": 1.0,
		"gamepad_enabled": false,
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
		"minimap_enabled": true,
		"hud_scale": 1.0,
		"share_gameplay_stats": true,
		"bindings": PlayerPrefs.default_bindings.duplicate(true),
		"pad_bindings": PlayerPrefs.PAD_DEFAULT_BUTTONS.duplicate(true),
	}

# Pushes a values dictionary (shaped like _snapshot / _read_controls) into every
# tab. Shared by Cancel (restores _original) and Reset (loads _defaults). Each tab
# reads only its own keys.
func _apply_values_to_controls(v: Dictionary) -> void:
	for tab: OptionsTab in _tabs:
		tab.apply_values(v)
	_update_apply_state()

# ---------------------------------------------------------------------------
# Layout helpers owned by the parent (the tabs share their own via OptionsTab)
# ---------------------------------------------------------------------------

# Wraps a tab's content box in a fixed-height scroll viewport. Horizontal scroll
# is disabled (content fills the width), and the scrollbar gutter is reserved on
# every tab via margin_right so the two-column layout lines up identically whether
# or not a given tab is tall enough to actually scroll.
func _scroll_wrap(content: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Controller: keep the focused control in view as focus walks down a tall tab,
	# so navigating past the visible area scrolls the page instead of focus moving
	# to off-screen controls the player can't see (it looked like it jumped to the
	# footer). Harmless for mouse (only acts on focus changes).
	scroll.follow_focus = true

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_right", _SCROLLBAR_GUTTER)
	margin.add_child(content)
	scroll.add_child(margin)
	return scroll

func _make_small_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(148, 48)
	btn.add_theme_font_size_override("font_size", 20)
	SoundManager.wire_button(btn)
	return btn
