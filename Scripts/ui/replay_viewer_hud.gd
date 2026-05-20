class_name ReplayViewerHUD
extends CanvasLayer

# Programmatic HUD for the offline replay viewer. Built in code (same pattern
# as the in-game HUD) so the viewer scene file stays minimal — ReplayViewer
# instantiates this and calls setup(driver, header).
#
# Layout:
#   - Top-center: compact scoreboard (HOME score / period · clock / score AWAY)
#   - Bottom: play/pause + seek bar with goal-jump tick marks + current /
#     total time + speed dropdown
#   - Top-right: × back-to-menu button (also bound to Escape)

const _DARK_BG: Color    = Color(0.07, 0.07, 0.09, 0.92)
const _WHITE: Color      = Color(1.00, 1.00, 1.00, 1.00)
const _DIM: Color        = Color(0.62, 0.62, 0.68, 1.00)
const _GOAL_TICK: Color  = Color(1.00, 0.85, 0.20, 0.85)

const _SPEEDS: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0]
# Parallel labels — GDScript's % operator doesn't support %g, and %f stamps
# ugly trailing zeros (1.000×).
const _SPEED_LABELS: Array[String] = ["0.25×", "0.5×", "1×", "2×", "4×"]
const _DEFAULT_SPEED_IDX: int = 2  # 1×

var _driver: FileReplayDriver = null
var _director: CameraDirector = null
var _header: Dictionary = {}
var _home_color: Color = Color(0.4, 0.4, 0.4)
var _away_color: Color = Color(0.4, 0.4, 0.4)

var _score_label_home: Label = null
var _score_label_away: Label = null
var _period_label: Label = null
var _clock_label: Label = null
var _play_pause_btn: Button = null
var _seek_slider: HSlider = null
var _seek_bar_root: Control = null
var _time_label: Label = null
var _speed_btn: OptionButton = null
var _camera_label: Label = null
var _seeking_user: bool = false
var _pause_menu_container: Control = null
var _pause_options_container: Control = null
# Remember whether playback was paused before the user opened the pause menu
# so closing the menu doesn't auto-resume if they had already paused.
var _was_paused_before_menu: bool = false


func setup(driver: FileReplayDriver, header: Dictionary, director: CameraDirector = null) -> void:
	_driver = driver
	_director = director
	_header = header
	# Legacy fruit-name strings in old replay headers won't typecheck — fall back
	# to defaults rather than crash. Hard break: no string→slot mapping.
	var raw_home: Variant = header.get("home_color_slot", TeamColorRegistry.DEFAULT_HOME_SLOT)
	var raw_away: Variant = header.get("away_color_slot", TeamColorRegistry.DEFAULT_AWAY_SLOT)
	var home_slot: int = raw_home if raw_home is int else TeamColorRegistry.DEFAULT_HOME_SLOT
	var away_slot: int = raw_away if raw_away is int else TeamColorRegistry.DEFAULT_AWAY_SLOT
	_home_color = TeamColorRegistry.get_colors(home_slot, 0).primary
	_away_color = TeamColorRegistry.get_colors(away_slot, 1).primary
	_build_ui()
	_driver.game_state_changed.connect(_on_game_state_changed)
	_driver.playback_ended.connect(_on_playback_ended)
	_update_play_pause_text()


# ── Build ────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_build_scoreboard(root)
	_build_back_button(root)
	_build_camera_label(root)
	_build_bottom_bar(root)
	_build_pause_menu()


func _build_scoreboard(root: Control) -> void:
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = _DARK_BG
	bar_style.set_corner_radius_all(3)
	bar_style.set_content_margin(SIDE_LEFT, 12)
	bar_style.set_content_margin(SIDE_RIGHT, 12)
	bar_style.set_content_margin(SIDE_TOP, 6)
	bar_style.set_content_margin(SIDE_BOTTOM, 6)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", bar_style)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.offset_top = 12
	root.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	panel.add_child(hbox)

	hbox.add_child(_team_badge("HOME", _home_color))
	_score_label_home = _label("0", 22, _WHITE)
	_score_label_home.custom_minimum_size = Vector2(28, 0)
	_score_label_home.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(_score_label_home)

	var middle := VBoxContainer.new()
	middle.alignment = BoxContainer.ALIGNMENT_CENTER
	middle.add_theme_constant_override("separation", 0)
	hbox.add_child(middle)
	_period_label = _label("1ST", 11, _DIM)
	_period_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	middle.add_child(_period_label)
	_clock_label = _label("0:00", 18, _WHITE)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.custom_minimum_size = Vector2(64, 0)
	middle.add_child(_clock_label)

	_score_label_away = _label("0", 22, _WHITE)
	_score_label_away.custom_minimum_size = Vector2(28, 0)
	_score_label_away.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(_score_label_away)
	hbox.add_child(_team_badge("AWAY", _away_color))


