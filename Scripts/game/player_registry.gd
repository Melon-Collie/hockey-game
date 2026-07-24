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
# Hot-path lookup tables that mirror `_players[peer_id]` fields,
# maintained alongside `_players` on every spawn / remove / slot-swap
# (slot swap mutates team_id_by_* and position_by_peer; peer_id_by_skater
# is stable for the lifetime of the skater).
# AI dispatch and PuckController.poke_check both iterate skaters and
# need O(1) team lookups; the original Callable-resolver pattern paid
# Callable.call overhead in tight loops. Read live by reference —
# consumers receive these once at setup and observe mutations directly.
var team_id_by_peer: Dictionary[int, int] = {}
var team_id_by_skater: Dictionary = {}    # Skater object -> team_id
var peer_id_by_skater: Dictionary = {}    # Skater object -> peer_id
# Per-peer attribute-scaled AI capabilities (AISkaterCaps), so bots model every
# player's REAL build. Same maintenance contract as the tables above — rebuilt
# only on spawn / remove / attribute re-apply (never per tick, since attributes
# change only at spawn or an offline picker change), read live by reference. A
# bot's decision layer looks up caps_by_peer[pid]; a missing entry means the
# league default (unwired / mid-spawn), which reproduces the prior behaviour.
var caps_by_peer: Dictionary[int, AISkaterCaps] = {}
# Live peer_id → lobby team_slot (0–4). team_slot doubles as the position
# identity (C/LW/RW/LD/RD — see PlayerRules.POSITION_NAMES); the 5v5
# TeamBrain reads this by reference for the F/D group split and home-side
# rest bias. Same maintenance contract as team_id_by_peer.
var position_by_peer: Dictionary[int, int] = {}
# Flat skater list for the per-tick scan loops (puck interactions, goalie
# crease-jam checks). Rebuilt on spawn/remove; consumers read the live
# reference through their skater-getter Callable and must not mutate it.
# Rebuilding per call allocated two arrays per invocation at the physics rate.
var _skaters_cache: Array[Skater] = []
# Flat bot-controller list for the centralized AI dispatch loop (AICoordinator
# path). Rebuilt on spawn/remove alongside _skaters_cache; the host iterates it
# once per tick instead of scanning _players for AIControllers. Bots are
# host-only, so this is empty on clients.
var _ai_controllers_cache: Array[AIController] = []
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
		jersey_number: int = 10,
		attributes: PlayerAttributes = null) -> PlayerRecord:
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
	record.attributes = attributes if attributes != null else PlayerAttributes.all_average()
	var faceoff_pos: Vector3 = PlayerRules.faceoff_position(team.team_id, team_slot)

	var puck: Puck = _puck_getter.call() as Puck
	# Look up the full v2 uniform locally — the wire-supplied jersey/helmet/
	# pants args above are kept for record bookkeeping but the painter reads
	# the local team_colors.json (so stripes and shoulder/arm detail come
	# from the same source as the base colors).
	var colors: Dictionary = TeamColorRegistry.get_colors(team.color_slot, team.team_id)
	var spawned: Dictionary
	if is_local:
		spawned = _spawner.spawn_local_player(
				faceoff_pos, is_left_handed, puck, _game_state_node, team.team_id, record.attributes)
	else:
		spawned = _spawner.spawn_remote_player(
				faceoff_pos, is_left_handed, puck, _game_state_node, record.attributes)
	record.skater = spawned.skater
	record.controller = spawned.controller
	# Resolver-based team lookup so a mid-game slot swap only has to update
	# record.team — the goalie's `carrier.get_team_id()` reads the live value
	# from the registry rather than a cached field that drifts.
	spawned.skater.set_team_id_resolver(func() -> int: return resolve_team_id_for_peer(peer_id))
	# Analytic skater-vs-skater contact iterates the cached skater list (skaters are
	# off each other's move_and_slide mask now — see Skater._resolve_player_collisions).
	# peer_id is the machine-stable tiebreak for the aggressor gate's head-on case.
	spawned.skater.set_skater_collision_provider(skaters)
	spawned.skater.collision_tiebreak_id = peer_id
	spawned.skater.set_player_name(player_name)
	spawned.skater.set_uniform(colors)
	spawned.skater.set_jersey_info(player_name, jersey_number)
	# Square the skater up to the puck on initial spawn — without this they
	# default to Vector2.DOWN (+Z) which leaves team 0 spawning backwards.
	# Through the CONTROLLER, not the skater directly: both facing stores
	# (root rotation + pose coordinator) must agree, or the first input tick
	# snaps the root back to the pose default and the player spawns twisted.
	spawned.controller.set_spawn_facing(PlayerRules.faceoff_facing(team.team_id))
	_players[peer_id] = record
	team_id_by_peer[peer_id] = team.team_id
	position_by_peer[peer_id] = record.team_slot
	team_id_by_skater[spawned.skater] = team.team_id
	peer_id_by_skater[spawned.skater] = peer_id
	refresh_caps(peer_id)
	# Slot-ring tint by relationship to the local player. Same resolver style as
	# the team lookup above — reads live so it survives slot swaps.
	spawned.skater.set_ring_relation_resolver(func() -> int: return ring_relation_for_peer(peer_id))

	if _spawn_wireup.is_valid():
		_spawn_wireup.call(record)
	_rebuild_skaters_cache()
	player_added.emit(record)
	if not is_local:
		player_joined.emit(record.display_name(), TeamColorRegistry.get_colors(team.color_slot, team.team_id).primary)
	return record


