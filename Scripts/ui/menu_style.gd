class_name MenuStyle

# Visual styling lives in Resources/MenuTheme.tres (set as the project default
# theme in Project Settings → GUI → Theme → Custom). Regenerate the resource
# from this palette by running tools/build_menu_theme.gd in the editor.
#
# What stays here:
#   - Color constants — for ad-hoc Label / ColorRect / overlay tinting that the
#     theme system can't express on a per-instance basis.
#   - panel(corner, margin) — for PanelContainers that need non-default sizing
#     (popups with extra padding, narrow cards, etc.). Default-sized panels are
#     covered by the theme's PanelContainer entry.
#   - close_button() — full control factory; the × button is a custom widget,
#     not just a styled Button.
#   - apply_tab_button() — flips between &"TabButton" and &"TabButtonActive"
#     theme variations.

# ── Palette ───────────────────────────────────────────────────────────────────

# Ice-blue accent family
const ICE         := Color(0.60, 0.82, 1.00, 1.00)
const ICE_MID     := Color(0.40, 0.62, 0.85, 0.80)
const ICE_DIM     := Color(0.35, 0.55, 0.78, 0.55)
const ICE_HOVER   := Color(0.62, 0.84, 1.00, 0.95)

# Text
const TEXT_TITLE  := Color(0.88, 0.95, 1.00, 1.00)
const TEXT_BODY   := Color(1.00, 1.00, 1.00, 1.00)
const TEXT_DIM    := Color(0.55, 0.62, 0.72, 1.00)
const TEXT_SEP    := Color(0.28, 0.32, 0.45, 1.00)

# Surfaces
const PANEL_BG    := Color(0.10, 0.10, 0.14, 0.88)
const HUD_BG      := Color(0.07, 0.07, 0.09, 0.92)

# Button fill states (referenced by ad-hoc styleboxes outside the theme system)
const BTN_FILL    := Color(0.10, 0.14, 0.22, 0.80)
const BTN_HOVER   := Color(0.14, 0.20, 0.34, 0.92)
const BTN_PRESS   := Color(0.07, 0.10, 0.18, 1.00)

# Non-blue accents
const GOLD        := Color(1.00, 0.85, 0.20, 1.00)


# ── HUD ice-overlay (3D-on-ice elements: rings, glyphs, reticles) ─────────────
# Shared by every element drawn flat on the ice under a skater. All three
# values are referenced by Skater for procedural mesh construction; tweak here
# rather than per-element.
# Slate grey-blue reads against bright white ice without glare washout, where
# the previous ICE blue washed out under overhead arena lights.
const HUD_SLATE      := Color(0.22, 0.30, 0.42, 1.00)
const HUD_ICE        := HUD_SLATE          # primary stroke color for all on-ice HUD
const HUD_OPACITY    := 0.85               # darker color reads better at higher opacity
const HUD_LINE_THIN  := 0.03               # "thin line" thickness in 3D meters (slot ring, reticle, arrow)
const HUD_LINE_THICK := 0.045              # heavier stroke for symbols (arrow, chevron)

# Charge-ring fill colors. Lerps from CHARGE_LOW → CHARGE_HIGH across the fill;
# CHARGE_FULL pulses at 100%; CHARGE_LOST flashes briefly when charge is
# cancelled without firing (e.g. puck stripped during wrister aim).
const CHARGE_LOW    := Color(1.00, 0.85, 0.20, 1.00)   # yellow
const CHARGE_HIGH   := Color(1.00, 0.50, 0.10, 1.00)   # orange
const CHARGE_FULL   := Color(1.00, 0.20, 0.20, 1.00)   # red pulse at full
const CHARGE_LOST   := Color(1.00, 0.20, 0.20, 1.00)   # red flash on cancel


# ── Factories ─────────────────────────────────────────────────────────────────

# Build a panel stylebox at custom dimensions. PanelContainers that don't call
# this just inherit the default panel from the project theme.
static func panel(corner: int = 6, margin: int = 32) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL_BG
	s.set_corner_radius_all(corner)
	s.set_content_margin_all(margin)
	s.border_color = ICE_DIM
	s.set_border_width_all(1)
	return s


# Custom × close button — a full control factory, not just styling.
static func close_button() -> Button:
	var btn := Button.new()
	btn.text = "×"
	btn.flat = true
	btn.custom_minimum_size = Vector2(30, 30)
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_color_override("font_color",         TEXT_DIM)
	btn.add_theme_color_override("font_hover_color",   TEXT_BODY)
	btn.add_theme_color_override("font_pressed_color", ICE)
	var empty := StyleBoxEmpty.new()
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(BTN_HOVER.r, BTN_HOVER.g, BTN_HOVER.b, 0.65)
	hover.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("normal",  empty)
	btn.add_theme_stylebox_override("hover",   hover)
	btn.add_theme_stylebox_override("pressed", hover)
	btn.add_theme_stylebox_override("focus",   empty)
	return btn


# Flip a tab button between active and inactive theme variations.
static func apply_tab_button(btn: Button, active: bool) -> void:
	btn.theme_type_variation = &"TabButtonActive" if active else &"TabButton"


# Wire hover/press scale animation on a button. The pivot tracks the button's
# size so the scale stays centered when the layout resizes after _ready.
static func wire_hover_scale(btn: Button) -> void:
	btn.item_rect_changed.connect(func() -> void: btn.pivot_offset = btn.size / 2.0)
	btn.mouse_entered.connect(func() -> void: _scale_btn(btn, Vector2(1.04, 1.04)))
	btn.mouse_exited.connect(func() -> void: _scale_btn(btn, Vector2.ONE))
	btn.button_down.connect(func() -> void: _scale_btn(btn, Vector2(0.97, 0.97)))
	btn.button_up.connect(func() -> void: _scale_btn(btn, Vector2(1.04, 1.04)))


static func _scale_btn(btn: Button, target: Vector2) -> void:
	var t := btn.create_tween()
	t.tween_property(btn, "scale", target, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# Standard popup-row button: 220×48, font 20, hover-scale tween, click sound.
static func popup_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(220, 48)
	btn.add_theme_font_size_override("font_size", 20)
	wire_hover_scale(btn)
	SoundManager.wire_button(btn)
	return btn


# Build an OptionButton populated with every team color preset, with one
# selected by id. Caller wires SoundManager if desired.
static func color_option_btn(selected_id: String, min_size: Vector2, font_size: int) -> OptionButton:
	var btn := OptionButton.new()
	btn.custom_minimum_size = min_size
	btn.add_theme_font_size_override("font_size", font_size)
	var ids: Array[String] = TeamColorRegistry.get_all_ids()
	for i: int in ids.size():
		btn.add_item(TeamColorRegistry.get_preset_name(ids[i]), i)
		if ids[i] == selected_id:
			btn.select(i)
	return btn
