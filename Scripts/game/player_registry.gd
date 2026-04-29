class_name PlayerRegistry
extends RefCounted

# Owns `players: Dictionary[int, PlayerRecord]` — the runtime roster. Pulled
# out of GameManager so spawning / removal / lookups live in one place.
#
# What's here:
#   - unified spawn() for local + remote (previously two 90%-duplicate methods)
#   - skater↔peer↔team resolvers used by puck + puck controller
#   - stats reset, color generation, disconnect cleanup
#
# What's NOT here:
#   - NetworkManager RPC calls — GameManager wires those via the signals below
#     (keeps this class independent of the autoload)
#   - Controller signal wiring to game-orchestration handlers — the owner
#     provides a `SpawnWireup` callback so we don't reach into unrelated
#     subsystems (shot tracker, phase coordinator, etc.)

signal player_added(record: PlayerRecord)
# Fires before the record is freed so subscribers can read every field
# (peer_id, team, colors). Companion to player_added; the player_joined /
# player_left signals stay name+color-only for the existing HUD toast path.
signal player_removed(record: PlayerRecord)
signal player_joined(name: String, team_color: Color)
signal player_left(name: String, team_color: Color)

var _players: Dictionary[int, PlayerRecord] = {}
var _spawner: ActorSpawner = null
var _state_machine: GameStateMachine = null
var _teams: Array[Team] = []
var _puck_getter: Callable = Callable()
var _game_state_node: Node = null
# (record: PlayerRecord) -> void — invoked after spawn so the caller can
# connect controller/skater signals to its own orchestration handlers.
var _spawn_wireup: Callable = Callable()


func setup(
		spawner: ActorSpawner,
		state_machine: GameStateMachine,
		teams: Array[Team],
		puck_getter: Callable,
		game_state_node: Node,
		spawn_wireup: Callable) -> void:
	_spawner = spawner
	_state_machine = state_machine
	_teams = teams
	_puck_getter = puck_getter
	_game_state_node = game_state_node
	_spawn_wireup = spawn_wireup


# ── Spawn ─────────────────────────────────────────────────────────────────────

# Unified local/remote spawn. Local players get a LocalController (input pump
# + reconciliation); remotes get a RemoteController (interpolating).
func spawn(
		peer_id: int,
		team_slot: int,
		team: Team,
		jersey_color: Color,
		helmet_color: Color,
		pants_color: Color,
		jersey_stripe_color: Color,
		gloves_color: Color,
		pants_stripe_color: Color,
		socks_color: Color,
		socks_stripe_color: Color,
		secondary_color: Color,
		text_color: Color,
		text_outline_color: Color,
		is_left_handed: bool,
		player_name: String,
		is_local: bool,
		jersey_number: int = 10) -> PlayerRecord:
	var record := PlayerRecord.new(peer_id, team_slot, is_local, team)
	record.jersey_color        = jersey_color
	record.helmet_color        = helmet_color
	record.pants_color         = pants_color
	record.jersey_stripe_color = jersey_stripe_color
	record.gloves_color        = gloves_color
	record.pants_stripe_color  = pants_stripe_color
	record.socks_color         = socks_color
	record.socks_stripe_color  = socks_stripe_color
	record.secondary_color     = secondary_color
	record.text_color          = text_color
	record.text_outline_color  = text_outline_color
	record.is_left_handed = is_left_handed
	record.player_name = player_name
	record.jersey_number = jersey_number
	var faceoff_pos: Vector3 = PlayerRules.faceoff_position(team.team_id, team_slot)
	record.faceoff_position = faceoff_pos

	var puck: Puck = _puck_getter.call() as Puck
	var blade_color: Color = TeamColorRegistry.get_colors(team.color_id, team.team_id).primary
	var spawned: Dictionary
	if is_local:
		spawned = _spawner.spawn_local_player(
				faceoff_pos, jersey_color, helmet_color, pants_color, socks_color, blade_color,
				is_left_handed, puck, _game_state_node, team.team_id)
	else:
		spawned = _spawner.spawn_remote_player(
				faceoff_pos, jersey_color, helmet_color, pants_color, socks_color, blade_color,
				is_left_handed, puck, _game_state_node)
	record.skater = spawned.skater
	record.controller = spawned.controller
	spawned.skater.team_id = team.team_id
	spawned.skater.set_player_name(player_name)
	spawned.skater.set_jersey_info(player_name, jersey_number, text_color)
	spawned.skater.set_jersey_stripes(jersey_stripe_color, pants_stripe_color, socks_stripe_color)
	_players[peer_id] = record

	if _spawn_wireup.is_valid():
		_spawn_wireup.call(record)
	player_added.emit(record)
	if not is_local:
		player_joined.emit(record.display_name(), TeamColorRegistry.get_colors(team.color_id, team.team_id).primary)
	return record


