class_name LobbyManager
extends Node

const _SETTING_CONTROL_WIDTH: int = 220

# The lobby panel sits over the live arena backdrop, and its content carries
# its own surfaces (slot cards, the recessed settings tray), so the shell can
# be a tint rather than a wall — let the rink read through. Local to the
# lobby: MenuStyle surfaces stay solid for every other popup by design.
const _PANEL_BG_ALPHA: float = 0.75

# key = LobbySlotKey.encode(team_id, slot)  →  { peer_id, player_name, is_left_handed, jersey_number }
# Players: team_id ∈ {0, 1}, slot ∈ {0,1,2}. Spectators: team_id = -1, slot = spectator_idx.
var _lobby_slots: Dictionary = {}

var _slot_grid: SlotGridPanel = null
var _backdrop: LobbyArenaBackdrop = null
# Host-only convenience: one press fills every open player slot with a bot.
# Deliberately a one-shot button, not a persistent auto-fill — slots that
# open later just leave the button pressable again, and it greys out when
# there's nothing to fill.
var _fill_bots_btn: Button = null
var _kick_confirm: ConfirmDialog = null
var _kick_pending_peer: int = -1
var _start_btn: Button = null
var _ready_btn: Button = null
var _build_popup: LobbyBuildPopup = null
var _settings_panel: LobbySettingsPanel = null
var _spectator_list_label: Label = null
var _spectator_join_btn: Button = null
# Dynamic teams column: every widget is built once, then _refresh_teams_column
# toggles visibility per refresh. A team with at least one human resolves its
# color from votes (the local player's vote dropdown shows while they're on a
# team); a humanless (bots/empty) team instead gets a host-picked dropdown,
# shown to the HOST ONLY — clients see the resulting colors on the slot cards
# (replicated via notify_team_colors) plus the "Host picks" hint, not a dead
# disabled picker.
var _vote_row: HBoxContainer = null
var _my_color_dropdown: PaletteDropdown = null
var _home_color_row: HBoxContainer = null
var _away_color_row: HBoxContainer = null
var _home_color_dropdown: PaletteDropdown = null
var _away_color_dropdown: PaletteDropdown = null
var _teams_hint: Label = null

# Lobby visibility selector (host only). Offline = no Steam lobby / no peer —
# the pre-unification "Play vs Bots" session. Friends / Public attach the
# Steam transport (async) and differ only in Steam lobby type. Offline is
# locked out while human peers are connected: the host kicks them via the
# grid first, deliberately — never as a toggle side effect.
const _VIS_OFFLINE: int = 0
const _VIS_FRIENDS: int = 1
const _VIS_PUBLIC: int = 2
var _visibility: int = _VIS_OFFLINE
var _visibility_target: int = _VIS_OFFLINE  # requested state while attach is in flight
var _visibility_btn: OptionButton = null
var _visibility_hint: Label = null

# key = peer_id → bool; tracks non-host peers only (host uses Start instead)
var _ready_states: Dictionary = {}
var _local_is_ready: bool = false

# Settings (host only editable; all players see them). The two AI difficulty
# values are the host's PlayerPrefs, synced to clients for display only —
# clients never persist them (see LobbySettingsPanel's class doc).
var _num_periods: int = GameRules.NUM_PERIODS
var _period_duration: float = GameRules.PERIOD_DURATION
var _ot_enabled: bool = GameRules.OT_ENABLED
var _rule_set: int = GameRules.DEFAULT_RULE_SET
var _team_size: int = GameRules.DEFAULT_TEAM_SIZE
var _bot_difficulty: int = BotSkillProfile.Difficulty.NORMAL
var _goalie_difficulty: int = GoalieSkillProfile.Difficulty.NORMAL

# Team color presets used as placeholders in the lobby slot-grid preview.
# Real per-team colors are resolved from votes at game start.
var _home_color_slot: int = TeamColorRegistry.DEFAULT_HOME_SLOT
var _away_color_slot: int = TeamColorRegistry.DEFAULT_AWAY_SLOT

# Local player's current color vote + a mirror of every player's vote so
# everyone in the lobby can see who voted for what. Host is authoritative;
# clients receive updates via NetworkManager.color_vote_changed.
var _my_color_slot: int = TeamColorRegistry.DEFAULT_HOME_SLOT
var _color_votes: Dictionary = {}  # peer_id → color_slot (int)

