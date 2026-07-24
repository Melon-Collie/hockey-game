class_name ControllerGlyphs

# Button iconography for on-screen hints. Text-badge glyphs — a small bordered
# "chip" holding the button label (A / LB / L3 / ↑ …) — so no glyph-font or texture
# assets are required and the look matches the existing ESC key hint.
#
# Brand-aware: the label set follows the connected pad so a face button reads "A"
# on Xbox, "✕" on PlayStation, "B" on a Switch pad, etc. SDL/Godot's JOY_BUTTON_*
# constants are POSITIONAL (JOY_BUTTON_A is always the SOUTH button), so the tables
# below re-label the same position per brand — including Nintendo's mirrored A/B
# and X/Y. Xbox is the default (also correct for Steam Deck + generic X-input).
#
# Uses:
#   * chip(text)          — build a hint chip for any label (a key or a pad glyph).
#   * prompt(kbd, pad)    — pick the label for the ACTIVE device (pad in controller
#                           mode, else keyboard).
#   * joy_label(button)   — brand-aware label for a JoyButton.
#   * trigger_label(right)— brand-aware analog-trigger label (RT / R2 / ZR …).

enum Brand { XBOX, PLAYSTATION, NINTENDO }

# Xbox-convention labels (also correct for Steam Deck + generic X-input). The
# default when the pad brand is unknown.
const _XBOX_LABELS: Dictionary = {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_START: "≡", JOY_BUTTON_BACK: "⧉",
	JOY_BUTTON_DPAD_UP: "↑", JOY_BUTTON_DPAD_DOWN: "↓",
	JOY_BUTTON_DPAD_LEFT: "←", JOY_BUTTON_DPAD_RIGHT: "→",
}
# PlayStation: the face buttons are shapes (JOY_BUTTON_A = the south button =
# Cross), the shoulders are L1/R1, and Options/Share keep the abstract ≡/⧉ marks.
const _PS_LABELS: Dictionary = {
	JOY_BUTTON_A: "✕", JOY_BUTTON_B: "○", JOY_BUTTON_X: "□", JOY_BUTTON_Y: "△",
	JOY_BUTTON_LEFT_SHOULDER: "L1", JOY_BUTTON_RIGHT_SHOULDER: "R1",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_START: "≡", JOY_BUTTON_BACK: "⧉",
	JOY_BUTTON_DPAD_UP: "↑", JOY_BUTTON_DPAD_DOWN: "↓",
	JOY_BUTTON_DPAD_LEFT: "←", JOY_BUTTON_DPAD_RIGHT: "→",
}
# Nintendo: the positional constants map onto Nintendo's MIRRORED layout, so the
# south button (JOY_BUTTON_A) is physically "B", east is "A", west is "Y", north
# is "X". Shoulders are L/R, and Start/Back are the Plus/Minus glyphs.
const _SWITCH_LABELS: Dictionary = {
	JOY_BUTTON_A: "B", JOY_BUTTON_B: "A", JOY_BUTTON_X: "Y", JOY_BUTTON_Y: "X",
	JOY_BUTTON_LEFT_SHOULDER: "L", JOY_BUTTON_RIGHT_SHOULDER: "R",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_START: "+", JOY_BUTTON_BACK: "−",
	JOY_BUTTON_DPAD_UP: "↑", JOY_BUTTON_DPAD_DOWN: "↓",
	JOY_BUTTON_DPAD_LEFT: "←", JOY_BUTTON_DPAD_RIGHT: "→",
}


# Classify a pad by its reported name (Input.get_joy_name). Pure + case-insensitive
# substring match so it's unit-testable; unknown pads fall back to Xbox (the widest
# correct default — X-input pads and the Steam Deck both use the ABXY layout).
static func brand_for_name(joy_name: String) -> int:
	var n: String = joy_name.to_lower()
	if "playstation" in n or "dualsense" in n or "dualshock" in n \
			or "ps3" in n or "ps4" in n or "ps5" in n or "sony" in n:
		return Brand.PLAYSTATION
	if "nintendo" in n or "switch" in n or "joy-con" in n or "joycon" in n or "joy con" in n:
		return Brand.NINTENDO
	return Brand.XBOX


# The brand of the first connected pad (matching LocalInputGatherer's device pick),
# or Xbox when none is connected. Read at label-build time; hot-swapping brands
# mid-session relabels on the next hint rebuild, same as the gamepad-mode reads.
static func active_brand() -> int:
	var pads: Array = Input.get_connected_joypads()
	if pads.is_empty():
		return Brand.XBOX
	return brand_for_name(Input.get_joy_name(int(pads[0])))


static func _labels_for(brand: int) -> Dictionary:
	match brand:
		Brand.PLAYSTATION:
			return _PS_LABELS
		Brand.NINTENDO:
			return _SWITCH_LABELS
		_:
			return _XBOX_LABELS


# Brand-aware label for a JoyButton (falls back to "?" for an unmapped button).
static func joy_label(button: int) -> String:
	return _labels_for(active_brand()).get(button, "?")


# Brand-aware analog-trigger label. Triggers aren't JoyButtons, so they're named
# here: RT/LT on Xbox, R2/L2 on PlayStation, ZR/ZL on Nintendo.
static func trigger_label(right: bool) -> String:
	match active_brand():
		Brand.PLAYSTATION:
			return "R2" if right else "L2"
		Brand.NINTENDO:
			return "ZR" if right else "ZL"
		_:
			return "RT" if right else "LT"


# The label to show for a prompt, resolved to the ACTIVE device (last-input-wins,
# via InputDeviceTracker): the pad glyph while the pad is driving, else the
# keyboard/mouse label. This is the transient "who's driving now" — distinct from
# ControllerNav.active()'s "gamepad allowed" (which gates build-time menu focus).
# A prompt that persists on screen should rebuild on InputDeviceTracker.device_changed
# so it follows a mid-session device swap; a one-shot (a toast) just reflects the
# device at the moment it was shown.
static func prompt(keyboard_label: String, pad_label: String) -> String:
	return pad_label if InputDeviceTracker.is_gamepad_active() else keyboard_label


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