# Removes a player from the registry and queues their nodes for deletion.
# Returns the removed record (for caller-side cleanup like puck cooldown / RPC),
# or null if the peer wasn't registered.
func remove(peer_id: int) -> PlayerRecord:
	if not _players.has(peer_id):
		return null
	var record: PlayerRecord = _players[peer_id]
	player_left.emit(record.display_name(), TeamColorRegistry.get_colors(record.team.color_id, record.team.team_id).primary)
	player_removed.emit(record)
	_players.erase(peer_id)
	if _state_machine != null:
		_state_machine.on_player_disconnected(peer_id)
	if record.controller:
		record.controller.queue_free()
	if record.skater:
		record.skater.queue_free()
	return record


# ── Lookups ───────────────────────────────────────────────────────────────────

func get_record(peer_id: int) -> PlayerRecord:
	return _players.get(peer_id)


func has(peer_id: int) -> bool:
	return _players.has(peer_id)


func all() -> Dictionary[int, PlayerRecord]:
	return _players


func get_local() -> PlayerRecord:
	for peer_id: int in _players:
		if _players[peer_id].is_local:
			return _players[peer_id]
	return null


func resolve_peer_id(skater: Skater) -> int:
	for peer_id: int in _players:
		if _players[peer_id].skater == skater:
			return peer_id
	return -1


func resolve_team(skater: Skater) -> Team:
	for peer_id: int in _players:
		var record: PlayerRecord = _players[peer_id]
		if record.skater == skater:
			return record.team
	return null


func resolve_team_id(skater: Skater) -> int:
	var team: Team = resolve_team(skater)
	return team.team_id if team != null else -1


func resolve_team_id_for_peer(peer_id: int) -> int:
	var record: PlayerRecord = _players.get(peer_id)
	return record.team.team_id if record != null else -1


# Returns the live players dict as positions for icing/ghost computation.
func positions_by_peer_id() -> Dictionary:
	var positions: Dictionary = {}
	for peer_id: int in _players:
		positions[peer_id] = _players[peer_id].skater.global_position
	return positions


# ── Stats ─────────────────────────────────────────────────────────────────────

func reset_all_stats() -> void:
	for peer_id: int in _players:
		_players[peer_id].stats = PlayerStats.new()


# ── Roster + colors ──────────────────────────────────────────────────────────

static func generate_colors(team_id: int) -> Dictionary:
	var id: String = NetworkManager.pending_home_color_id if team_id == 0 else NetworkManager.pending_away_color_id
	return TeamColorRegistry.get_colors(id, team_id)


# Returns the domain roster enriched with live player names from PlayerRecord.
func get_slot_roster() -> Array[Dictionary]:
	if _state_machine == null:
		return []
	var raw: Array[Dictionary] = _state_machine.get_slot_roster()
	for entry: Dictionary in raw:
		var pid: int = entry.peer_id
		if _players.has(pid):
			var rec: PlayerRecord = _players[pid]
			entry["player_name"]    = rec.display_name()
			entry["jersey_number"]  = rec.jersey_number
			entry["is_left_handed"] = rec.is_left_handed
		else:
			entry["player_name"]    = ""
			entry["jersey_number"]  = 10
			entry["is_left_handed"] = true
	return raw


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func clear_state() -> void:
	_players.clear()
