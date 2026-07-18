class_name AttributePickerPanel
extends VBoxContainer

# Reusable height + tier attribute picker with build presets. Embedded by both the
# free-play PlayerSettingsPopup and the lobby's build editor so the two never
# diverge. Owns a WORKING COPY of the player's presets (deep-copied from
# PlayerPrefs on snapshot()) and edits it in place; the host commits or reverts:
#
#   host.open()   -> panel.set_locked(...); panel.snapshot()
#   host.cancel() -> panel.restore()
#   host.apply()  -> if panel.is_dirty(): var attrs := panel.commit()
#
# The panel emits `changed` on every edit so the host can refresh its Apply
# button; the host gates Apply on panel.is_dirty() and panel.is_valid().
#
# A build is a free HEIGHT (5'8"..6'7") plus three TIERS (Skating / Skill /
# Checking, weak/avg/strong). A LEGAL build spends exactly one strength and one
# weakness (or all-average) — see PlayerAttributes.is_legal_build. Invariant kept
# by the UI: you can't LEAVE a preset (switch chips / add a new one) unless it's
# a legal shape; the one preset that can be mid-edit is the active one. is_valid()
# only demands legality once a build was actually touched, so a name-only edit
# over a pre-existing (migrated) preset isn't blocked.

signal changed

# The three attribute tiers. Height is a separate, always-free dial handled above
# these. The per-preset "levels" array is [height, skating, skill, checking].
const _TIER_LABELS: Array[String] = ["Skating", "Skill", "Checking"]
const _TIER_NAMES: Array[String] = ["Weak", "Average", "Strong"]  # tier 1..3
const _HEIGHT_NAMES: Array[String] = ["5'8\"", "5'10\"", "6'1\"", "6'4\"", "6'7\""]

# Hover tooltips. Headline effects only — height decides the baselines and how
# each tier's payoff lands (small = agility/hands/elusive, big = speed/shot/hits).
const _HEIGHT_TOOLTIP: String = "Frame: reach, mass, and the speed/agility/shot/hands baselines.\nSmall = quicker & shiftier with better hands; big = harder shot & hits."
const _TIER_TOOLTIPS: Array[String] = [
	"Speed, acceleration, and agility. Small frames turn this into\nelite agility; big frames into straight-line speed.",
	"Hands (dangle / carry / backhand) and shot power. Small frames\nlean it into hands; big frames into a harder shot.",
	"Delivering checks and resisting them. Big frames lay bigger hits;\nsmall frames get elusive and hard to knock off the puck.",
]

# Working copy: Array of {"name": String, "levels": Array[int]}: [height, skating,
# skill, checking] — height 1..5, each tier 1..3.
var _working: Array[Dictionary] = []
var _active: int = 0
# Deep copy taken on snapshot(); restore() reverts to it and is_dirty() compares
# against it.
var _snapshot_working: Array[Dictionary] = []
var _snapshot_active: int = 0
var _locked: bool = false

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
var _tier_sliders: Array[HSlider] = []
var _tier_value_labels: Array[Label] = []


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
	_tier_sliders = []
	_tier_value_labels = []
	for tier_idx: int in _TIER_LABELS.size():
		_build_tier_slider_row(tier_idx)


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
	_height_value_label.custom_minimum_size = Vector2(52, 0)
	_height_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_height_value_label.add_theme_font_size_override("font_size", 18)
	_height_value_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	_height_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_height_value_label)


