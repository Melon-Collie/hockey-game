class_name LobbyManager
extends Node

const _WHITE     := MenuStyle.TEXT_BODY
const _DIM       := MenuStyle.TEXT_DIM

const _SETTING_CONTROL_WIDTH: int = 220

# key = LobbySlotKey.encode(team_id, slot)  →  { peer_id, player_name, is_left_handed, jersey_number }
# Players: team_id ∈ {0, 1}, slot ∈ {0,1,2}. Spectators: team_id = -1, slot = spectator_idx.
var _lobby_slots: Dictionary = {}

var _slot_grid: SlotGridPanel = null
var _start_btn: Button = null
var _ready_btn: Button = null
var _settings_panel: LobbySettingsPanel = null
var _spectator_list_label: Label = null
var _spectator_join_btn: Button = null

# key = peer_id → bool; tracks non-host peers only (host uses Start instead)
var _ready_states: Dictionary = {}
var _local_is_ready: bool = false

# Settings (host only editable; all players see them)
var _num_periods: int = GameRules.NUM_PERIODS
var _period_duration: float = GameRules.PERIOD_DURATION
var _ot_enabled: bool = GameRules.OT_ENABLED
var _rule_set: int = GameRules.DEFAULT_RULE_SET

# Team color presets used as placeholders in the lobby slot-grid preview.
# Real per-team colors are resolved from votes at game start.
var _home_color_id: String = TeamColorRegistry.DEFAULT_HOME_ID
var _away_color_id: String = TeamColorRegistry.DEFAULT_AWAY_ID

# Local player's current color vote + a mirror of every player's vote so
# everyone in the lobby can see who voted for what. Host is authoritative;
# clients receive updates via NetworkManager.color_vote_changed.
var _my_color_id: String = TeamColorRegistry.DEFAULT_HOME_ID
var _color_votes: Dictionary = {}  # peer_id → color_id
var _my_color_btn: OptionButton = null
var _color_vote_row: Control = null

func _ready() -> void:
	_home_color_id = NetworkManager.pending_home_color_id
	_away_color_id = NetworkManager.pending_away_color_id
	_num_periods = NetworkManager.pending_num_periods
	_period_duration = NetworkManager.pending_period_duration
	_ot_enabled = NetworkManager.pending_ot_enabled
	_rule_set = NetworkManager.pending_rule_set
	_my_color_id = _initial_color_preference()
	_color_votes = NetworkManager.pending_color_votes.duplicate()
	_build_ui()
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	NetworkManager.slot_swap_requested.connect(_on_slot_swap_requested)
	NetworkManager.slot_swap_confirmed.connect(_on_slot_swap_confirmed)
	NetworkManager.lobby_roster_synced.connect(_on_lobby_roster_synced)
	NetworkManager.game_started.connect(_on_game_started)
	NetworkManager.color_vote_changed.connect(_on_color_vote_changed)
	NetworkManager.color_votes_synced.connect(_on_color_votes_synced)
	NetworkManager.bot_slot_changed.connect(_on_bot_slot_changed)
	NetworkManager.bot_slots_synced.connect(_on_bot_slots_synced)
	NetworkManager.lobby_settings_synced.connect(_on_lobby_settings_synced)
	NetworkManager.player_ready_changed.connect(_on_player_ready_changed)

	# Submit our own vote into the shared map so the host (and other peers)
	# count it. send_color_vote handles both host-local and client-RPC paths.
	# Offline mode skips this — the color vote pool stays empty, the picks
	# made in the main menu (pending_home/away_color_id) are kept verbatim.
	if not NetworkManager.is_offline_mode:
		NetworkManager.send_color_vote(_my_color_id)

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

func _initial_color_preference() -> String:
	var saved: String = PlayerPrefs.preferred_color_id
	if saved.is_empty():
		return TeamColorRegistry.DEFAULT_HOME_ID
	if not TeamColorRegistry.get_all_ids().has(saved):
		return TeamColorRegistry.DEFAULT_HOME_ID
	return saved

