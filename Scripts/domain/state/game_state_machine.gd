class_name GameStateMachine
extends RefCounted

# Pure-domain state owned by the FSM:
#   - current phase + timer
#   - scores
#   - player slot registry (peer_id → {team_slot, team_id})
#   - icing state + last carrier tracking
#   - ghost computation (uses InfractionRules + dead-puck check)
#
# GameManager still owns infrastructure: references to actors, the PlayerRecord
# with node refs, RPC sending, signal emission. It calls state-machine methods
# and reacts to the outcomes (what phase are we in? did something transition?).
#
# The state machine exists on both host and client. On the host, GameManager
# drives it with tick(delta). On the client, apply_remote_state() syncs it
# from world-state broadcasts.

# ── Phase + timer ────────────────────────────────────────────────────────────
var current_phase: int = GamePhase.Phase.PLAYING
var _phase_timer: float = 0.0

# XZ dot where the next/current faceoff is held. Set by begin_faceoff_prep
# (default center ice); read by PhaseCoordinator to position puck + players.
var active_faceoff_dot: Vector2 = GameRules.CENTER_ICE_DOT

# ── Period + clock ───────────────────────────────────────────────────────────
var current_period: int   = 1
var time_remaining: float = GameRules.PERIOD_DURATION
var infinite_time: bool   = false

# ── Configurable rules (overridden by lobby; default to GameRules constants) ─
var num_periods: int       = GameRules.NUM_PERIODS
var period_duration: float = GameRules.PERIOD_DURATION
var ot_enabled: bool       = GameRules.OT_ENABLED
var ot_duration: float     = GameRules.OT_DURATION
var rule_set: int          = GameRules.DEFAULT_RULE_SET

# ── Scores ───────────────────────────────────────────────────────────────────
var scores: Array[int] = [0, 0]
var last_scoring_team_id: int = -1
var team_shots: Array[int] = [0, 0]
var period_scores: Array[Array] = []  # [team_id][period_index 0-based]; grows dynamically in OT; set in _init

# ── Player registry (domain view) ────────────────────────────────────────────
# peer_id → { team_slot: int, team_id: int }. faceoff_position is derived
# on demand via PlayerRules.faceoff_position(team_id, team_slot, active_dot).
var players: Dictionary[int, Dictionary] = {}

# ── Icing ────────────────────────────────────────────────────────────────────
var last_carrier_team_id: int = -1
var last_carrier_z: float = 0.0
# Last carrier's X — used to pick the side of the offending team's defensive
# zone for the NHL icing faceoff dot.
var last_carrier_x: float = 0.0
var icing_team_id: int = -1
var _icing_timer: float = 0.0

# ── Offsides ─────────────────────────────────────────────────────────────────
# ARCADE path: peer IDs currently serving an offside ghost. Cleared by tagging
# up (crossing back into neutral zone) or by a dead-puck phase.
var _offside_peer_ids: Dictionary = {}
# NHL delayed-offside path: peers who entered their attacking zone before the
# puck and have not yet tagged up. Tracked separately so we don't ghost them.
var _delayed_offside_peer_ids: Dictionary = {}
# Set to a team_id when there is at least one offside peer on that team AND
# the puck is in their attacking zone — i.e. an NHL delayed-offside is active
# and any touch by that team will whistle the play dead.
var delayed_offside_team_id: int = -1
# Stashed at update_delayed_offside time so notify_puck_touch can build the
# offside faceoff dot without re-receiving the puck position.
var _last_puck_x: float = 0.0

# ── Crease protection ─────────────────────────────────────────────────────────
# peer_id → seconds the skater has continuously dwelt inside a goalie crease.
# Accumulates while in the paint, resets (key erased) on exit. Once it reaches
# GameRules.CREASE_DWELL_DURATION the skater is ghosted until they leave — the
# crease boundary is the "tag-up line". Advanced inside compute_ghost_state
# (the one per-tick path that has every player's position). Active in ARCADE
# and NHL; cleared on OFF and during dead-puck phases like the offside set.
var _crease_dwell: Dictionary[int, float] = {}

# ── Pending faceoff ──────────────────────────────────────────────────────────
# When the domain decides a stoppage should fire (NHL icing confirmed, NHL
# offside touch), it stashes the dot + reason here for GameManager to consume
# in the same tick and route through the whistle + faceoff_prep pipeline.
enum FaceoffReason { NONE, ICING, OFFSIDE }
var pending_faceoff_dot: Vector2 = Vector2.ZERO
var pending_faceoff_reason: int = FaceoffReason.NONE