# Spawns an AI bot into a team slot. Host-only. Bots get a synthetic peer_id
# in the BOT_ID_BASE range (10000+) so dictionary keying stays int and the
# id is unambiguously non-routable for ENet. Any RPC dispatch must gate on
# NetworkManager.is_real_peer / record.is_bot — peer_id sign is no longer
# a reliable bot indicator (real peers and bots are both positive).
#
# Mirrors spawn() above but skips the human-player surface (handedness pref,
# jersey number from preferences, ready state). When `identity` is non-empty,
# its name / number / handedness are used; otherwise bots fall back to
# deterministic defaults: alternating handedness by slot, jersey numbers
# 80+slot, name "Bot N". Stripe / glove / sock palette is generated the same
# way as for humans via TeamColorRegistry so the visual matches.
func spawn_bot(
		bot_id: int,
		team_slot: int,
		team: Team,
		identity: Dictionary = {}) -> PlayerRecord:
	assert(bot_id >= 0 and bot_id < 10, "bot_id must be 0..9 (one per team slot)")
	var peer_id: int = NetworkManager.BOT_ID_BASE + bot_id
	var colors: Dictionary = TeamColorRegistry.get_colors(team.color_slot, team.team_id)
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
	if identity.is_empty():
		record.is_left_handed = (team_slot % 2 == 1)
		record.player_name = "Bot %d" % (bot_id + 1)
		record.jersey_number = 80 + bot_id
		record.attributes = PlayerAttributes.all_average()
	else:
		record.is_left_handed = identity.get("is_left_handed", team_slot % 2 == 1)
		record.player_name = identity.get("name", "Bot %d" % (bot_id + 1))
		record.jersey_number = identity.get("number", 80 + bot_id)
		# Identity dicts are normalized by BotIdentityRegistry to the native
		# height/weight/gear keys; from_dict also migrates tier-era and legacy
		# six-attribute roster on the fly.
		record.attributes = PlayerAttributes.from_dict(identity)
	var faceoff_pos: Vector3 = PlayerRules.faceoff_position(team.team_id, team_slot)

	var puck: Puck = _puck_getter.call() as Puck
	var spawned: Dictionary = _spawner.spawn_ai_player(
			faceoff_pos, record.is_left_handed, puck, _game_state_node, record.attributes)
	record.skater = spawned.skater
	record.controller = spawned.controller
	# Brain lookup: GameManager owns the per-team brains (host-only, indexed
	# by team_id). We're host here (only host runs spawn_bot), so the array
	# is populated by the time this fires.
	var brain: TeamBrain = GameManager.team_brains[team.team_id] if team.team_id < GameManager.team_brains.size() else null
	(spawned.controller as AIController).setup_agent(peer_id, team.team_id, brain, team_id_by_peer, record.is_left_handed, GameManager.bot_skill_profile, caps_by_peer)
	# Same resolver-based team lookup as spawn() — see comment there.
	spawned.skater.set_team_id_resolver(func() -> int: return resolve_team_id_for_peer(peer_id))
	# See spawn() — analytic skater-vs-skater contact iterates the cached skater list.
	spawned.skater.set_skater_collision_provider(skaters)
	spawned.skater.collision_tiebreak_id = peer_id
	spawned.skater.set_player_name(record.player_name)
	spawned.skater.set_uniform(colors)
	spawned.skater.set_jersey_info(record.player_name, record.jersey_number)
	# Same initial-facing fix as spawn() — and through the CONTROLLER for the
	# same reason: setting only the skater leaves the pose coordinator's
	# facing store at its default, and the first input tick snaps the root
	# back to it — the bot spawns twisted π off and the gait plays in the
	# wrong body frame until its aim re-tracks.
	spawned.controller.set_spawn_facing(PlayerRules.faceoff_facing(team.team_id))
	_players[peer_id] = record
	team_id_by_peer[peer_id] = team.team_id
	position_by_peer[peer_id] = record.team_slot
	team_id_by_skater[spawned.skater] = team.team_id
	peer_id_by_skater[spawned.skater] = peer_id
	refresh_caps(peer_id)
	# Same slot-ring relationship tint as spawn() — see comment there.
	spawned.skater.set_ring_relation_resolver(func() -> int: return ring_relation_for_peer(peer_id))

	if _spawn_wireup.is_valid():
		_spawn_wireup.call(record)
	_rebuild_skaters_cache()
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
	player_left.emit(record.display_name(), TeamColorRegistry.get_colors(record.team.color_slot, record.team.team_id).primary)
	player_removed.emit(record)
	_players.erase(peer_id)
	team_id_by_peer.erase(peer_id)
	caps_by_peer.erase(peer_id)
	position_by_peer.erase(peer_id)
	if record.skater != null:
		team_id_by_skater.erase(record.skater)
		peer_id_by_skater.erase(record.skater)
	_rebuild_skaters_cache()
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


