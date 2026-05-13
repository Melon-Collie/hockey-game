@tool
extends EditorScript

# Run this script (File → Run, Ctrl+Shift+X) to (re)generate Resources/MenuTheme.tres
# from the MenuStyle palette. After running, set the resource as the project's
# default theme: Project Settings → General → GUI → Theme → Custom.

const _OUT_PATH: String = "res://Resources/MenuTheme.tres"


func _run() -> void:
	var theme: Theme = _build_theme()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://Resources"))
	var err: int = ResourceSaver.save(theme, _OUT_PATH)
	if err != OK:
		push_error("Failed to save theme: %d" % err)
		return
	print("Wrote ", _OUT_PATH)
	print("Now set Project Settings → General → GUI → Theme → Custom = ", _OUT_PATH)


func _build_theme() -> Theme:
	var theme := Theme.new()
	_apply_button_type(theme, "Button")
	_apply_button_type(theme, "OptionButton")
	_apply_primary_button_variation(theme)
	_apply_tertiary_button_variation(theme)
	_apply_line_edit(theme)
	_apply_h_slider(theme)
	_apply_check_button(theme)
	_apply_panel_container(theme)
	_apply_popup_menu(theme)
	_apply_scroll_bar(theme, "VScrollBar")
	_apply_scroll_bar(theme, "HScrollBar")
	_apply_tab_inactive_variation(theme)
	_apply_tab_active_variation(theme)
	return theme


# ── Type entries ─────────────────────────────────────────────────────────────

# Default Button = ghost / secondary style. Transparent fill, teal-line border,
# brighter teal-glow on hover. Primary CTAs opt in to &"ButtonPrimary" instead.
func _apply_button_type(theme: Theme, type: String) -> void:
	theme.set_color("font_color",          type, MenuStyle.TEXT_BODY)
	theme.set_color("font_hover_color",    type, MenuStyle.TEAL_HOVER)
	theme.set_color("font_pressed_color",  type, MenuStyle.TEAL_HOVER)
	theme.set_color("font_disabled_color", type, MenuStyle.TEXT_MUTED)
	theme.set_stylebox("normal",   type, _btn_box(Color(0, 0, 0, 0),   MenuStyle.TEAL_DIM,   1))
	theme.set_stylebox("hover",    type, _btn_box(MenuStyle.TEAL_GLOW, MenuStyle.TEAL,       1))
	theme.set_stylebox("pressed",  type, _btn_box(MenuStyle.TEAL_GLOW, MenuStyle.TEAL_HOVER, 1))
	theme.set_stylebox("focus",    type, _btn_box(MenuStyle.TEAL_GLOW, MenuStyle.TEAL,       1))
	theme.set_stylebox("disabled", type, _btn_box(
		Color(0, 0, 0, 0),
		Color(MenuStyle.TEAL_DIM.r, MenuStyle.TEAL_DIM.g, MenuStyle.TEAL_DIM.b, 0.12),
		1))


# Primary CTA — solid teal fill, dark text. One per screen. Opt-in via
# btn.theme_type_variation = &"ButtonPrimary".
func _apply_primary_button_variation(theme: Theme) -> void:
	const TYPE: StringName = &"ButtonPrimary"
	theme.set_type_variation(TYPE, &"Button")
	theme.set_color("font_color",          TYPE, MenuStyle.ON_TEAL)
	theme.set_color("font_hover_color",    TYPE, MenuStyle.ON_TEAL)
	theme.set_color("font_pressed_color",  TYPE, MenuStyle.ON_TEAL)
	theme.set_color("font_disabled_color", TYPE, MenuStyle.TEXT_MUTED)
	theme.set_stylebox("normal",   TYPE, _btn_box(MenuStyle.TEAL,       MenuStyle.TEAL,       0))
	theme.set_stylebox("hover",    TYPE, _btn_box(MenuStyle.TEAL_HOVER, MenuStyle.TEAL_HOVER, 0))
	theme.set_stylebox("pressed",  TYPE, _btn_box(MenuStyle.TEAL,       MenuStyle.TEAL,       0))
	theme.set_stylebox("focus",    TYPE, _btn_box(MenuStyle.TEAL_HOVER, MenuStyle.TEAL_HOVER, 0))


