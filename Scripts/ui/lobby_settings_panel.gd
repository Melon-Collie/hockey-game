class_name LobbySettingsPanel
extends VBoxContainer

# Compact match-settings section for the lobby. Renders seven rows
# (Mode, Periods, Period Length, Overtime, Rules, Bot Difficulty, Goalie),
# each with a label on the left and the control on the right, laid out as two
# side-by-side row columns so the section stays shallow: the pace rules
# (Mode / Periods / Period Length / Overtime) on the left, the OptionButton
# trio (Rules + the two host-local AI difficulty prefs) on the right. Hosts
# get editable controls; clients see them dimmed and disabled. The "MATCH"
# header above this panel is rendered by LobbyManager so the same widget can
# drop into either the lobby tray or a hypothetical pause-menu surface later.
#
# The first five rows are NETWORK-SYNCED match rules — they emit
# settings_changed and LobbyManager owns broadcasting them to clients. Bot
# Difficulty and Goalie are different: they're host-LOCAL persisted preferences
# (bots and both goalies are host-spawned AI, so clients never need them), so
# those rows write straight to PlayerPrefs + save and do NOT go through
# settings_changed. GameManager reads PlayerPrefs.bot_difficulty and
# PlayerPrefs.goalie_difficulty at match start.

signal settings_changed(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int,
		team_size: int)

const _ROW_HEIGHT: int = 28
const _PERIODS_MIN: int = 1
const _PERIODS_MAX: int = 3
const _DUR_MIN_MINUTES: int = 1
const _DUR_MAX_MINUTES: int = 10

var _num_periods: int
var _period_duration: float
var _ot_enabled: bool
var _rule_set: int
var _team_size: int
var _is_host: bool

var _periods_value_label: Label = null
var _dur_value_label: Label = null
var _ot_check: CheckButton = null
var _rules_btn: OptionButton = null
var _mode_btn: OptionButton = null
var _bot_difficulty_btn: OptionButton = null
var _goalie_difficulty_btn: OptionButton = null
var _periods_minus: Button = null
var _periods_plus: Button = null
var _dur_minus: Button = null
var _dur_plus: Button = null


func _init(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int, is_host: bool,
		team_size: int = GameRules.DEFAULT_TEAM_SIZE) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	_team_size = team_size
	_is_host = is_host
	add_theme_constant_override("separation", 10)
	_build()


func apply_settings(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int,
		team_size: int = GameRules.DEFAULT_TEAM_SIZE) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	_team_size = team_size
	_periods_value_label.text = str(_num_periods)
	_dur_value_label.text = "%d min" % int(_period_duration / 60.0)
	_ot_check.set_pressed_no_signal(_ot_enabled)
	_rules_btn.select(_rule_set)
	_mode_btn.select(maxi(GameRules.TEAM_SIZE_OPTIONS.find(_team_size), 0))
	_update_stepper_enabled()


# ── Build helpers ────────────────────────────────────────────────────────────

