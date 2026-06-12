class_name LoadingScreen
extends CanvasLayer

signal cancel_pressed

var _status_label: Label = null
var _subtitle_label: Label = null
var _cancel_btn: Button = null
var _base_status: String = ""
var _dot_timer: float = 0.0
var _dot_count: int = 0
var _shown_at: float = -1.0
var _is_error: bool = false

const MIN_DISPLAY_SECS: float = 1.0

func _ready() -> void:
	layer = 100
	_build_ui()
	visible = false

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.10, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Mitts"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color.WHITE)
	vbox.add_child(title)

	_subtitle_label = Label.new()
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_size_override("font_size", 18)
	_subtitle_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.60, 1.0))
	vbox.add_child(_subtitle_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	vbox.add_child(spacer)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 22)
	_status_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.90, 1.0))
	vbox.add_child(_status_label)

	_cancel_btn = Button.new()
	_cancel_btn.text = "Cancel"
	_cancel_btn.custom_minimum_size = Vector2(200, 48)
	_cancel_btn.add_theme_font_size_override("font_size", 20)
	_cancel_btn.pressed.connect(func() -> void: cancel_pressed.emit())
	SoundManager.wire_button(_cancel_btn)
	var cancel_container := CenterContainer.new()
	cancel_container.add_child(_cancel_btn)
	vbox.add_child(cancel_container)

func _process(delta: float) -> void:
	if not visible or _is_error:
		return
	_dot_timer += delta
	if _dot_timer >= 0.4:
		_dot_timer = 0.0
		_dot_count = (_dot_count + 1) % 4
		_status_label.text = _base_status + ".".repeat(_dot_count)

# Host spinner while the Steam lobby is being created (no cancel — creation is
# quick and there's nothing to back out of yet).
func show_hosting() -> void:
	_subtitle_label.text = "Hosting"
	_cancel_btn.visible = false
	_is_error = false
	set_status("Creating lobby")
	_shown_at = Time.get_ticks_msec() / 1000.0
	visible = true

# Client spinner during the Steam lobby-join + connection handshake.
func show_joining_lobby() -> void:
	_subtitle_label.text = "Joining game"
	_cancel_btn.visible = true
	_is_error = false
	set_status("Connecting")
	_shown_at = Time.get_ticks_msec() / 1000.0
	visible = true

# Surface a lobby/connection failure in place; the Cancel button dismisses it
# (wired to the same cancel handler that resets network state).
func show_error(message: String) -> void:
	_subtitle_label.text = ""
	_cancel_btn.visible = true
	_is_error = true
	_base_status = message
	_status_label.text = message
	visible = true

func close_when_ready(callback: Callable) -> void:
	var remaining: float = MIN_DISPLAY_SECS - (Time.get_ticks_msec() / 1000.0 - _shown_at)
	if remaining <= 0.0:
		callback.call()
	else:
		get_tree().create_timer(remaining).timeout.connect(callback, CONNECT_ONE_SHOT)

func set_status(text: String) -> void:
	_base_status = text
	_dot_count = 0
	_dot_timer = 0.0
	_status_label.text = text
