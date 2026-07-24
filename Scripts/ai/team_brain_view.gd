class_name TeamBrainView
extends TeamStrategyView

# Frozen per-tick copy of a TeamBrain's outputs (docs/ai-threading-plan.md,
# Phase 3a). Built on the main thread by TeamBrain.build_view once per frame,
# then read by the agent dispatch — in Phase 3c, off the physics thread. Reused
# per brain (refilled, never reallocated: hot-path allocation discipline), and
# because main only refills it *after* the worker has finished reading last
# tick's copy, no mutex or double-buffer is needed (see the plan's concurrency
# notes).
#
# Storage is public so TeamBrain.build_view can fill it directly; consumers read
# through the TeamStrategyView interface methods below.

var strong_x_val: float = 1.0
var team_size_val: int = GameRules.DEFAULT_TEAM_SIZE
var slot_by_peer: Dictionary[int, int] = {}
var anchor_by_peer: Dictionary[int, Vector3] = {}
var assigned_threat_by_peer: Dictionary[int, int] = {}
var position_by_peer: Dictionary[int, int] = {}
var one_timer_ready_by_peer: Dictionary[int, bool] = {}
var ping_move_by_peer: Dictionary[int, Vector3] = {}
var ping_shoot_by_peer: Dictionary[int, bool] = {}
var ping_pass_by_peer: Dictionary[int, int] = {}
var threat_shoot_base: Dictionary[int, float] = {}


func get_slot(peer_id: int) -> int:
	return slot_by_peer.get(peer_id, AIRoleSlots.Slot.NONE)


func get_anchor(peer_id: int, _snapshot: WorldSnapshot) -> Vector3:
	# The anchor was frozen against the build-time snapshot; the live snapshot
	# arg is ignored (the whole point is not to recompute off-thread).
	return anchor_by_peer.get(peer_id, Vector3.ZERO)


func strong_x() -> float:
	return strong_x_val


func assigned_threat(peer_id: int) -> int:
	return assigned_threat_by_peer.get(peer_id, -1)


func position_of(peer_id: int) -> int:
	return position_by_peer.get(peer_id, 0)


func is_one_timer_ready(peer_id: int) -> bool:
	return one_timer_ready_by_peer.get(peer_id, false)


func ping_move_target(peer_id: int) -> Vector3:
	return ping_move_by_peer.get(peer_id, Vector3.INF)


func ping_shoot(peer_id: int) -> bool:
	return ping_shoot_by_peer.get(peer_id, false)


func ping_pass_target(peer_id: int) -> int:
	return ping_pass_by_peer.get(peer_id, -1)


func get_team_size() -> int:
	return team_size_val


func get_threat_shoot_base_by_opp() -> Dictionary[int, float]:
	return threat_shoot_base