func _ready() -> void:
	_home_color_slot = NetworkManager.pending_home_color_slot
	_away_color_slot = NetworkManager.pending_away_color_slot
	_num_periods = NetworkManager.pending_num_periods
	_period_duration = NetworkManager.pending_period_duration
	_ot_enabled = NetworkManager.pending_ot_enabled
	_rule_set = NetworkManager.pending_rule_set
	_team_size = NetworkManager.pending_team_size
	# Host: the difficulty dropdowns show (and edit) the host's own prefs.
	# Client: show whatever the host last synced.
	if NetworkManager.is_host:
		_bot_difficulty = PlayerPrefs.bot_difficulty
		_goalie_difficulty = PlayerPrefs.goalie_difficulty
	else:
		_bot_difficulty = NetworkManager.pending_bot_difficulty
		_goalie_difficulty = NetworkManager.pending_goalie_difficulty
	_my_color_slot = _initial_color_preference()
	_color_votes = NetworkManager.pending_color_votes.duplicate()
	# Re-entering the lobby (return-to-lobby after a match) restores whatever
	# visibility the session already has; a fresh Play lobby starts Offline.
	if NetworkManager.is_offline_mode:
		_visibility = _VIS_OFFLINE
	else:
		_visibility = _VIS_PUBLIC if SteamManager.is_lobby_public else _VIS_FRIENDS
	_build_ui()
	_kick_confirm = ConfirmDialog.new()
	_kick_confirm.confirmed.connect(_on_kick_confirmed)
	_kick_confirm.cancelled.connect(func() -> void: _kick_pending_peer = -1)
	add_child(_kick_confirm)
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	NetworkManager.slot_swap_requested.connect(_on_slot_swap_requested)
	NetworkManager.slot_swap_confirmed.connect(_on_slot_swap_confirmed)
	NetworkManager.lobby_roster_synced.connect(_on_lobby_roster_synced)
	NetworkManager.game_started.connect(_on_game_started)
	NetworkManager.color_vote_changed.connect(_on_color_vote_changed)
	NetworkManager.color_votes_synced.connect(_on_color_votes_synced)
	NetworkManager.team_colors_changed.connect(_on_team_colors_changed)
	NetworkManager.bot_slot_changed.connect(_on_bot_slot_changed)
	NetworkManager.bot_slots_synced.connect(_on_bot_slots_synced)
	NetworkManager.lobby_settings_synced.connect(_on_lobby_settings_synced)
	NetworkManager.player_ready_changed.connect(_on_player_ready_changed)

	# Submit our own vote into the shared map so the host (and other peers)
	# count it. send_color_vote handles both host-local and client-RPC paths
	# and works offline too (no peers → local emit only): the host's vote is
	# what colors their own team while the humanless team keeps the host's
	# direct dropdown pick.
	NetworkManager.send_color_vote(_my_color_slot)

	if not NetworkManager.pending_lobby_roster.is_empty():
		_on_lobby_roster_synced(NetworkManager.pending_lobby_roster)
		NetworkManager.pending_lobby_roster = []
	elif NetworkManager.is_host:
		_assign_slot(1, 0, 0, NetworkManager.local_player_name, NetworkManager.local_is_left_handed, NetworkManager.local_jersey_number)
		_broadcast_confirm(1, 0, 0)
	# Initial Start-button state. The button is constructed disabled; nothing
	# else fires _update_start_btn until a peer joins/readies, so without this
	# the host-alone case stays disabled forever.
	_update_start_btn()

func _initial_color_preference() -> int:
	var saved: int = PlayerPrefs.preferred_color_slot
	if saved < 0:
		return TeamColorRegistry.DEFAULT_HOME_SLOT
	if not TeamColorRegistry.get_all_slots().has(saved):
		return TeamColorRegistry.DEFAULT_HOME_SLOT
	return saved

# ── UI ────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 10
	add_child(canvas)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(root)

	# Live 3D arena behind the panel — the real rink + stands with a slow
	# camera drift. Sits in the 3D world, so the CanvasLayer UI draws over it.
	_backdrop = LobbyArenaBackdrop.new()
	add_child(_backdrop)

	var panel_style := MenuStyle.panel()
	panel_style.bg_color = Color(MenuStyle.PANEL_BG, _PANEL_BG_ALPHA)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(960, 0)
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	# Header row: screen title + (host only) the lobby-visibility selector.
	vbox.add_child(_build_header_row())

	_slot_grid = SlotGridPanel.new()
	_slot_grid.set_active_team_size(_team_size)
	_slot_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot_grid.slot_selected.connect(_on_slot_selected)
	_slot_grid.bot_toggled.connect(_on_bot_toggled)
	_slot_grid.kick_requested.connect(_on_kick_requested)
	# Tighter inner box so the host's fill-bots toggle reads as part of the
	# grid rather than a separate section in the 20px-separated outer stack.
	var grid_box := VBoxContainer.new()
	grid_box.add_theme_constant_override("separation", 4)
	grid_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_box.add_child(_slot_grid)
	if NetworkManager.is_host:
		grid_box.add_child(_build_fill_bots_row())
	vbox.add_child(grid_box)

	# Recessed settings tray below the slot grid: TEAMS / MATCH / SPECTATORS
	# side by side in one full-width strip.
	vbox.add_child(_build_settings_tray())

	var btn_box := HBoxContainer.new()
	btn_box.add_theme_constant_override("separation", 12)
	btn_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_box)

	var back_btn := _btn("Back to Menu")
	back_btn.pressed.connect(_on_back_pressed)
	btn_box.add_child(back_btn)

	var build_btn := _btn("Edit Build")
	build_btn.pressed.connect(_on_edit_build_pressed)
	btn_box.add_child(build_btn)

	if NetworkManager.is_host:
		_start_btn = _btn("Start Game")
		MenuStyle.apply_primary_cta(_start_btn)
		_start_btn.pressed.connect(_on_start_pressed)
		_start_btn.disabled = true
		_start_btn.modulate = Color(1, 1, 1, 0.5)
		btn_box.add_child(_start_btn)
	else:
		_ready_btn = _btn("Ready")
		MenuStyle.apply_primary_cta(_ready_btn)
		_ready_btn.pressed.connect(_on_ready_pressed)
		btn_box.add_child(_ready_btn)

	_build_popup = LobbyBuildPopup.new()
	root.add_child(_build_popup)

	_refresh_grid()
	_refresh_spectator_panel()


func _on_edit_build_pressed() -> void:
	if _build_popup != null:
		_build_popup.open()


# Host-only one-shot button tucked under the slot grid (see _fill_bots_btn).
func _build_fill_bots_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	_fill_bots_btn = Button.new()
	_fill_bots_btn.text = "Fill with Bots"
	_fill_bots_btn.add_theme_font_size_override("font_size", 13)
	_fill_bots_btn.custom_minimum_size = Vector2(0, 28)
	MenuStyle.wire_hover_scale(_fill_bots_btn)
	SoundManager.wire_button(_fill_bots_btn)
	_fill_bots_btn.pressed.connect(_fill_open_slots_with_bots)
	row.add_child(_fill_bots_btn)
	return row