func _build_camera_label(root: Control) -> void:
	if _director == null:
		return
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = _DARK_BG
	style.set_corner_radius_all(3)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = 12
	panel.offset_top = 12
	root.add_child(panel)
	_camera_label = _label("CAMERA: BROADCAST  ·  [C] cycle  ·  [↑↓] player  ·  RMB drag look", 11, _DIM)
	panel.add_child(_camera_label)


func _build_back_button(root: Control) -> void:
	var btn := Button.new()
	btn.text = "×"
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(40, 40)
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.anchor_top = 0.0
	btn.anchor_bottom = 0.0
	btn.offset_left = -52
	btn.offset_top = 12
	btn.offset_right = -12
	btn.offset_bottom = 52
	btn.pressed.connect(_toggle_pause_menu)
	root.add_child(btn)


# Centered modal that escape opens. Two buttons — Options (inlines the same
# OptionsPanel the in-game pause menu uses) and Return to Free Play. Avoids
# the in-game PauseMenu directly because that's wired to live-game state
# (slot grid, registry-aware buttons) which doesn't exist in the viewer.
func _build_pause_menu() -> void:
	_pause_menu_container = Control.new()
	_pause_menu_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pause_menu_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_menu_container.visible = false
	# Mouse_filter STOP on the backdrop blocks clicks from reaching the HUD
	# controls underneath while the menu is open.
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_menu_container.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_pause_menu_container.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(title)

	var resume_btn := MenuStyle.popup_button("Resume")
	resume_btn.pressed.connect(_close_pause_menu)
	vbox.add_child(resume_btn)

	var options_btn := MenuStyle.popup_button("Options")
	options_btn.pressed.connect(_open_pause_options)
	vbox.add_child(options_btn)

	var exit_btn := MenuStyle.popup_button("Return to Free Play")
	exit_btn.pressed.connect(_exit_to_free_play)
	vbox.add_child(exit_btn)

	add_child(_pause_menu_container)
	_build_pause_options_overlay()


# OptionsPanel lives on its own layer above the pause menu so the user can
# scrub video / audio / control settings without the pause menu visually
# overlapping. Mirror PauseMenu's layout (layer 21 above the menu's 20).
func _build_pause_options_overlay() -> void:
	_pause_options_container = Control.new()
	_pause_options_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pause_options_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_options_container.visible = false

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_options_container.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var options := OptionsPanel.new()
	options.close_requested.connect(_close_pause_options)
	panel.add_child(options)
	_pause_options_container.add_child(panel)

	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = 21
	canvas_layer.add_child(_pause_options_container)
	add_child(canvas_layer)