func _init() -> void:
	period_scores = _make_period_scores(num_periods)

static func _make_period_scores(count: int) -> Array[Array]:
	var arr: Array[int] = []
	arr.resize(count)
	arr.fill(0)
	return [arr.duplicate(), arr.duplicate()]


# ── Frame tick (host only) ───────────────────────────────────────────────────
# Returns true if the phase changed this tick, so GameManager knows to fire
# phase-entry side effects.
func tick(delta: float) -> bool:
	_tick_icing(delta)
	return _tick_phase(delta)


# ── Events from infrastructure ───────────────────────────────────────────────

# Returns the scoring team id (0 or 1), or -1 if the goal is ignored (wrong phase).
# Enters GOAL_CELEBRATION rather than GOAL_SCORED directly — celebration is the
# movement-allowed beat with banner + VFX; the state machine auto-advances to
# GOAL_SCORED (and the replay cinematic) after GOAL_CELEBRATION_DURATION.
func on_goal_scored(defending_team_id: int) -> int:
	if current_phase != GamePhase.Phase.PLAYING:
		return -1
	var scoring_team_id: int = 1 - defending_team_id
	scores[scoring_team_id] += 1
	period_scores[scoring_team_id][current_period - 1] += 1
	last_scoring_team_id = scoring_team_id
	_set_phase(GamePhase.Phase.GOAL_CELEBRATION)
	return scoring_team_id


# Drives the state machine forward from GOAL_SCORED. Sudden-death OT (any
# period past num_periods) ends the game here; otherwise we cycle to
# FACEOFF_PREP for the next play. Used by both the timer-driven advance in
# tick() and external callers (GoalReplayDriver finishing) that need to
# bypass the timer because tick() is gated during is_replay_mode.
func advance_post_goal() -> void:
	if current_phase != GamePhase.Phase.GOAL_SCORED:
		return
	if _is_ot_period():
		_set_phase(GamePhase.Phase.GAME_OVER)
	else:
		active_faceoff_dot = GameRules.CENTER_ICE_DOT
		_set_phase(GamePhase.Phase.FACEOFF_PREP)


# Called when a puck is picked up during FACEOFF phase. Returns true if it
# caused the transition back to PLAYING.
func on_faceoff_puck_picked_up() -> bool:
	if current_phase != GamePhase.Phase.FACEOFF:
		return false
	_set_phase(GamePhase.Phase.PLAYING)
	return true

# Host-side: called every physics frame while the puck has a carrier. Tracks
# carrier info for icing detection. Any pickup clears active icing (opponent
# pickup instantly resets; same-team pickup just refreshes the tracker).
func notify_puck_carried(carrier_team_id: int, carrier_z: float, carrier_x: float = 0.0) -> void:
	last_carrier_team_id = carrier_team_id
	last_carrier_z = carrier_z
	last_carrier_x = carrier_x
	if icing_team_id != -1 and carrier_team_id != icing_team_id:
		icing_team_id = -1
		_icing_timer = 0.0

# Host-side: called when a loose puck is touched by any player (deflection,
# body block, poke check, body check strip). Clears the icing tracker so the
# touch is not counted as an intentional ice.
func notify_icing_contact() -> void:
	last_carrier_team_id = -1

# Host-side: called every physics frame when the puck is loose. Detects icing
# and applies the hybrid-icing race: compares each team's closest player to the
# crossed goal line. Icing is confirmed immediately if the defending team wins;
# waved off if the icing team's player is closer.
func check_icing_for_loose_puck(
		puck_z: float, player_positions: Dictionary = {}) -> void:
	if rule_set != GameRules.RuleSet.NHL:
		return
	if current_phase != GamePhase.Phase.PLAYING:
		return
	if icing_team_id != -1:
		return
	var offender: int = InfractionRules.check_icing(last_carrier_team_id, last_carrier_z, puck_z)
	if offender == -1:
		return

	# Hybrid icing race: find each team's closest player to the end-zone faceoff dot.
	var dot_z: float = -GameRules.ICING_FACEOFF_DOT_Z if offender == 0 else GameRules.ICING_FACEOFF_DOT_Z
	var icing_min_dist: float = INF
	var defending_min_dist: float = INF
	for peer_id in player_positions:
		if not players.has(peer_id):
			continue
		var team_id: int = players[peer_id].team_id
		var dist: float = abs(player_positions[peer_id].z - dot_z)
		if team_id == offender:
			icing_min_dist = min(icing_min_dist, dist)
		else:
			defending_min_dist = min(defending_min_dist, dist)

	if InfractionRules.defending_wins_icing_race(icing_min_dist, defending_min_dist):
		icing_team_id = offender
		_icing_timer = GameRules.ICING_GHOST_DURATION
		pending_faceoff_dot = GameRules.icing_faceoff_dot(offender, last_carrier_x)
		pending_faceoff_reason = FaceoffReason.ICING

	last_carrier_team_id = -1