# Grey the fill button out when every fielded slot is already taken.
func _update_fill_bots_btn() -> void:
	if _fill_bots_btn == null:
		return
	var open: int = 0
	for team_id: int in 2:
		for s: int in _team_size:
			var key: int = LobbySlotKey.encode(team_id, s)
			if not _lobby_slots.has(key) and not NetworkManager.pending_bot_slots.get(key, false):
				open += 1
	_fill_bots_btn.disabled = open == 0


# Top up every open player slot with a bot. Each send_bot_slot broadcasts and
# re-fires _refresh_grid via bot_slot_changed, so the cards land one by one.
func _fill_open_slots_with_bots() -> void:
	if not NetworkManager.is_host:
		return
	for team_id: int in 2:
		for s: int in _team_size:
			var key: int = LobbySlotKey.encode(team_id, s)
			if _lobby_slots.has(key):
				continue
			if NetworkManager.pending_bot_slots.get(key, false):
				continue
			NetworkManager.send_bot_slot(key, true)


# Header row above the slot grid: heading on the left and, for the host, the
# lobby-visibility selector (with its status hint) on the right. Visibility is
# a session-level state — who can get in at all — not a match rule, so it
# lives up here rather than in the MATCH settings stack. Clients joined
# through a visibility they can't change, so their header is just the title.
func _build_header_row() -> HBoxContainer:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var title := Label.new()
	title.text = "Lobby"
	MenuStyle.apply_heading(title, 30)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	if NetworkManager.is_host:
		var vis_box := VBoxContainer.new()
		vis_box.add_theme_constant_override("separation", 2)
		vis_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		vis_box.custom_minimum_size = Vector2(280, 0)
		vis_box.add_child(_build_visibility_row())
		_visibility_hint = Label.new()
		_visibility_hint.add_theme_font_size_override("font_size", 11)
		_visibility_hint.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
		_visibility_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_visibility_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vis_box.add_child(_visibility_hint)
		header.add_child(vis_box)
		_update_visibility_row()

	return header


# One recessed full-width strip holding the three option sections side by
# side, split by hairlines: TEAMS | MATCH | SPECTATORS. MATCH gets roughly
# double width — LobbySettingsPanel lays its rows out in two columns — so all
# three sections land at a similar height instead of one tall middle tower.
# The tray shares the empty slot cards' surface (SURFACE_ELEV) so the screen
# reads as two tones — shell + raised surfaces — rather than a third dark.
func _build_settings_tray() -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.SURFACE_ELEV
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)

	var tray := PanelContainer.new()
	tray.add_theme_stylebox_override("panel", style)
	tray.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tray.add_child(row)

	row.add_child(_build_teams_column())
	row.add_child(_tray_separator())
	var match_col := _build_match_column()
	match_col.size_flags_stretch_ratio = 2.2
	row.add_child(match_col)
	row.add_child(_tray_separator())
	row.add_child(_build_spectators_column())

	return tray


# 1px vertical hairline between tray sections.
func _tray_separator() -> ColorRect:
	var sep := ColorRect.new()
	sep.color = MenuStyle.TEXT_SEP
	sep.custom_minimum_size = Vector2(1, 0)
	return sep


# Small uppercase tracking-y header used at the top of each column to
# echo the slot-grid's LW/C/RW headers.
func _column_header(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return lbl


# Teams column: one vote dropdown + one direct dropdown per team, all built
# up front. _refresh_teams_column shows the right subset — your vote while
# you're on a team, and a host-picked dropdown for each team with no human
# on it (see the var-block doc).
func _build_teams_column() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_column_header("TEAMS"))

	_vote_row = _color_picker_row("YOUR VOTE", _my_color_slot, true)
	_my_color_dropdown = _vote_row.get_meta(&"dropdown") as PaletteDropdown
	_my_color_dropdown.selected.connect(_on_my_color_vote_selected)
	col.add_child(_vote_row)

	_away_color_row = _color_picker_row("AWAY", _away_color_slot, NetworkManager.is_host)
	_away_color_dropdown = _away_color_row.get_meta(&"dropdown") as PaletteDropdown
	if NetworkManager.is_host:
		_away_color_dropdown.selected.connect(_on_away_color_selected)
	col.add_child(_away_color_row)

	_home_color_row = _color_picker_row("HOME", _home_color_slot, NetworkManager.is_host)
	_home_color_dropdown = _home_color_row.get_meta(&"dropdown") as PaletteDropdown
	if NetworkManager.is_host:
		_home_color_dropdown.selected.connect(_on_home_color_selected)
	col.add_child(_home_color_row)

	_teams_hint = Label.new()
	_teams_hint.add_theme_font_size_override("font_size", 11)
	_teams_hint.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	col.add_child(_teams_hint)

	_refresh_teams_column()
	return col


# Show/hide the teams-column rows for the current roster and sync the direct
# dropdowns to the resolved slots. Called from _refresh_grid, so every slot
# swap, vote, join, and leave re-evaluates which pickers apply.
func _refresh_teams_column() -> void:
	if _vote_row == null:
		return
	var home_has_human: bool = false
	var away_has_human: bool = false
	var local_on_team: bool = false
	var local_peer: int = NetworkManager.local_peer_id()
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k):
			continue
		if LobbySlotKey.team_id(k) == 0:
			home_has_human = true
		else:
			away_has_human = true
		if _lobby_slots[k].peer_id == local_peer:
			local_on_team = true
	_vote_row.visible = local_on_team
	# Host-picked open-team dropdowns are host-only (see the var-block doc);
	# clients read the pick off the slot cards and the hint below.
	_home_color_row.visible = NetworkManager.is_host and not home_has_human
	_away_color_row.visible = NetworkManager.is_host and not away_has_human
	# Keep the direct dropdowns showing the live resolved slots — a manual pick
	# can be re-rolled by the collision rule when the other team's votes land
	# on the same palette.
	_home_color_dropdown.set_selected(_home_color_slot)
	_away_color_dropdown.set_selected(_away_color_slot)
	if not home_has_human or not away_has_human:
		_teams_hint.text = "Host picks open-team colors"
	else:
		_teams_hint.text = "Most votes wins"


