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

# Primary brand accent — sampled from the Mitts logo's skater silhouette
# highlights (#C0D8E0). Used as the primary CTA fill and key accents.
const TEAL        := Color(0.753, 0.847, 0.878, 1.00)
# Brighter highlight-tip variant (#DCEEF2) — primary-button hover, accent text.
const TEAL_HOVER  := Color(0.863, 0.933, 0.949, 1.00)
# Low-alpha brand teal — borders, focus rings, separators. Replaces the
# previous grey-teal so borders are on-brand instead of just "dark cool."
const TEAL_DIM    := Color(0.753, 0.847, 0.878, 0.28)
# Very low-alpha brand teal — ghost-button hover fill, hover-glow surfaces.
const TEAL_GLOW   := Color(0.753, 0.847, 0.878, 0.14)

# Text — three weights, all on dark surfaces
const TEXT_TITLE  := Color(0.941, 0.965, 0.984, 1.00)  # near-white, for h1/titles
const TEXT_BODY   := Color(0.941, 0.965, 0.984, 1.00)
const TEXT_DIM    := Color(0.659, 0.710, 0.780, 1.00)  # cool grey, secondary
const TEXT_MUTED  := Color(0.369, 0.420, 0.490, 1.00)  # quiet, tertiary
const TEXT_SEP    := Color(0.18, 0.22, 0.28, 1.00)     # 1px divider lines

# Dark text used *on* teal fill — primary button label.
const ON_TEAL     := Color(0.055, 0.086, 0.125, 1.00)

# Surfaces — solid (alpha 1.0). Same value renders consistently against the
# ice background and against the popup scrim, which is the point.
const PANEL_BG    := Color(0.067, 0.094, 0.141, 1.00)  # #111824 — true dark navy
const SURFACE_ELEV := Color(0.102, 0.137, 0.192, 1.00) # #1A2331 — hover/nested
const SURFACE_INPUT := Color(0.039, 0.063, 0.102, 1.00) # #0A101A — input wells
const HUD_BG      := Color(0.07, 0.07, 0.09, 0.92)     # in-game scorebug (unchanged)

# Modal scrim alpha — single source of truth so every popup uses the same dim.
const SCRIM       := Color(0.024, 0.039, 0.071, 0.55)

# Legacy button-state fills — referenced by ad-hoc styleboxes in main_menu.gd's
# player-card hover and a few places that don't go through the theme system.
# The themed Button (= ghost) uses transparent + teal-glow on hover instead.
const BTN_FILL    := Color(0.067, 0.094, 0.141, 0.00)  # ghost: transparent at rest
const BTN_HOVER   := SURFACE_ELEV
const BTN_PRESS   := Color(0.039, 0.063, 0.102, 1.00)

# Warm accent — goals, low-clock, game-over title (never on the main menu).
const GOLD        := Color(1.00, 0.85, 0.20, 1.00)
# Destructive hover — Exit Game tertiary button, etc.
const DANGER      := Color(0.878, 0.471, 0.510, 1.00)


# ── Broadcast HUD (in-game scorebug + popup scoreboard) ──────────────────────
# Modern indie sport HUD palette. The "broadcast" name is historical — we
# dropped the vintage cream tones in favor of pure white + cool-neutral
# gray to match the game's precision-sport character. Tune here to shift
# the whole HUD warmer/cooler/punchier.
#
# Typography is a two-font system, both OFL-licensed:
#   - DISPLAY_FONT (Big Shoulders Display Black) — heavy condensed sans,
#     matches the logo's wordmark. Used for scorebug numbers, headers,
#     player-card identity labels.
#   - UI_FONT (Manrope Regular) — humanist sans, neutral body text.
#     Default font for menu rows, button labels, body copy.
const DISPLAY_FONT       := preload("res://Assets/Fonts/BigShouldersDisplay-Black.ttf")  # SIL OFL 1.1
const UI_FONT            := preload("res://Assets/Fonts/Manrope-Regular.ttf")  # SIL OFL 1.1
# Dark surface for HUD overlays. Now identical to PANEL_BG so the menu and
# scorebug share a single dark background — no visible seam between the two
# surfaces when both are on screen.
const BROADCAST_BG       := Color(0.067, 0.094, 0.141, 1.00)  # #111824, matches PANEL_BG
const BROADCAST_BORDER_T := Color(0.227, 0.227, 0.306, 1.00)  # #3A3A4E top-edge highlight
const BROADCAST_SHADOW   := Color(0.0,   0.0,   0.0,   0.50)  # offset drop shadow (unused; wrap_drop_shadow is now a no-op)
const BROADCAST_CREAM    := Color(1.000, 1.000, 1.000, 1.00)  # #FFFFFF primary text (was cream #F6EFE2)
const BROADCAST_DIM      := Color(0.608, 0.627, 0.675, 1.00)  # #9BA0AC cool-neutral gray labels (was cream-dim #B8B0A0)
const BROADCAST_SEP      := Color(0.165, 0.165, 0.220, 1.00)  # #2A2A38 column separator
const BROADCAST_TITLE_BG := Color(0.102, 0.102, 0.149, 1.00)  # #1A1A26 scoreboard title strip


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

