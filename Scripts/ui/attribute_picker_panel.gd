class_name AttributePickerPanel
extends VBoxContainer

# Reusable body-build picker (attributes v4) with build presets. Embedded by
# both the free-play PlayerSettingsPopup and the lobby's build editor so the
# two never diverge. Owns a WORKING COPY of the player's presets (deep-copied
# from PlayerPrefs on snapshot()) and edits it in place; the host commits or
# reverts:
#
#   host.open()   -> panel.set_locked(...); panel.snapshot()
#   host.cancel() -> panel.restore()
#   host.apply()  -> if panel.is_dirty(): var attrs := panel.commit()
#
# The panel emits `changed` on every edit so the host can refresh its Apply
# button; the host gates Apply on panel.is_dirty() and panel.is_valid().
#
# A build is two continuous body dials: HEIGHT (5'8"..6'7", every inch) and
# WEIGHT (lbs, bounded per height by the single BMI band — see
# PlayerAttributes.weight_min/max). Every slider position is a legal build —
# there is no power economy and no shape to validate, so is_valid() is always
# true and preset switching is never blocked. Moving the height slider
# preserves the build's FRAME (its position in the BMI band) and recomputes
# pounds, so a lean build stays lean as it grows.
#
# Gear slots ride through the preset levels; each gains its selector when its
# gameplay stage lands. Live: STICK LENGTH (levels[5]), BLADE CURVE
# (levels[3]) and STICK FLEX (levels[4]) — three-way exclusive rows sharing
# one builder. Skate profile (levels[2]) is stored but not yet editable.

signal changed

# Hover tooltips. Headline effects only.
const _HEIGHT_TOOLTIP: String = "Frame length: reach, stick length, and the speed/agility/shot baselines.\nSmall = shiftier with quicker turns; big = longer reach & harder shot."
const _WEIGHT_TOOLTIP: String = "Frame mass, bounded by your height.\nLean = quicker first step, fast stamina recovery, easier to move.\nHeavy = harder hits & harder to move, deep but slow-refilling tank."
const _LENGTH_TOOLTIP: String = "Cut relative to your height.\nShort = snappier blade, finest close control, less reach.\nLong = more reach & sweep, slower to cut back."
const _LENGTH_LABELS: Array[String] = ["Short", "Standard", "Long"]
const _CURVE_TOOLTIP: String = "Blade face.\nClosed = best backhand, hardest to elevate.\nOpen = easy elevation & quick release, weak backhand."
const _CURVE_LABELS: Array[String] = ["Closed", "Balanced", "Open"]
const _FLEX_TOOLTIP: String = "Shaft stiffness.\nWhippy = fastest release, softer shot ceiling.\nStiff = biggest shot, slower to load."
const _FLEX_LABELS: Array[String] = ["Whippy", "Medium", "Stiff"]
const _PROFILE_TOOLTIP: String = "Blade grind.\nAgility = quicker first step & tighter cornering, lower top speed.\nPower = higher top speed & better glide, wider turns."
const _PROFILE_LABELS: Array[String] = ["Agility", "Balanced", "Power"]

# Working copy: Array of {"name": String, "levels": Array[int]} in canonical
# order [height_in, weight_lbs, profile, curve, flex, length]. The UI edits
# only height/weight; gear carries through.
var _working: Array[Dictionary] = []
var _active: int = 0
# Deep copy taken on snapshot(); restore() reverts to it and is_dirty()
# compares against it.
var _snapshot_working: Array[Dictionary] = []
var _snapshot_active: int = 0
var _locked: bool = false
# Reentrancy guard for _refresh(): assigning the weight slider's min/max there
# can re-clamp its value and emit value_changed (Godot's Range.set_min/set_max
# route through set_value, which is NOT silenced by set_value_no_signal). Left
# unguarded, that reentrant _on_weight_changed clobbers the active preset's
# stored weight with a band-clamped value — the "weight isn't saved" bug.
var _refreshing: bool = false

# Controls.
var _chip_row: HBoxContainer = null
var _chip_buttons: Array[Button] = []
var _new_btn: Button = null
var _delete_btn: Button = null
var _name_field: LineEdit = null
var _status_label: Label = null
var _lock_label: Label = null
var _height_slider: HSlider = null
var _height_value_label: Label = null
var _weight_slider: HSlider = null
var _weight_value_label: Label = null
# Gear selector button rows, keyed by the levels index they edit
# (3 = curve, 4 = flex, 5 = length).
var _gear_buttons: Dictionary = {}


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 10)
	_build()