# ── UI ────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 10
	add_child(canvas)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.04, 0.06, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var panel_style := MenuStyle.panel()

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

	var title := Label.new()
	title.text = "LOBBY"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", _WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_color_vote_row = _build_color_vote_row()
	# Hide the per-player color vote in offline mode — colors come from
	# the "With Bots" popup directly, no votes to cast.
	_color_vote_row.visible = not NetworkManager.is_offline_mode
	vbox.add_child(_color_vote_row)

	_slot_grid = SlotGridPanel.new()
	_slot_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot_grid.slot_selected.connect(_on_slot_selected)
	_slot_grid.bot_toggled.connect(_on_bot_toggled)
	vbox.add_child(_slot_grid)

	vbox.add_child(_build_spectator_panel())

	_settings_panel = LobbySettingsPanel.new(_num_periods, _period_duration, _ot_enabled, _rule_set, NetworkManager.is_host)
	_settings_panel.settings_changed.connect(_on_settings_panel_changed)
	vbox.add_child(_settings_panel)

	var btn_box := HBoxContainer.new()
	btn_box.add_theme_constant_override("separation", 12)
	btn_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_box)

	var back_btn := _btn("Back to Menu")
	back_btn.pressed.connect(_on_back_pressed)
	btn_box.add_child(back_btn)

	if NetworkManager.is_host:
		_start_btn = _btn("Start Game")
		_start_btn.pressed.connect(_on_start_pressed)
		_start_btn.disabled = true
		_start_btn.modulate = Color(1, 1, 1, 0.5)
		btn_box.add_child(_start_btn)
	else:
		_ready_btn = _btn("Ready")
		_ready_btn.pressed.connect(_on_ready_pressed)
		btn_box.add_child(_ready_btn)

	_refresh_grid()
	_refresh_spectator_panel()

# Spectator slots sit below the 3v3 slot grid. The list shows everyone currently
# spectating; the button toggles the local peer between "playing slot" and
# "spectator slot" — the host's slot-swap path validates and broadcasts.
func _build_spectator_panel() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	_spectator_list_label = Label.new()
	_spectator_list_label.add_theme_font_size_override("font_size", 13)
	_spectator_list_label.add_theme_color_override("font_color", _DIM)
	_spectator_list_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spectator_list_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_spectator_list_label)

	_spectator_join_btn = _btn("Spectate")
	_spectator_join_btn.pressed.connect(_on_spectate_pressed)
	row.add_child(_spectator_join_btn)

	return box

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
	# Hide the row entirely so the UI doesn't suggest the dropdown does anything.
	# In offline mode it's always hidden — colors come from the With Bots popup.
	if _color_vote_row != null:
		_color_vote_row.visible = not local_is_spectator and not NetworkManager.is_offline_mode

func _on_spectate_pressed() -> void:
	var open: int = _find_open_spectator_slot()
	if open < 0:
		return
	NetworkManager.send_request_slot_swap(GameRules.SPECTATOR_TEAM_ID, open)

# Builds the live color-vote row that sits above the slot grid. Every player
# votes for their own team's color; both teams' resolved colors are recomputed
# on every vote change and reflected in the slot-grid preview below.
# Resolution is sticky — a previous winner that's still tied for the lead
# stays put, so the displayed colors don't flicker when unrelated votes shift.
func _build_color_vote_row() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)

	var lbl := Label.new()
	lbl.text = "Team Color"
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", _DIM)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	_my_color_btn = MenuStyle.color_option_btn(_my_color_id, Vector2(_SETTING_CONTROL_WIDTH, 40), 16)
	SoundManager.wire_button(_my_color_btn)
	_my_color_btn.item_selected.connect(func(idx: int) -> void:
		_my_color_id = TeamColorRegistry.get_all_ids()[idx]
		PlayerPrefs.preferred_color_id = _my_color_id
		PlayerPrefs.save()
		NetworkManager.send_color_vote(_my_color_id))
	row.add_child(_my_color_btn)

	return row


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
		for s: int in PlayerRules.MAX_PER_TEAM:
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
		TeamColorRegistry.get_colors(_home_color_id, 0),
		TeamColorRegistry.get_colors(_away_color_id, 1),
	]

func _refresh_grid() -> void:
	if _slot_grid == null:
		return
	_recompute_resolved_colors()
	_slot_grid.refresh(_build_slot_grid_roster(), NetworkManager.local_peer_id(), _get_team_colors(),
			NetworkManager.pending_bot_slots, NetworkManager.is_host)
	_refresh_spectator_panel()

