class_name TeamBrain
extends RefCounted

# Per-team strategy node, v2 (possession-state model). Replaces the
# F1/F2/F3 closest-to-puck role assignment + man-to-man coverage
# assignment with a single positional-slot system driven by team
# possession state.
#
# Driven by GameManager._physics_process (host only) — ticks once
# every TICK_PERIOD seconds (~6 Hz).
#
# Blackboard:
#   state              — AIPossessionState.State enum (DZONE / OZONE /
#                        TRANS_DO / TRANS_OD / NEUTRAL).
#   slot_assignments   — Dictionary[peer_id, AIRoleSlots.Slot].
#
# Roles assigned by current geometry per brain tick — no SPRINT_BY
# locking; the bot whose body is in the right place gets the role.
# Hysteresis (1.5 m) prevents flicker from small position changes.
#
# `team_id_by_peer` is `Dictionary[int, int]` — live reference owned
# by PlayerRegistry, mutated when players spawn / leave / slot-swap.
# Read via `dict.get(pid, -1)`. Used to be a Callable; downgraded to
# a Dictionary because AI hot loops eat Callable.call overhead.

const TICK_PERIOD: float = 1.0 / 6.0
# Strong-side X is sign(puck.x) but with a hysteresis band so the
# strong/weak side doesn't flip every tick when the puck cycles
# through center. Once we've picked +1, only flip to -1 when puck.x
# crosses below -STRONG_SIDE_HYSTERESIS_M, and vice versa. Without
# this, ANCHOR / FINISHER / etc. anchors flip strong-side rapidly on
# a corner-to-corner cycle and bots try to switch sides every brain tick.
const STRONG_SIDE_HYSTERESIS_M: float = 1.5

var team_id: int = 0
# Latched match team size (3 or 5). Selects the role-slot path: 3 → the
# legacy AIRoleSlots election (verbatim), 5 → AIRoleSlots5's position-aware
# group-scoped election. Set once at construction from the state machine.
var team_size: int = GameRules.DEFAULT_TEAM_SIZE
var state: int = AIPossessionState.State.DZONE
# Live smart-ping directives for this team's bots (host-only AI bookkeeping,
# same shape as _one_timer_ready_by_peer). GameManager routes a validated
# ping in via apply_ping; slot/threat overrides land in _compute_tick and the
# per-bot queries are read through RoleContext every AI dispatch.
var ping_directives := AIPingDirectives.new()
var slot_assignments: Dictionary[int, int] = {}      # peer_id -> AIRoleSlots.Slot
# Central man-on-threat partition: backline defender peer_id -> the opponent
# (carrier's receiver) it should cover. Computed per tick in defensive states
# so the MARK defenders each focus on a DISTINCT man instead of all collapsing on
# the single most dangerous opponent. Empty in offensive / neutral states.
var threat_assignments: Dictionary[int, int] = {}    # defender peer -> opp peer

# True while last tick's state was RETRIEVAL — feeds the enter/hold
# hysteresis in AIPossessionState.retrieval_read so the DZONE ↔ RETRIEVAL
# boundary can't flicker at the race margin.
var _was_retrieval: bool = false

# Internal — sticky possession for loose-puck handling.
var _last_carrier_team: int = -1
# Hysteretic strong-side X. Updated per brain tick from puck.x.
var _strong_x: float = 1.0

var _accumulator: float = 0.0
# Set by force_retick(); next tick() call bypasses the rate-limit and
# computes immediately. Used for event-driven re-evaluation when a
# puck-carrier change makes the current slot assignment stale.
var _force_tick_pending: bool = false
# Set of peer_ids that should NOT receive a slot assignment. Used by the
# tutorial to puppet a bot in scripted mode — the puppeted bot's slot
# would otherwise drag it back to a role anchor each brain tick. Kept as
# a Dictionary[int, bool] for O(1) `has()` lookups.
var _excluded_peers: Dictionary = {}
var _team_id_by_peer: Dictionary = {}
# Live per-peer AISkaterCaps from PlayerRegistry (memoized), so man-marking reads
# each defender's real top speed. Empty when unwired (tests) → league default.
var _caps_by_peer: Dictionary = {}
# Live peer_id → lobby team_slot (0–4) from PlayerRegistry. 5v5 only: feeds
# the F/D group split and the home-side rest bias in AIRoleSlots5. Empty in
# 3v3 / tests (the legacy path never reads it).
var _position_by_peer: Dictionary = {}
# Cached own-goal Z derived from team_id at construction. Team 0
# defends +GOAL_LINE_Z, Team 1 defends -GOAL_LINE_Z.
var _own_goal_z: float = 0.0


