class_name TeamColorPopup
extends Control

# Used by both the Free Play and With Bots offline flows. The two only differ
# in title, the play button label, and where MainMenu routes after play_pressed
# (straight into the game vs. through the lobby).

enum Mode {
	FREE_PLAY,
	WITH_BOTS,
}

signal play_pressed(mode: Mode, home_color_id: String, away_color_id: String)
signal back_pressed(mode: Mode)

var _home_btn: OptionButton = null
var _away_btn: OptionButton = null
var _title_label: Label = null
var _play_btn: Button = null
var _mode: Mode = Mode.FREE_PLAY
var _home_color_id: String = TeamColorRegistry.DEFAULT_HOME_ID
var _away_color_id: String = TeamColorRegistry.DEFAULT_AWAY_ID


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	visible = false


func _build() -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.6)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_overlay_clicked)
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	var close_row := HBoxContainer.new()
	var close_spacer := Control.new()
	close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(close_spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(func() -> void:
		visible = false
		back_pressed.emit(_mode))
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 28)
	_title_label.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(_title_label)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 12)
	vbox.add_child(grid)

	var home_lbl := Label.new()
	home_lbl.text = "Home:"
	home_lbl.add_theme_font_size_override("font_size", 20)
	home_lbl.add_theme_color_override("font_color", Color.WHITE)
	home_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	grid.add_child(home_lbl)

	_home_btn = MenuStyle.color_option_btn(_home_color_id, Vector2(160, 40), 18)
	SoundManager.wire_button(_home_btn)
	_home_btn.item_selected.connect(_on_home_selected)
	grid.add_child(_home_btn)

	var away_lbl := Label.new()
	away_lbl.text = "Away:"
	away_lbl.add_theme_font_size_override("font_size", 20)
	away_lbl.add_theme_color_override("font_color", Color.WHITE)
	away_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	grid.add_child(away_lbl)

	_away_btn = MenuStyle.color_option_btn(_away_color_id, Vector2(160, 40), 18)
	SoundManager.wire_button(_away_btn)
	_away_btn.item_selected.connect(_on_away_selected)
	grid.add_child(_away_btn)

	_play_btn = Button.new()
	_play_btn.custom_minimum_size = Vector2(308, 48)
	_play_btn.add_theme_font_size_override("font_size", 20)
	MenuStyle.wire_hover_scale(_play_btn)
	SoundManager.wire_button(_play_btn)
	_play_btn.pressed.connect(_on_play_pressed)
	vbox.add_child(_play_btn)


func open(mode: Mode, home_color_id: String, away_color_id: String) -> void:
	_mode = mode
	_home_color_id = home_color_id
	_away_color_id = away_color_id
	_title_label.text = "Free Play" if mode == Mode.FREE_PLAY else "With Bots"
	_play_btn.text = "Play" if mode == Mode.FREE_PLAY else "Continue to Lobby"
	_refresh_color_buttons()
	visible = true


func _refresh_color_buttons() -> void:
	var ids: Array[String] = TeamColorRegistry.get_all_ids()
	for i: int in ids.size():
		_home_btn.set_item_disabled(i, ids[i] == _away_color_id)
		_away_btn.set_item_disabled(i, ids[i] == _home_color_id)
		if ids[i] == _home_color_id:
			_home_btn.select(i)
		if ids[i] == _away_color_id:
			_away_btn.select(i)


func _on_home_selected(idx: int) -> void:
	_home_color_id = TeamColorRegistry.get_all_ids()[idx]
	_refresh_color_buttons()


func _on_away_selected(idx: int) -> void:
	_away_color_id = TeamColorRegistry.get_all_ids()[idx]
	_refresh_color_buttons()


func _on_play_pressed() -> void:
	visible = false
	play_pressed.emit(_mode, _home_color_id, _away_color_id)


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		visible = false


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		visible = false
		get_viewport().set_input_as_handled()