# Build one [LABEL] [PaletteDropdown] row. The dropdown's closed state shows
# the selected slot's primary+stripe styling (lobby-card look), so no
# separate swatch preview is needed alongside it.
func _color_picker_row(label_text: String, initial_slot: int, editable: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(56, 0)
	row.add_child(lbl)

	var dropdown := PaletteDropdown.new(initial_slot, Vector2(_SETTING_CONTROL_WIDTH - 64, 32))
	dropdown.set_disabled(not editable)
	row.add_child(dropdown)

	row.set_meta(&"dropdown", dropdown)
	return row


func _build_match_column() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_column_header("MATCH"))

	_settings_panel = LobbySettingsPanel.new(_num_periods, _period_duration, _ot_enabled, _rule_set,
			NetworkManager.is_host, _team_size, _bot_difficulty, _goalie_difficulty)
	_settings_panel.settings_changed.connect(_on_settings_panel_changed)
	col.add_child(_settings_panel)

	return col


# "Visibility: [Offline | Friends | Public]" — the header-row selector.
# Selecting Friends/Public from Offline attaches the Steam transport
# (async — the selector disables until host_lobby_ready / _failed lands);
# Friends ↔ Public is a live Steam lobby-type flip; Offline detaches, and is
# only selectable with no human peers connected.
func _build_visibility_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(0, 28)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = "Visibility"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	_visibility_btn = OptionButton.new()
	_visibility_btn.custom_minimum_size = Vector2(120, 28)
	_visibility_btn.add_theme_font_size_override("font_size", 13)
	_visibility_btn.add_item("Offline", _VIS_OFFLINE)
	_visibility_btn.add_item("Friends", _VIS_FRIENDS)
	_visibility_btn.add_item("Public", _VIS_PUBLIC)
	_visibility_btn.select(_visibility)
	SoundManager.wire_button(_visibility_btn)
	_visibility_btn.item_selected.connect(_on_visibility_selected)
	row.add_child(_visibility_btn)
	return row


func _on_visibility_selected(idx: int) -> void:
	if idx == _visibility:
		return
	if idx == _VIS_OFFLINE:
		# The item is disabled while human peers are connected; re-check anyway
		# in case a join landed between the click and this handler.
		if not NetworkManager.connected_peer_ids().is_empty():
			_visibility_btn.select(_visibility)
			_update_visibility_row()
			return
		NetworkManager.detach_online()
		_visibility = _VIS_OFFLINE
		_refresh_grid()
		return
	if _visibility == _VIS_OFFLINE:
		# Going online: async Steam lobby create. Lock the selector until the
		# result lands so a second flip can't race the in-flight create.
		_visibility_target = idx
		_visibility_btn.disabled = true
		_set_visibility_hint("Creating Steam lobby…")
		NetworkManager.host_lobby_ready.connect(_on_attach_online_ready, CONNECT_ONE_SHOT)
		NetworkManager.host_lobby_failed.connect(_on_attach_online_failed, CONNECT_ONE_SHOT)
		NetworkManager.attach_online(idx == _VIS_PUBLIC)
		return
	# Friends ↔ Public while already online: live lobby-type flip.
	SteamManager.set_lobby_visibility(idx == _VIS_PUBLIC)
	_visibility = idx
	_update_visibility_row()


func _on_attach_online_ready() -> void:
	if NetworkManager.host_lobby_failed.is_connected(_on_attach_online_failed):
		NetworkManager.host_lobby_failed.disconnect(_on_attach_online_failed)
	_visibility = _visibility_target
	_visibility_btn.disabled = false
	_refresh_grid()


func _on_attach_online_failed(reason: String) -> void:
	if NetworkManager.host_lobby_ready.is_connected(_on_attach_online_ready):
		NetworkManager.host_lobby_ready.disconnect(_on_attach_online_ready)
	_visibility = _VIS_OFFLINE
	_visibility_btn.disabled = false
	_visibility_btn.select(_VIS_OFFLINE)
	_update_visibility_row()
	_set_visibility_hint(reason)


# Re-derives which selector items are legal (Steam down pins the lobby to
# Offline; connected human peers lock Offline out) and refreshes the hint.
# Cheap — called from _refresh_grid so joins/leaves re-evaluate it.
func _update_visibility_row() -> void:
	if _visibility_btn == null:
		return
	var steam_ok: bool = SteamManager.is_available
	var humans_connected: bool = not NetworkManager.connected_peer_ids().is_empty()
	_visibility_btn.set_item_disabled(_VIS_FRIENDS, not steam_ok)
	_visibility_btn.set_item_disabled(_VIS_PUBLIC, not steam_ok)
	_visibility_btn.set_item_disabled(_VIS_OFFLINE, humans_connected)
	if not steam_ok:
		_set_visibility_hint("Steam isn't running — offline only.")
	elif humans_connected:
		_set_visibility_hint("Remove connected players to go offline.")
	elif _visibility == _VIS_OFFLINE:
		_set_visibility_hint("Just you and bots — open it up anytime.")
	elif _visibility == _VIS_FRIENDS:
		_set_visibility_hint("Steam friends can join.")
	else:
		_set_visibility_hint("Listed in the public game browser.")


func _set_visibility_hint(text: String) -> void:
	if _visibility_hint != null:
		_visibility_hint.text = text


func _build_spectators_column() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_column_header("SPECTATORS"))

	_spectator_list_label = Label.new()
	_spectator_list_label.add_theme_font_size_override("font_size", 12)
	_spectator_list_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_spectator_list_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spectator_list_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_spectator_list_label)

	_spectator_join_btn = _btn("Spectate")
	_spectator_join_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_spectator_join_btn.pressed.connect(_on_spectate_pressed)
	col.add_child(_spectator_join_btn)

	return col