# Host-side: compute ghost state for all players. Returns {peer_id: should_ghost}.
func compute_ghost_state(
		player_positions: Dictionary,
		puck_carrier_peer_id: int,
		puck_position: Vector3,
		delta: float = 0.0) -> Dictionary:
	var result: Dictionary = {}
	# OFF preset disables every infraction-driven ghost.
	if rule_set == GameRules.RuleSet.OFF:
		_offside_peer_ids.clear()
		_crease_dwell.clear()
		for peer_id in player_positions:
			result[peer_id] = false
		return result
	var is_active_play: bool = (current_phase == GamePhase.Phase.PLAYING
			or current_phase == GamePhase.Phase.FACEOFF)
	if not is_active_play:
		_offside_peer_ids.clear()
		_crease_dwell.clear()
		for peer_id in player_positions:
			result[peer_id] = false
		return result
	# NHL replaces the per-player offside ghost with delayed-offside + whistle
	# (driven by update_delayed_offside + notify_puck_touch), so the offside
	# branch only runs for ARCADE here.
	var ghost_for_offside: bool = rule_set != GameRules.RuleSet.NHL
	for peer_id in player_positions:
		if not players.has(peer_id):
			result[peer_id] = false
			continue
		var slot: Dictionary = players[peer_id]
		var pos_z: float = player_positions[peer_id].z
		var ghost: bool = false
		if ghost_for_offside:
			if _offside_peer_ids.has(peer_id):
				# Already serving offside — hold until they tag up at the blue line.
				if InfractionRules.has_tagged_up(pos_z, slot.team_id):
					_offside_peer_ids.erase(peer_id)
				else:
					ghost = true
			else:
				var is_carrier: bool = peer_id == puck_carrier_peer_id
				if InfractionRules.is_offside(pos_z, slot.team_id, puck_position.z, is_carrier):
					_offside_peer_ids[peer_id] = true
					ghost = true
		if icing_team_id == slot.team_id:
			ghost = true
		# Crease protection — no field skater (either team, carrier included) may
		# camp in a goalie crease. Dwell-timed: a brief net drive passes through;
		# lingering past CREASE_DWELL_DURATION ghosts you until you leave the paint
		# (exit resets the timer, which un-ghosts next tick — the crease is the
		# tag-up line). Independent of offside/icing so it stacks with them.
		var pos: Vector3 = player_positions[peer_id]
		if CreaseRules.is_in_crease(Vector2(pos.x, pos.z)):
			var dwell: float = _crease_dwell.get(peer_id, 0.0) + delta
			_crease_dwell[peer_id] = dwell
			if dwell >= GameRules.CREASE_DWELL_DURATION:
				ghost = true
		else:
			_crease_dwell.erase(peer_id)
		result[peer_id] = ghost
	return result


# Host-side (NHL only): tracks delayed-offside state. An attacker who entered
# their attacking zone before the puck is added to the offside set and stays
# until they tag up at the blue line. delayed_offside_team_id flips on while
# at least one such peer is offside AND the puck is in their attacking zone;
# it clears when everyone tags up or the puck leaves the zone (defenders
# clear). The whistle itself fires from notify_puck_touch.
func update_delayed_offside(
		player_positions: Dictionary,
		puck_position: Vector3,
		puck_carrier_peer_id: int) -> void:
	if rule_set != GameRules.RuleSet.NHL:
		return
	if current_phase != GamePhase.Phase.PLAYING:
		_delayed_offside_peer_ids.clear()
		delayed_offside_team_id = -1
		return
	var puck_z: float = puck_position.z
	_last_puck_x = puck_position.x

	# Add new offside peers; remove ones who have tagged up. A peer stays in
	# the set even after the puck enters the zone — they must physically cross
	# back into neutral to clear.
	for peer_id in player_positions:
		if not players.has(peer_id):
			continue
		var slot: Dictionary = players[peer_id]
		var pos_z: float = player_positions[peer_id].z
		if _delayed_offside_peer_ids.has(peer_id):
			if InfractionRules.has_tagged_up(pos_z, slot.team_id):
				_delayed_offside_peer_ids.erase(peer_id)
		else:
			var is_carrier: bool = peer_id == puck_carrier_peer_id
			if InfractionRules.is_offside(pos_z, slot.team_id, puck_z, is_carrier):
				_delayed_offside_peer_ids[peer_id] = slot.team_id

	# A team's delayed offside is active once the puck reaches their attacking
	# zone (touch by them is now a whistle). Walk the set and take the first
	# team whose zone the puck is in.
	delayed_offside_team_id = -1
	for tid in _delayed_offside_peer_ids.values():
		if _puck_in_attacking_zone(tid, puck_z):
			delayed_offside_team_id = tid
			break