# Live reference to the cached skater list — consumers must not mutate it.
func skaters() -> Array[Skater]:
	return _skaters_cache


# Live reference to the cached bot-controller list — consumers must not mutate
# it. Drives the host's centralized per-tick AI dispatch.
func ai_controllers() -> Array[AIController]:
	return _ai_controllers_cache


func _rebuild_skaters_cache() -> void:
	_skaters_cache.clear()
	_ai_controllers_cache.clear()
	for r: PlayerRecord in _players.values():
		if r.skater != null:
			_skaters_cache.append(r.skater)
		if r.controller is AIController:
			_ai_controllers_cache.append(r.controller as AIController)


# (Re)build the memoized AI capabilities for one peer from its controller's
# current scaled values. Called on spawn and whenever attributes re-apply (the
# offline free-play picker) — never per tick. Bots hold caps_by_peer by live
# reference, so refreshing an entry is seen without re-wiring.
func refresh_caps(peer_id: int) -> void:
	var record: PlayerRecord = _players.get(peer_id)
	if record != null and record.controller != null:
		caps_by_peer[peer_id] = record.controller.build_ai_caps()


func all() -> Dictionary[int, PlayerRecord]:
	return _players


func get_local() -> PlayerRecord:
	for peer_id: int in _players:
		if _players[peer_id].is_local:
			return _players[peer_id]
	return null


func resolve_peer_id(skater: Skater) -> int:
	if skater == null:
		return -1
	return peer_id_by_skater.get(skater, -1)


func resolve_team(skater: Skater) -> Team:
	var pid: int = resolve_peer_id(skater)
	if pid == -1:
		return null
	var record: PlayerRecord = _players.get(pid)
	return record.team if record != null else null


func resolve_team_id(skater: Skater) -> int:
	if skater == null:
		return -1
	return team_id_by_skater.get(skater, -1)


func resolve_team_id_for_peer(peer_id: int) -> int:
	var record: PlayerRecord = _players.get(peer_id)
	return record.team.team_id if record != null else -1


# Relationship of the given peer's skater to the LOCAL player, for HUD slot-ring
# coloring (self / teammate / enemy). Read live each refresh so a late-spawning
# local player and mid-game slot swaps self-correct. Returns UNKNOWN until the
# local player and both team ids are known, leaving the ring its neutral tint.
func ring_relation_for_peer(peer_id: int) -> int:
	var local: PlayerRecord = get_local()
	if local == null:
		return SkaterHUDCoordinator.RingRelation.UNKNOWN
	if local.peer_id == peer_id:
		return SkaterHUDCoordinator.RingRelation.SELF
	var my_team: int = resolve_team_id_for_peer(peer_id)
	var local_team: int = resolve_team_id_for_peer(local.peer_id)
	if my_team == -1 or local_team == -1:
		return SkaterHUDCoordinator.RingRelation.UNKNOWN
	return SkaterHUDCoordinator.RingRelation.TEAMMATE if my_team == local_team \
			else SkaterHUDCoordinator.RingRelation.ENEMY


# Returns the live players dict as positions for icing/ghost computation.
func positions_by_peer_id() -> Dictionary:
	var positions: Dictionary = {}
	fill_positions_by_peer_id(positions)
	return positions


# Caller-owned-dictionary variant for per-tick callers (ghost state, icing
# check) so the per-tick host loop doesn't allocate a Dictionary per call.
func fill_positions_by_peer_id(out: Dictionary) -> void:
	out.clear()
	for peer_id: int in _players:
		out[peer_id] = _players[peer_id].skater.global_position


# ── Stats ─────────────────────────────────────────────────────────────────────

func reset_all_stats() -> void:
	for peer_id: int in _players:
		_players[peer_id].stats = PlayerStats.new()


# ── Roster + colors ──────────────────────────────────────────────────────────

static func generate_colors(team_id: int) -> Dictionary:
	var slot: int = NetworkManager.pending_home_color_slot if team_id == 0 else NetworkManager.pending_away_color_slot
	return TeamColorRegistry.get_colors(slot, team_id)


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
	position_by_peer.clear()
	team_id_by_skater.clear()
	peer_id_by_skater.clear()
	_skaters_cache.clear()
	_ai_controllers_cache.clear()
