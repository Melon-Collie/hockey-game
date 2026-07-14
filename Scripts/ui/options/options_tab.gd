class_name OptionsTab
extends VBoxContainer

# Base class for a single tab of the Options panel. Each subclass owns only its
# own controls and its own slice of the settings dict; the parent OptionsPanel
# merges every tab's read_controls() into one dictionary and drives Apply /
# Cancel / Defaults across all of them.
#
# Lifecycle: the parent instantiates the tab, calls build() to populate it, wraps
# it in a scroll viewport, and connects `changed`. Control handlers must call
# _notify_changed() (never poke the parent directly) so the parent can recompute
# the Apply-enabled state.
#
# Subclasses override _build_content / read_controls / apply_values, and
# is_valid() when the tab can be in an un-appliable state (e.g. a binding
# conflict).

signal changed

const _WHITE  := MenuStyle.TEXT_BODY
const _DIM    := MenuStyle.TEXT_DIM
const _MUTED  := MenuStyle.TEXT_MUTED
const _SEP    := MenuStyle.TEXT_SEP

# Two-column row layout shared by every tab so labels and controls line up
# vertically across rows and between tabs.
const _LABEL_COL_WIDTH := 180
const _LABEL_FONT_SIZE := 17
const _VALUE_FONT_SIZE := 14
const _SECTION_FONT_SIZE := 11
const _VALUE_COL_WIDTH := 56

# Builds the tab's content. Sets the shared box layout, then defers to the
# subclass's _build_content(). Called by the parent before the tab is added to
# the tree.
func build() -> void:
	add_theme_constant_override("separation", 10)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_content()

# --- Subclass seam -----------------------------------------------------------

# Populate `self` (a VBoxContainer) with rows. Override.
func _build_content() -> void:
	pass

# This tab's slice of the settings dict (keys must be disjoint across tabs and
# their union must equal OptionsPanel._snapshot()'s keys). Override.
func read_controls() -> Dictionary:
	return {}

# Push a values dict (shaped like read_controls / OptionsPanel._snapshot) back
# into this tab's controls. Reads only its own keys. Override.
func apply_values(_v: Dictionary) -> void:
	pass

# Whether this tab is in an appliable state. Override when a tab can hold an
# invalid selection (e.g. conflicting key bindings).
func is_valid() -> bool:
	return true

# Control handlers call this instead of touching the parent; the parent listens
# on `changed` and recomputes the Apply-enabled state.
func _notify_changed() -> void:
	changed.emit()

# --- Shared row/layout helpers ----------------------------------------------

# Small-caps muted heading used to group rows into named sections.
func _section_header(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", _SECTION_FONT_SIZE)
	l.add_theme_color_override("font_color", _MUTED)
	return l

# Vertical breathing room above a non-first section header.
func _section_spacer() -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, 8)
	return s

# Standard label + control row. Label sits in a fixed-width column on the left so
# controls line up across every row in the tab.
func _field_row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 14)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(_LABEL_COL_WIDTH, 0)
	lbl.add_theme_font_size_override("font_size", _LABEL_FONT_SIZE)
	lbl.add_theme_color_override("font_color", _WHITE)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)
	row.add_child(control)
	return row

# Label + slider that fills + fixed-width value label on the right. Slider is set
# to expand horizontally so its width tracks the row width.
func _slider_row(label_text: String, slider: HSlider, value_control: Control) -> HBoxContainer:
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var pair := HBoxContainer.new()
	pair.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pair.add_theme_constant_override("separation", 12)
	pair.add_child(slider)
	pair.add_child(value_control)

	return _field_row(label_text, pair)

# Right-aligned dim numeric value label shown to the right of a slider.
func _value_label(text: String, min_width: int = _VALUE_COL_WIDTH) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(min_width, 0)
	l.add_theme_font_size_override("font_size", _VALUE_FONT_SIZE)
	l.add_theme_color_override("font_color", _DIM)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l

# Wide action button (used by the Customization export rows).
func _make_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(308, 48)
	btn.add_theme_font_size_override("font_size", 20)
	SoundManager.wire_button(btn)
	return btn