# Default slot-ring tint by the skater's relationship to the LOCAL player, so
# you can re-identify your own skater and read friend-vs-foe at a glance while
# the camera pans. Relationship-relative (not absolute team), so it stays the
# same regardless of which jersey each side wears. Blue-vs-red is
# colorblind-safe; self is green — a third primary that stays clearly apart from
# both the team blue and enemy red (the old cyan sat adjacent to team blue and
# was easy to confuse mid-rush) and stays apart from the amber/red the stamina
# ring uses for its low/locked states. These are only the DEFAULTS now: each is fully
# user-pickable (Options → Game → Ring Colors), and PlayerPrefs.ring_color_*
# holds the live values that SkaterHUDCoordinator reads. The self color also
# drives the overhead self-beacon so the on-ice ring and the floating marker
# share one self color. HUD_ICE remains the neutral fallback (e.g. before the
# local player has spawned, or replay).
const HUD_RING_SELF  := Color(0.20, 0.95, 0.40, 1.00)   # green — your own skater
const HUD_RING_TEAM  := Color(0.25, 0.55, 1.00, 1.00)   # blue — teammates
const HUD_RING_ENEMY := Color(0.95, 0.25, 0.25, 1.00)   # red  — opponents


# ── Factories ─────────────────────────────────────────────────────────────────

# Wrap a PanelContainer in a Control with a hard-edged, CSS-style offset drop
# shadow. Godot's StyleBoxFlat shadow expands the shadow rect uniformly before
# applying offset, which produces a soft-edged halo instead of the crisp
# "spread: 0" behavior we want. This composes two panels: a shadow panel
# (offset, behind, anti-aliasing off) and the original (at origin), with the
# shadow size kept in sync with the original via the resized signal. The
# Drop-shadow helper retained as a pass-through so existing HUD call sites
# don't have to be rewritten. The drop shadow itself was removed in the
# visual harmonization pass — the broadcast surfaces now sit flat against
# the unified dark background, matching the menu's look. If we ever want
# shadows back, restore the body of this function (wrap + shadow_style +
# size sync) from git history.
static func wrap_drop_shadow(main_panel: PanelContainer, _offset: Vector2) -> Control:
	return main_panel


# Cascading theme that sets UI_FONT as the default font for a control and
# all its descendants. Side menu / Boot title card / future menu surfaces
# set this on their root Control so every Label/Button under them picks
# up Manrope without needing per-control font overrides. Per-control size
# overrides still apply on top.
static func ui_theme() -> Theme:
	var t := Theme.new()
	t.default_font = UI_FONT
	return t


# Build a panel stylebox at custom dimensions. PanelContainers that don't call
# this just inherit the default panel from the project theme.
static func panel(corner: int = 6, margin: int = 32) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL_BG
	s.set_corner_radius_all(corner)
	s.set_content_margin_all(margin)
	s.border_color = TEAL_DIM
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
	btn.add_theme_color_override("font_pressed_color", TEAL)
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


# Standard breathing-pulse alpha range and per-direction duration. Anything
# that wants a "waiting / available action" rhythm — splash prompt, skip-replay
# reminder, future affordances — should use MenuStyle.pulse() so the cadence
# stays identical across the game.
const PULSE_LOW_ALPHA: float = 0.45
const PULSE_FADE_DURATION: float = 0.9

# Continuous looping alpha pulse on a CanvasItem's modulate. Returns the tween
# so the caller can kill() it when the pulse should stop (typically on hide).
# Sine ease-in-out gives an organic breathing rhythm rather than a hard sawtooth.
static func pulse(node: CanvasItem) -> Tween:
	node.modulate.a = 1.0
	var t: Tween = node.create_tween().set_loops()
	t.tween_property(node, "modulate:a", PULSE_LOW_ALPHA, PULSE_FADE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(node, "modulate:a", 1.0, PULSE_FADE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return t


# Standard popup-row button: 220×48, font 20, hover-scale tween, click sound.
static func popup_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(220, 48)
	btn.add_theme_font_size_override("font_size", 20)
	wire_hover_scale(btn)
	SoundManager.wire_button(btn)
	return btn
