class_name SlotGridPanel
extends VBoxContainer

# Lobby slot grid. Six cards in a 2x3 layout (AWAY/HOME rows × LW/C/RW
# columns), each card showing:
#
#   ┌──────────────────────────────────┐
#   │ ▶  88  PLAYERNAME              L │   ← action icon (X / +) top-left;
#   │ │                       ●  32ms  │     position letter top-right;
#   └──────────────────────────────────┘     name in middle; ping or AI label
#                                            bottom-right; left stripe in
#                                            jersey_stripe color.
#
# Card visual semantics:
#   - Empty slot      → dark neutral bg, no stripe color, "+" icon (host).
#   - Bot slot        → jersey color bg, stripe, "AI" badge bottom-right, "X" icon (host).
#   - Remote human    → jersey color bg, stripe, "##ms ●" ping with status dot.
#   - Your slot       → jersey color bg, stripe, ping, plus a 1px TEAL_DIM
#                       border around the whole card so the local player can
#                       recognize their own slot at a glance.
#
# Clicking the card body emits slot_selected (used by LobbyManager to swap
# into the slot). Clicking the action icon emits bot_toggled (add/remove a
# bot, host-only). The two click targets are siblings under the card root
# and use mouse_filter STOP, so clicking the icon does NOT propagate to the
# card's swap handler.

signal slot_selected(team_id: int, slot: int)
signal bot_toggled(team_id: int, slot: int, is_bot: bool)

# Column display order: Left Wing (slot 1), Center (slot 0), Right Wing (slot 2)
const _DISPLAY_ORDER  := [1, 0, 2]
const _POSITION_LABEL := ["C", "L", "R"]   # indexed by slot
const _POSITION_HEADER := ["LEFT WING", "CENTER", "RIGHT WING"]

const _CARD_HEIGHT: int = 96
const _STRIPE_WIDTH: int = 4
const _ICON_SIZE: int = 20

# Ping color bands (ms).
const _PING_GREEN: int  = 60
const _PING_YELLOW: int = 120
const _COLOR_PING_GOOD := Color(0.36, 0.85, 0.45, 1.0)
const _COLOR_PING_OKAY := Color(0.95, 0.78, 0.22, 1.0)
const _COLOR_PING_BAD  := Color(0.92, 0.40, 0.40, 1.0)

# Per-slot widget caches. Indexed [team_id][slot].
var _cards:        Array = [[], []]
var _stylebox:     Array = [[], []]   # StyleBoxFlat — recolored per refresh
var _stripe:       Array = [[], []]   # ColorRect — inset left edge band
var _num_labels:   Array = [[], []]
var _name_labels:  Array = [[], []]
var _pos_labels:   Array = [[], []]
var _status_box:   Array = [[], []]   # HBoxContainer holding ping/AI
var _ping_label:   Array = [[], []]
var _ping_dot:     Array = [[], []]
var _ai_label:     Array = [[], []]
var _action_btn:   Array = [[], []]   # X / + button (host only, hidden on remote-human)
var _peer_ids:     Array = [[], []]

var _team_colors: Array[Dictionary] = []
var _bot_slots: Dictionary = {}
var _is_local_host: bool = false