func _init(t: int, team_id_by_peer: Dictionary, caps_by_peer: Dictionary = {},
		p_team_size: int = GameRules.DEFAULT_TEAM_SIZE,
		position_by_peer: Dictionary = {}) -> void:
	team_id = t
	_team_id_by_peer = team_id_by_peer
	_caps_by_peer = caps_by_peer
	team_size = p_team_size
	_position_by_peer = position_by_peer
	_own_goal_z = GameRules.GOAL_LINE_Z if t == 0 else -GameRules.GOAL_LINE_Z


# Called every host physics frame from GameManager. Snapshot is the freshest
# captured world state (delay 0). Internally rate-limited to TICK_PERIOD,
# unless `_force_tick_pending` was set by force_retick() — then this tick
# computes regardless of the accumulator.
func tick(delta: float, snapshot: WorldSnapshot) -> void:
	# Ping directives age in real host time, not brain-tick time — advance
	# before the rate-limit gate so expiry never stretches with the cadence.
	ping_directives.advance(delta)
	_accumulator += delta
	if _accumulator < TICK_PERIOD and not _force_tick_pending:
		return
	# Natural cadence: drain one tick's worth of accumulator. Forced
	# tick: reset accumulator to zero so the next natural tick fires
	# TICK_PERIOD seconds from now (avoids back-to-back forced+natural
	# ticks compounding into a double-rate burst).
	if _force_tick_pending:
		_accumulator = 0.0
		_force_tick_pending = false
	else:
		_accumulator -= TICK_PERIOD
	_compute_tick(snapshot)


# Schedules an immediate re-tick on the next physics frame, bypassing
# the TICK_PERIOD rate-limit. Called from GameManager when an event
# (puck-carrier change) makes the role assignment immediately stale —
# the natural 6 Hz cadence would leave it stale for up to ~166 ms,
# during which the new carrier still has the previous assignment.
# Both team brains should be force-reticked together since a carrier
# change affects both possession states symmetrically.
func force_retick() -> void:
	_force_tick_pending = true


# Exclude a peer from slot assignment. Used by the tutorial when a bot is
# put into scripted/puppet mode — without this the brain would assign it a
# role and downstream get_slot / get_anchor calls would yank it toward an
# anchor each tick. Include is the inverse.
func exclude_skater(peer_id: int) -> void:
	_excluded_peers[peer_id] = true
	slot_assignments.erase(peer_id)


func include_skater(peer_id: int) -> void:
	_excluded_peers.erase(peer_id)


