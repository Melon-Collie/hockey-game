class_name TeamBrain
extends RefCounted

# Per-team strategy node, v2 (possession-state model). Replaces the
# F1/F2/F3 closest-to-puck role assignment + man-to-man coverage
# assignment with a single positional-slot system driven by team
# possession state. See `docs/specs/AI_PLAN.md` (v2 model) and the
# article-distilled three principles (sprint-by, play off heels,
# simple 2v1).
#
# Driven by GameManager._physics_process (host only) — ticks once
# every TICK_PERIOD seconds (~6 Hz).
#
# Blackboard:
#   state              — AIPossessionState.State enum (DZONE / OZONE /
#                        TRANS_DO / TRANS_OD).
#   slot_assignments   — Dictionary[peer_id, AIRoleSlots.Slot].
#   sprint_by_peer_id  — peer locked into SPRINT_BY for a TRANS state
#                        (0 if none / state isn't TRANS / sprinter
#                        graduated).
#   sprint_by_target   — Vector3 world target for the locked SPRINT_BY
#                        peer (Vector3.ZERO when no active sprint).
#   published_anchors  — Dictionary[peer_id, Vector3] of off-puck bot
#                        steering anchors, kept from v1 for the
#                        carrier's pass-aim receiver lead.
#
# `team_id_resolver` is `func(peer_id: int) -> int` — bound by
# GameManager at construction (see `_registry.resolve_team_id_for_peer`).
# `is_human_resolver` is no longer used in v2 (no role-yield logic),
# kept on the constructor signature for backwards compatibility with
# GameManager's existing call site.

const TICK_PERIOD: float = 1.0 / 6.0

var team_id: int = 0
var state: int = AIPossessionState.State.DZONE
var slot_assignments: Dictionary = {}      # peer_id -> AIRoleSlots.Slot
var sprint_by_peer_id: int = 0             # 0 = none
var sprint_by_target: Vector3 = Vector3.ZERO
var published_anchors: Dictionary = {}     # peer_id -> Vector3

# Internal — sticky possession for loose-puck handling.
var _last_carrier_team: int = -1

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

	# 2. SPRINT_BY tracking — locked at TRANS state entry, cleared on
	#    state change or graduation.
	if new_state != state:
		# State changed. Clear any active sprint.
		sprint_by_peer_id = 0
		sprint_by_target = Vector3.ZERO
		# Lock a new SPRINT_BY if we're entering a TRANS state.
		if AIPossessionState.is_transition(new_state):
			sprint_by_peer_id = AIRoleSlots.pick_sprint_by_peer(
					new_state, snapshot, team_id, _own_goal_z, _team_id_resolver)
			if sprint_by_peer_id != 0:
				var puck_pos: Vector3 = snapshot.puck_state.position
				var strong_x: float = signf(puck_pos.x)
				if absf(puck_pos.x) < 0.5:
					strong_x = 1.0
				sprint_by_target = AIRoleSlots.compute_sprint_by_target(
						new_state, puck_pos, _own_goal_z, strong_x)
	elif sprint_by_peer_id != 0:
		# Same state, but check if the sprinter has reached the target.
		if AIRoleSlots.sprint_by_should_graduate(
				sprint_by_peer_id, sprint_by_target, snapshot):
			sprint_by_peer_id = 0
			sprint_by_target = Vector3.ZERO

	# 3. Slot assignment for the (possibly updated) state.
	var prev_assignments: Dictionary = slot_assignments
	state = new_state
	slot_assignments = AIRoleSlots.assign(
			snapshot, team_id, _own_goal_z, state, _team_id_resolver,
			prev_assignments, sprint_by_peer_id, sprint_by_target)


# Returns the slot a peer is currently assigned to, or NONE if not
# assigned (e.g., peer_id isn't on this team, or the brain hasn't
# ticked yet).
func get_slot(peer_id: int) -> int:
	return slot_assignments.get(peer_id, AIRoleSlots.Slot.NONE)


# True iff the peer is the locked SPRINT_BY in the current TRANS state.
# Used by the SM to swap to sprint-through steering mode.
func is_sprint_by(peer_id: int) -> bool:
	return sprint_by_peer_id != 0 and sprint_by_peer_id == peer_id


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
	var strong_x: float = signf(puck_pos.x)
	if absf(puck_pos.x) < 0.5:
		strong_x = 1.0
	return AIRoleSlots.slot_anchor(
			slot, state, puck_pos, carrier_pos, sprint_by_target,
			_own_goal_z, strong_x)


# Called by each off-puck bot per physics tick to publish where they're
# steering. Read by the carrier in `_pass_aim_point` for receiver lead.
func publish_anchor(peer_id: int, anchor: Vector3) -> void:
	published_anchors[peer_id] = anchor


# Returns the receiver's published steering anchor, or Vector3.ZERO if
# none has been published yet (carrier should fall back to velocity-only).
func get_published_anchor(peer_id: int) -> Vector3:
	return published_anchors.get(peer_id, Vector3.ZERO)
