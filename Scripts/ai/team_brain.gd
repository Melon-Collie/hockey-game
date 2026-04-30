class_name TeamBrain
extends RefCounted

# Per-team strategy node. Owns role assignments + a tiny blackboard. Driven
# by GameManager._physics_process (host only) — ticks once every TICK_PERIOD
# seconds rather than every physics frame so role decisions don't churn at
# 240 Hz. Spec called for a 6 Hz Timer Node; we use a RefCounted with an
# accumulator to keep ownership/lifecycle simpler.
#
# Phase 4: blackboard is just `roles: Dictionary[int, StringName]`. Future
# phases will add anchors per role, possession flag, zone flag, etc.
#
# Consumes the existing WorldSnapshot captured by StateBufferManager.
# team_id_resolver is `func(peer_id: int) -> int` — bound by GameManager
# at construction (see _registry.resolve_team_id_for_peer).

const TICK_PERIOD: float = 1.0 / 6.0

var team_id: int = 0
var roles: Dictionary = {}    # peer_id -> StringName (F1 / OFF)

var _accumulator: float = 0.0
var _team_id_resolver: Callable = Callable()


func _init(t: int, resolver: Callable) -> void:
	team_id = t
	_team_id_resolver = resolver


# Called every host physics frame from GameManager. Snapshot is the freshest
# captured world state (delay 0). Internally rate-limited to TICK_PERIOD.
func tick(delta: float, snapshot: WorldSnapshot) -> void:
	_accumulator += delta
	if _accumulator < TICK_PERIOD:
		return
	_accumulator -= TICK_PERIOD
	roles = AIRoleAssignment.compute(snapshot, team_id, _team_id_resolver)


func get_role(peer_id: int) -> StringName:
	return roles.get(peer_id, AIRoleAssignment.ROLE_OFF)
