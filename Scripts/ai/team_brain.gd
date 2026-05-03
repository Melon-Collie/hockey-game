class_name TeamBrain
extends RefCounted

# Per-team strategy node. Owns role assignments + man coverage targets.
# Driven by GameManager._physics_process (host only) — ticks once every
# TICK_PERIOD seconds rather than every physics frame so role decisions
# don't churn at 240 Hz. Spec called for a 6 Hz Timer Node; we use a
# RefCounted with an accumulator to keep ownership/lifecycle simpler.
#
# Blackboard:
#   roles: peer_id → StringName (F1 / F2 / F3 / OFF)
#   coverage_targets: peer_id → opposing peer_id  (man-marking)
# The SM uses coverage_targets only when in DZ + not in own possession;
# in other situations it falls back to zone-style F2/F3 anchors.
#
# Consumes the existing WorldSnapshot captured by StateBufferManager.
# team_id_resolver is `func(peer_id: int) -> int` — bound by GameManager
# at construction (see _registry.resolve_team_id_for_peer).

const TICK_PERIOD: float = 1.0 / 6.0

var team_id: int = 0
var roles: Dictionary = {}              # peer_id -> StringName (F1 / F2 / F3 / OFF)
var coverage_targets: Dictionary = {}   # peer_id -> opposing peer_id

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
	roles = AIRoleAssignment.compute(snapshot, team_id, _team_id_resolver, _is_human_resolver)
	coverage_targets = AICoverageAssignment.compute(
			snapshot, team_id, _own_goal_z, _team_id_resolver, roles)


func get_role(peer_id: int) -> StringName:
	return roles.get(peer_id, AIRoleAssignment.ROLE_OFF)


func get_coverage_target(peer_id: int) -> int:
	# Returns 0 (sentinel — no real peer_id is 0) when no mark assigned.
	return coverage_targets.get(peer_id, 0)