static func _puck_in_attacking_zone(team_id: int, puck_z: float) -> bool:
	if team_id == 0:
		return puck_z < -GameRules.BLUE_LINE_Z
	else:
		return puck_z > GameRules.BLUE_LINE_Z


# Host-side (NHL only): called when any player gains control of / touches the
# puck (pickup or loose-puck touch). If a delayed offside is active for that
# player's team, stash the faceoff dot so GameManager whistles the play.
func notify_puck_touch(peer_id: int) -> void:
	if rule_set != GameRules.RuleSet.NHL:
		return
	if delayed_offside_team_id == -1:
		return
	if not players.has(peer_id):
		return
	if players[peer_id].team_id != delayed_offside_team_id:
		return
	pending_faceoff_dot = GameRules.offside_faceoff_dot(delayed_offside_team_id, _last_puck_x)
	pending_faceoff_reason = FaceoffReason.OFFSIDE
	_delayed_offside_peer_ids.clear()
	delayed_offside_team_id = -1


# GameManager polls each frame; if a stoppage is pending, returns the reason
# and clears the slot so we don't double-fire. Caller reads pending_faceoff_dot
# directly when the returned reason is non-NONE.
func consume_pending_faceoff() -> int:
	var r: int = pending_faceoff_reason
	pending_faceoff_reason = FaceoffReason.NONE
	return r


# ── Player registry ──────────────────────────────────────────────────────────

func _first_available_slot(team_id: int) -> int:
	var occupied: Array[int] = []
	for p: Dictionary in players.values():
		if p.team_id == team_id:
			occupied.append(p.team_slot)
	for s: int in range(PlayerRules.MAX_PER_TEAM):
		if s not in occupied:
			return s
	return occupied.size()

# Call once at host startup. Returns { team_slot: int, team_id: int }.
func register_host(peer_id: int) -> Dictionary:
	var team_id: int = PlayerRules.assign_team(0, 0)
	var team_slot: int = _first_available_slot(team_id)
	players[peer_id] = {
		"team_slot": team_slot,
		"team_id": team_id,
	}
	return {"team_slot": team_slot, "team_id": team_id}

# Call for each non-host peer that connects. Returns { team_slot: int, team_id: int }.
func on_player_connected(peer_id: int) -> Dictionary:
	var team_id: int = PlayerRules.assign_team(
			count_players_on_team(0), count_players_on_team(1))
	var team_slot: int = _first_available_slot(team_id)
	players[peer_id] = {
		"team_slot": team_slot,
		"team_id": team_id,
	}
	return {"team_slot": team_slot, "team_id": team_id}

# Called by remote clients when they receive a slot assignment RPC.
func register_remote_assigned_player(peer_id: int, team_slot: int, team_id: int) -> void:
	players[peer_id] = {
		"team_slot": team_slot,
		"team_id": team_id,
	}

func on_player_disconnected(peer_id: int) -> void:
	players.erase(peer_id)
	_offside_peer_ids.erase(peer_id)
	_delayed_offside_peer_ids.erase(peer_id)

func count_players_on_team(team_id: int) -> int:
	var count: int = 0
	for peer_id in players:
		if players[peer_id].team_id == team_id:
			count += 1
	return count

# Returns Array of { peer_id, team_id, slot } for all registered players.
# player_name is not stored here; callers enrich via PlayerRecord if needed.
func get_slot_roster() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for peer_id: int in players:
		var slot: Dictionary = players[peer_id]
		result.append({ "peer_id": peer_id, "team_id": slot.team_id, "slot": slot.team_slot })
	return result

