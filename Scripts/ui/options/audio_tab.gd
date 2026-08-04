class_name OptionsAudioTab
extends OptionsTab

# Audio tab — volume mix plus the two mute toggles.

var _volume_slider: HSlider = null
var _music_slider: HSlider = null
var _sfx_slider: HSlider = null
var _ui_slider: HSlider = null
var _arena_slider: HSlider = null
var _mute_check: CheckButton = null
var _mute_unfocused_check: CheckButton = null

func _build_content() -> void:
	add_child(_section_header("Volume"))

	_volume_slider = _make_volume_slider(PlayerPrefs.master_volume)
	var master_val := _value_label("%d%%" % int(PlayerPrefs.master_volume * 100))
	_volume_slider.value_changed.connect(func(v: float) -> void: master_val.text = "%d%%" % int(v * 100))
	add_child(_slider_row("Master", _volume_slider, master_val))

	_music_slider = _make_volume_slider(PlayerPrefs.music_volume)
	var music_val := _value_label("%d%%" % int(PlayerPrefs.music_volume * 100))
	_music_slider.value_changed.connect(func(v: float) -> void: music_val.text = "%d%%" % int(v * 100))
	add_child(_slider_row("Music", _music_slider, music_val))

	_sfx_slider = _make_volume_slider(PlayerPrefs.sfx_volume)
	var sfx_val := _value_label("%d%%" % int(PlayerPrefs.sfx_volume * 100))
	_sfx_slider.value_changed.connect(func(v: float) -> void: sfx_val.text = "%d%%" % int(v * 100))
	add_child(_slider_row("SFX", _sfx_slider, sfx_val))

	_ui_slider = _make_volume_slider(PlayerPrefs.ui_volume)
	var ui_val := _value_label("%d%%" % int(PlayerPrefs.ui_volume * 100))
	_ui_slider.value_changed.connect(func(v: float) -> void: ui_val.text = "%d%%" % int(v * 100))
	add_child(_slider_row("UI", _ui_slider, ui_val))

	_arena_slider = _make_volume_slider(PlayerPrefs.arena_volume)
	var arena_val := _value_label("%d%%" % int(PlayerPrefs.arena_volume * 100))
	_arena_slider.value_changed.connect(func(v: float) -> void: arena_val.text = "%d%%" % int(v * 100))
	add_child(_slider_row("Arena", _arena_slider, arena_val))

	add_child(_section_spacer())

	_mute_check = CheckButton.new()
	_mute_check.set_pressed_no_signal(PlayerPrefs.master_muted)
	SoundManager.wire_button(_mute_check)
	_mute_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Mute All", _mute_check))

	_mute_unfocused_check = CheckButton.new()
	_mute_unfocused_check.set_pressed_no_signal(PlayerPrefs.mute_when_unfocused)
	SoundManager.wire_button(_mute_unfocused_check)
	_mute_unfocused_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Mute When Unfocused", _mute_unfocused_check))

# All four volume sliders share the same range / step / notify handler.
func _make_volume_slider(initial: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.value = initial
	s.value_changed.connect(func(_v: float) -> void: _notify_changed())
	return s

func read_controls() -> Dictionary:
	return {
		"master_volume": _volume_slider.value,
		"music_volume": _music_slider.value,
		"sfx_volume": _sfx_slider.value,
		"ui_volume": _ui_slider.value,
		"arena_volume": _arena_slider.value,
		"master_muted": _mute_check.button_pressed,
		"mute_when_unfocused": _mute_unfocused_check.button_pressed,
	}

func apply_values(v: Dictionary) -> void:
	_volume_slider.value = v.master_volume
	_music_slider.value = v.music_volume
	_sfx_slider.value = v.sfx_volume
	_ui_slider.value = v.ui_volume
	_arena_slider.value = v.arena_volume
	_mute_check.set_pressed_no_signal(v.master_muted)
	_mute_unfocused_check.set_pressed_no_signal(v.mute_when_unfocused)
