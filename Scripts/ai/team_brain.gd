class_name TeamBrain
extends RefCounted

# Per-team strategy node, v2 (possession-state model). Replaces the
# F1/F2/F3 closest-to-puck role assignment + man-to-man coverage
# assignment with a single positional-slot system driven by team
# possession state. See `docs/specs/AI_PLAN.md` (v2 model).
#
# Driven by GameManager._physics_process (host only) — ticks once
# every TICK_PERIOD seconds (~6 Hz).
#
# Blackboard:
#   state              — AIPossessionState.State enum (DZONE / OZONE /
#                        TRANS_DO / TRANS_OD / NEUTRAL).
#   slot_assignments   — Dictionary[peer_id, AIRoleSlots.Slot].
#   published_anchors  — Dictionary[peer_id, Vector3] of off-puck bot
#                        steering anchors, kept from v1 for the
#                        carrier's pass-aim receiver lead.
#
# Roles assigned by current geometry per brain tick — no SPRINT_BY
# locking; the bot whose body is in the right place gets the role.
# Hysteresis (1.5 m) prevents flicker from small position changes.
#
# `team_id_resolver` is `func(peer_id: int) -> int` — bound by
# GameManager at construction (see `_registry.resolve_team_id_for_peer`).
# `is_human_resolver` is no longer used in v2 (no role-yield logic),
# kept on the constructor signature for backwards compatibility with
# GameManager's existing call site.

const TICK_PERIOD: float = 1.0 / 6.0
# Strong-side X is sign(puck.x) but with a hysteresis band so the
# strong/weak side doesn't flip every tick when the puck cycles
# through center. Once we've picked +1, only flip to -1 when puck.x
# crosses below -STRONG_SIDE_HYSTERESIS_M, and vice versa. Without
# this, NET / BACKDOOR / etc. anchors flip strong-side rapidly on a
# corner-to-corner cycle and bots try to switch sides every brain tick.
const STRONG_SIDE_HYSTERESIS_M: float = 1.5

var team_id: int = 0
var state: int = AIPossessionState.State.DZONE
var slot_assignments: Dictionary = {}      # peer_id -> AIRoleSlots.Slot
var published_anchors: Dictionary = {}     # peer_id -> Vector3

# Internal — sticky possession for loose-puck handling.
var _last_carrier_team: int = -1
# Hysteretic strong-side X. Updated per brain tick from puck.x.
var _strong_x: float = 1.0

var _accumulator: float = 0.0
var _team_id_resolver: Callable = Callable()
var _is_human_resolver: Callable = Callable()
# Cached own-goal Z derived from team_id at construction. Team 0
# defends +GOAL_LINE_Z, Team 1 defends -GOAL_LINE_Z.
var _own_goal_z: float = 0.0


func _init(t: int, resolver: Callable, human_resolver: Callable) -> void:
	team_id = t
	_team_id_resolver = resolver
	_is_human_resolver = human_resolver
	_own_goal_z = GameRules.GOAL_LINE_Z if t == 0 else -GameRules.GOAL_LINE_Z


# Called every host physics frame from GameManager. Snapshot is the freshest
# captured world state (delay 0). Internally rate-limited to TICK_PERIOD.
func tick(delta: float, snapshot: WorldSnapshot) -> void:
	_accumulator += delta
	if _accumulator < TICK_PERIOD:
		return
	_accumulator -= TICK_PERIOD

	# 1. Possession state.
	var new_state_pair: Array = AIPossessionState.compute(
			snapshot, team_id, _own_goal_z, _team_id_resolver, _last_carrier_team)
	var new_state: int = new_state_pair[0]
	_last_carrier_team = new_state_pair[1]
	state = new_state

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
			snapshot, team_id, _own_goal_z, state, _team_id_resolver,
			prev_assignments, _strong_x)


# Returns the slot a peer is currently assigned to, or NONE if not
# assigned (e.g., peer_id isn't on this team, or the brain hasn't
# ticked yet).
func get_slot(peer_id: int) -> int:
	return slot_assignments.get(peer_id, AIRoleSlots.Slot.NONE)


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
	return AIRoleSlots.slot_anchor(
			slot, state, puck_pos, carrier_pos,
			_own_goal_z, _strong_x)


# Called by each off-puck bot per physics tick to publish where they're
# steering. Read by the carrier in `_pass_aim_point` for receiver lead.
func publish_anchor(peer_id: int, anchor: Vector3) -> void:
	published_anchors[peer_id] = anchor


# Returns the receiver's published steering anchor, or Vector3.ZERO if
# none has been published yet (carrier should fall back to velocity-only).
func get_published_anchor(peer_id: int) -> Vector3:
	return published_anchors.get(peer_id, Vector3.ZERO)