func _build_bottom_bar(root: Control) -> void:
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = _DARK_BG
	bar_style.set_corner_radius_all(3)
	bar_style.set_content_margin_all(10)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", bar_style)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_bottom = -16
	panel.custom_minimum_size = Vector2(720, 0)
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Row 1: play/pause + seek slider + time + speed
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 12)
	vbox.add_child(controls)

	_play_pause_btn = Button.new()
	_play_pause_btn.text = "▶"
	_play_pause_btn.custom_minimum_size = Vector2(48, 36)
	_play_pause_btn.add_theme_font_size_override("font_size", 18)
	_play_pause_btn.pressed.connect(_on_play_pause_pressed)
	controls.add_child(_play_pause_btn)

	_seek_bar_root = Control.new()
	_seek_bar_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seek_bar_root.custom_minimum_size = Vector2(0, 36)
	controls.add_child(_seek_bar_root)

	_seek_slider = HSlider.new()
	_seek_slider.min_value = 0.0
	_seek_slider.max_value = 1.0
	_seek_slider.step = 0.0001
	_seek_slider.value = 0.0
	_seek_slider.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seek_bar_root.add_child(_seek_slider)
	_seek_slider.value_changed.connect(_on_seek_changed)
	_seek_slider.drag_started.connect(func() -> void: _seeking_user = true)
	# drag_ended flushes the rebuild that seek_drag deferred — a single
	# queue_free + respawn cycle at the final drag position instead of one
	# per slider step.
	_seek_slider.drag_ended.connect(func(_changed: bool) -> void:
		_seeking_user = false
		_driver.commit_drag())

	_time_label = _label("0:00 / 0:00", 12, _DIM)
	_time_label.custom_minimum_size = Vector2(96, 0)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls.add_child(_time_label)

	_speed_btn = OptionButton.new()
	for i: int in _SPEEDS.size():
		_speed_btn.add_item(_SPEED_LABELS[i], i)
	_speed_btn.select(_DEFAULT_SPEED_IDX)
	_speed_btn.custom_minimum_size = Vector2(72, 36)
	_speed_btn.item_selected.connect(_on_speed_changed)
	controls.add_child(_speed_btn)

	# Row 2: goal-event tick markers drawn under the seek bar.
	_seek_bar_root.draw.connect(_draw_goal_ticks)


# ── Signal handlers ──────────────────────────────────────────────────────────

func _on_play_pause_pressed() -> void:
	_driver.toggle_pause()
	_update_play_pause_text()


func _on_seek_changed(value: float) -> void:
	if not _seeking_user:
		return  # programmatic update from _process
	var target_ts: float = _driver.get_start_ts() + value * _driver.get_duration()
	# seek_drag walks the clock and refreshes the visible frame without
	# emitting roster_rebuild_requested. The drag_ended handler calls
	# _driver.commit_drag() once the user releases the slider.
	_driver.seek_drag(target_ts)


func _on_speed_changed(idx: int) -> void:
	_driver.playback_speed = _SPEEDS[clampi(idx, 0, _SPEEDS.size() - 1)]


func _on_game_state_changed(game_state: Dictionary) -> void:
	_score_label_home.text = str(int(game_state.get("score0", 0)))
	_score_label_away.text = str(int(game_state.get("score1", 0)))
	_period_label.text = _format_period(int(game_state.get("period", 1)))
	_clock_label.text = _format_clock(float(game_state.get("time_remaining", 0.0)))


func _on_playback_ended() -> void:
	_update_play_pause_text()


func _process(_delta: float) -> void:
	if _driver == null:
		return
	if not _seeking_user:
		_seek_slider.set_value_no_signal(_driver.get_progress())
	_time_label.text = "%s / %s" % [
		_format_seconds(_driver.get_virtual_clock() - _driver.get_start_ts()),
		_format_seconds(_driver.get_duration()),
	]
	_seek_bar_root.queue_redraw()
	if _camera_label != null and _director != null:
		_camera_label.text = "CAMERA: %s  ·  [C] cycle  ·  [↑↓] player  ·  RMB drag look" % _director.get_mode_label()


# Yellow tick marks at each goal's progress along the slider. Driven by the
# slider's draw signal so they always sit at the correct screen-space x.
func _draw_goal_ticks() -> void:
	if _driver == null or _seek_bar_root == null:
		return
	var dur: float = _driver.get_duration()
	if dur <= 0.0:
		return
	var rect: Rect2 = _seek_bar_root.get_rect()
	for event: Dictionary in _driver.get_events():
		if not event.data.has("kind") or event.data.kind != "goal":
			continue
		var progress: float = (event.host_ts - _driver.get_start_ts()) / dur
		var x: float = clampf(progress, 0.0, 1.0) * rect.size.x
		_seek_bar_root.draw_line(Vector2(x, 4), Vector2(x, rect.size.y - 4), _GOAL_TICK, 2.0)


func _update_play_pause_text() -> void:
	if _play_pause_btn == null or _driver == null:
		return
	_play_pause_btn.text = "▶" if _driver.is_paused() else "⏸"


# ── Input ────────────────────────────────────────────────────────────────────