# Body of the per-tick computation. Extracted from tick() so
# force_retick() can drive it without going through the accumulator
# rate-limit.
func _compute_tick(snapshot: WorldSnapshot) -> void:
	# 1. Possession state.
	var possession: AIPossessionState.Result = AIPossessionState.compute(
			snapshot, team_id, _own_goal_z, _team_id_by_peer, _last_carrier_team)
	_last_carrier_team = possession.carrier_team
	state = possession.state

	# 1.5 RETRIEVAL upgrade (5v5 only — docs/breakout-plan.md Phase A): a
	# loose puck in our DZ that WE clearly win the race to flips the team
	# from defensive coverage into the breakout posture — the outlets take
	# their posts WHILE the retriever skates back, instead of only after
	# pickup (which left him meeting the forecheck alone). Gated on the
	# same race model the chase election runs (best_intercept_time), with
	# enter/hold hysteresis in AIPossessionState.retrieval_read. A dead
	# puck (goalie smother / phase lock) publishes a −1 chase election and
	# stays DZONE; contested races stay DZONE (a slot scramble is defense).
	if team_size >= 5 and state == AIPossessionState.State.DZONE \
			and snapshot != null and snapshot.puck_state != null \
			and snapshot.puck_state.carrier_peer_id == -1 \
			and snapshot.closest_to_puck_by_team.get(team_id, -1) != -1:
		var p_pos: Vector3 = snapshot.puck_state.position
		var p_vel: Vector3 = snapshot.puck_state.velocity
		var our_t: float = AILoosePuckChase.best_intercept_time(
				snapshot.skater_states,
				snapshot.teammate_ids_by_team.get(team_id, []),
				p_pos, p_vel, _caps_by_peer)
		var opp_t: float = AILoosePuckChase.best_intercept_time(
				snapshot.skater_states,
				snapshot.teammate_ids_by_team.get(1 - team_id, []),
				p_pos, p_vel, _caps_by_peer)
		if AIPossessionState.retrieval_read(our_t, opp_t, _was_retrieval):
			state = AIPossessionState.State.RETRIEVAL
	_was_retrieval = state == AIPossessionState.State.RETRIEVAL

	# 2. Strong-side X with hysteresis (see STRONG_SIDE_HYSTERESIS_M).
	if snapshot != null and snapshot.puck_state != null:
		var puck_x: float = snapshot.puck_state.position.x
		if _strong_x > 0.0 and puck_x < -STRONG_SIDE_HYSTERESIS_M:
			_strong_x = -1.0
		elif _strong_x < 0.0 and puck_x > STRONG_SIDE_HYSTERESIS_M:
			_strong_x = 1.0

	# 3. Slot assignment by current kinematics (momentum-aware soonest-to-
	#    arrive elections at each peer's real Speed cap). CARRIER is fixed
	#    to the puck holder; everything else falls out of the per-state
	#    elections with hysteresis. No locking needed. 5v5 routes through
	#    the position-aware group-scoped election; 3v3 keeps the legacy
	#    path verbatim (plan §"Guiding constraint").
	var prev_assignments: Dictionary = slot_assignments
	if team_size >= 5:
		slot_assignments = AIRoleSlots5.assign(
				snapshot, team_id, _own_goal_z, state, _team_id_by_peer,
				prev_assignments, _strong_x, _caps_by_peer, _position_by_peer)
	else:
		slot_assignments = AIRoleSlots.assign(
				snapshot, team_id, _own_goal_z, state, _team_id_by_peer,
				prev_assignments, _strong_x, _caps_by_peer)
	# Drop excluded peers (puppeted tutorial bots) so neither they nor any
	# downstream consumer of get_slot / get_anchor pulls them toward a slot
	# anchor. AIRoleSlots.assign already may have given them a slot — erase
	# after the fact rather than touching the call signature.
	for excluded_pid: int in _excluded_peers:
		slot_assignments.erase(excluded_pid)

	# 4. Man-on-threat partition for the backline (defensive states only).
	#    Passes the prior assignment so AIThreatAssignment can apply switch
	#    hysteresis; cleared to {} in non-defensive states so re-entry starts
	#    fresh. Excluded peers are already absent from slot_assignments, so
	#    they're never picked as defenders here.
	threat_assignments = _compute_threat_assignments(snapshot, threat_assignments)

	# 5. Smart-ping obedience: force-slot the obeying bots (COVER_HIM also
	#    pins its man into the threat partition, the house-pin shape). Applied
	#    last so a live human order wins over the geometric assignment.
	var ping_carrier: int = -1
	if snapshot != null and snapshot.puck_state != null:
		ping_carrier = snapshot.puck_state.carrier_peer_id
	ping_directives.apply_overrides(slot_assignments, threat_assignments, ping_carrier)