# Tertiary — text-only quiet link. Exit Game, "skip" actions, etc. Hover goes
# to DANGER red for destructive actions. Caller can swap font_hover_color to
# something less alarming for non-destructive tertiary uses.
func _apply_tertiary_button_variation(theme: Theme) -> void:
	const TYPE: StringName = &"ButtonTertiary"
	theme.set_type_variation(TYPE, &"Button")
	theme.set_color("font_color",          TYPE, MenuStyle.TEXT_MUTED)
	theme.set_color("font_hover_color",    TYPE, MenuStyle.DANGER)
	theme.set_color("font_pressed_color",  TYPE, MenuStyle.DANGER)
	theme.set_color("font_disabled_color", TYPE, MenuStyle.TEXT_MUTED)
	var empty := StyleBoxEmpty.new()
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus", &"disabled"]:
		theme.set_stylebox(state, TYPE, empty)


func _apply_line_edit(theme: Theme) -> void:
	const TYPE: String = "LineEdit"
	theme.set_color("font_color",             TYPE, MenuStyle.TEXT_BODY)
	theme.set_color("font_placeholder_color", TYPE, MenuStyle.TEXT_DIM)
	theme.set_color("caret_color",            TYPE, MenuStyle.TEAL)
	theme.set_color("selection_color",        TYPE,
		Color(MenuStyle.TEAL.r, MenuStyle.TEAL.g, MenuStyle.TEAL.b, 0.35))
	theme.set_stylebox("normal",    TYPE, _btn_box(MenuStyle.BTN_FILL, MenuStyle.TEAL_DIM,   1))
	theme.set_stylebox("focus",     TYPE, _btn_box(MenuStyle.BTN_FILL, MenuStyle.TEAL_HOVER, 2))
	theme.set_stylebox("read_only", TYPE, _btn_box(MenuStyle.BTN_FILL, MenuStyle.TEAL_DIM,   1))


