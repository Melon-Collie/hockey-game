class_name LobbySettingsPanel
extends VBoxContainer

signal settings_changed(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int)

const _SETTING_LABEL_WIDTH: int = 140
const _SETTING_CONTROL_WIDTH: int = 220

var _num_periods: int
var _period_duration: float
var _ot_enabled: bool
var _rule_set: int
var _is_host: bool

var _periods_slider: HSlider = null
var _periods_value_label: Label = null
var _dur_slider: HSlider = null
var _dur_value_label: Label = null
var _ot_check: CheckButton = null
var _rules_btn: OptionButton = null


func _init(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int, is_host: bool) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	_is_host = is_host
	add_theme_constant_override("separation", 10)
	_build()


func apply_settings(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	_periods_slider.set_value_no_signal(_num_periods)
	_periods_value_label.text = str(_num_periods)
	var dur_min: int = int(_period_duration / 60.0)
	_dur_slider.set_value_no_signal(dur_min)
	_dur_value_label.text = "%d min" % dur_min
	_ot_check.set_pressed_no_signal(_ot_enabled)
	_rules_btn.select(_rule_set)


# ── Build helpers ────────────────────────────────────────────────────────────

func _build() -> void:
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = MenuStyle.TEXT_SEP
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", sep_style)
	add_child(sep)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(center)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 12)
	center.add_child(grid)

	grid.add_child(_setting_label("Periods"))
	var periods_row := _stepper_row()
	_periods_slider = _stepper_slider(1, 3, _num_periods)
	_periods_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _is_host:
		_periods_slider.value_changed.connect(_on_periods_changed)
	periods_row.add_child(_periods_slider)
	_periods_value_label = _stepper_value_label(str(_num_periods))
	periods_row.add_child(_periods_value_label)
	grid.add_child(periods_row)

	grid.add_child(_setting_label("Period Length"))
	var dur_row := _stepper_row()
	var dur_min: int = int(_period_duration / 60.0)
	_dur_slider = _stepper_slider(1, 10, dur_min)
	_dur_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _is_host:
		_dur_slider.value_changed.connect(_on_duration_changed)
	dur_row.add_child(_dur_slider)
	_dur_value_label = _stepper_value_label("%d min" % dur_min)
	dur_row.add_child(_dur_value_label)
	grid.add_child(dur_row)

	grid.add_child(_setting_label("Overtime"))
	_ot_check = CheckButton.new()
	_ot_check.set_pressed_no_signal(_ot_enabled)
	_ot_check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	SoundManager.wire_button(_ot_check)
	_ot_check.disabled = not _is_host
	if _is_host:
		_ot_check.toggled.connect(_on_ot_toggled)
	else:
		_ot_check.modulate = Color(1, 1, 1, 0.5)
	grid.add_child(_ot_check)

	grid.add_child(_setting_label("Rules"))
	_rules_btn = OptionButton.new()
	_rules_btn.custom_minimum_size = Vector2(_SETTING_CONTROL_WIDTH, 40)
	_rules_btn.add_theme_font_size_override("font_size", 16)
	for i: int in range(GameRules.RULE_SET_NAMES.size()):
		_rules_btn.add_item(GameRules.RULE_SET_NAMES[i], i)
	_rules_btn.select(_rule_set)
	SoundManager.wire_button(_rules_btn)
	_rules_btn.disabled = not _is_host
	if _is_host:
		_rules_btn.item_selected.connect(_on_rule_set_selected)
	else:
		_rules_btn.modulate = Color(1, 1, 1, 0.5)
	grid.add_child(_rules_btn)


func _stepper_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(_SETTING_CONTROL_WIDTH, 0)
	return row


func _setting_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(_SETTING_LABEL_WIDTH, 0)
	return lbl


# Discrete-integer slider for small ranges (periods, period length). Tick marks
# on every integer make the granularity obvious.
func _stepper_slider(low: int, high: int, value: int) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = 1
	slider.value = value
	slider.tick_count = high - low + 1
	slider.ticks_on_borders = true
	slider.custom_minimum_size = Vector2(0, 32)
	slider.editable = _is_host
	if not _is_host:
		slider.modulate = Color(1, 1, 1, 0.5)
	return slider


func _stepper_value_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(56, 0)
	return lbl


# ── Change handlers ─────────────────────────────────────────────────────────

func _on_periods_changed(v: float) -> void:
	_num_periods = int(v)
	_periods_value_label.text = str(_num_periods)
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set)


func _on_duration_changed(v: float) -> void:
	_period_duration = v * 60.0
	_dur_value_label.text = "%d min" % int(v)
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set)


func _on_ot_toggled(pressed: bool) -> void:
	_ot_enabled = pressed
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set)


func _on_rule_set_selected(idx: int) -> void:
	_rule_set = idx
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set)