func _init() -> void:
	_build_grid()


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

	# Column header row: AWAY/HOME spacer + LW / C / RW labels.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(header)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(56, 0)
	header.add_child(spacer)

	for col: int in _DISPLAY_ORDER.size():
		var lbl := Label.new()
		lbl.text = _POSITION_HEADER[col]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_child(lbl)

	# Away on top (team 1), Home on bottom (team 0) — matches rink perspective.
	for team_id: int in [1, 0]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(row)

		var team_label := Label.new()
		team_label.text = "AWAY" if team_id == 1 else "HOME"
		team_label.add_theme_font_size_override("font_size", 13)
		team_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		team_label.custom_minimum_size = Vector2(56, 0)
		team_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(team_label)

		_cards[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_stylebox[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_stripe[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_num_labels[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_name_labels[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_pos_labels[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_status_box[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_ping_label[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_ping_dot[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_ai_label[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_action_btn[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_peer_ids[team_id].resize(PlayerRules.MAX_PER_TEAM)
		_peer_ids[team_id].fill(-1)

		for col: int in _DISPLAY_ORDER.size():
			var s: int = _DISPLAY_ORDER[col]
			row.add_child(_build_card(team_id, s))


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

	# Inset jersey-stripe band — anchored to the left edge of the content
	# area, sharp rectangle sitting a few pixels off the top/bottom so it
	# doesn't curl with the card's corner radius.
	var stripe := ColorRect.new()
	stripe.color = MenuStyle.TEXT_SEP
	stripe.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	stripe.offset_left = -6
	stripe.offset_right = -6 + _STRIPE_WIDTH
	stripe.offset_top = 4
	stripe.offset_bottom = -4
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(stripe)
	_stripe[team_id][slot] = stripe

	var main_row := HBoxContainer.new()
	# Tight separation lets the name sit right next to the number, like a
	# real roster card: "10 Panarin" reads as one unit rather than two
	# columns. The number takes whatever width its glyphs need, no fixed
	# 72px reservation, so single-digit and double-digit numbers both
	# end up flush against the name.
	main_row.add_theme_constant_override("separation", 10)
	main_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(main_row)

	var num := Label.new()
	num.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	num.add_theme_font_size_override("font_size", 44)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_row.add_child(num)
	_num_labels[team_id][slot] = num

	# Name label fills the remaining width to the right of the number.
	var name_lbl := Label.new()
	name_lbl.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	name_lbl.add_theme_font_size_override("font_size", 22)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	right_col.custom_minimum_size = Vector2(72, 0)
	right_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_row.add_child(right_col)

	var pos_lbl := Label.new()
	pos_lbl.text = _POSITION_LABEL[slot]
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

	var ai_lbl := Label.new()
	ai_lbl.text = "AI"
	ai_lbl.add_theme_font_size_override("font_size", 11)
	ai_lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	ai_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ai_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ai_lbl.visible = false
	status_box.add_child(ai_lbl)
	_ai_label[team_id][slot] = ai_lbl

	# Action button: small filled square in the top-left corner of the card.
	# Used by the host to add/remove bots. Default-hidden; refresh() shows
	# it for empty (+) and bot (X) slots when the local peer is the host.
	var action := Button.new()
	action.custom_minimum_size = Vector2(_ICON_SIZE, _ICON_SIZE)
	action.set_anchors_preset(Control.PRESET_TOP_LEFT)
	action.position = Vector2(6, 6)
	action.size = Vector2(_ICON_SIZE, _ICON_SIZE)
	action.add_theme_font_size_override("font_size", 14)
	action.mouse_filter = Control.MOUSE_FILTER_STOP
	action.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	action.visible = false
	action.pressed.connect(_on_action_pressed.bind(team_id, slot))
	content.add_child(action)
	_action_btn[team_id][slot] = action

	return card


# ── Refresh ──────────────────────────────────────────────────────────────────

# roster: Array of { team_id, slot, peer_id, player_name, jersey_number, is_left_handed, is_ready }
# local_peer_id: this client's peer ID
# team_colors: Array[Dictionary] indexed by team_id, each with jersey/text/text_outline fields
# bot_slots: slot_key (team*3+slot) -> bool. Marks empty slots that should
#   render as bots and (host-only) show the X action.
# is_local_host: whether the local peer is the host. Drives X/+ visibility.
func refresh(roster: Array[Dictionary], local_peer_id: int, team_colors: Array[Dictionary] = [],
		bot_slots: Dictionary = {}, is_local_host: bool = false) -> void:
	_team_colors = team_colors
	_bot_slots = bot_slots
	_is_local_host = is_local_host

	var by_slot: Dictionary = {}
	for entry: Dictionary in roster:
		by_slot[entry.team_id * 3 + entry.slot] = entry

	for team_id: int in 2:
		for s: int in PlayerRules.MAX_PER_TEAM:
			var key: int = team_id * 3 + s
			var entry = by_slot.get(key, null)
			var is_local: bool = entry != null and entry.peer_id == local_peer_id
			_update_card(team_id, s, entry, is_local)


func _update_card(team_id: int, slot: int, entry, is_local: bool) -> void:
	var style:    StyleBoxFlat = _stylebox[team_id][slot]
	var stripe:   ColorRect = _stripe[team_id][slot]
	var num_lbl:  Label = _num_labels[team_id][slot]
	var name_lbl: Label = _name_labels[team_id][slot]
	var pos_lbl:  Label = _pos_labels[team_id][slot]
	var ping_lbl: Label = _ping_label[team_id][slot]
	var dot:      ColorRect = _ping_dot[team_id][slot]
	var ai_lbl:   Label = _ai_label[team_id][slot]
	var action:   Button = _action_btn[team_id][slot]

	var jersey_c:  Color = MenuStyle.PANEL_BG
	var stripe_c:  Color = MenuStyle.TEXT_SEP
	var text_c:    Color = MenuStyle.TEXT_BODY
	if _team_colors.size() > team_id:
		var tc: Dictionary = _team_colors[team_id]
		jersey_c = tc.get("jersey", jersey_c)
		stripe_c = tc.get("jersey_stripe", stripe_c)
		text_c   = tc.get("text", text_c)

	var slot_key: int = team_id * 3 + slot
	var is_bot_slot: bool = entry == null and _bot_slots.get(slot_key, false)

	if entry == null and not is_bot_slot:
		# === Empty slot ============================================
		_peer_ids[team_id][slot] = -1
		style.bg_color = MenuStyle.PANEL_BG
		stripe.color = MenuStyle.TEXT_SEP
		num_lbl.text = ""
		# Empty cards use a smaller name font so "OPEN SLOT" fits the
		# narrower side columns without clipping.
		name_lbl.text = "OPEN SLOT"
		name_lbl.add_theme_font_size_override("font_size", 16)
		name_lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		pos_lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		ping_lbl.visible = false
		dot.visible = false
		ai_lbl.visible = false
		_set_action(action, "+", _is_local_host, MenuStyle.TEXT_DIM)
		return

	# Filled cards (bot or human) — restore full-size name.
	name_lbl.add_theme_font_size_override("font_size", 22)

	if is_bot_slot:
		# === Bot slot ==============================================
		_peer_ids[team_id][slot] = -1
		style.bg_color = jersey_c
		stripe.color = stripe_c
		num_lbl.text = "##"
		num_lbl.add_theme_color_override("font_color", text_c)
		name_lbl.text = "BOT"
		name_lbl.add_theme_color_override("font_color", text_c)
		pos_lbl.add_theme_color_override("font_color", _muted(text_c, 0.7))
		ping_lbl.visible = false
		dot.visible = false
		ai_lbl.visible = true
		ai_lbl.add_theme_color_override("font_color", _muted(text_c, 0.75))
		_set_action(action, "x", _is_local_host, text_c)
		return

	# === Human-filled slot (local or remote) =====================
	var peer_id: int = entry.get("peer_id", -1)
	_peer_ids[team_id][slot] = peer_id
	style.bg_color = jersey_c
	stripe.color = stripe_c

	num_lbl.text = str(entry.get("jersey_number", 10))
	num_lbl.add_theme_color_override("font_color", text_c)

	var p_name: String = entry.get("player_name", "")
	name_lbl.text = p_name.to_upper() if not p_name.is_empty() else "PLAYER"
	name_lbl.add_theme_color_override("font_color", text_c)
	pos_lbl.add_theme_color_override("font_color", _muted(text_c, 0.7))

	ai_lbl.visible = false
	ping_lbl.visible = true
	dot.visible = true
	_apply_ping(ping_lbl, dot, peer_id, text_c)
	# Local player's own slot — no kick-yourself action.
	# Remote-human slot — no action either; only host-edited bots get one.
	action.visible = false


# Small outline-only square in the top-left corner of a card. `accent` is
# the team's text color (on a jersey background) or TEXT_DIM (on an empty
# card) — guaranteed contrast since `text` is the registry's contrast-
# engineered color. Transparent fill at rest, lightly-tinted on hover.
func _set_action(action: Button, icon: String, visible: bool, accent: Color) -> void:
	action.visible = visible
	if not visible:
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
				text_c = _team_colors[team_id].get("text", text_c)
			_apply_ping(ping_lbl, dot, peer_id, text_c)


# ── Input ────────────────────────────────────────────────────────────────────

func _on_card_input(event: InputEvent, team_id: int, slot: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		slot_selected.emit(team_id, slot)


func _on_action_pressed(team_id: int, slot: int) -> void:
	# is_bot=true when slot was empty (+ icon → add), false when bot (X icon → remove).
	var slot_key: int = team_id * 3 + slot
	var was_bot: bool = _bot_slots.get(slot_key, false)
	bot_toggled.emit(team_id, slot, not was_bot)