# Escape lives in _shortcut_input so it fires before any focused Control's
# _gui_input can swallow it (clicking the speed dropdown or seek slider sets
# focus on those, and some Godot Control internals consume Escape to release
# focus). _shortcut_input is the canonical home for global shortcuts that
# must work regardless of focus.
func _shortcut_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_pause_menu()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	# Pause menu blocks playback shortcuts so the user doesn't accidentally
	# scrub or change speed while picking a menu option. Escape (handled in
	# _shortcut_input) is the only key that still flows through.
	if _pause_menu_container != null and _pause_menu_container.visible:
		return
	var key: InputEventKey = event as InputEventKey
	# Skip OS auto-repeat so holding period/bracket doesn't spam frame-steps or
	# speed changes — one tap = one action. The user re-taps to step again.
	if key.echo:
		return
	match key.keycode:
		KEY_SPACE:
			_on_play_pause_pressed()
			get_viewport().set_input_as_handled()
		KEY_BRACKETLEFT:
			_step_speed(-1)
			get_viewport().set_input_as_handled()
		KEY_BRACKETRIGHT:
			_step_speed(1)
			get_viewport().set_input_as_handled()
		KEY_LEFT:
			_driver.seek(_driver.get_virtual_clock() - 5.0)
			get_viewport().set_input_as_handled()
		KEY_RIGHT:
			_driver.seek(_driver.get_virtual_clock() + 5.0)
			get_viewport().set_input_as_handled()
		KEY_COMMA:
			if _driver.is_paused():
				_driver.step_frame(-1)
				get_viewport().set_input_as_handled()
		KEY_PERIOD:
			if _driver.is_paused():
				_driver.step_frame(1)
				get_viewport().set_input_as_handled()


func _step_speed(direction: int) -> void:
	var idx: int = clampi(_speed_btn.selected + direction, 0, _SPEEDS.size() - 1)
	if idx == _speed_btn.selected:
		return
	_speed_btn.select(idx)
	_on_speed_changed(idx)


func _exit_to_free_play() -> void:
	GameManager.return_to_free_play()


# Escape and the × button funnel through here. Cascades: options open → close
# options; menu open → close menu (resume); nothing open → open menu (pause).
func _toggle_pause_menu() -> void:
	if _pause_options_container != null and _pause_options_container.visible:
		_close_pause_options()
		return
	if _pause_menu_container != null and _pause_menu_container.visible:
		_close_pause_menu()
		return
	_open_pause_menu()


func _open_pause_menu() -> void:
	if _pause_menu_container == null:
		return
	_was_paused_before_menu = _driver.is_paused() if _driver != null else true
	if _driver != null and not _was_paused_before_menu:
		_driver.pause()
		_update_play_pause_text()
	_pause_menu_container.visible = true


func _close_pause_menu() -> void:
	if _pause_menu_container == null:
		return
	_pause_menu_container.visible = false
	# Only auto-resume if the user wasn't paused before opening the menu.
	# Otherwise they'd have to re-pause on every escape press.
	if _driver != null and not _was_paused_before_menu:
		_driver.play()
		_update_play_pause_text()


func _open_pause_options() -> void:
	if _pause_options_container != null:
		_pause_options_container.visible = true


func _close_pause_options() -> void:
	if _pause_options_container != null:
		_pause_options_container.visible = false


# ── Helpers ──────────────────────────────────────────────────────────────────

func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _team_badge(text: String, bg: Color) -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(3)
	style.set_content_margin(SIDE_LEFT, 6)
	style.set_content_margin(SIDE_RIGHT, 6)
	style.set_content_margin(SIDE_TOP, 3)
	style.set_content_margin(SIDE_BOTTOM, 3)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", style)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lum: float = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
	var fg: Color = Color(0.06, 0.06, 0.06) if lum > 0.4 else _WHITE
	badge.add_child(_label(text, 11, fg))
	return badge


func _format_period(p: int) -> String:
	match p:
		1: return "1ST"
		2: return "2ND"
		3: return "3RD"
		_: return "P%d" % p


func _format_clock(t: float) -> String:
	var secs: int = int(ceil(t))
	return "%d:%02d" % [int(secs / 60.0), secs % 60]


func _format_seconds(s: float) -> String:
	var secs: int = int(s)
	return "%d:%02d" % [int(secs / 60.0), secs % 60]
