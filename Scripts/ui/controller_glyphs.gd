class_name ControllerGlyphs

# Button iconography for on-screen hints. Text-badge glyphs — a small bordered
# "chip" holding the button label (A / LB / L3 / ↑ …) — so no glyph-font or texture
# assets are required and the look matches the existing ESC key hint. The face /
# shoulder / stick labels are plain ASCII (always render); the D-pad uses arrows.
#
# Two uses:
#   * chip(text)         — build a hint chip for any label (a key or a pad glyph).
#   * prompt(kbd, pad)   — pick the label for the ACTIVE device (pad in controller
#                          mode, else keyboard), so a "Close" hint reads "B" on a
#                          pad and "ESC" on a keyboard from one call.

const _JOY_LABELS: Dictionary = {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_START: "≡", JOY_BUTTON_BACK: "⧉",
	JOY_BUTTON_DPAD_UP: "↑", JOY_BUTTON_DPAD_DOWN: "↓",
	JOY_BUTTON_DPAD_LEFT: "←", JOY_BUTTON_DPAD_RIGHT: "→",
}


# Short label for a JoyButton (falls back to "?" for an unmapped button).
static func joy_label(button: int) -> String:
	return _JOY_LABELS.get(button, "?")


# The label to show for a prompt, resolved to the active device: the pad glyph in
# controller mode, else the keyboard/mouse label.
static func prompt(keyboard_label: String, pad_label: String) -> String:
	return pad_label if ControllerNav.active() else keyboard_label


# A hint chip: a bordered, rounded pill holding `text`, matching the ESC key hint.
# `font_size` and colors default to the small muted hint look.
static func chip(text: String, font_size: int = 10) -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = MenuStyle.TEXT_SEP
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.set_content_margin(SIDE_LEFT, 6)
	style.set_content_margin(SIDE_RIGHT, 6)
	style.set_content_margin(SIDE_TOP, 2)
	style.set_content_margin(SIDE_BOTTOM, 2)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	panel.add_child(label)
	return panel