func _apply_h_slider(theme: Theme) -> void:
	const TYPE: String = "HSlider"
	var track := StyleBoxFlat.new()
	track.bg_color = MenuStyle.BTN_FILL
	track.set_corner_radius_all(3)
	track.border_color = MenuStyle.TEAL_DIM
	track.set_border_width_all(1)
	track.set_content_margin(SIDE_TOP, 3)
	track.set_content_margin(SIDE_BOTTOM, 3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(MenuStyle.TEAL.r, MenuStyle.TEAL.g, MenuStyle.TEAL.b, 0.65)
	fill.set_corner_radius_all(3)
	fill.set_content_margin(SIDE_TOP, 3)
	fill.set_content_margin(SIDE_BOTTOM, 3)
	theme.set_stylebox("slider",                 TYPE, track)
	theme.set_stylebox("grabber_area",           TYPE, fill)
	theme.set_stylebox("grabber_area_highlight", TYPE, fill)
	# Circular grabber knob — a procedural ice-blue dot with a darker rim.
	theme.set_icon("grabber",           TYPE, _circle_icon(16, MenuStyle.TEAL,       MenuStyle.BTN_PRESS))
	theme.set_icon("grabber_highlight", TYPE, _circle_icon(18, MenuStyle.TEAL_HOVER, MenuStyle.BTN_PRESS))
	theme.set_icon("grabber_disabled",  TYPE, _circle_icon(16, MenuStyle.TEXT_DIM,   MenuStyle.BTN_PRESS))


func _apply_check_button(theme: Theme) -> void:
	# CheckButton is a slide-switch — show the native switch icon and label,
	# but don't draw a heavy Button-style box around the whole thing.
	const TYPE: String = "CheckButton"
	theme.set_color("font_color",          TYPE, MenuStyle.TEXT_BODY)
	theme.set_color("font_hover_color",    TYPE, MenuStyle.TEXT_TITLE)
	theme.set_color("font_pressed_color",  TYPE, MenuStyle.TEAL_HOVER)
	theme.set_color("font_disabled_color", TYPE, MenuStyle.TEXT_DIM)
	var empty := StyleBoxEmpty.new()
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus", &"disabled", &"hover_pressed"]:
		theme.set_stylebox(state, TYPE, empty)
	# Procedural slide-switch icons in our ice palette — overrides Godot's
	# default green/grey switches.
	var on_icon: ImageTexture = _slide_switch(true, false)
	var off_icon: ImageTexture = _slide_switch(false, false)
	var on_disabled: ImageTexture = _slide_switch(true, true)
	var off_disabled: ImageTexture = _slide_switch(false, true)
	theme.set_icon("checked",                     TYPE, on_icon)
	theme.set_icon("unchecked",                   TYPE, off_icon)
	theme.set_icon("checked_disabled",            TYPE, on_disabled)
	theme.set_icon("unchecked_disabled",          TYPE, off_disabled)
	theme.set_icon("checked_mirrored",            TYPE, on_icon)
	theme.set_icon("unchecked_mirrored",          TYPE, off_icon)
	theme.set_icon("checked_disabled_mirrored",   TYPE, on_disabled)
	theme.set_icon("unchecked_disabled_mirrored", TYPE, off_disabled)


func _apply_panel_container(theme: Theme) -> void:
	const TYPE: String = "PanelContainer"
	var s := StyleBoxFlat.new()
	s.bg_color = MenuStyle.PANEL_BG
	s.set_corner_radius_all(6)
	s.set_content_margin_all(32)
	s.border_color = MenuStyle.TEAL_DIM
	s.set_border_width_all(1)
	theme.set_stylebox("panel", TYPE, s)


func _apply_popup_menu(theme: Theme) -> void:
	# Styles the dropdown that appears when an OptionButton is opened.
	const TYPE: String = "PopupMenu"
	theme.set_color("font_color",           TYPE, MenuStyle.TEXT_BODY)
	theme.set_color("font_hover_color",     TYPE, MenuStyle.TEAL_HOVER)
	theme.set_color("font_disabled_color",  TYPE, MenuStyle.TEXT_DIM)
	theme.set_color("font_separator_color", TYPE, MenuStyle.TEXT_SEP)
	theme.set_constant("h_separation", TYPE, 8)
	theme.set_constant("v_separation", TYPE, 4)
	var panel := StyleBoxFlat.new()
	panel.bg_color = MenuStyle.PANEL_BG
	panel.set_corner_radius_all(4)
	panel.border_color = MenuStyle.TEAL_DIM
	panel.set_border_width_all(1)
	panel.set_content_margin_all(6)
	theme.set_stylebox("panel", TYPE, panel)
	var hover := StyleBoxFlat.new()
	hover.bg_color = MenuStyle.BTN_HOVER
	hover.set_corner_radius_all(3)
	hover.set_content_margin(SIDE_LEFT,  6)
	hover.set_content_margin(SIDE_RIGHT, 6)
	theme.set_stylebox("hover", TYPE, hover)
	var sep := StyleBoxFlat.new()
	sep.bg_color = MenuStyle.TEXT_SEP
	sep.set_content_margin(SIDE_TOP,    1)
	sep.set_content_margin(SIDE_BOTTOM, 1)
	theme.set_stylebox("separator", TYPE, sep)
	# Procedural radio + checkbox icons. OptionButton dropdown items render
	# as radio-checkable, so radio_checked / radio_unchecked are what shows
	# next to each option; the regular checked / unchecked are styled too in
	# case any future PopupMenu uses them.
	theme.set_icon("radio_checked",            TYPE, _radio_dot(true))
	theme.set_icon("radio_unchecked",          TYPE, _radio_dot(false))
	theme.set_icon("radio_checked_disabled",   TYPE, _radio_dot(true))
	theme.set_icon("radio_unchecked_disabled", TYPE, _radio_dot(false))
	theme.set_icon("checked",                  TYPE, _check_square(true))
	theme.set_icon("unchecked",                TYPE, _check_square(false))
	theme.set_icon("checked_disabled",         TYPE, _check_square(true))
	theme.set_icon("unchecked_disabled",       TYPE, _check_square(false))


# Track + grabber for V/HScrollBar. Used by ScrollContainer in the input
# tab and in the career screen's recent-games list. Slim minimal-chrome style:
# a barely-visible track, a teal-dim pill grabber that brightens on hover.
func _apply_scroll_bar(theme: Theme, type: String) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(MenuStyle.SURFACE_INPUT.r, MenuStyle.SURFACE_INPUT.g,
		MenuStyle.SURFACE_INPUT.b, 0.6)
	track.set_corner_radius_all(4)
	theme.set_stylebox("scroll",       type, track)
	theme.set_stylebox("scroll_focus", type, track)

	var grabber := StyleBoxFlat.new()
	grabber.bg_color = MenuStyle.TEAL_DIM
	grabber.set_corner_radius_all(4)
	grabber.set_content_margin_all(2)
	theme.set_stylebox("grabber", type, grabber)

	var grabber_hover := StyleBoxFlat.new()
	grabber_hover.bg_color = MenuStyle.TEAL
	grabber_hover.set_corner_radius_all(4)
	grabber_hover.set_content_margin_all(2)
	theme.set_stylebox("grabber_highlight", type, grabber_hover)

	var grabber_press := StyleBoxFlat.new()
	grabber_press.bg_color = MenuStyle.TEAL_HOVER
	grabber_press.set_corner_radius_all(4)
	grabber_press.set_content_margin_all(2)
	theme.set_stylebox("grabber_pressed", type, grabber_press)

	# Hide the default decrement/increment arrow buttons — ScrollContainer
	# doesn't show them by default, but Godot's stock icons would still be
	# referenced. Empty 1x1 transparent textures suppress them.
	var empty_icon := _empty_icon()
	for icon_name: String in ["decrement", "decrement_highlight", "decrement_pressed",
			"increment", "increment_highlight", "increment_pressed"]:
		theme.set_icon(icon_name, type, empty_icon)


func _empty_icon() -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)