func _build_tier_slider_row(tier_idx: int) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	add_child(row)

	var label := Label.new()
	label.text = _TIER_LABELS[tier_idx]
	label.custom_minimum_size = Vector2(80, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = _TIER_TOOLTIPS[tier_idx]
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = PlayerAttributes.TIER_WEAK
	slider.max_value = PlayerAttributes.TIER_STRONG
	slider.step = 1
	slider.custom_minimum_size = Vector2(200, 36)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.set_value_no_signal(PlayerAttributes.TIER_AVERAGE)
	slider.tooltip_text = _TIER_TOOLTIPS[tier_idx]
	slider.value_changed.connect(_on_tier_changed.bind(tier_idx))
	row.add_child(slider)
	_tier_sliders.append(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(64, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.add_theme_font_size_override("font_size", 18)
	value_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value_label)
	_tier_value_labels.append(value_label)


# ── Host API ─────────────────────────────────────────────────────────────────

# Whether attribute editing is disabled (an active online match locks the build).
func set_locked(locked: bool) -> void:
	_locked = locked
	if not _tier_sliders.is_empty():
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


# Valid to commit: legality is only required once a build was actually touched,
# so a name-only edit over a pre-existing (migrated) preset isn't blocked.
func is_valid() -> bool:
	return not _builds_changed() or _all_legal()


# ── Interaction ──────────────────────────────────────────────────────────────

func _on_height_changed(value: float) -> void:
	if _active < 0 or _active >= _working.size():
		return
	(_working[_active]["levels"] as Array)[0] = int(value)
	_refresh()
	changed.emit()


func _on_tier_changed(value: float, tier_idx: int) -> void:
	if _active < 0 or _active >= _working.size():
		return
	# levels[0] is height; tiers live at levels[1..3].
	(_working[_active]["levels"] as Array)[tier_idx + 1] = int(value)
	_refresh()
	changed.emit()


func _on_chip_pressed(index: int) -> void:
	if index == _active or index < 0 or index >= _working.size():
		return
	if not _can_leave_active():
		_refresh()  # re-assert disabled/active states; the switch is rejected
		return
	_active = index
	_load_active_into_name_field()
	_refresh()
	changed.emit()


func _on_new_pressed() -> void:
	if _working.size() >= PlayerPrefs.MAX_PRESETS or not _can_leave_active() or _locked:
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
	if _tier_sliders.is_empty() or _active < 0 or _active >= _working.size():
		return
	var levels: Array = _working[_active]["levels"]
	_height_slider.set_value_no_signal(levels[0])
	_height_slider.editable = not _locked
	_height_value_label.text = _height_name(int(levels[0]))
	for i: int in _tier_sliders.size():
		_tier_sliders[i].set_value_no_signal(levels[i + 1])
		_tier_sliders[i].editable = not _locked
		_tier_value_labels[i].text = _TIER_NAMES[clampi(int(levels[i + 1]) - 1, 0, 2)]

	var legal: bool = _levels_legal(levels)
	_status_label.text = _shape_status(levels)
	_status_label.add_theme_color_override("font_color",
			MenuStyle.TEXT_BODY if legal else MenuStyle.DANGER)

	_lock_label.visible = _locked
	_name_field.editable = not _locked
	_new_btn.disabled = _locked or _working.size() >= PlayerPrefs.MAX_PRESETS or not _can_leave_active()
	_delete_btn.disabled = _locked or _working.size() <= 1

	var can_leave: bool = _can_leave_active()
	for i: int in _chip_buttons.size():
		MenuStyle.apply_tab_button(_chip_buttons[i], i == _active)
		# Can't jump off an illegal build; the active chip stays clickable.
		_chip_buttons[i].disabled = _locked or (i != _active and not can_leave)


func _load_active_into_name_field() -> void:
	if _active >= 0 and _active < _working.size():
		_name_field.text = String(_working[_active]["name"])


# ── Helpers ──────────────────────────────────────────────────────────────────

func _read_prefs_working() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Dictionary in PlayerPrefs.get_presets():
		var a: PlayerAttributes = p["attrs"]
		var levels: Array[int] = [a.height, a.skating, a.skill, a.checking]
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


# levels = [height, skating, skill, checking].
func _levels_legal(levels: Array) -> bool:
	if levels.size() < 4:
		return false
	return PlayerAttributes.is_legal_build(
			int(levels[0]), int(levels[1]), int(levels[2]), int(levels[3]))


# Human-readable status for the active build's shape.
func _shape_status(levels: Array) -> String:
	var strong: int = 0
	var weak: int = 0
	for i: int in [1, 2, 3]:
		if int(levels[i]) == PlayerAttributes.TIER_STRONG:
			strong += 1
		elif int(levels[i]) == PlayerAttributes.TIER_WEAK:
			weak += 1
	if strong > weak:
		return "Each strength needs a weakness"
	if strong == 0 and weak == 0:
		return "All-average ✓"
	return "1 strength, 1 weakness ✓" if strong == 1 else "Legal ✓"


func _can_leave_active() -> bool:
	return _levels_legal(_working[_active]["levels"])


func _all_legal() -> bool:
	for e: Dictionary in _working:
		if not _levels_legal(e["levels"]):
			return false
	return true


# Whether any build's LEVELS differ from the snapshot (names/active ignored).
func _builds_changed() -> bool:
	if _working.size() != _snapshot_working.size():
		return true
	for i: int in _working.size():
		if not _levels_equal(_working[i]["levels"], _snapshot_working[i]["levels"]):
			return true
	return false


func _levels_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		if int(a[i]) != int(b[i]):
			return false
	return true


func _height_name(level: int) -> String:
	return _HEIGHT_NAMES[clampi(level - PlayerAttributes.HEIGHT_MIN, 0, _HEIGHT_NAMES.size() - 1)]


func _default_preset_name() -> String:
	return "Build %d" % (_working.size() + 1)


func _display_name(raw_name: String) -> String:
	var trimmed: String = raw_name.strip_edges()
	return trimmed if not trimmed.is_empty() else "(unnamed)"