func _refresh_spectator_panel() -> void:
	_update_ready_btn()
	if _spectator_list_label == null:
		return
	var entries: Array[Dictionary] = _build_spectator_roster()
	if entries.is_empty():
		_spectator_list_label.text = "No spectators"
	else:
		var names: Array[String] = []
		for e: Dictionary in entries:
			names.append(e.player_name)
		_spectator_list_label.text = "Spectating: " + ", ".join(names)
	var local_peer: int = NetworkManager.local_peer_id()
	var local_is_spectator: bool = false
	for e: Dictionary in entries:
		if e.peer_id == local_peer:
			local_is_spectator = true
			break
	if _spectator_join_btn != null:
		# Spectators get back into a player slot by clicking on an empty slot in
		# the grid above — no separate "Play" button. Only show "Spectate" while
		# the local peer is in a player slot.
		_spectator_join_btn.visible = not local_is_spectator
		_spectator_join_btn.disabled = _find_open_spectator_slot() < 0
	# Spectators don't belong to a team, so their color vote can't affect any
	# team's resolution (`_recompute_resolved_colors` skips spectator entries).
	# _refresh_teams_column hides the vote row entirely while spectating.


func _on_spectate_pressed() -> void:
	var open: int = _find_open_spectator_slot()
	if open < 0:
		return
	NetworkManager.send_request_slot_swap(GameRules.SPECTATOR_TEAM_ID, open)


# ── Color-picker change handlers ────────────────────────────────────────────

# Writes the player's vote into the shared pool. Host receives the vote,
# updates pending_color_votes, recomputes resolved team colors, and
# broadcasts. PlayerPrefs is updated so the next session remembers. Works
# offline too — the host is then the only voter on their own team.
func _on_my_color_vote_selected(slot: int) -> void:
	_my_color_slot = slot
	PlayerPrefs.preferred_color_slot = slot
	PlayerPrefs.save()
	NetworkManager.send_color_vote(slot)


# Host's direct pick for a humanless team. send_team_colors mirrors the pair
# into NetworkManager.pending_*_color_slot and broadcasts so clients' lobby
# previews follow (a no-op with no peers connected).
func _on_away_color_selected(slot: int) -> void:
	_away_color_slot = slot
	NetworkManager.send_team_colors(_home_color_slot, _away_color_slot)
	_refresh_grid()


func _on_home_color_selected(slot: int) -> void:
	_home_color_slot = slot
	NetworkManager.send_team_colors(_home_color_slot, _away_color_slot)
	_refresh_grid()


# Client side of the host's direct picks (notify_team_colors RPC).
func _on_team_colors_changed(home_slot: int, away_slot: int) -> void:
	_home_color_slot = home_slot
	_away_color_slot = away_slot
	_refresh_grid()


func _btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(140, 40)
	MenuStyle.wire_hover_scale(b)
	SoundManager.wire_button(b)
	return b


# ── Slot management ───────────────────────────────────────────────────────────

func _assign_slot(peer_id: int, team_id: int, slot: int, player_name: String, is_left_handed: bool, jersey_number: int = 10) -> void:
	# Clear any existing slot for this peer first.
	for k: int in _lobby_slots.keys():
		if _lobby_slots[k].peer_id == peer_id:
			_lobby_slots.erase(k)
			break
	_lobby_slots[LobbySlotKey.encode(team_id, slot)] = {
		"peer_id": peer_id,
		"player_name": player_name,
		"is_left_handed": is_left_handed,
		"jersey_number": jersey_number,
	}
	# If a player takes over a bot slot, retire the bot — otherwise it would
	# respawn the moment the player moved away. send_bot_slot is host-only;
	# clients pick up the change via the broadcast RPC.
	if team_id != GameRules.SPECTATOR_TEAM_ID:
		var bot_key: int = LobbySlotKey.encode(team_id, slot)
		if NetworkManager.pending_bot_slots.get(bot_key, false):
			NetworkManager.send_bot_slot(bot_key, false)

func _find_balanced_slot(_peer_id: int) -> Array:
	var team0: int = 0
	var team1: int = 0
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k):
			continue
		if LobbySlotKey.team_id(k) == 0: team0 += 1
		else: team1 += 1
	var preferred_team: int = 0 if team0 <= team1 else 1
	for attempt_team: int in [preferred_team, 1 - preferred_team]:
		for s: int in _team_size:
			if not _lobby_slots.has(LobbySlotKey.encode(attempt_team, s)):
				return [attempt_team, s]
	return []

func _find_open_spectator_slot() -> int:
	for s: int in GameRules.MAX_SPECTATORS:
		if not _lobby_slots.has(LobbySlotKey.encode(GameRules.SPECTATOR_TEAM_ID, s)):
			return s
	return -1

func _build_roster_array() -> Array:
	var result: Array = []
	for k: int in _lobby_slots:
		var team_id: int = LobbySlotKey.team_id(k)
		var slot: int = LobbySlotKey.slot(k)
		var entry: Dictionary = _lobby_slots[k]
		var is_ready: bool = _ready_states.get(entry.peer_id, false)
		result.append([entry.peer_id, team_id, slot, entry.player_name, entry.is_left_handed, entry.get("jersey_number", 10), is_ready])
	return result

func _build_slot_grid_roster() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k):
			continue
		var team_id: int = LobbySlotKey.team_id(k)
		var slot: int = LobbySlotKey.slot(k)
		var entry: Dictionary = _lobby_slots[k]
		result.append({
			"peer_id":        entry.peer_id,
			"team_id":        team_id,
			"slot":           slot,
			"player_name":    entry.player_name,
			"jersey_number":  entry.get("jersey_number", 10),
			"is_left_handed": entry.is_left_handed,
			"is_ready":       _ready_states.get(entry.peer_id, false),
		})
	return result