func _build() -> void:
	# Two side-by-side row columns (see class doc). Rows below append to
	# `left` or `right` instead of directly to self.
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(cols)
	var left := _row_column()
	cols.add_child(left)
	var right := _row_column()
	cols.add_child(right)

	# Row 0 (left): Mode (team size — 3v3 / 5v5). Network-synced match rule
	# like Rules; latched at puck drop into GameStateMachine.team_size.
	var m_row := _row("Mode")
	_mode_btn = OptionButton.new()
	_mode_btn.custom_minimum_size = Vector2(120, 28)
	_mode_btn.add_theme_font_size_override("font_size", 13)
	for i: int in range(GameRules.TEAM_SIZE_NAMES.size()):
		_mode_btn.add_item(GameRules.TEAM_SIZE_NAMES[i], i)
	_mode_btn.select(maxi(GameRules.TEAM_SIZE_OPTIONS.find(_team_size), 0))
	SoundManager.wire_button(_mode_btn)
	_mode_btn.disabled = not _is_host
	if _is_host:
		_mode_btn.item_selected.connect(_on_mode_selected)
	else:
		_mode_btn.modulate = Color(1, 1, 1, 0.5)
	m_row.add_child(_mode_btn)
	left.add_child(m_row)

	# Row 1 (left): Periods
	var p_row := _row("Periods")
	_periods_minus = _stepper_btn("-")
	_periods_value_label = _value_label(str(_num_periods))
	_periods_plus = _stepper_btn("+")
	if _is_host:
		_periods_minus.pressed.connect(_on_periods_minus)
		_periods_plus.pressed.connect(_on_periods_plus)
	p_row.add_child(_periods_value_label)
	p_row.add_child(_periods_minus)
	p_row.add_child(_periods_plus)
	left.add_child(p_row)

	# Row 2 (left): Period Length
	var d_row := _row("Period Length")
	_dur_minus = _stepper_btn("-")
	var dur_min: int = int(_period_duration / 60.0)
	_dur_value_label = _value_label("%d min" % dur_min)
	_dur_plus = _stepper_btn("+")
	if _is_host:
		_dur_minus.pressed.connect(_on_dur_minus)
		_dur_plus.pressed.connect(_on_dur_plus)
	d_row.add_child(_dur_value_label)
	d_row.add_child(_dur_minus)
	d_row.add_child(_dur_plus)
	left.add_child(d_row)

	# Row 3 (left): Overtime
	var ot_row := _row("Overtime")
	_ot_check = CheckButton.new()
	_ot_check.set_pressed_no_signal(_ot_enabled)
	_ot_check.size_flags_horizontal = Control.SIZE_SHRINK_END
	SoundManager.wire_button(_ot_check)
	_ot_check.disabled = not _is_host
	if _is_host:
		_ot_check.toggled.connect(_on_ot_toggled)
	else:
		_ot_check.modulate = Color(1, 1, 1, 0.5)
	ot_row.add_child(_ot_check)
	left.add_child(ot_row)

	# Row 4 (right): Rules
	var r_row := _row("Rules")
	_rules_btn = OptionButton.new()
	_rules_btn.custom_minimum_size = Vector2(120, 28)
	_rules_btn.add_theme_font_size_override("font_size", 13)
	for i: int in range(GameRules.RULE_SET_NAMES.size()):
		_rules_btn.add_item(GameRules.RULE_SET_NAMES[i], i)
	_rules_btn.select(_rule_set)
	SoundManager.wire_button(_rules_btn)
	_rules_btn.disabled = not _is_host
	if _is_host:
		_rules_btn.item_selected.connect(_on_rule_set_selected)
	else:
		_rules_btn.modulate = Color(1, 1, 1, 0.5)
	r_row.add_child(_rules_btn)
	right.add_child(r_row)

	# Row 5 (right): Bot Difficulty. Host-local preference (see class doc) —
	# writes PlayerPrefs directly, no settings_changed emit. Host-gated like
	# Rules.
	var b_row := _row("Bot Difficulty")
	_bot_difficulty_btn = OptionButton.new()
	_bot_difficulty_btn.custom_minimum_size = Vector2(120, 28)
	_bot_difficulty_btn.add_theme_font_size_override("font_size", 13)
	for i: int in range(PlayerPrefs.BOT_DIFFICULTY_LABELS.size()):
		_bot_difficulty_btn.add_item(PlayerPrefs.BOT_DIFFICULTY_LABELS[i], i)
	_bot_difficulty_btn.select(PlayerPrefs.bot_difficulty)
	SoundManager.wire_button(_bot_difficulty_btn)
	_bot_difficulty_btn.disabled = not _is_host
	if _is_host:
		_bot_difficulty_btn.item_selected.connect(_on_bot_difficulty_selected)
	else:
		_bot_difficulty_btn.modulate = Color(1, 1, 1, 0.5)
	b_row.add_child(_bot_difficulty_btn)
	right.add_child(b_row)

	# Row 6 (right): Goalie Difficulty. Host-local preference like Bot
	# Difficulty — the host runs both nets' AI, so clients never need it.
	# Writes PlayerPrefs directly, no settings_changed emit. GameManager reads
	# it at match start.
	var g_row := _row("Goalie")
	_goalie_difficulty_btn = OptionButton.new()
	_goalie_difficulty_btn.custom_minimum_size = Vector2(120, 28)
	_goalie_difficulty_btn.add_theme_font_size_override("font_size", 13)
	for i: int in range(PlayerPrefs.GOALIE_DIFFICULTY_LABELS.size()):
		_goalie_difficulty_btn.add_item(PlayerPrefs.GOALIE_DIFFICULTY_LABELS[i], i)
	_goalie_difficulty_btn.select(PlayerPrefs.goalie_difficulty)
	SoundManager.wire_button(_goalie_difficulty_btn)
	_goalie_difficulty_btn.disabled = not _is_host
	if _is_host:
		_goalie_difficulty_btn.item_selected.connect(_on_goalie_difficulty_selected)
	else:
		_goalie_difficulty_btn.modulate = Color(1, 1, 1, 0.5)
	g_row.add_child(_goalie_difficulty_btn)
	right.add_child(g_row)

	_update_stepper_enabled()