# Validates and applies a slot swap. Returns { old_team_id, old_slot, new_team_id,
# new_slot } on success, or an empty Dictionary if the swap is rejected.
func try_swap_slot(peer_id: int, new_team_id: int, new_slot: int) -> Dictionary:
	if not players.has(peer_id):
		return {}
	if new_team_id < 0 or new_team_id > 1 or new_slot < 0 or new_slot >= PlayerRules.MAX_PER_TEAM:
		return {}
	var current: Dictionary = players[peer_id]
	if current.team_id == new_team_id and current.team_slot == new_slot:
		return {}
	for other_id: int in players:
		if other_id == peer_id:
			continue
		if players[other_id].team_id == new_team_id and players[other_id].team_slot == new_slot:
			return {}
	var old_team_id: int = current.team_id
	var old_slot: int   = current.team_slot
	players[peer_id].team_id       = new_team_id
	players[peer_id].team_slot     = new_slot
	return { "old_team_id": old_team_id, "old_slot": old_slot,
			 "new_team_id": new_team_id, "new_slot": new_slot }


# ── Reset ────────────────────────────────────────────────────────────────────

func reset_scores() -> void:
	scores[0] = 0
	scores[1] = 0

func reset_all() -> void:
	scores[0] = 0
	scores[1] = 0
	team_shots[0] = 0
	team_shots[1] = 0
	period_scores = _make_period_scores(num_periods)
	current_period = 1
	time_remaining = period_duration
	icing_team_id = -1
	_icing_timer = 0.0
	last_carrier_team_id = -1
	_offside_peer_ids.clear()
	_delayed_offside_peer_ids.clear()
	delayed_offside_team_id = -1
	pending_faceoff_reason = FaceoffReason.NONE

func apply_config(p_num_periods: int, p_period_duration: float, p_ot_enabled: bool, p_ot_duration: float,
		p_rule_set: int = GameRules.DEFAULT_RULE_SET) -> void:
	infinite_time    = (p_period_duration <= 0.0)
	num_periods      = p_num_periods
	period_duration  = p_period_duration
	ot_enabled       = p_ot_enabled
	ot_duration      = p_ot_duration
	rule_set         = p_rule_set
	time_remaining   = 0.0 if infinite_time else p_period_duration
	period_scores    = _make_period_scores(num_periods)

# Transitions to FACEOFF_PREP at the given dot and clears infraction state.
# Used by manual reset (default center), the OOB path, and the NHL stoppage
# paths (icing / offside, both pass the rule-specific dot). The post-goal
# pipeline is driven automatically by the tick timer in advance_post_goal.
func begin_faceoff_prep(dot_xz: Vector2 = GameRules.CENTER_ICE_DOT) -> void:
	icing_team_id = -1
	_icing_timer = 0.0
	last_carrier_team_id = -1
	_offside_peer_ids.clear()
	_delayed_offside_peer_ids.clear()
	delayed_offside_team_id = -1
	pending_faceoff_reason = FaceoffReason.NONE
	active_faceoff_dot = dot_xz
	_set_phase(GamePhase.Phase.FACEOFF_PREP)


# ── Remote state application (clients) ──────────────────────────────────────
# World-state broadcasts carry authoritative phase + scores. Returns true if
# the phase changed (so GameManager can emit phase_changed, lock/unlock puck).

func apply_remote_state(
		score0: int, score1: int, phase: int,
		period: int, t_remaining: float) -> bool:
	scores[0] = score0
	scores[1] = score1
	current_period = period
	time_remaining = t_remaining
	if phase == current_phase:
		return false
	current_phase = phase
	_phase_timer = 0.0
	return true

# Called on clients when they receive the goal RPC directly (arrives before
# world state most of the time). Enters GOAL_CELEBRATION so the client mirrors
# the host's phase flow — the host's WS will later advance them to GOAL_SCORED
# when the replay should start.
func apply_remote_goal(scoring_team_id: int, score0: int, score1: int) -> void:
	scores[0] = score0
	scores[1] = score1
	last_scoring_team_id = scoring_team_id
	if current_phase != GamePhase.Phase.GOAL_CELEBRATION \
			and current_phase != GamePhase.Phase.GOAL_SCORED:
		current_phase = GamePhase.Phase.GOAL_CELEBRATION
		_phase_timer = 0.0


