class_name SlotGridPanel
extends VBoxContainer

# Lobby slot grid. One 3-across forward row per team (AWAY/HOME × LW/C/RW
# columns); in 5v5 each team adds a centered two-card D row behind its
# forwards (above the away row, below the home row). Each card shows:
#
#   ┌──────────────────────────────────┐
#   │ ▶  88  PLAYERNAME              L │   ← action icon (X / +) top-left;
#   │ │                       ●  32ms  │     position letter top-right;
#   └──────────────────────────────────┘     name in middle; ping or AI label
#                                            bottom-right; left stripe in
#                                            the team's UI stripe color.
#
# Cards use the team's canonical UI palette (TeamColorRegistry.get_ui_colors):
# home = primary body + secondary stripe, away = light body + primary stripe.
#
# Card visual semantics:
#   - Empty slot      → dark neutral bg, no stripe color, "+" icon (host).
#   - Bot slot        → team body color bg, stripe, "BOT" badge bottom-right, "X" icon (host).
#   - Remote human    → jersey color bg, stripe, "##ms ●" ping with status dot,
#                       a green "READY" / amber "WAITING" tag in the status row
#                       (lobby only, non-host humans), "X" kick icon (host only,
#                       connected transport peers only).
#   - Your slot       → jersey color bg, stripe, ping, plus a 1px TEAL_DIM
#                       border around the whole card so the local player can
#                       recognize their own slot at a glance.
#
# Clicking the card body emits slot_selected (used by LobbyManager to swap
# into the slot). Clicking the action icon emits bot_toggled (add/remove a
# bot on empty/bot cards) or kick_requested (remote-human cards), both
# host-only. The two click targets are siblings under the card root
# and use mouse_filter STOP, so clicking the icon does NOT propagate to the
# card's swap handler.

signal slot_selected(team_id: int, slot: int)
signal bot_toggled(team_id: int, slot: int, is_bot: bool)
signal kick_requested(peer_id: int, player_name: String)

# Column display order: Left Wing (slot 1), Center (slot 0), Right Wing
# (slot 2) — the familiar 3-across forward row in both modes. 5v5 adds a
# second, centered row of two D cards (slots 3/4) BEHIND each team's
# forwards — above the away row, below the home row, so the whole grid
# reads like a faceoff lineup with each pair backing its own end (3v3
# hides the D rows — see set_active_team_size). Both team rows share the
# physical column layout, but since the away team attacks the opposite
# direction its L/R slots are its own R/L, the mirror image of home's in
# the same columns. The _AWAY label sets reflect that; the slot→column
# layout itself does not change.
const _DISPLAY_ORDER  := [1, 0, 2]
const _D_DISPLAY_ORDER := [3, 4]
const _POSITION_LABEL      := ["C", "L", "R", "LD", "RD"]   # indexed by slot, home
const _POSITION_LABEL_AWAY := ["C", "R", "L", "RD", "LD"]   # indexed by slot, away
# 5v5 badge variants: with LD/RD on the board the wingers spell out LW/RW
# too (3v3 keeps the classic single letters).
const _POSITION_LABEL_5V5      := ["C", "LW", "RW", "LD", "RD"]
const _POSITION_LABEL_AWAY_5V5 := ["C", "RW", "LW", "RD", "LD"]
const _POSITION_HEADER      := ["LEFT WING", "CENTER", "RIGHT WING"]   # indexed by col, home
const _POSITION_HEADER_AWAY := ["RIGHT WING", "CENTER", "LEFT WING"]   # indexed by col, away

const _CARD_HEIGHT: int = 96
const _STRIPE_WIDTH: int = 6
const _ICON_SIZE: int = 20

# Name label font sizing. The name auto-shrinks to fit the card so long names
# (e.g. "SCHROEDER") display in full instead of hard-clipping at the default
# size. _NAME_FONT_SIZE is the preferred size on filled cards, _OPEN the
# (smaller, centered) "OPEN SLOT" placeholder size, and _MIN the floor below
# which we stop shrinking and let clip_text take over as a last resort.
const _NAME_FONT_SIZE: int = 24
const _NAME_FONT_SIZE_OPEN: int = 18
const _NAME_FONT_MIN: int = 14