# Live vote resolution. Walks the current roster, buckets each player's vote
# onto their currently assigned team, then asks ColorVoteRules for the new
# (home, away) pair — passing the previous winners as sticky hints so an
# already-tied lead doesn't re-roll on every unrelated vote change.
func _recompute_resolved_colors() -> void:
	# Offline mode: no per-player vote pool to resolve. Keep
	# _home_color_id / _away_color_id at their init values (seeded from
	# NetworkManager.pending_home/away_color_id, which the main menu
	# "With Bots" popup wrote).
	if NetworkManager.is_offline_mode:
		return
	var home_votes: Array[String] = []
	var away_votes: Array[String] = []
	for k: int in _lobby_slots:
		if LobbySlotKey.is_spectator(k):
			continue
		var entry: Dictionary = _lobby_slots[k]
		var peer_id: int = entry.peer_id
		if not _color_votes.has(peer_id):
			continue
		var team_id: int = LobbySlotKey.team_id(k)
		var vote: String = _color_votes[peer_id]
		if team_id == 0:
			home_votes.append(vote)
		else:
			away_votes.append(vote)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var resolved: Array[String] = ColorVoteRules.resolve_team_colors(
			home_votes, away_votes,
			TeamColorRegistry.get_all_ids(),
			TeamColorRegistry.DEFAULT_HOME_ID,
			TeamColorRegistry.DEFAULT_AWAY_ID,
			rng,
			_home_color_id,
			_away_color_id)
	_home_color_id = resolved[0]
	_away_color_id = resolved[1]

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
	var color_id: String = _home_color_id if team_id == 0 else _away_color_id
	var colors: Dictionary = TeamColorRegistry.get_colors(color_id, team_id)
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
	_ready_btn.text = "Unready" if _local_is_ready else "Ready"

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
	NetworkManager.send_lobby_settings_to(peer_id, _num_periods, _period_duration, _ot_enabled, _rule_set)
	NetworkManager.send_bot_slots_to(peer_id, NetworkManager.pending_bot_slots)
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
		if count >= PlayerRules.MAX_PER_TEAM:
			return
	var identity: Dictionary = _find_peer_identity(peer_id)
	_assign_slot(peer_id, new_team_id, new_slot,
			identity.player_name, identity.is_left_handed, identity.jersey_number)
	_broadcast_confirm(peer_id, new_team_id, new_slot)
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

func _on_color_vote_changed(peer_id: int, color_id: String) -> void:
	_color_votes[peer_id] = color_id
	_refresh_grid()

func _on_color_votes_synced(votes: Dictionary) -> void:
	_color_votes = votes.duplicate()
	# Make sure our own vote is still recorded after a full sync.
	_color_votes[NetworkManager.local_peer_id()] = _my_color_id
	_refresh_grid()

func _on_bot_toggled(team_id: int, slot: int, is_bot: bool) -> void:
	# Host-only by gating: SlotGridPanel hides the CheckButton on non-hosts so
	# this only fires from the host. send_bot_slot is a no-op on clients.
	if not NetworkManager.is_host:
		return
	NetworkManager.send_bot_slot(team_id * 3 + slot, is_bot)

func _on_bot_slot_changed(_key: int, _is_bot: bool) -> void:
	_refresh_grid()

func _on_bot_slots_synced(_bot_slots: Dictionary) -> void:
	_refresh_grid()

func _on_lobby_settings_synced(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	if _settings_panel != null:
		_settings_panel.apply_settings(num_periods, period_duration, ot_enabled, rule_set)

func _on_settings_panel_changed(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int) -> void:
	_num_periods = num_periods
	_period_duration = period_duration
	_ot_enabled = ot_enabled
	_rule_set = rule_set
	NetworkManager.send_lobby_settings(num_periods, period_duration, ot_enabled, rule_set)

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
	# _home_color_id / _away_color_id already reflect the live vote tally —
	# every vote and slot change has been folded in by _refresh_grid →
	# _recompute_resolved_colors. Just ship the current values.
	var config: Dictionary = {
		"num_periods": _num_periods,
		"period_duration": _period_duration,
		"ot_enabled": _ot_enabled,
		"ot_duration": GameRules.OT_DURATION,
		"home_color_id": _home_color_id,
		"away_color_id": _away_color_id,
		"rule_set": _rule_set,
		# Minted on the host and broadcast via game_start so every peer shares
		# the same id. Used as the .mreplay filename and (Feature C) stored on
		# career_stats rows so a game can be reconstructed across players.
		"game_id": PlayerPrefs.generate_uuid(),
	}
	NetworkManager.send_game_start(config)

func _on_back_pressed() -> void:
	GameManager.exit_to_main_menu()