# Builds the backline man-on-threat partition for the current tick. Defensive
# states only (DZONE + TRANS_OD); every other state returns {} so no defender
# carries a stale assignment.
#
# Backline = our peers slotted MARK (DZONE and TRANS_OD).
# The carrier is owned separately — PRESSURE in DZONE, the CONTAIN gap defender
# in TRANS_OD — so it's excluded; the men are the opposing carrier's potential
# receivers (every opponent except the carrier). Each man's value is the raw
# pass-threat surface (no defenders in the view), so AIThreatAssignment pairs
# the most dangerous men with the best-positioned defenders. `prev` is last
# tick's partition, threaded through for switch hysteresis.
func _compute_threat_assignments(snapshot: WorldSnapshot,
		prev: Dictionary) -> Dictionary[int, int]:
	var empty: Dictionary[int, int] = {}
	if state != AIPossessionState.State.DZONE \
			and state != AIPossessionState.State.TRANS_OD:
		return empty
	if snapshot == null or snapshot.puck_state == null:
		return empty
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id
	# Need a live OPPONENT carrier to define the receivers / score pass threats.
	if carrier_pid == -1 or _team_id_by_peer.get(carrier_pid, -1) == team_id:
		return empty
	if not snapshot.skater_states.has(carrier_pid):
		return empty
	var carrier_pos: Vector3 = snapshot.skater_states[carrier_pid].position

	# Backline man-markers (MARK, in DZONE and TRANS_OD) and their kinematics.
	var defenders: Array[int] = []
	var defender_pos: Dictionary = {}
	var defender_vel: Dictionary = {}
	var defender_caps: Dictionary = {}
	for pid: int in slot_assignments:
		var slot: int = slot_assignments[pid]
		if slot != AIRoleSlots.Slot.MARK:
			continue
		if not snapshot.skater_states.has(pid):
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		defenders.append(pid)
		defender_pos[pid] = s.position
		defender_vel[pid] = s.velocity
		var caps: AISkaterCaps = _caps_by_peer.get(pid)
		if caps != null:
			defender_caps[pid] = caps
	if defenders.is_empty():
		return empty

	# Men = non-carrier opponents; value = raw pass-threat surface.
	var our_net := Vector3(0.0, 0.0, _own_goal_z)
	var our_goalie_pos: Vector3 = _resolve_our_goalie_pos(snapshot)
	var no_defenders: Array[Vector3] = []
	var men: Array[int] = []
	var man_pos: Dictionary = {}
	var man_value: Dictionary = {}
	var man_danger: Dictionary = {}
	for pid: int in snapshot.skater_states:
		if _team_id_by_peer.get(pid, -1) == team_id:
			continue
		if pid == carrier_pid:
			continue
		var mp: Vector3 = snapshot.skater_states[pid].position
		men.append(pid)
		man_pos[pid] = mp
		man_value[pid] = AIActionScoring.threat_surface_pass(
				carrier_pos, mp, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, no_defenders)
		# Finish danger if fed: shot value from his spot with the goalie
		# PREDICTED OVER THE FEED'S FLIGHT (he starts tracking the carrier;
		# a short doorstep feed arrives before he traverses — lethal — while
		# a long perimeter feed hands him the whole flight to re-square), no
		# field defenders. Feeds the net-front override (drops the lane
		# factor man_value folds in: a contested feed still becomes a
		# tap-in if it arrives).
		var feed_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, mp)
		var feed_flight: float = carrier_pos.distance_to(mp) / maxf(feed_speed, 1.0)
		# Predicted post-seal for the man's spot (derive_post_seal_x_sign): a
		# sharp-angle man fires into the wall a competent keeper adopts, so he
		# is not a finish threat the assignment must chase.
		var man_seal: float = AIActionScoring.derive_post_seal_x_sign(mp, our_net)
		# Pre-armed feed keeper: our goalie's backdoor depth cap already
		# guards this man, so the threat partition weighs him at the
		# merely-strong danger the real keeper concedes.
		var g_state: GoalieNetworkState = snapshot.goalie_states.get(team_id)
		AIActionScoring.resolve_feed_keeper(
				our_goalie_pos, our_net, feed_flight, mp, carrier_pos,
				g_state.hands_read(our_net.z) if g_state != null else Vector4.INF,
				feed_speed)
		man_danger[pid] = AIActionScoring.score_shoot(
				mp, our_net,
				AIActionScoring.feed_keeper_pos,
				GameRules.NET_HALF_WIDTH, no_defenders,
				AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				AIActionScoring.feed_keeper_unsettled,
				[], -1.0, false, man_seal, man_seal != 0.0, 0.0, [],
				AIActionScoring.feed_keeper_hands)
	if men.is_empty():
		return empty

	return AIThreatAssignment.assign(
			defenders, defender_pos, defender_vel,
			men, man_pos, man_value, our_net, prev, defender_caps, man_danger)


# Our goalie's current world position, or the goal mouth as a first-frame
# fallback. Mirrors AIRoleHelpers.resolve_our_goalie_pos for the brain's own
# threat scoring (the brain has no RoleContext).
func _resolve_our_goalie_pos(snapshot: WorldSnapshot) -> Vector3:
	var goalie: GoalieNetworkState = snapshot.goalie_states.get(team_id)
	if goalie == null:
		return Vector3(0.0, 0.0, _own_goal_z)
	return Vector3(goalie.position_x, 0.0, goalie.position_z)