# Ping color bands (ms).
const _PING_GREEN: int  = 60
const _PING_YELLOW: int = 120
const _COLOR_PING_GOOD := Color(0.36, 0.85, 0.45, 1.0)
const _COLOR_PING_OKAY := Color(0.95, 0.78, 0.22, 1.0)
const _COLOR_PING_BAD  := Color(0.92, 0.40, 0.40, 1.0)

# Ready-status tag colors (green = readied up, amber = still waiting).
const _COLOR_READY   := Color(0.36, 0.85, 0.45, 1.0)
const _COLOR_WAITING := Color(0.95, 0.78, 0.22, 1.0)

# Controller navigation: the cards as a flat focusable list + parallel A-handlers
# (each emits slot_selected for its slot — the primary card click). Rebuilt with
# the grid. See _input / focus_first_card.
var _nav_cards: Array[Control] = []
var _nav_card_handlers: Array[Callable] = []
var _nav_card_coords: Array[Vector2i] = []   # (team, slot) per nav card, for the X action

# Per-slot widget caches. Indexed [team_id][slot].
var _cards:        Array = [[], []]
var _stylebox:     Array = [[], []]   # StyleBoxFlat — recolored per refresh
var _stripe:       Array = [[], []]   # Panel — left edge band, rounded outside / flat inside
var _stripe_style: Array = [[], []]   # StyleBoxFlat backing each stripe (for recolor)
var _num_labels:   Array = [[], []]
var _name_labels:  Array = [[], []]
var _pos_labels:   Array = [[], []]
var _right_cols:   Array = [[], []]   # VBoxContainer holding pos + status
var _status_box:   Array = [[], []]   # HBoxContainer holding ping/AI
var _ping_label:   Array = [[], []]
var _ping_dot:     Array = [[], []]
var _ai_label:     Array = [[], []]
var _ready_label:  Array = [[], []]   # READY / WAITING tag (lobby only, non-host humans)
var _action_btn:   Array = [[], []]   # X / + button (host only, hidden on remote-human)
var _peer_ids:     Array = [[], []]

var _team_colors: Array[Dictionary] = []
var _bot_slots: Dictionary = {}
var _bot_identities: Dictionary = {}
var _is_local_host: bool = false
var _bot_editing: bool = true
var _show_ready: bool = false

# Live lobby mode: how many of the capacity slots are fielded. The grid is
# always built at full capacity; 3v3 hides the two D rows.
var _active_team_size: int = GameRules.DEFAULT_TEAM_SIZE
var _d_rows: Array = [null, null]   # [team_id] — the D-pair HBox, hidden in 3v3
# The LW/C/RW column-header HBoxes, hidden in 5v5 — with four rows of cards
# on screen the headers just wedge awkward gaps between the team blocks,
# and every card already wears its position badge.
var _header_rows: Array = [null, null]


func _init() -> void:
	_build_grid()
	_apply_mode_visibility()


# Show/hide the D rows to match the lobby's selected mode. Called by
# LobbyManager on build and whenever the host flips the Mode row.
func set_active_team_size(team_size: int) -> void:
	_active_team_size = clampi(team_size, 1, PlayerRules.MAX_PER_TEAM)
	_apply_mode_visibility()


func _apply_mode_visibility() -> void:
	var show_d: bool = _active_team_size > PlayerRules.FIRST_DEFENSE_SLOT
	for team_id: int in 2:
		if _d_rows[team_id] != null:
			(_d_rows[team_id] as HBoxContainer).visible = show_d
		if _header_rows[team_id] != null:
			(_header_rows[team_id] as HBoxContainer).visible = not show_d
		# Re-stamp the badges — the L/R ↔ LW/RW wording is mode-dependent.
		for slot: int in _pos_labels[team_id].size():
			if _pos_labels[team_id][slot] != null:
				(_pos_labels[team_id][slot] as Label).text = _position_badge(team_id, slot)


# The card's position badge for the current mode: 3v3 keeps the classic
# single letters (C/L/R); 5v5 spells the wingers out (LW/RW) so they read
# consistently next to LD/RD. Away rows mirror L/R as usual.
func _position_badge(team_id: int, slot: int) -> String:
	var is_5v5: bool = _active_team_size > PlayerRules.FIRST_DEFENSE_SLOT
	if team_id == 1:
		return _POSITION_LABEL_AWAY_5V5[slot] if is_5v5 else _POSITION_LABEL_AWAY[slot]
	return _POSITION_LABEL_5V5[slot] if is_5v5 else _POSITION_LABEL[slot]


