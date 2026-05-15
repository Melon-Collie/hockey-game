class_name Boot
extends Control

# Title card shown at app launch. Holds the user on the logo while Hockey.tscn
# loads in a background thread, then on first key/mouse press bootstraps free
# play and transitions to the rink. The user lands directly on the ice — there
# is no main menu screen; Escape from free play opens the SideMenu instead.

const _HOCKEY_SCENE_PATH := "res://Scenes/Hockey.tscn"

var _prompt_label: Label = null
var _loading_label: Label = null
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

	# Gentle pulse on the prompt so it reads as "waiting for input."
	MenuStyle.pulse(_prompt_label)


func _unhandled_input(event: InputEvent) -> void:
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
	NetworkManager.start_free_play()
	get_tree().change_scene_to_packed(scene)