# Called on clients when they receive the reliable faceoff-positions RPC. The
# faceoff RPC is the authoritative, reliable trigger for the prep phase — world
# state (unreliable) is only a correction channel. Without this the client's
# phase advanced into the faceoff sequence solely via the WS phase byte, so a
# lost FACEOFF_PREP/FACEOFF packet right after a goal replay could collapse the
# client straight from GOAL_CELEBRATION into a later PLAYING packet — dropping
# them into live play with no faceoff prep ("spawned in as the game started").
# Guarded so a very-late RPC can't regress a client that WS already advanced to
# FACEOFF. Returns true if the phase changed (caller emits phase_changed).
func apply_remote_faceoff_prep() -> bool:
	if current_phase == GamePhase.Phase.FACEOFF_PREP \
			or current_phase == GamePhase.Phase.FACEOFF:
		return false
	current_phase = GamePhase.Phase.FACEOFF_PREP
	_phase_timer = 0.0
	return true


# ── Queries ──────────────────────────────────────────────────────────────────

func is_movement_locked() -> bool:
	return PhaseRules.is_movement_locked(current_phase)

func allows_blade_aim_during_lock() -> bool:
	return PhaseRules.allows_blade_aim_during_lock(current_phase)

# Returns { peer_id: Vector3 } — each player's faceoff position derived from
# their slot/team around the active dot. PlayerRules.faceoff_position is the
# single source of truth; we hold no cached positions ourselves.
func get_faceoff_positions() -> Dictionary:
	var result: Dictionary = {}
	for peer_id in players:
		var p: Dictionary = players[peer_id]
		result[peer_id] = PlayerRules.faceoff_position(p.team_id, p.team_slot, active_faceoff_dot)
	return result


# ── Internal ─────────────────────────────────────────────────────────────────

func _set_phase(phase: int) -> void:
	current_phase = phase
	_phase_timer = 0.0

func _tick_phase(delta: float) -> bool:
	if current_phase == GamePhase.Phase.PLAYING:
		if infinite_time:
			time_remaining += delta
			return false
		time_remaining -= delta
		if time_remaining <= 0.0:
			time_remaining = 0.0
			_on_period_clock_expired()
			return true
		return false
	if current_phase == GamePhase.Phase.GAME_OVER:
		return false
	_phase_timer += delta
	match current_phase:
		GamePhase.Phase.GOAL_CELEBRATION:
			if _phase_timer >= GameRules.GOAL_CELEBRATION_DURATION:
				_set_phase(GamePhase.Phase.GOAL_SCORED)
				return true
		GamePhase.Phase.GOAL_SCORED:
			if _phase_timer >= GameRules.GOAL_PAUSE_DURATION:
				advance_post_goal()
				return true
		GamePhase.Phase.FACEOFF_PREP:
			if _phase_timer >= GameRules.FACEOFF_PREP_DURATION:
				_set_phase(GamePhase.Phase.FACEOFF)
				return true
		GamePhase.Phase.FACEOFF:
			if _phase_timer >= GameRules.FACEOFF_TIMEOUT:
				_set_phase(GamePhase.Phase.PLAYING)
				return true
		GamePhase.Phase.END_OF_PERIOD:
			if _phase_timer >= GameRules.END_OF_PERIOD_PAUSE:
				_advance_period()
				return true
	return false

func _on_period_clock_expired() -> void:
	if current_period >= num_periods:
		if ot_enabled and scores[0] == scores[1]:
			_set_phase(GamePhase.Phase.END_OF_PERIOD)
		else:
			_set_phase(GamePhase.Phase.GAME_OVER)
	else:
		_set_phase(GamePhase.Phase.END_OF_PERIOD)

func _is_ot_period() -> bool:
	return current_period > num_periods

func _advance_period() -> void:
	current_period += 1
	time_remaining = ot_duration if _is_ot_period() else period_duration
	# Extend period_scores arrays to cover the new period
	if period_scores[0].size() < current_period:
		period_scores[0].append(0)
		period_scores[1].append(0)
	icing_team_id = -1
	_icing_timer = 0.0
	last_carrier_team_id = -1
	active_faceoff_dot = GameRules.CENTER_ICE_DOT
	_set_phase(GamePhase.Phase.FACEOFF_PREP)

func _tick_icing(delta: float) -> void:
	if icing_team_id == -1:
		return
	_icing_timer -= delta
	if _icing_timer <= 0.0:
		icing_team_id = -1