# Returns the slot a peer is currently assigned to, or NONE if not
# assigned (e.g., peer_id isn't on this team, or the brain hasn't
# ticked yet).
func get_slot(peer_id: int) -> int:
	return slot_assignments.get(peer_id, AIRoleSlots.Slot.NONE)


# The opponent a given backline defender is assigned to cover, or -1 if it has
# no man-coverage assignment this tick (offensive/neutral state, or the peer
# isn't a backline defender). Read by MARK via RoleContext.
func assigned_threat(peer_id: int) -> int:
	return threat_assignments.get(peer_id, -1)


# Hysteretic strong-side sign (+1 = +X, -1 = -X), updated per brain
# tick from puck.x. Role behaviors (BREAKOUT outlets) read this so
# their strong/weak split matches the brain's slot assignment instead
# of recomputing a raw sign that would thrash near center ice.
func strong_x() -> float:
	return _strong_x


# This peer's lobby position (team_slot 0–4; see PlayerRules.POSITION_NAMES).
# 0 (C) when unknown — tests / 3v3, where nothing reads it.
func position_of(peer_id: int) -> int:
	return _position_by_peer.get(peer_id, 0)


# ── One-timer readiness signaling ───────────────────────────────────────────
# Off-puck bots in the FINISHER role publish "I'm camped + pre-aimed,
# fire me a pass and I'll one-time it" via set_one_timer_ready(true).
# The carrier reads via is_one_timer_ready(peer_id) when scoring
# passes — a ready receiver gets a no-charge goalie prediction (since
# they fire on contact, the goalie can't react to a wind-up), which
# leaves the goalie less settled in the seven-hole geometry and naturally
# rewards passes to them.
# Stored host-side on the brain, not in SkaterNetworkState — this is
# pure AI bookkeeping that the network doesn't need to see.
var _one_timer_ready_by_peer: Dictionary = {}   # peer_id -> bool


func set_one_timer_ready(peer_id: int, ready: bool) -> void:
	if ready:
		_one_timer_ready_by_peer[peer_id] = true
	else:
		_one_timer_ready_by_peer.erase(peer_id)


func is_one_timer_ready(peer_id: int) -> bool:
	return _one_timer_ready_by_peer.get(peer_id, false)


# ── Smart-ping directives ───────────────────────────────────────────────────
# GameManager (host) routes a validated smart ping here; the slot/threat
# overrides apply on the next brain tick (force_retick makes that the next
# physics frame) and the per-bot queries below are read every AI dispatch
# via RoleContext, so obedience is frame-tight while the directive lives.

func apply_ping(type: int, pinger_peer: int, target_peer: int,
		obeyer_peer: int, world_pos: Vector3) -> void:
	ping_directives.add(type, pinger_peer, target_peer, obeyer_peer,
			world_pos, PingRules.directive_duration_s(type))
	force_retick()


func ping_move_target(peer_id: int) -> Vector3:
	return ping_directives.move_target_for(peer_id)


func ping_chase_peer() -> int:
	return ping_directives.chase_peer()


func ping_shoot(peer_id: int) -> bool:
	return ping_directives.shoot_ping_for(peer_id)


func ping_pass_target(peer_id: int) -> int:
	return ping_directives.pass_target_for(peer_id)


# Computes the world-space anchor for a given peer's current slot.
# Returns Vector3.ZERO if the peer isn't assigned a slot.
func get_anchor(peer_id: int, snapshot: WorldSnapshot) -> Vector3:
	var slot: int = slot_assignments.get(peer_id, AIRoleSlots.Slot.NONE)
	if slot == AIRoleSlots.Slot.NONE:
		return Vector3.ZERO
	if snapshot == null or snapshot.puck_state == null:
		return Vector3.ZERO
	var puck_pos: Vector3 = snapshot.puck_state.position
	var carrier_pos: Vector3 = puck_pos
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id
	if carrier_pid != -1 and snapshot.skater_states.has(carrier_pid):
		carrier_pos = snapshot.skater_states[carrier_pid].position
	if team_size >= 5:
		return AIRoleSlots5.slot_anchor(
				slot, _own_goal_z, _strong_x, puck_pos, carrier_pos)
	return AIRoleSlots.slot_anchor(slot, carrier_pos)