# ── Type variations ──────────────────────────────────────────────────────────

# Underline tabs — transparent everywhere except a 2px bottom border on the
# active tab. Replaces the old boxy tab variant. Active tab gets brighter text
# + teal underline; inactive is muted, brightens on hover.
func _apply_tab_inactive_variation(theme: Theme) -> void:
	const TYPE: StringName = &"TabButton"
	theme.set_type_variation(TYPE, &"Button")
	theme.set_color("font_color",       TYPE, MenuStyle.TEXT_MUTED)
	theme.set_color("font_hover_color", TYPE, MenuStyle.TEXT_DIM)
	var s := _tab_box(false)
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus"]:
		theme.set_stylebox(state, TYPE, s)


func _apply_tab_active_variation(theme: Theme) -> void:
	const TYPE: StringName = &"TabButtonActive"
	theme.set_type_variation(TYPE, &"Button")
	theme.set_color("font_color",       TYPE, MenuStyle.TEAL_HOVER)
	theme.set_color("font_hover_color", TYPE, MenuStyle.TEAL_HOVER)
	var s := _tab_box(true)
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus"]:
		theme.set_stylebox(state, TYPE, s)


# ── Stylebox / icon factories ────────────────────────────────────────────────

func _btn_box(bg: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(6)
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_content_margin_all(10)
	return s


func _tab_box(active: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.set_corner_radius_all(0)
	s.set_content_margin(SIDE_LEFT,   18)
	s.set_content_margin(SIDE_RIGHT,  18)
	s.set_content_margin(SIDE_TOP,    10)
	s.set_content_margin(SIDE_BOTTOM, 10)
	s.bg_color = Color(0.0, 0.0, 0.0, 0.0)   # transparent — no box for either state
	s.border_color = MenuStyle.TEAL if active else Color(0.0, 0.0, 0.0, 0.0)
	s.set_border_width_all(0)
	if active:
		s.border_width_bottom = 2
	return s


# Antialiased pill-shaped slide switch with a circular knob — overrides
# Godot's default CheckButton icons so the "on" state is ice-blue rather
# than the editor's stock green/grey.
func _slide_switch(on: bool, disabled: bool) -> ImageTexture:
	const W: int = 32
	const H: int = 16
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var track_color: Color
	var border_color: Color
	var knob_color: Color
	if disabled:
		track_color  = Color(MenuStyle.BTN_FILL.r, MenuStyle.BTN_FILL.g, MenuStyle.BTN_FILL.b, 0.40)
		border_color = Color(MenuStyle.TEAL_DIM.r, MenuStyle.TEAL_DIM.g, MenuStyle.TEAL_DIM.b, 0.40)
		knob_color   = Color(MenuStyle.TEXT_DIM.r, MenuStyle.TEXT_DIM.g, MenuStyle.TEXT_DIM.b, 0.7)
	elif on:
		track_color  = Color(MenuStyle.TEAL.r, MenuStyle.TEAL.g, MenuStyle.TEAL.b, 0.85)
		border_color = MenuStyle.TEAL_HOVER
		knob_color   = MenuStyle.TEXT_BODY
	else:
		track_color  = MenuStyle.BTN_FILL
		border_color = MenuStyle.TEAL_DIM
		knob_color   = MenuStyle.TEXT_DIM

	var radius_outer: float = H * 0.5
	var radius_inner: float = radius_outer - 1.5
	var cy: float = H * 0.5 - 0.5
	var center_l := Vector2(radius_outer - 0.5, cy)
	var center_r := Vector2(W - radius_outer - 0.5, cy)

	for y: int in H:
		for x: int in W:
			var pos := Vector2(x, y)
			var d_pill: float
			if pos.x < center_l.x:
				d_pill = pos.distance_to(center_l)
			elif pos.x > center_r.x:
				d_pill = pos.distance_to(center_r)
			else:
				d_pill = absf(pos.y - cy)
			if d_pill < radius_inner - 0.5:
				img.set_pixel(x, y, track_color)
			elif d_pill < radius_inner + 0.5:
				var t: float = clampf(radius_inner + 0.5 - d_pill, 0.0, 1.0)
				img.set_pixel(x, y, border_color.lerp(track_color, t))
			elif d_pill < radius_outer - 0.5:
				img.set_pixel(x, y, border_color)
			elif d_pill < radius_outer + 0.5:
				var t: float = clampf(radius_outer + 0.5 - d_pill, 0.0, 1.0)
				img.set_pixel(x, y, Color(border_color.r, border_color.g, border_color.b, border_color.a * t))

	# Knob — overlay a filled circle on the appropriate side
	var knob_r: float = radius_outer - 2.5
	var knob_center: Vector2 = center_r if on else center_l
	for y: int in H:
		for x: int in W:
			var d: float = Vector2(x, y).distance_to(knob_center)
			if d < knob_r - 0.5:
				img.set_pixel(x, y, knob_color)
			elif d < knob_r + 0.5:
				var t: float = clampf(knob_r + 0.5 - d, 0.0, 1.0)
				var existing: Color = img.get_pixel(x, y)
				img.set_pixel(x, y, existing.lerp(knob_color, t * knob_color.a))
	return ImageTexture.create_from_image(img)


# Hollow ring (filled = false) or ring with a centered dot (filled = true).
# Used for PopupMenu radio_unchecked / radio_checked icons.
func _radio_dot(filled: bool) -> ImageTexture:
	const SIZE: int = 16
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var center := Vector2(SIZE * 0.5 - 0.5, SIZE * 0.5 - 0.5)
	var outer: float = SIZE * 0.5 - 1.0
	var inner: float = outer - 1.5
	var dot: float = outer - 4.0
	var rim: Color = MenuStyle.TEAL if filled else MenuStyle.TEAL_DIM
	for y: int in SIZE:
		for x: int in SIZE:
			var d: float = Vector2(x, y).distance_to(center)
			if d > inner and d <= outer + 0.5:
				var alpha: float = 1.0
				if d > outer - 0.5:
					alpha = clampf(outer + 0.5 - d, 0.0, 1.0)
				elif d < inner + 0.5:
					alpha = clampf(d - inner, 0.0, 1.0)
				img.set_pixel(x, y, Color(rim.r, rim.g, rim.b, rim.a * alpha))
			elif filled and d <= dot + 0.5:
				var alpha: float = 1.0
				if d > dot - 0.5:
					alpha = clampf(dot + 0.5 - d, 0.0, 1.0)
				img.set_pixel(x, y, Color(MenuStyle.TEAL.r, MenuStyle.TEAL.g, MenuStyle.TEAL.b, MenuStyle.TEAL.a * alpha))
	return ImageTexture.create_from_image(img)


# Hollow square (filled = false) or filled square with a check tick
# (filled = true). Used for PopupMenu checked / unchecked icons.
func _check_square(filled: bool) -> ImageTexture:
	const SIZE: int = 16
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rim: Color = MenuStyle.TEAL if filled else MenuStyle.TEAL_DIM
	const PAD: int = 1
	const T: int = 1   # rim thickness
	for y: int in SIZE:
		for x: int in SIZE:
			if x < PAD or x >= SIZE - PAD or y < PAD or y >= SIZE - PAD:
				continue
			var on_rim: bool = (x < PAD + T or x >= SIZE - PAD - T
				or y < PAD + T or y >= SIZE - PAD - T)
			if on_rim:
				img.set_pixel(x, y, rim)
			elif filled:
				img.set_pixel(x, y, Color(MenuStyle.TEAL.r, MenuStyle.TEAL.g, MenuStyle.TEAL.b, 0.40))
	if filled:
		# Diagonal check tick
		const TICK_PTS: Array[Vector2i] = [
			Vector2i(4, 8), Vector2i(5, 9), Vector2i(6, 10), Vector2i(7, 9),
			Vector2i(8, 8), Vector2i(9, 7), Vector2i(10, 6), Vector2i(11, 5),
		]
		for p: Vector2i in TICK_PTS:
			img.set_pixel(p.x, p.y, MenuStyle.TEXT_BODY)
			img.set_pixel(p.x, p.y + 1, MenuStyle.TEXT_BODY)
	return ImageTexture.create_from_image(img)


# Antialiased filled circle with a 1-pixel rim — used for slider grabbers.
func _circle_icon(diameter: int, fill: Color, rim: Color) -> ImageTexture:
	var img := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var center := Vector2(diameter * 0.5 - 0.5, diameter * 0.5 - 0.5)
	var outer: float = diameter * 0.5
	var inner: float = outer - 1.5
	for y: int in diameter:
		for x: int in diameter:
			var d: float = Vector2(x, y).distance_to(center)
			if d <= inner - 0.5:
				img.set_pixel(x, y, fill)
			elif d <= inner + 0.5:
				var t: float = clampf(inner + 0.5 - d, 0.0, 1.0)
				img.set_pixel(x, y, fill.lerp(rim, 1.0 - t))
			elif d <= outer - 0.5:
				img.set_pixel(x, y, rim)
			elif d <= outer:
				var t: float = clampf(outer - d, 0.0, 1.0)
				img.set_pixel(x, y, Color(rim.r, rim.g, rim.b, rim.a * t))
	return ImageTexture.create_from_image(img)