func _ready() -> void:
	var t := Timer.new()
	t.wait_time = 2.0
	t.autostart = true
	t.timeout.connect(_refresh_pings)
	add_child(t)


# ── Build ────────────────────────────────────────────────────────────────────

func _build_grid() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nav_cards.clear()
	_nav_card_handlers.clear()
	_nav_card_coords.clear()

	# Away on top (team 1), Home on bottom (team 0) — matches rink perspective,
	# and each team's D pair sits BEHIND its forwards (above for away, below
	# for home), so 5v5 reads like a faceoff lineup backing toward each net.
	# Each team gets its own column header (LW/C/RW vs. the away-mirrored
	# RW/C/LW) since the two teams' true wing labels are swapped in the same
	# physical columns — see the _DISPLAY_ORDER comment above.
	for team_id: int in [1, 0]:
		_cards[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_stylebox[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_stripe[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_stripe_style[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_num_labels[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_name_labels[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_pos_labels[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_right_cols[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_status_box[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_ping_label[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_ping_dot[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_ai_label[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_ready_label[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_action_btn[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_peer_ids[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_peer_ids[team_id].fill(-1)

		if team_id == 1:
			_d_rows[team_id] = _build_d_row(team_id)
			add_child(_d_rows[team_id])
			_build_header(team_id)
			add_child(_build_forward_row(team_id))
		else:
			_build_header(team_id)
			add_child(_build_forward_row(team_id))
			_d_rows[team_id] = _build_d_row(team_id)
			add_child(_d_rows[team_id])


# The familiar 3-across forward row (LW / C / RW), with the AWAY/HOME team
# label on its left edge.
func _build_forward_row(team_id: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var team_label := Label.new()
	team_label.text = "AWAY" if team_id == 1 else "HOME"
	team_label.add_theme_font_size_override("font_size", 13)
	team_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	team_label.custom_minimum_size = Vector2(56, 0)
	team_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(team_label)

	for col: int in _DISPLAY_ORDER.size():
		var s: int = _DISPLAY_ORDER[col]
		row.add_child(_build_card(team_id, s))
	return row


# The 5v5 D pair: two cards centered under (home) / over (away) the forward
# row, sized to match the forward cards. Half-weight stretch spacers on each
# side make every card exactly one column wide (0.5 + 1 + 1 + 0.5 = the same
# 3 flex units the forward row spans), so LD sits under the LW–C seam and RD
# under the C–RW seam — the lineup "behind them" read.
func _build_d_row(team_id: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label_spacer := Control.new()
	label_spacer.custom_minimum_size = Vector2(56, 0)
	row.add_child(label_spacer)

	var lead := Control.new()
	lead.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lead.size_flags_stretch_ratio = 0.5
	row.add_child(lead)
	for s: int in _D_DISPLAY_ORDER:
		row.add_child(_build_card(team_id, s))
	var tail := Control.new()
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tail.size_flags_stretch_ratio = 0.5
	row.add_child(tail)
	return row


# Column header row for one team: AWAY/HOME spacer + LW / C / RW labels (or
# the away-mirrored RW / C / LW), matching that row's card badges.
func _build_header(team_id: int) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(header)
	_header_rows[team_id] = header

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(56, 0)
	header.add_child(spacer)

	var labels: Array = _POSITION_HEADER_AWAY if team_id == 1 else _POSITION_HEADER
	for col: int in _DISPLAY_ORDER.size():
		var lbl := Label.new()
		lbl.text = labels[col]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_child(lbl)


# Build a single slot card. The card root is a PanelContainer whose stylebox
# carries the background color. The jersey-stripe band is a separate
# ColorRect child anchored to the left edge and inset a few pixels from
# the top/bottom so it sits as a hard rectangle inside the rounded card —
# avoiding the concentric-rounded-corners "designed by AI" tell. gui_input
# on the panel handles the click-to-swap; the X/+ action button is a child
# with mouse_filter STOP so its clicks don't bubble to the panel's swap
# handler.
func _build_card(team_id: int, slot: int) -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.PANEL_BG
	style.set_corner_radius_all(4)
	style.set_content_margin_all(12)
	# Pad an extra slice on the left so the inset stripe doesn't collide
	# with the number label.
	style.set_content_margin(SIDE_LEFT, 18)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", style)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size = Vector2(0, _CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(_on_card_input.bind(team_id, slot))
	_cards[team_id][slot] = card
	_stylebox[team_id][slot] = style

	# Card content lives inside a Control so we can absolute-position the
	# action button and the inset stripe on top of the main row.
	var content := Control.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(content)

	# Jersey-stripe band on the card's left edge. A Panel with a
	# StyleBoxFlat — corner_radius matches the card's outer curve on
	# the left side (top-left + bottom-left = 4) and is flat on the
	# right side (top-right + bottom-right = 0) so the inner edge sits
	# clean against the card's primary background. Negative offsets
	# escape the panel's content margin so the stripe extends to the
	# card's actual top, bottom, and left edges. Rounded outside,
	# flat inside.
	var stripe_style := StyleBoxFlat.new()
	stripe_style.bg_color = MenuStyle.TEXT_SEP
	stripe_style.corner_radius_top_left = 4
	stripe_style.corner_radius_bottom_left = 4
	stripe_style.corner_radius_top_right = 0
	stripe_style.corner_radius_bottom_right = 0
	var stripe := Panel.new()
	stripe.add_theme_stylebox_override("panel", stripe_style)
	stripe.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	stripe.offset_left = -18
	stripe.offset_right = -18 + _STRIPE_WIDTH
	stripe.offset_top = -12
	stripe.offset_bottom = 12
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(stripe)
	_stripe[team_id][slot] = stripe
	_stripe_style[team_id][slot] = stripe_style

	var main_row := HBoxContainer.new()
	# Number sits in a fixed-width slot and is centered within it, so the
	# name's left edge lines up across cards regardless of whether the
	# number is one or two digits. Separation between number slot and
	# name is small — the name should feel attached to the number, not
	# columned away from it.
	main_row.add_theme_constant_override("separation", 8)
	main_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(main_row)

	var num := Label.new()
	num.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	num.add_theme_font_size_override("font_size", 50)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.custom_minimum_size = Vector2(56, 0)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_row.add_child(num)
	_num_labels[team_id][slot] = num

	# Name label fills the remaining width to the right of the number. It
	# auto-shrinks to fit (see _fit_name): "fit_base" is the preferred size,
	# re-fit on every layout change via the resized signal so it tracks
	# window resizing. clip_text stays on purely as a last-resort guard for
	# pathologically long names that hit _NAME_FONT_MIN.
	var name_lbl := Label.new()
	name_lbl.add_theme_font_override("font", MenuStyle.NAME_FONT)
	name_lbl.add_theme_font_size_override("font_size", _NAME_FONT_SIZE)
	name_lbl.set_meta("fit_base", _NAME_FONT_SIZE)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.resized.connect(_fit_name.bind(name_lbl))
	main_row.add_child(name_lbl)
	_name_labels[team_id][slot] = name_lbl

	# Right column: position letter pinned to top, status (ping or AI)
	# pinned to bottom. The middle spacer eats any leftover height so the
	# two anchors don't shift up/down with the status visibility — empty
	# slots (status hidden) used to drift the position letter upward
	# because ALIGNMENT_CENTER recentered it.
	var right_col := VBoxContainer.new()
	right_col.alignment = BoxContainer.ALIGNMENT_BEGIN
	right_col.add_theme_constant_override("separation", 0)
	# Reserve only what the position letter / ping ("###ms ●") actually need.
	# This used to be 72, which stranded whitespace next to a single-char
	# position letter and squeezed the name; 56 fits the ping comfortably
	# (~42px) while handing the freed width to the name column.
	right_col.custom_minimum_size = Vector2(56, 0)
	right_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_row.add_child(right_col)
	_right_cols[team_id][slot] = right_col

	var pos_lbl := Label.new()
	pos_lbl.text = _position_badge(team_id, slot)
	pos_lbl.add_theme_font_size_override("font_size", 13)
	pos_lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	pos_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pos_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pos_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right_col.add_child(pos_lbl)
	_pos_labels[team_id][slot] = pos_lbl

	# Spacer pushes the status row to the bottom regardless of whether
	# the status row's contents are visible.
	var col_spacer := Control.new()
	col_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right_col.add_child(col_spacer)

	# Status row carries either the ping ("32ms ●") or the AI badge.
	var status_box := HBoxContainer.new()
	status_box.alignment = BoxContainer.ALIGNMENT_END
	status_box.add_theme_constant_override("separation", 6)
	status_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right_col.add_child(status_box)
	_status_box[team_id][slot] = status_box

	var ping_lbl := Label.new()
	ping_lbl.add_theme_font_size_override("font_size", 11)
	ping_lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	ping_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ping_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_box.add_child(ping_lbl)
	_ping_label[team_id][slot] = ping_lbl

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(6, 6)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_box.add_child(dot)
	_ping_dot[team_id][slot] = dot

	# Ready tag, sitting after the ping ("32ms ● READY"). Color carries the
	# meaning (green ready / amber waiting); default-hidden and only shown for
	# non-host human cards in a lobby (see _update_card).
	var ready_lbl := Label.new()
	ready_lbl.add_theme_font_size_override("font_size", 11)
	ready_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ready_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ready_lbl.visible = false
	status_box.add_child(ready_lbl)
	_ready_label[team_id][slot] = ready_lbl

	var ai_lbl := Label.new()
	ai_lbl.text = "BOT"
	ai_lbl.add_theme_font_size_override("font_size", 11)
	ai_lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	ai_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ai_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ai_lbl.visible = false
	status_box.add_child(ai_lbl)
	_ai_label[team_id][slot] = ai_lbl

	# Action button: small outline square in the top-left corner of the
	# CARD itself (not the content area). Negative offsets escape the
	# panel's content_margin so the icon sits at card-position (10, 6),
	# clear of both the centered jersey number AND the left stripe band.
	# Default-hidden; refresh() shows it for empty (+) and bot (X) slots
	# when the local peer is the host.
	var action := Button.new()
	action.custom_minimum_size = Vector2(_ICON_SIZE, _ICON_SIZE)
	action.set_anchors_preset(Control.PRESET_TOP_LEFT)
	action.position = Vector2(-8, -6)
	action.size = Vector2(_ICON_SIZE, _ICON_SIZE)
	action.add_theme_font_size_override("font_size", 14)
	action.mouse_filter = Control.MOUSE_FILTER_STOP
	action.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	action.visible = false
	action.pressed.connect(_on_action_pressed.bind(team_id, slot))
	content.add_child(action)
	_action_btn[team_id][slot] = action

	# The card is the focusable nav target and A selects the slot (the primary
	# click). A focus-ring overlay reads the selection since a PanelContainer draws
	# no focus of its own. The host's +/X action stays out of the focus order so the
	# card is the single pad target (bots via Fill with Bots; kick via mouse). Set up
	# unconditionally — the overlay uses the device-aware focus ring (invisible in
	# mouse mode), so this also lets a mouse→pad switch land the pad on a card without
	# rebuilding the grid.
	action.focus_mode = Control.FOCUS_NONE
	card.focus_mode = Control.FOCUS_ALL
	var ring := Panel.new()
	ring.add_theme_stylebox_override("panel", MenuStyle.focus_ring_box())
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.visible = false
	card.add_child(ring)
	card.focus_entered.connect(func() -> void: ring.visible = true)
	card.focus_exited.connect(func() -> void: ring.visible = false)
	var t: int = team_id
	var sl: int = slot
	_nav_cards.append(card)
	_nav_card_handlers.append(func() -> void: slot_selected.emit(t, sl))
	_nav_card_coords.append(Vector2i(team_id, slot))

	return card


# Controller card input on the focused card:
#   * A / ui_accept → select the slot (slot_selected — the primary click). Cards are
#     custom PanelContainers, so ui_accept is routed here, not via gui_input.
#   * X → the card's +/X action (add/remove bot, or kick a peer), matching the mouse
#     action button — only fired when that action is actually shown for the slot.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if ControllerNav.activate_focused(event, _nav_cards, _nav_card_handlers):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed \
			and (event as InputEventJoypadButton).button_index == JOY_BUTTON_X:
		for i: int in _nav_cards.size():
			if _nav_cards[i].has_focus():
				var coord: Vector2i = _nav_card_coords[i]
				var btn: Button = _action_btn[coord.x][coord.y]
				if btn != null and btn.visible:
					_on_action_pressed(coord.x, coord.y)
					get_viewport().set_input_as_handled()
				return


# Drop controller focus on the first VISIBLE slot card — the Lobby calls this on
# open. In 3v3 the D-row cards are hidden, so the first entry may not be visible.
func focus_first_card() -> void:
	for card: Control in _nav_cards:
		if card.is_visible_in_tree():
			ControllerNav.grab_focus(card)
			return


# ── Refresh ──────────────────────────────────────────────────────────────────

# roster: Array of { team_id, slot, peer_id, player_name, jersey_number, is_left_handed, is_ready }
# team_colors: Array[Dictionary] indexed by team_id, each with ui_base/ui_stripe/ui_text fields
# bot_slots: slot_key (team*3+slot) -> bool. Marks empty slots that should
#   render as bots and (host-only) show the X action.
# is_local_host: whether the local peer is the host. Drives X/+ visibility.
# bot_identities: slot_key -> { name, number, is_left_handed }. Picked at
#   lobby-toggle time so the bot card previews the actual name/number that
#   will spawn instead of a generic "BOT" placeholder.
# allow_bot_edit: shows the host's +/X bot actions. The pause menu's mid-match
#   grid passes false (no bot add/remove once the game is running) while still
#   passing is_local_host so the kick X stays available on peer cards.
# show_ready: render the per-player READY / WAITING tag. Lobby passes true; the
#   mid-match grid leaves it off (ready state is a lobby concept and the
#   mid-match roster doesn't carry is_ready).
func refresh(roster: Array[Dictionary], team_colors: Array[Dictionary] = [],
		bot_slots: Dictionary = {}, is_local_host: bool = false,
		bot_identities: Dictionary = {}, allow_bot_edit: bool = true,
		show_ready: bool = false) -> void:
	_team_colors = team_colors
	_bot_slots = bot_slots
	_bot_identities = bot_identities
	_is_local_host = is_local_host
	_bot_editing = allow_bot_edit
	_show_ready = show_ready

	var by_slot: Dictionary = {}
	for entry: Dictionary in roster:
		by_slot[LobbySlotKey.encode(entry.team_id, entry.slot)] = entry

	for team_id: int in 2:
		for s: int in PlayerRules.MAX_PER_TEAM:
			var key: int = LobbySlotKey.encode(team_id, s)
			var entry = by_slot.get(key, null)
			_update_card(team_id, s, entry)


func _update_card(team_id: int, slot: int, entry) -> void:
	var style:        StyleBoxFlat = _stylebox[team_id][slot]
	var stripe_style: StyleBoxFlat = _stripe_style[team_id][slot]
	var num_lbl:  Label = _num_labels[team_id][slot]
	var name_lbl: Label = _name_labels[team_id][slot]
	var pos_lbl:  Label = _pos_labels[team_id][slot]
	var right_col: VBoxContainer = _right_cols[team_id][slot]
	var ping_lbl: Label = _ping_label[team_id][slot]
	var dot:      ColorRect = _ping_dot[team_id][slot]
	var ai_lbl:   Label = _ai_label[team_id][slot]
	var ready_lbl: Label = _ready_label[team_id][slot]
	var action:   Button = _action_btn[team_id][slot]

	var jersey_c:  Color = MenuStyle.PANEL_BG
	var stripe_c:  Color = MenuStyle.TEXT_SEP
	var text_c:    Color = MenuStyle.TEXT_BODY
	if _team_colors.size() > team_id:
		var tc: Dictionary = _team_colors[team_id]
		jersey_c = tc.get("ui_base", jersey_c)
		stripe_c = tc.get("ui_stripe", stripe_c)
		text_c   = tc.get("ui_text", text_c)

	var slot_key: int = LobbySlotKey.encode(team_id, slot)
	var is_bot_slot: bool = entry == null and _bot_slots.get(slot_key, false)

	if entry == null and not is_bot_slot:
		# === Empty slot ============================================
		_peer_ids[team_id][slot] = -1
		# Slightly elevated card bg so the empty slot still reads as a
		# card against the dark lobby panel.
		style.bg_color = MenuStyle.SURFACE_ELEV
		stripe_style.bg_color = MenuStyle.TEXT_SEP
		# Hide the number column and the right column entirely on empty
		# cards so "OPEN SLOT" centers across the full card width. The
		# column header above already provides position context (LEFT
		# WING / CENTER / RIGHT WING) — no info loss from dropping the
		# per-card L/C/R indicator.
		num_lbl.visible = false
		right_col.visible = false
		name_lbl.text = "OPEN SLOT"
		name_lbl.set_meta("fit_base", _NAME_FONT_SIZE_OPEN)
		name_lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_fit_name(name_lbl)
		_set_action(action, "+", _is_local_host and _bot_editing, MenuStyle.TEXT_DIM)
		return

	# Filled cards (bot or human) — restore the number + right columns and
	# the default left-aligned full-size name.
	num_lbl.visible = true
	right_col.visible = true
	name_lbl.set_meta("fit_base", _NAME_FONT_SIZE)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

	if is_bot_slot:
		# === Bot slot ==============================================
		_peer_ids[team_id][slot] = -1
		style.bg_color = jersey_c
		stripe_style.bg_color = stripe_c
		var identity: Dictionary = _bot_identities.get(slot_key, {})
		var bot_name: String = identity.get("name", "BOT")
		var bot_num: int = identity.get("number", 0)
		num_lbl.text = str(bot_num) if bot_num > 0 else "#"
		num_lbl.add_theme_color_override("font_color", text_c)
		name_lbl.text = bot_name.to_upper()
		name_lbl.add_theme_color_override("font_color", text_c)
		_fit_name(name_lbl)
		pos_lbl.add_theme_color_override("font_color", _muted(text_c, 0.7))
		ping_lbl.visible = false
		dot.visible = false
		ai_lbl.visible = true
		ai_lbl.add_theme_color_override("font_color", _muted(text_c, 0.75))
		ready_lbl.visible = false
		_set_action(action, "x", _is_local_host and _bot_editing, text_c)
		return

	# === Human-filled slot (local or remote) =====================
	var peer_id: int = entry.get("peer_id", -1)
	_peer_ids[team_id][slot] = peer_id
	style.bg_color = jersey_c
	stripe_style.bg_color = stripe_c

	num_lbl.text = str(entry.get("jersey_number", 10))
	num_lbl.add_theme_color_override("font_color", text_c)

	var p_name: String = entry.get("player_name", "")
	name_lbl.text = p_name.to_upper() if not p_name.is_empty() else "PLAYER"
	name_lbl.add_theme_color_override("font_color", text_c)
	_fit_name(name_lbl)
	pos_lbl.add_theme_color_override("font_color", _muted(text_c, 0.7))

	ai_lbl.visible = false
	ping_lbl.visible = true
	dot.visible = true
	_apply_ping(ping_lbl, dot, peer_id, text_c)
	# READY / WAITING tag — lobby only, and never for the host (peer 1), who
	# gates the start via the Start button rather than readying up. Bots are
	# handled in the bot branch above (no tag).
	if _show_ready and peer_id != 1:
		ready_lbl.visible = true
		var is_ready: bool = entry.get("is_ready", false)
		ready_lbl.text = "READY" if is_ready else "WAITING"
		ready_lbl.add_theme_color_override(
				"font_color", _COLOR_READY if is_ready else _COLOR_WAITING)
	else:
		ready_lbl.visible = false
	# Host gets a kick X on other connected peers' cards — never its own, and
	# never a mid-match bot (bot actor ids aren't transport peers).
	if _is_local_host and peer_id != NetworkManager.local_peer_id() \
			and peer_id in NetworkManager.connected_peer_ids():
		_set_action(action, "x", true, text_c)
	else:
		action.visible = false


# Shrink the name's font size so the whole name fits the label's current
# width, mirroring the in-game jersey renderer (which measures the string and
# fits it) rather than hard-clipping. Measures at the label's preferred
# "fit_base" size and scales down proportionally if the text overflows,
# flooring at _NAME_FONT_MIN; clip_text catches anything still too long. Wired
# to the label's resized signal so it re-fits on window/layout changes, and
# called explicitly after each text update. Idempotent — always measures from
# fit_base, so repeated calls converge without drift.
func _fit_name(lbl: Label) -> void:
	var base: int = lbl.get_meta("fit_base", _NAME_FONT_SIZE)
	var avail: float = lbl.size.x
	if avail <= 0.0 or lbl.text.is_empty():
		# Layout not resolved yet (or nothing to show) — keep the preferred
		# size; the resized signal will re-fit once a real width is known.
		lbl.add_theme_font_size_override("font_size", base)
		return
	var font: Font = lbl.get_theme_font("font")
	var text_w: float = font.get_string_size(
			lbl.text, lbl.horizontal_alignment, -1, base).x
	var size_px: int = base
	if text_w > avail:
		size_px = maxi(_NAME_FONT_MIN, int(floor(base * avail / text_w)))
	lbl.add_theme_font_size_override("font_size", size_px)


# Small outline-only square in the top-left corner of a card. `accent` is
# the team's text color (on a jersey background) or TEXT_DIM (on an empty
# card) — guaranteed contrast since `text` is the registry's contrast-
# engineered color. Transparent fill at rest, lightly-tinted on hover.
func _set_action(action: Button, icon: String, should_show: bool, accent: Color) -> void:
	action.visible = should_show
	if not should_show:
		return
	action.text = icon
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0, 0, 0, 0)
	normal_style.border_color = accent
	normal_style.set_border_width_all(1)
	normal_style.set_corner_radius_all(3)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(accent.r, accent.g, accent.b, 0.18)
	hover_style.border_color = accent
	hover_style.set_border_width_all(1)
	hover_style.set_corner_radius_all(3)
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = Color(accent.r, accent.g, accent.b, 0.30)
	pressed_style.border_color = accent
	pressed_style.set_border_width_all(1)
	pressed_style.set_corner_radius_all(3)
	action.add_theme_stylebox_override("normal", normal_style)
	action.add_theme_stylebox_override("hover", hover_style)
	action.add_theme_stylebox_override("pressed", pressed_style)
	action.add_theme_color_override("font_color", accent)
	action.add_theme_color_override("font_hover_color", accent)
	action.add_theme_color_override("font_pressed_color", accent)


func _apply_ping(ping_lbl: Label, dot: ColorRect, peer_id: int, text_c: Color) -> void:
	var ms: int = _peer_ping(peer_id)
	if ms <= 0:
		ping_lbl.text = ""
		dot.visible = false
		return
	ping_lbl.text = "%dms" % ms
	ping_lbl.add_theme_color_override("font_color", _muted(text_c, 0.75))
	dot.visible = true
	if ms <= _PING_GREEN:
		dot.color = _COLOR_PING_GOOD
	elif ms <= _PING_YELLOW:
		dot.color = _COLOR_PING_OKAY
	else:
		dot.color = _COLOR_PING_BAD


func _peer_ping(peer_id: int) -> int:
	if peer_id < 0:
		return -1
	var local_id: int = NetworkManager.local_peer_id()
	if peer_id == local_id:
		if NetworkManager.is_host:
			return -1
		return int(NetworkManager.get_rtt_ms())
	return NetworkManager.get_peer_ping_ms(peer_id)


func _muted(c: Color, alpha: float) -> Color:
	return Color(c.r, c.g, c.b, alpha)


# Refresh ping displays without rebuilding the whole grid.
func _refresh_pings() -> void:
	for team_id: int in 2:
		for s: int in PlayerRules.MAX_PER_TEAM:
			var peer_id: int = _peer_ids[team_id][s]
			if peer_id < 0:
				continue
			var ping_lbl: Label = _ping_label[team_id][s]
			var dot: ColorRect = _ping_dot[team_id][s]
			var text_c: Color = MenuStyle.TEXT_BODY
			if _team_colors.size() > team_id:
				text_c = _team_colors[team_id].get("ui_text", text_c)
			_apply_ping(ping_lbl, dot, peer_id, text_c)


# ── Input ────────────────────────────────────────────────────────────────────

func _on_card_input(event: InputEvent, team_id: int, slot: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		slot_selected.emit(team_id, slot)


func _on_action_pressed(team_id: int, slot: int) -> void:
	var peer_id: int = _peer_ids[team_id][slot]
	if peer_id > 0:
		# Card held by a live actor — the only action shown here is the
		# host's kick X (gated to connected transport peers in _update_card).
		if peer_id in NetworkManager.connected_peer_ids():
			var name_lbl: Label = _name_labels[team_id][slot]
			kick_requested.emit(peer_id, name_lbl.text)
		return
	# is_bot=true when slot was empty (+ icon → add), false when bot (X icon → remove).
	var slot_key: int = LobbySlotKey.encode(team_id, slot)
	var was_bot: bool = _bot_slots.get(slot_key, false)
	bot_toggled.emit(team_id, slot, not was_bot)
