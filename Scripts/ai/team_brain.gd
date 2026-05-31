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
var state: int = AIPossessionState.State.DZONE
var slot_assignments: Dictionary[int, int] = {}      # peer_id -> AIRoleSlots.Slot

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
# Cached own-goal Z derived from team_id at construction. Team 0
# defends +GOAL_LINE_Z, Team 1 defends -GOAL_LINE_Z.
var _own_goal_z: float = 0.0


func _init(t: int, team_id_by_peer: Dictionary) -> void:
	team_id = t
	_team_id_by_peer = team_id_by_peer
	_own_goal_z = GameRules.GOAL_LINE_Z if t == 0 else -GameRules.GOAL_LINE_Z


# Called every host physics frame from GameManager. Snapshot is the freshest
# captured world state (delay 0). Internally rate-limited to TICK_PERIOD,
# unless `_force_tick_pending` was set by force_retick() — then this tick
# computes regardless of the accumulator.
func tick(delta: float, snapshot: WorldSnapshot) -> void:
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

	# 2. Strong-side X with hysteresis (see STRONG_SIDE_HYSTERESIS_M).
	if snapshot != null and snapshot.puck_state != null:
		var puck_x: float = snapshot.puck_state.position.x
		if _strong_x > 0.0 and puck_x < -STRONG_SIDE_HYSTERESIS_M:
			_strong_x = -1.0
		elif _strong_x < 0.0 and puck_x > STRONG_SIDE_HYSTERESIS_M:
			_strong_x = 1.0

	# 3. Slot assignment by current geometry. CARRIER is fixed to the
	#    puck holder; everything else falls out of the permutation
	#    enumeration with hysteresis. No locking needed.
	var prev_assignments: Dictionary = slot_assignments
	slot_assignments = AIRoleSlots.assign(
			snapshot, team_id, _own_goal_z, state, _team_id_by_peer,
			prev_assignments, _strong_x)
	# Drop excluded peers (puppeted tutorial bots) so neither they nor any
	# downstream consumer of get_slot / get_anchor pulls them toward a slot
	# anchor. AIRoleSlots.assign already may have given them a slot — erase
	# after the fact rather than touching the call signature.
	for excluded_pid: int in _excluded_peers:
		slot_assignments.erase(excluded_pid)


# Returns the slot a peer is currently assigned to, or NONE if not
# assigned (e.g., peer_id isn't on this team, or the brain hasn't
# ticked yet).
func get_slot(peer_id: int) -> int:
	return slot_assignments.get(peer_id, AIRoleSlots.Slot.NONE)


# Hysteretic strong-side sign (+1 = +X, -1 = -X), updated per brain
# tick from puck.x. Role behaviors (BREAKOUT outlets) read this so
# their strong/weak split matches the brain's slot assignment instead
# of recomputing a raw sign that would thrash near center ice.
func strong_x() -> float:
	return _strong_x


# ── One-timer readiness signaling ───────────────────────────────────────────
# Off-puck bots in the FINISHER role publish "I'm camped + pre-aimed,
# fire me a pass and I'll one-time it" via set_one_timer_ready(true).
# The carrier reads via is_one_timer_ready(peer_id) when scoring
# passes — a ready receiver gets a no-charge goalie prediction (since
# they fire on contact, the goalie can't react to a wind-up), which
# inflates the squareness term and naturally rewards passes to them.
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
	return AIRoleSlots.slot_anchor(slot, carrier_pos)
