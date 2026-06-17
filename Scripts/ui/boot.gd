class_name Boot
extends Control

# Title card shown at app launch. Holds the user on the logo while Hockey.tscn
# loads in a background thread, then on first key/mouse press bootstraps free
# play and transitions to the rink. The user lands directly on the ice — there
# is no main menu screen; Escape from free play opens the SideMenu instead.

const _HOCKEY_SCENE_PATH := "res://Scenes/Hockey.tscn"

var _prompt_label: Label = null
var _loading_label: Label = null
var _settings_container: Control = null
var _input_received: bool = false
var _transitioned: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Pass mouse events through to _unhandled_input so the title card can
	# be dismissed by clicking, not just by keyboard. The default STOP
	# filter on a root Control would otherwise swallow the click.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	TeamColorRegistry.ensure_loaded()
	PlayerPrefs.apply_video()
	# Kick off threaded load of the heavy rink scene immediately. By the time
	# the user has reacted to the title card the load is almost always done.
	ResourceLoader.load_threaded_request(_HOCKEY_SCENE_PATH)
	_build_ui()


func _build_ui() -> void:
	# Cascade Manrope to every Label under the title card.
	theme = MenuStyle.ui_theme()

	# Flat dark navy background — same value as the side menu / scorebug,
	# so the title card lives in the same visual world the rest of the
	# UI does. The old ice photo washed out the "Press any key" prompt.
	var bg := ColorRect.new()
	bg.color = MenuStyle.PANEL_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 24)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	# Logo with a glow halo behind it — same two-rect treatment as the old
	# main menu. Bigger on the title card (no other UI competing for space)
	# so the brand moment lands.
	var logo_slot := Control.new()
	logo_slot.custom_minimum_size = Vector2(820, 360)
	logo_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(logo_slot)

	var logo_tex: Texture2D = load("res://Assets/logos/Mitts_logo_full_padded.png")

	var glow := TextureRect.new()
	glow.texture = logo_tex
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var glow_mat := ShaderMaterial.new()
	glow_mat.shader = load("res://Assets/Shaders/ui_glow.gdshader")
	glow.material = glow_mat
	logo_slot.add_child(glow)

	var logo := TextureRect.new()
	logo.texture = logo_tex
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	logo_slot.add_child(logo)

	_prompt_label = Label.new()
	_prompt_label.text = "Press any key"
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 22)
	_prompt_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_prompt_label)

	# Hidden until the user presses something before the threaded load finishes.
	# Replaces the prompt so the moment doesn't feel frozen.
	_loading_label = Label.new()
	_loading_label.text = "Loading…"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 22)
	_loading_label.add_theme_color_override("font_color", MenuStyle.TEAL)
	_loading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading_label.visible = false
	vbox.add_child(_loading_label)

	# Lets players adjust audio / video / controls before committing to a
	# session. The OptionsPanel reads PlayerPrefs at build time and only writes
	# on Apply, so it's safe to open before the rink scene exists.
	var settings_btn := MenuStyle.popup_button("Settings")
	settings_btn.pressed.connect(_on_settings_pressed)
	vbox.add_child(settings_btn)

	var version_label := Label.new()
	version_label.text = "v%s" % BuildInfo.VERSION
	version_label.add_theme_font_size_override("font_size", 14)
	version_label.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	version_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version_label.offset_right = -16
	version_label.offset_bottom = -12
	add_child(version_label)

	# Polls the GitHub Releases API once and shows an "update available" nudge
	# when the running build is stale (no-op in dev builds). Boot is the one
	# screen every launch passes through, so the check lives here.
	var update_checker := UpdateChecker.new()
	update_checker.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	update_checker.offset_top = -84
	update_checker.offset_bottom = -36
	update_checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(update_checker)

	# Settings overlay sits on top of everything; hidden until the button is hit.
	_build_settings_overlay()

	# Gentle pulse on the prompt so it reads as "waiting for input."
	MenuStyle.pulse(_prompt_label)


func _build_settings_overlay() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_settings_container.visible = false)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var options := OptionsPanel.new()
	options.close_requested.connect(func() -> void:
		_settings_container.visible = false)
	panel.add_child(options)

	_settings_container = Control.new()
	_settings_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_container.visible = false
	_settings_container.add_child(overlay)
	_settings_container.add_child(panel)
	add_child(_settings_container)


func _on_settings_pressed() -> void:
	if _settings_container != null:
		_settings_container.visible = true


func _unhandled_input(event: InputEvent) -> void:
	# While the settings overlay is up, Escape closes it and every other input
	# is swallowed so the title card isn't dismissed out from under the panel.
	if _settings_container != null and _settings_container.visible:
		if event.is_action_pressed(&"ui_cancel"):
			_settings_container.visible = false
			get_viewport().set_input_as_handled()
		return
	if _input_received:
		return
	# Accept key presses, mouse clicks, and joypad buttons — anything decisive.
	# Ignore mouse motion and key releases.
	var triggered: bool = (
		(event is InputEventKey and event.pressed and not event.echo)
		or (event is InputEventMouseButton and event.pressed)
		or (event is InputEventJoypadButton and event.pressed)
	)
	if not triggered:
		return
	_input_received = true
	get_viewport().set_input_as_handled()
	if _prompt_label != null:
		_prompt_label.visible = false
	if _loading_label != null:
		_loading_label.visible = true
	_try_transition()


func _process(_delta: float) -> void:
	if _input_received and not _transitioned:
		_try_transition()


func _try_transition() -> void:
	var status := ResourceLoader.load_threaded_get_status(_HOCKEY_SCENE_PATH)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		# Fallback: synchronous load. Should be vanishingly rare since the
		# threaded load was requested at boot, but we don't want to softlock.
		var scene := load(_HOCKEY_SCENE_PATH) as PackedScene
		if scene == null:
			push_error("Boot: failed to load Hockey scene")
			return
		_bootstrap_free_play_and_change(scene)
		return
	var packed := ResourceLoader.load_threaded_get(_HOCKEY_SCENE_PATH) as PackedScene
	if packed == null:
		push_error("Boot: threaded load returned null PackedScene")
		return
	_bootstrap_free_play_and_change(packed)


func _bootstrap_free_play_and_change(scene: PackedScene) -> void:
	if _transitioned:
		return
	_transitioned = true
	# First-time players land in the Basics tutorial after the splash instead
	# of dropping straight into free play. Once they finish — or hit Skip All
	# in the HUD — PlayerPrefs.mark_tutorial_complete("basics") flips this so
	# subsequent boots go straight to the rink. An accepted Steam invite
	# trumps the tutorial: the player clicked "Join Game", and the SideMenu
	# consumes the stashed lobby id once free play is up.
	if not PlayerPrefs.is_tutorial_complete(TutorialRegistry.BASICS_ID) \
			and SteamManager.pending_invite_lobby_id == 0:
		NetworkManager.start_tutorial(TutorialRegistry.BASICS_ID)
	else:
		NetworkManager.start_free_play()
	get_tree().change_scene_to_packed(scene)