func _build_spectator_roster() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for k: int in _lobby_slots:
		if not LobbySlotKey.is_spectator(k):
			continue
		var entry: Dictionary = _lobby_slots[k]
		result.append({
			"peer_id":        entry.peer_id,
			"slot":           LobbySlotKey.slot(k),
			"player_name":    entry.player_name,
			"is_ready":       _ready_states.get(entry.peer_id, false),
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.slot < b.slot)
	return result

func _get_team_colors() -> Array[Dictionary]:
	return [
		TeamColorRegistry.get_colors(_home_color_slot, 0),
		TeamColorRegistry.get_colors(_away_color_slot, 1),
	]

func _refresh_grid() -> void:
	if _slot_grid == null:
		return
	_recompute_resolved_colors()
	if _backdrop != null:
		_backdrop.set_team_color_slots(_home_color_slot, _away_color_slot)
		var bench: Array[int] = _bench_occupancy()
		_backdrop.set_bench_counts(bench[0], bench[1])
	_slot_grid.refresh(_build_slot_grid_roster(), _get_team_colors(),
			NetworkManager.pending_bot_slots, NetworkManager.is_host,
			NetworkManager.pending_bot_identities, true, true)
	_refresh_teams_column()
	_update_visibility_row()
	_update_fill_bots_btn()
	_refresh_spectator_panel()

# [home, away] occupied-slot counts (humans + bots) for the backdrop's bench
# dummies. Slots beyond the live team size don't count — they aren't fielded.
func _bench_occupancy() -> Array[int]:
	var counts: Array[int] = [0, 0]
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k) or LobbySlotKey.slot(k) >= _team_size:
			continue
		counts[LobbySlotKey.team_id(k)] += 1
	for bot_key: int in NetworkManager.pending_bot_slots:
		if not NetworkManager.pending_bot_slots[bot_key]:
			continue
		if LobbySlotKey.is_spectator(bot_key) or LobbySlotKey.slot(bot_key) >= _team_size:
			continue
		counts[LobbySlotKey.team_id(bot_key)] += 1
	return counts


# Live vote resolution. Walks the current roster, buckets each player's vote
# onto their currently assigned team, then asks ColorVoteRules for the new
# (home, away) pair — passing the previous winners as sticky hints so an
# already-tied lead doesn't re-roll on every unrelated vote change. A team
# with no human voters has an empty pool, and its current slot rides through
# as the fallback default — which is exactly how the host's direct pick for
# a humanless team survives resolution.
func _recompute_resolved_colors() -> void:
	var home_votes: Array[int] = []
	var away_votes: Array[int] = []
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k):
			continue
		var entry: Dictionary = _lobby_slots[k]
		var peer_id: int = entry.peer_id
		if not _color_votes.has(peer_id):
			continue
		var team_id: int = LobbySlotKey.team_id(k)
		var vote: int = int(_color_votes[peer_id])
		if team_id == 0:
			home_votes.append(vote)
		else:
			away_votes.append(vote)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var resolved: Array[int] = ColorVoteRules.resolve_team_colors(
			home_votes, away_votes,
			TeamColorRegistry.get_all_slots(),
			_home_color_slot,
			_away_color_slot,
			rng,
			_home_color_slot,
			_away_color_slot)
	_home_color_slot = resolved[0]
	_away_color_slot = resolved[1]

func _broadcast_confirm(peer_id: int, team_id: int, slot: int) -> void:
	var entry: Dictionary = _lobby_slots.get(LobbySlotKey.encode(team_id, slot), {})
	if entry.is_empty():
		return
	if team_id == GameRules.SPECTATOR_TEAM_ID:
		# Spectators don't carry a jersey palette; pass zero colors so the receiving
		# side knows to take the spectator path rather than spawn a skater.
		NetworkManager.send_confirm_slot_swap(peer_id, -1, -1, team_id, slot,
				Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0))
		return
	var color_slot: int = _home_color_slot if team_id == 0 else _away_color_slot
	var colors: Dictionary = TeamColorRegistry.get_colors(color_slot, team_id)
	NetworkManager.send_confirm_slot_swap(peer_id, -1, -1, team_id, slot,
			colors.jersey, colors.helmet, colors.pants)

func _update_start_btn() -> void:
	if _start_btn == null:
		return
	# Spectators don't have a controller to ready; their ready state is ignored
	# so the host can start with a non-empty spectator pool. Host alone (no
	# non-host player peers) can also start — useful for solo testing.
	var spectator_peers: Dictionary = {}
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k):
			spectator_peers[_lobby_slots[k].peer_id] = true
	var all_ready: bool = true
	for pid: int in _ready_states:
		if spectator_peers.has(pid):
			continue
		if not _ready_states[pid]:
			all_ready = false
			break
	_start_btn.disabled = not all_ready
	_start_btn.modulate = Color(1, 1, 1, 1.0) if all_ready else Color(1, 1, 1, 0.5)

