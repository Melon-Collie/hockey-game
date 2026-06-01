class_name GameOverPopup
extends CanvasLayer

signal rematch_toggled
signal host_action_pressed
signal free_play_pressed
signal exit_pressed

const _GOLD := MenuStyle.GOLD
const _DIM := Color(0.62, 0.62, 0.68, 1.0)

var _rematch_btn: Button = null
var _vote_label: Label = null
var _host_btn: Button = null


func _ready() -> void:
	layer = 5
	_build_ui()
	visible = false


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_bottom = -20

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "GAME OVER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", _GOLD)
	vbox.add_child(title)

	var rematch_box := VBoxContainer.new()
	rematch_box.add_theme_constant_override("separation", 4)
	vbox.add_child(rematch_box)

	_rematch_btn = MenuStyle.popup_button("Rematch")
	_rematch_btn.pressed.connect(func() -> void: rematch_toggled.emit())
	rematch_box.add_child(_rematch_btn)

	_vote_label = Label.new()
	_vote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vote_label.add_theme_font_size_override("font_size", 13)
	_vote_label.add_theme_color_override("font_color", _DIM)
	rematch_box.add_child(_vote_label)

	# "Return to Lobby" only exists for an online host — it pulls the whole
	# group back to the shared lobby. Offline has no lobby, and clients can't
	# drive everyone's scene, so neither sees this button.
	if NetworkManager.is_host and not NetworkManager.is_offline_mode:
		_host_btn = MenuStyle.popup_button("Return to Lobby")
		_host_btn.pressed.connect(func() -> void: host_action_pressed.emit())
		vbox.add_child(_host_btn)

	# Always available: drop to solo free play. Offline this is the only leave
	# action; for an online client it disconnects just them; for an online host
	# it tears down the server (everyone drops out).
	var free_play_btn := MenuStyle.popup_button("Return to Free Play")
	free_play_btn.pressed.connect(func() -> void: free_play_pressed.emit())
	vbox.add_child(free_play_btn)

	var exit_btn := MenuStyle.popup_button("Exit Game")
	exit_btn.pressed.connect(func() -> void: exit_pressed.emit())
	vbox.add_child(exit_btn)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)
	add_child(root)


func show_popup() -> void:
	visible = true


func set_spectator(is_spec: bool) -> void:
	_rematch_btn.visible = not is_spec
	_vote_label.visible = not is_spec


func hide_popup() -> void:
	visible = false


func update_votes(votes: Dictionary, total_voters: int, local_voted: bool) -> void:
	_rematch_btn.text = "Unvote" if local_voted else "Rematch"
	var count: int = 0
	for v: bool in votes.values():
		if v:
			count += 1
	_vote_label.text = "%d / %d voted" % [count, total_voters]