func _build() -> void:
	var heading := Label.new()
	heading.text = "Attributes"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(heading, 22)
	add_child(heading)

	_build_preset_row()
	_build_name_row()

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	add_child(_status_label)

	_lock_label = Label.new()
	_lock_label.text = "Locked during online play."
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_lock_label.add_theme_font_size_override("font_size", 13)
	_lock_label.visible = false
	add_child(_lock_label)

	_build_height_row()
	_build_weight_row()
	# The four gear slots — all live. Each is a three-way exclusive choice
	# (the loft-level pattern — discrete and chunky, never a slider).
	_build_gear_row("Stick", _LENGTH_TOOLTIP, _LENGTH_LABELS, 5)
	_build_gear_row("Curve", _CURVE_TOOLTIP, _CURVE_LABELS, 3)
	_build_gear_row("Flex", _FLEX_TOOLTIP, _FLEX_LABELS, 4)
	_build_gear_row("Skates", _PROFILE_TOOLTIP, _PROFILE_LABELS, 2)


func _build_preset_row() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	add_child(row)

	var label := Label.new()
	label.text = "Preset:"
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	_chip_row = HBoxContainer.new()
	_chip_row.add_theme_constant_override("separation", 6)
	row.add_child(_chip_row)

	_new_btn = Button.new()
	_new_btn.text = "+ New"
	_new_btn.custom_minimum_size = Vector2(72, 40)
	_new_btn.add_theme_font_size_override("font_size", 15)
	MenuStyle.wire_hover_scale(_new_btn)
	SoundManager.wire_button(_new_btn)
	_new_btn.pressed.connect(_on_new_pressed)
	row.add_child(_new_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.custom_minimum_size = Vector2(72, 40)
	_delete_btn.add_theme_font_size_override("font_size", 15)
	MenuStyle.wire_hover_scale(_delete_btn)
	SoundManager.wire_button(_delete_btn)
	_delete_btn.pressed.connect(_on_delete_pressed)
	row.add_child(_delete_btn)


func _build_name_row() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	add_child(row)

	var label := Label.new()
	label.text = "Name:"
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	_name_field = LineEdit.new()
	_name_field.max_length = PlayerPrefs.PRESET_NAME_MAX_LEN
	_name_field.custom_minimum_size = Vector2(180, 40)
	_name_field.add_theme_font_size_override("font_size", 16)
	_name_field.text_changed.connect(_on_name_text_changed)
	row.add_child(_name_field)


func _build_height_row() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	add_child(row)

	var label := Label.new()
	label.text = "Height"
	label.custom_minimum_size = Vector2(80, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = _HEIGHT_TOOLTIP
	row.add_child(label)

	_height_slider = HSlider.new()
	_height_slider.min_value = PlayerAttributes.HEIGHT_MIN
	_height_slider.max_value = PlayerAttributes.HEIGHT_MAX
	_height_slider.step = 1
	_height_slider.custom_minimum_size = Vector2(200, 36)
	_height_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_height_slider.set_value_no_signal(PlayerAttributes.HEIGHT_MEDIUM)
	_height_slider.tooltip_text = _HEIGHT_TOOLTIP
	_height_slider.value_changed.connect(_on_height_changed)
	row.add_child(_height_slider)

	_height_value_label = Label.new()
	_height_value_label.custom_minimum_size = Vector2(60, 0)
	_height_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_height_value_label.add_theme_font_size_override("font_size", 18)
	_height_value_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	_height_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_height_value_label)


func _build_weight_row() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	add_child(row)

	var label := Label.new()
	label.text = "Weight"
	label.custom_minimum_size = Vector2(80, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = _WEIGHT_TOOLTIP
	row.add_child(label)

	_weight_slider = HSlider.new()
	_weight_slider.step = 1
	_weight_slider.custom_minimum_size = Vector2(200, 36)
	_weight_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_weight_slider.tooltip_text = _WEIGHT_TOOLTIP
	_weight_slider.value_changed.connect(_on_weight_changed)
	row.add_child(_weight_slider)

	_weight_value_label = Label.new()
	_weight_value_label.custom_minimum_size = Vector2(60, 0)
	_weight_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_weight_value_label.add_theme_font_size_override("font_size", 18)
	_weight_value_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	_weight_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_weight_value_label)


func _build_gear_row(label_text: String, tooltip: String,
		option_labels: Array[String], level_idx: int) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(80, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = tooltip
	row.add_child(label)

	var buttons: Array[Button] = []
	for i: int in option_labels.size():
		var btn := Button.new()
		btn.text = option_labels[i]
		btn.custom_minimum_size = Vector2(92, 40)
		btn.add_theme_font_size_override("font_size", 15)
		btn.tooltip_text = tooltip
		SoundManager.wire_button(btn)
		btn.pressed.connect(_on_gear_pressed.bind(level_idx, i))
		row.add_child(btn)
		buttons.append(btn)
	_gear_buttons[level_idx] = buttons
	# Controller: keep D-pad left/right cycling WITHIN the segmented row (wrap at the
	# ends) instead of escaping sideways to the slider above. Up/down still move
	# between rows. Set after all buttons are in the tree so the paths resolve.
	if ControllerNav.active() and buttons.size() > 1:
		for i: int in buttons.size():
			buttons[i].focus_neighbor_left = buttons[(i - 1 + buttons.size()) % buttons.size()].get_path()
			buttons[i].focus_neighbor_right = buttons[(i + 1) % buttons.size()].get_path()


# ── Host API ─────────────────────────────────────────────────────────────────

# Whether attribute editing is disabled (an active online match locks the build).
func set_locked(locked: bool) -> void:
	_locked = locked
	if _height_slider != null:
		_refresh()


# Deep-copy the player's presets from PlayerPrefs into the working model and
# record the revert baseline. Call whenever the host opens.
func snapshot() -> void:
	_working = _read_prefs_working()
	_active = clampi(PlayerPrefs.get_active_preset_index(), 0, _working.size() - 1)
	_snapshot_working = _dup_working(_working)
	_snapshot_active = _active
	_rebuild_chips()
	_load_active_into_name_field()
	_refresh()


# Revert the working model to the last snapshot (host Cancel).
func restore() -> void:
	_working = _dup_working(_snapshot_working)
	_active = _snapshot_active
	_rebuild_chips()
	_load_active_into_name_field()
	_refresh()


# Push the working model back into PlayerPrefs and return the (new) active build.
# The host persists (PlayerPrefs.save()) and networks the result.
func commit() -> PlayerAttributes:
	PlayerPrefs.set_all_presets(_working, _active)
	return PlayerPrefs.get_player_attributes()


func is_dirty() -> bool:
	if _active != _snapshot_active or _working.size() != _snapshot_working.size():
		return true
	for i: int in _working.size():
		if _working[i]["name"] != _snapshot_working[i]["name"]:
			return true
		if not _levels_equal(_working[i]["levels"], _snapshot_working[i]["levels"]):
			return true
	return false


# Every slider position is a legal v4 build (lateral axes, coercion-validated),
# so there is nothing to gate. Kept for the host-API contract.
func is_valid() -> bool:
	return true


# ── Interaction ──────────────────────────────────────────────────────────────

func _on_height_changed(value: float) -> void:
	if _refreshing or _active < 0 or _active >= _working.size():
		return
	# Preserve the FRAME across the height change: a lean build stays lean as
	# it grows instead of snapping against the new band edge.
	var levels: Array = _working[_active]["levels"]
	var old_h: int = int(levels[0])
	var old_w: int = int(levels[1])
	var bmi: float = 703.0 * float(old_w) / float(old_h * old_h)
	var new_h: int = int(value)
	levels[0] = new_h
	levels[1] = PlayerAttributes.coerce_weight(new_h,
			PlayerAttributes.weight_for_bmi(new_h, bmi))
	_refresh()
	changed.emit()


func _on_weight_changed(value: float) -> void:
	if _refreshing or _locked or _active < 0 or _active >= _working.size():
		return
	var levels: Array = _working[_active]["levels"]
	levels[1] = PlayerAttributes.coerce_weight(int(levels[0]), int(value))
	_refresh()
	changed.emit()


func _on_gear_pressed(level_idx: int, option: int) -> void:
	if _locked or _active < 0 or _active >= _working.size():
		return
	var levels: Array = _working[_active]["levels"]
	if int(levels[level_idx]) == option:
		return
	levels[level_idx] = option
	_refresh()
	changed.emit()


func _on_chip_pressed(index: int) -> void:
	if index == _active or index < 0 or index >= _working.size():
		return
	_active = index
	_load_active_into_name_field()
	_refresh()
	changed.emit()


func _on_new_pressed() -> void:
	if _working.size() >= PlayerPrefs.MAX_PRESETS or _locked:
		return
	var copy_levels: Array[int] = _dup_levels(_working[_active]["levels"])
	_working.append({"name": _default_preset_name(), "levels": copy_levels})
	_active = _working.size() - 1
	_rebuild_chips()
	_load_active_into_name_field()
	_refresh()
	changed.emit()


func _on_delete_pressed() -> void:
	if _working.size() <= 1 or _locked:
		return
	_working.remove_at(_active)
	_active = clampi(_active, 0, _working.size() - 1)
	_rebuild_chips()
	_load_active_into_name_field()
	_refresh()
	changed.emit()


func _on_name_text_changed(new_text: String) -> void:
	if _active < 0 or _active >= _working.size():
		return
	# Store raw; PlayerPrefs.set_all_presets sanitizes on commit. Update the chip
	# label in place — never rebuild here, that would steal focus from the field.
	_working[_active]["name"] = new_text
	if _active < _chip_buttons.size():
		_chip_buttons[_active].text = _display_name(new_text)
	changed.emit()


# ── Rendering ────────────────────────────────────────────────────────────────

func _rebuild_chips() -> void:
	for child: Node in _chip_row.get_children():
		child.queue_free()
	_chip_buttons = []
	for i: int in _working.size():
		var chip := Button.new()
		chip.text = _display_name(_working[i]["name"])
		chip.custom_minimum_size = Vector2(0, 40)
		chip.add_theme_font_size_override("font_size", 15)
		SoundManager.wire_button(chip)
		chip.pressed.connect(_on_chip_pressed.bind(i))
		_chip_row.add_child(chip)
		_chip_buttons.append(chip)


# Refresh sliders, value labels, status readout, chip states, and button enables
# from the working model. Does NOT touch the name field (avoids clobbering typing
# / focus) — that's done by _load_active_into_name_field on preset switches.
func _refresh() -> void:
	if _height_slider == null or _active < 0 or _active >= _working.size():
		return
	# Guard the whole pass: assigning the weight slider's bounds below can emit a
	# reentrant value_changed that would otherwise clobber the stored weight.
	_refreshing = true
	var levels: Array = _working[_active]["levels"]
	var h: int = int(levels[0])
	var w: int = int(levels[1])
	_height_slider.set_value_no_signal(h)
	_height_slider.editable = not _locked
	_height_value_label.text = PlayerAttributes.inches_label(h)
	# Bounds first, then the value — setting a value outside the slider's
	# current range would clamp it before the new bounds land.
	_weight_slider.min_value = PlayerAttributes.weight_min(h)
	_weight_slider.max_value = PlayerAttributes.weight_max(h)
	_weight_slider.set_value_no_signal(w)
	_weight_slider.editable = not _locked
	_weight_value_label.text = "%d lbs" % w

	for level_idx: int in _gear_buttons:
		var buttons: Array[Button] = _gear_buttons[level_idx]
		var opt: int = clampi(int(levels[level_idx]), 0, buttons.size() - 1)
		for i: int in buttons.size():
			MenuStyle.apply_tab_button(buttons[i], i == opt)
			buttons[i].disabled = _locked and i != opt

	_status_label.text = "%s  ·  %d lbs" % [PlayerAttributes.inches_label(h), w]
	_status_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)

	_lock_label.visible = _locked
	_name_field.editable = not _locked
	_new_btn.disabled = _locked or _working.size() >= PlayerPrefs.MAX_PRESETS
	_delete_btn.disabled = _locked or _working.size() <= 1

	for i: int in _chip_buttons.size():
		MenuStyle.apply_tab_button(_chip_buttons[i], i == _active)
		_chip_buttons[i].disabled = _locked and i != _active

	_refreshing = false


func _load_active_into_name_field() -> void:
	if _active >= 0 and _active < _working.size():
		_name_field.text = String(_working[_active]["name"])


# ── Helpers ──────────────────────────────────────────────────────────────────

func _read_prefs_working() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Dictionary in PlayerPrefs.get_presets():
		var a: PlayerAttributes = p["attrs"]
		var levels: Array[int] = [a.height, a.weight, a.profile, a.curve, a.flex, a.length]
		out.append({"name": String(p["name"]), "levels": levels})
	return out


func _dup_working(src: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in src:
		out.append({"name": String(e["name"]), "levels": _dup_levels(e["levels"])})
	return out


func _dup_levels(levels: Array) -> Array[int]:
	var out: Array[int] = []
	for v: int in levels:
		out.append(v)
	return out


func _levels_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		if int(a[i]) != int(b[i]):
			return false
	return true


func _default_preset_name() -> String:
	return "Build %d" % (_working.size() + 1)


func _display_name(raw_name: String) -> String:
	var trimmed: String = raw_name.strip_edges()
	return trimmed if not trimmed.is_empty() else "(unnamed)"