func _update_ready_btn() -> void:
	if _ready_btn == null:
		return
	# Spectators don't ready up — their button hides until they swap back to a
	# playing slot. _refresh_spectator_panel calls this whenever the local slot
	# changes.
	var local_peer: int = NetworkManager.local_peer_id()
	var local_is_spectator: bool = false
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k) and _lobby_slots[k].peer_id == local_peer:
			local_is_spectator = true
			break
	_ready_btn.visible = not local_is_spectator
	# Uppercase to match apply_primary_cta's display-caps treatment — dynamic
	# text assignments bypass the one-time uppercasing done at build time.
	_ready_btn.text = "UNREADY" if _local_is_ready else "READY"

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_peer_joined(peer_id: int) -> void:
	if not NetworkManager.is_host:
		return
	var target: Array = _find_balanced_slot(peer_id)
	if target.is_empty():
		# Player roster full — fall back to a spectator slot. If those are also
		# full, drop the assignment (peer stays connected but in limbo).
		var spec_slot: int = _find_open_spectator_slot()
		if spec_slot < 0:
			return
		target = [GameRules.SPECTATOR_TEAM_ID, spec_slot]
	var name_val: String = NetworkManager.get_peer_name(peer_id)
	var is_left: bool = NetworkManager.get_peer_handedness(peer_id)
	var num: int = NetworkManager.get_peer_number(peer_id)
	_assign_slot(peer_id, target[0], target[1], name_val, is_left, num)
	_ready_states[peer_id] = false
	var roster: Array = _build_roster_array()
	for existing_peer: int in NetworkManager.connected_peer_ids():
		NetworkManager.send_lobby_roster(existing_peer, roster)
	NetworkManager.send_color_votes_to(peer_id, _color_votes)
	NetworkManager.send_team_colors_to(peer_id, _home_color_slot, _away_color_slot)
	NetworkManager.send_lobby_settings_to(peer_id, _num_periods, _period_duration, _ot_enabled,
			_rule_set, _team_size, _bot_difficulty, _goalie_difficulty)
	NetworkManager.send_bot_slots_to(peer_id, NetworkManager.pending_bot_slots, NetworkManager.pending_bot_identities)
	_broadcast_confirm(peer_id, target[0], target[1])
	_update_start_btn()
	_refresh_grid()

func _on_peer_disconnected(peer_id: int) -> void:
	for k: int in _lobby_slots.keys():
		if _lobby_slots[k].peer_id == peer_id:
			_lobby_slots.erase(k)
			break
	_ready_states.erase(peer_id)
	_color_votes.erase(peer_id)
	_update_start_btn()
	_refresh_grid()

func _on_slot_selected(team_id: int, slot: int) -> void:
	NetworkManager.send_request_slot_swap(team_id, slot)

func _find_peer_identity(peer_id: int) -> Dictionary:
	for k: int in _lobby_slots:
		if _lobby_slots[k].peer_id == peer_id:
			var entry: Dictionary = _lobby_slots[k]
			return {
				"player_name": entry.player_name,
				"is_left_handed": entry.is_left_handed,
				"jersey_number": entry.get("jersey_number", 10),
			}
	return { "player_name": "", "is_left_handed": true, "jersey_number": 10 }

func _on_slot_swap_requested(peer_id: int, new_team_id: int, new_slot: int) -> void:
	if not NetworkManager.is_host:
		return
	if _lobby_slots.has(LobbySlotKey.encode(new_team_id, new_slot)):
		return
	if new_team_id == GameRules.SPECTATOR_TEAM_ID:
		if new_slot < 0 or new_slot >= GameRules.MAX_SPECTATORS:
			return
	else:
		var count: int = 0
		for k: int in _lobby_slots:
			if LobbySlotKey.is_spectator(k):
				continue
			if LobbySlotKey.team_id(k) == new_team_id:
				count += 1
		if count >= _team_size:
			return
	var identity: Dictionary = _find_peer_identity(peer_id)
	_assign_slot(peer_id, new_team_id, new_slot,
			identity.player_name, identity.is_left_handed, identity.jersey_number)
	_broadcast_confirm(peer_id, new_team_id, new_slot)
	# Swapping to/from spectator changes who counts toward the ready check, so
	# re-evaluate the start button — otherwise a sole client moving to spectate
	# leaves the host's button stuck disabled.
	_update_start_btn()
	_refresh_grid()
	_refresh_spectator_panel()

func _on_slot_swap_confirmed(peer_id: int, _old_team_id: int, _old_slot: int,
		new_team_id: int, new_slot: int,
		_jersey: Color, _helmet: Color, _pants: Color) -> void:
	var identity: Dictionary = _find_peer_identity(peer_id)
	_assign_slot(peer_id, new_team_id, new_slot,
			identity.player_name, identity.is_left_handed, identity.jersey_number)
	_refresh_grid()
	_refresh_spectator_panel()

func _on_lobby_roster_synced(roster: Array) -> void:
	_lobby_slots.clear()
	_ready_states.clear()
	for entry: Array in roster:
		var peer_id: int = entry[0]
		var team_id: int = entry[1]
		var slot: int    = entry[2]
		var p_name: String = entry[3] if entry.size() > 3 else "Player"
		var is_left: bool = entry[4] if entry.size() > 4 else true
		var p_number: int = entry[5] if entry.size() > 5 else 10
		var is_ready: bool = entry[6] if entry.size() > 6 else false
		_lobby_slots[LobbySlotKey.encode(team_id, slot)] = {
			"peer_id": peer_id,
			"player_name": p_name,
			"is_left_handed": is_left,
			"jersey_number": p_number,
		}
		# Host (peer_id 1) doesn't participate in the ready-check.
		if peer_id != 1:
			_ready_states[peer_id] = is_ready
	_update_start_btn()
	_refresh_grid()
	_refresh_spectator_panel()

func _on_player_ready_changed(peer_id: int, is_ready: bool) -> void:
	# Host doesn't need to be ready — only track non-host peers.
	if peer_id == 1:
		return
	_ready_states[peer_id] = is_ready
	if peer_id == NetworkManager.local_peer_id():
		_local_is_ready = is_ready
		_update_ready_btn()
	_update_start_btn()
	_refresh_grid()

func _on_color_vote_changed(peer_id: int, color_slot: int) -> void:
	_color_votes[peer_id] = color_slot
	_refresh_grid()

