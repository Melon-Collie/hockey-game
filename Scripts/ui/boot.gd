class_name Boot
extends Control

# Title card shown at app launch. Holds the user on the logo while Hockey.tscn
# loads in a background thread. A small menu — Play / Options / Exit — sits
# under the logo: Play bootstraps free play (or the first-run tutorial) and
# transitions to the rink, Options opens the settings overlay in place, Exit
# quits. There is no separate main menu screen; Escape from free play opens
# the SideMenu instead.

const _HOCKEY_SCENE_PATH := "res://Scenes/Hockey.tscn"

var _button_column: Control = null
var _loading_label: Label = null
var _settings_container: Control = null
var _input_received: bool = false
var _transitioned: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The root is just a backdrop; let the menu buttons handle their own clicks
	# rather than the default STOP filter swallowing them at the root.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	TeamColorRegistry.ensure_loaded()
	PlayerPrefs.apply_video()
	# Kick off threaded load of the heavy rink scene immediately. By the time
	# the user has read the menu the load is almost always done.
	ResourceLoader.load_threaded_request(_HOCKEY_SCENE_PATH)
	_build_ui()


func _build_ui() -> void:
	# Cascade Manrope to every Label under the title card.
	theme = MenuStyle.ui_theme()

	# Scratched-ice texture (same asset as the lobby) under a heavy navy tint.
	# The tint is what makes this work: an earlier full-brightness ice photo
	# washed out the menu text, so the texture sits behind PANEL_BG at high
	# alpha — subtle surface interest, same dark world as the rest of the UI.
	var bg := TextureRect.new()
	bg.texture = load("res://Assets/Mitts_ice_background.png")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var tint := ColorRect.new()
	tint.color = Color(MenuStyle.PANEL_BG.r, MenuStyle.PANEL_BG.g, MenuStyle.PANEL_BG.b, 0.86)
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tint)

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

	# Play / Options / Exit. Play enters the game; Options opens the settings
	# overlay (PlayerPrefs is read at build time and only written on Apply, so
	# it's safe before the rink scene exists); Exit quits.
	_button_column = VBoxContainer.new()
	(_button_column as VBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	_button_column.add_theme_constant_override("separation", 12)
	vbox.add_child(_button_column)

	var play_btn := _title_button("Play")
	MenuStyle.apply_primary_cta(play_btn, 26)
	play_btn.pressed.connect(_on_play_pressed)
	_button_column.add_child(play_btn)

	var options_btn := _title_button("Options")
	options_btn.pressed.connect(_on_settings_pressed)
	_button_column.add_child(options_btn)

	var exit_btn := _title_button("Exit")
	exit_btn.pressed.connect(_on_exit_pressed)
	_button_column.add_child(exit_btn)

	# Hidden until Play is pressed before the threaded load finishes. Replaces
	# the menu so the moment doesn't feel frozen.
	_loading_label = Label.new()
	_loading_label.text = "Loading…"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 22)
	_loading_label.add_theme_color_override("font_color", MenuStyle.TEAL)
	_loading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading_label.visible = false
	vbox.add_child(_loading_label)

	var version_label := Label.new()
	# Steam builds append their BuildID — a unique per-upload identifier that's
	# useful in bug reports and unambiguous about which build is running. Dev /
	# non-Steam builds (BuildID 0) just show the VERSION string.
	var version_text: String = "v%s" % BuildInfo.VERSION
	var build_id: int = SteamManager.get_app_build_id()
	if build_id != 0:
		version_text += " (build %d)" % build_id
	version_label.text = version_text
	version_label.add_theme_font_size_override("font_size", 14)
	version_label.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	version_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version_label.offset_right = -16
	version_label.offset_bottom = -12
	add_child(version_label)

	# Settings overlay sits on top of everything; hidden until Options is hit.
	_build_settings_overlay()


# Title-card menu button. Fixed width (SHRINK_CENTER keeps it from stretching
# to the 820px logo column) in Manrope SemiBold caps — matching every other
# button in the game so controls read consistently; the Barlow identity lives
# in the logo, scorebug, and headings, not the buttons.
func _title_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label.to_upper()
	btn.custom_minimum_size = Vector2(340, 56)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.add_theme_font_override("font", MenuStyle.name_font_spaced())
	btn.add_theme_font_size_override("font_size", 26)
	MenuStyle.wire_hover_scale(btn)
	SoundManager.wire_button(btn)
	return btn


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


func _on_play_pressed() -> void:
	if _input_received:
		return
	_input_received = true
	if _button_column != null:
		_button_column.visible = false
	if _loading_label != null:
		_loading_label.visible = true
	_try_transition()


func _on_exit_pressed() -> void:
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	# While the settings overlay is up, Escape closes it.
	if _settings_container != null and _settings_container.visible:
		if event.is_action_pressed(&"ui_cancel"):
			_settings_container.visible = false
			get_viewport().set_input_as_handled()


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
	# Players who have never engaged the tutorial course land in its first
	# part (Movement) after the splash instead of dropping straight into free
	# play. ANY touch dismisses this for good: finishing a part and hitting
	# Exit both mark that part complete, and one marked part means the player
	# has seen the course — being routed back through every remaining part on
	# each boot would nag; the Tutorial menu keeps the rest available.
	# PlayerPrefs wipes completion when the course version bumps, so a
	# restructured course puts everyone back through this gate once. An
	# accepted Steam invite trumps the tutorial: the player clicked
	# "Join Game", and the SideMenu consumes the stashed lobby id once free
	# play is up.
	var course_touched: bool = false
	for id: String in TutorialRegistry.ALL_IDS:
		if PlayerPrefs.is_tutorial_complete(id):
			course_touched = true
			break
	if not course_touched and SteamManager.pending_invite_lobby_id == 0:
		NetworkManager.start_tutorial(TutorialRegistry.MOVEMENT_ID)
	else:
		NetworkManager.start_free_play()
	get_tree().change_scene_to_packed(scene)
