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
# Hot-path lookup tables that mirror `_players[peer_id].team.team_id`,
# maintained alongside `_players` on every spawn / remove / slot-swap.
# AI dispatch and PuckController.poke_check both iterate skaters and
# need O(1) team lookups; the original Callable-resolver pattern paid
# Callable.call overhead in tight loops. Read live by reference —
# consumers receive these once at setup and observe mutations directly.
var team_id_by_peer: Dictionary[int, int] = {}
var team_id_by_skater: Dictionary = {}    # Skater object -> team_id
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
	# Derive is_bot from the peer_id so client-side records (where bots come
	# in via spawn_remote_skater RPC) match host-side records. The flag
	# never crosses the wire — peer_id range is the source of truth.
	record.is_bot = NetworkManager.is_bot_peer(peer_id)
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
	# Resolver-based team lookup so a mid-game slot swap only has to update
	# record.team — the goalie's `carrier.get_team_id()` reads the live value
	# from the registry rather than a cached field that drifts.
	spawned.skater.set_team_id_resolver(func() -> int: return resolve_team_id_for_peer(peer_id))
	spawned.skater.set_player_name(player_name)
	spawned.skater.set_jersey_info(player_name, jersey_number, text_color)
	spawned.skater.set_jersey_stripes(jersey_stripe_color, pants_stripe_color, socks_stripe_color)
	# Square the skater up to the puck on initial spawn — without this they
	# default to Vector2.DOWN (+Z) which leaves team 0 spawning backwards.
	spawned.skater.set_facing(PlayerRules.faceoff_facing(team.team_id))
	_players[peer_id] = record
	team_id_by_peer[peer_id] = team.team_id
	team_id_by_skater[spawned.skater] = team.team_id

	if _spawn_wireup.is_valid():
		_spawn_wireup.call(record)
	player_added.emit(record)
	if not is_local:
		player_joined.emit(record.display_name(), TeamColorRegistry.get_colors(team.color_id, team.team_id).primary)
	return record


# Spawns an AI bot into a team slot. Host-only. Bots get a synthetic peer_id
# in the BOT_ID_BASE range (10000+) so dictionary keying stays int and the
# id is unambiguously non-routable for ENet. Any RPC dispatch must gate on
# NetworkManager.is_real_peer / record.is_bot — peer_id sign is no longer
# a reliable bot indicator (real peers and bots are both positive).
#
# Mirrors spawn() above but skips the human-player surface (handedness pref,
# jersey number from preferences, ready state). Bots get deterministic
# defaults: alternating handedness by slot, jersey numbers 80+slot, name
# "Bot N". Stripe / glove / sock palette is generated the same way as for
# humans via TeamColorRegistry so the visual matches.
func spawn_bot(
		bot_id: int,
		team_slot: int,
		team: Team) -> PlayerRecord:
	assert(bot_id >= 0 and bot_id < 6, "bot_id must be 0..5 (one per team slot)")
	var peer_id: int = NetworkManager.BOT_ID_BASE + bot_id
	var colors: Dictionary = TeamColorRegistry.get_colors(team.color_id, team.team_id)
	var record := PlayerRecord.new(peer_id, team_slot, false, team)
	record.is_bot = true
	record.jersey_color        = colors.jersey
	record.helmet_color        = colors.helmet
	record.pants_color         = colors.pants
	record.jersey_stripe_color = colors.get("jersey_stripe", colors.jersey)
	record.gloves_color        = colors.get("gloves", colors.pants)
	record.pants_stripe_color  = colors.get("pants_stripe", colors.pants)
	record.socks_color         = colors.get("socks", colors.jersey)
	record.socks_stripe_color  = colors.get("socks_stripe", colors.jersey)
	record.secondary_color     = colors.get("secondary", colors.pants)
	record.text_color          = colors.text
	record.text_outline_color  = colors.text_outline
	record.is_left_handed = (team_slot % 2 == 1)
	record.player_name = "Bot %d" % (bot_id + 1)
	record.jersey_number = 80 + bot_id
	var faceoff_pos: Vector3 = PlayerRules.faceoff_position(team.team_id, team_slot)

	var puck: Puck = _puck_getter.call() as Puck
	var blade_color: Color = colors.primary
	var spawned: Dictionary = _spawner.spawn_ai_player(
			faceoff_pos, record.jersey_color, record.helmet_color, record.pants_color,
			record.socks_color, blade_color, record.is_left_handed, puck, _game_state_node)
	record.skater = spawned.skater
	record.controller = spawned.controller
	# Brain lookup: GameManager owns the per-team brains (host-only, indexed
	# by team_id). We're host here (only host runs spawn_bot), so the array
	# is populated by the time this fires.
	var brain: TeamBrain = GameManager.team_brains[team.team_id] if team.team_id < GameManager.team_brains.size() else null
	(spawned.controller as AIController).setup_agent(peer_id, team.team_id, brain, team_id_by_peer, record.is_left_handed)
	# Same resolver-based team lookup as spawn() — see comment there.
	spawned.skater.set_team_id_resolver(func() -> int: return resolve_team_id_for_peer(peer_id))
	spawned.skater.set_player_name(record.player_name)
	spawned.skater.set_jersey_info(record.player_name, record.jersey_number, record.text_color)
	spawned.skater.set_jersey_stripes(record.jersey_stripe_color, record.pants_stripe_color, record.socks_stripe_color)
	# Same initial-facing fix as spawn() — see comment there.
	spawned.skater.set_facing(PlayerRules.faceoff_facing(team.team_id))
	_players[peer_id] = record
	team_id_by_peer[peer_id] = team.team_id
	team_id_by_skater[spawned.skater] = team.team_id

	if _spawn_wireup.is_valid():
		_spawn_wireup.call(record)
	player_added.emit(record)
	player_joined.emit(record.display_name(), colors.primary)
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
	team_id_by_peer.erase(peer_id)
	if record.skater != null:
		team_id_by_skater.erase(record.skater)
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
	team_id_by_peer.clear()
	team_id_by_skater.clear()