# One of the two row columns _build lays rows into.
func _row_column() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return col


func _row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(0, _ROW_HEIGHT)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	return row


func _stepper_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(24, 24)
	btn.add_theme_font_size_override("font_size", 14)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	SoundManager.wire_button(btn)
	if not _is_host:
		btn.disabled = true
		btn.modulate = Color(1, 1, 1, 0.5)
	return btn


func _value_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(60, 0)
	return lbl


# Disable the +/- buttons at the range edges so the host can't step out of
# bounds. Re-enabled when a step away from the edge brings the value back
# into the interior. Skipped entirely on clients (everything's disabled).
func _update_stepper_enabled() -> void:
	if not _is_host:
		return
	if _periods_minus != null:
		_periods_minus.disabled = _num_periods <= _PERIODS_MIN
	if _periods_plus != null:
		_periods_plus.disabled = _num_periods >= _PERIODS_MAX
	if _dur_minus != null:
		_dur_minus.disabled = int(_period_duration / 60.0) <= _DUR_MIN_MINUTES
	if _dur_plus != null:
		_dur_plus.disabled = int(_period_duration / 60.0) >= _DUR_MAX_MINUTES


# ── Change handlers ─────────────────────────────────────────────────────────

func _on_periods_minus() -> void:
	_num_periods = clampi(_num_periods - 1, _PERIODS_MIN, _PERIODS_MAX)
	_periods_value_label.text = str(_num_periods)
	_update_stepper_enabled()
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set, _team_size)


func _on_periods_plus() -> void:
	_num_periods = clampi(_num_periods + 1, _PERIODS_MIN, _PERIODS_MAX)
	_periods_value_label.text = str(_num_periods)
	_update_stepper_enabled()
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set, _team_size)


func _on_dur_minus() -> void:
	var dur_min: int = clampi(int(_period_duration / 60.0) - 1, _DUR_MIN_MINUTES, _DUR_MAX_MINUTES)
	_period_duration = dur_min * 60.0
	_dur_value_label.text = "%d min" % dur_min
	_update_stepper_enabled()
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set, _team_size)


func _on_dur_plus() -> void:
	var dur_min: int = clampi(int(_period_duration / 60.0) + 1, _DUR_MIN_MINUTES, _DUR_MAX_MINUTES)
	_period_duration = dur_min * 60.0
	_dur_value_label.text = "%d min" % dur_min
	_update_stepper_enabled()
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set, _team_size)


func _on_ot_toggled(pressed: bool) -> void:
	_ot_enabled = pressed
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set, _team_size)


func _on_rule_set_selected(idx: int) -> void:
	_rule_set = idx
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set, _team_size)


func _on_mode_selected(idx: int) -> void:
	_team_size = GameRules.TEAM_SIZE_OPTIONS[clampi(idx, 0, GameRules.TEAM_SIZE_OPTIONS.size() - 1)]
	settings_changed.emit(_num_periods, _period_duration, _ot_enabled, _rule_set, _team_size)


# Host-local preference, persisted immediately. Not part of settings_changed
# (see class doc) — GameManager reads PlayerPrefs.bot_difficulty at match start.
func _on_bot_difficulty_selected(idx: int) -> void:
	PlayerPrefs.bot_difficulty = idx
	PlayerPrefs.save()


# Host-local preference, persisted immediately. Not part of settings_changed
# (see class doc) — GameManager reads PlayerPrefs.goalie_difficulty at match start.
func _on_goalie_difficulty_selected(idx: int) -> void:
	PlayerPrefs.goalie_difficulty = idx
	PlayerPrefs.save()