func _on_color_votes_synced(votes: Dictionary) -> void:
	_color_votes = votes.duplicate()
	# Make sure our own vote is still recorded after a full sync.
	_color_votes[NetworkManager.local_peer_id()] = _my_color_slot
	_refresh_grid()

func _on_kick_requested(peer_id: int, player_name: String) -> void:
	# SlotGridPanel only shows the kick X to the host, but re-check anyway.
	if not NetworkManager.is_host:
		return
	_kick_pending_peer = peer_id
	_kick_confirm.open("Remove %s from the lobby?" % player_name)

func _on_kick_confirmed() -> void:
	if _kick_pending_peer > 0:
		NetworkManager.kick_peer(_kick_pending_peer,
				"You were removed from the lobby by the host.")
	_kick_pending_peer = -1

func _on_bot_toggled(team_id: int, slot: int, is_bot: bool) -> void:
	# Host-only by gating: SlotGridPanel hides the CheckButton on non-hosts so
	# this only fires from the host. send_bot_slot is a no-op on clients.
	if not NetworkManager.is_host:
		return
	NetworkManager.send_bot_slot(LobbySlotKey.encode(team_id, slot), is_bot)

func _on_bot_slot_changed(_key: int, _is_bot: bool) -> void:
	_refresh_grid()

func _on_bot_slots_synced(_bot_slots: Dictionary) -> void:
	_refresh_grid()

func _on_lobby_settings_synced(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int,
		team_size: int, bot_difficulty: int, goalie_difficulty: int) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	_bot_difficulty = bot_difficulty
	_goalie_difficulty = goalie_difficulty
	_apply_team_size(team_size)
	if _settings_panel != null:
		_settings_panel.apply_settings(num_periods, period_duration, ot_enabled, rule_set, team_size,
				bot_difficulty, goalie_difficulty)

func _on_settings_panel_changed(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int,
		team_size: int, bot_difficulty: int, goalie_difficulty: int) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	_bot_difficulty = bot_difficulty
	_goalie_difficulty = goalie_difficulty
	_apply_team_size(team_size)
	NetworkManager.send_lobby_settings(num_periods, period_duration, ot_enabled, rule_set, team_size,
			bot_difficulty, goalie_difficulty)

# Applies a mode (team size) change to the live lobby: resizes the visible
# grid and — host only — evicts anything seated in a slot the new size no
# longer fields (a 5v5 → 3v3 flip with players/bots on LD/RD). Bots retire;
# humans re-seat into the first open slot (spectator gallery as the overflow
# valve so nobody is ever silently dropped).
func _apply_team_size(team_size: int) -> void:
	var changed: bool = team_size != _team_size
	_team_size = team_size
	if _slot_grid != null:
		_slot_grid.set_active_team_size(team_size)
	if not changed or not NetworkManager.is_host:
		_refresh_grid()
		return
	# Retire bots parked beyond the new size.
	for bot_key: int in NetworkManager.pending_bot_slots.keys():
		if NetworkManager.pending_bot_slots[bot_key] \
				and not LobbySlotKey.is_spectator(bot_key) \
				and LobbySlotKey.slot(bot_key) >= team_size:
			NetworkManager.send_bot_slot(bot_key, false)
	# Re-seat humans stranded on now-invalid slots.
	for k: int in _lobby_slots.keys():
		if LobbySlotKey.is_spectator(k) or LobbySlotKey.slot(k) < team_size:
			continue
		var entry: Dictionary = _lobby_slots[k]
		var seat: Array = _find_balanced_slot(entry.peer_id)
		if seat.is_empty():
			var spec_slot: int = _find_open_spectator_slot()
			if spec_slot == -1:
				continue  # nowhere to go; grid will still render the row
			seat = [GameRules.SPECTATOR_TEAM_ID, spec_slot]
		_assign_slot(entry.peer_id, seat[0], seat[1],
				entry.player_name, entry.is_left_handed, entry.jersey_number)
		_broadcast_confirm(entry.peer_id, seat[0], seat[1])
	_refresh_grid()

func _on_game_started(config: Dictionary) -> void:
	NetworkManager.pending_game_config = config
	NetworkManager.pending_lobby_slots = _build_pending_slots()
	get_tree().change_scene_to_file(Constants.SCENE_HOCKEY)

func _build_pending_slots() -> Dictionary:
	var result: Dictionary = {}
	for k: int in _lobby_slots:
		var team_id: int = LobbySlotKey.team_id(k)
		var slot: int = LobbySlotKey.slot(k)
		var entry: Dictionary = _lobby_slots[k]
		result[entry.peer_id] = {
			"team_id": team_id,
			"team_slot": slot,
			"player_name": entry.player_name,
			"is_left_handed": entry.is_left_handed,
			"jersey_number": entry.get("jersey_number", 10),
		}
	return result

func _on_ready_pressed() -> void:
	_local_is_ready = not _local_is_ready
	_update_ready_btn()
	NetworkManager.send_player_ready(_local_is_ready)

func _on_start_pressed() -> void:
	# _home_color_slot / _away_color_slot already reflect the live vote tally —
	# every vote and slot change has been folded in by _refresh_grid →
	# _recompute_resolved_colors. Just ship the current values.
	var config: Dictionary = {
		"num_periods": _num_periods,
		"period_duration": _period_duration,
		"ot_enabled": _ot_enabled,
		"ot_duration": GameRules.OT_DURATION,
		"home_color_slot": _home_color_slot,
		"away_color_slot": _away_color_slot,
		"rule_set": _rule_set,
		"team_size": _team_size,
		# Minted on the host and broadcast via game_start so every peer shares
		# the same id. Used as the .mreplay filename and (Feature C) stored on
		# career_stats rows so a game can be reconstructed across players.
		"game_id": PlayerPrefs.generate_uuid(),
	}
	NetworkManager.send_game_start(config)

func _on_back_pressed() -> void:
	GameManager.return_to_free_play()
