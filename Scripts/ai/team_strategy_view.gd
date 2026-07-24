class_name TeamStrategyView
extends RefCounted

# Read-only team-strategy surface the AI role behaviors consume during dispatch.
# Two implementations share it (see docs/ai-threading-plan.md, Phase 3a):
#   - TeamBrain          — the live strategy node (read directly by unit tests
#                          and, as a fallback, whenever no frozen view exists).
#   - TeamBrainView      — a frozen per-tick copy the off-thread dispatch reads,
#                          so the worker never touches the live brain while the
#                          main thread mutates it (pings / retick / spawns).
#
# RoleContext.team_brain holds one of these. Existing tests set the live brain
# (it is-a TeamStrategyView), so nothing in the test path changes; production
# dispatch reads the frozen view. Defaults below are the "no strategy" neutral,
# matching an unwired context.

func get_slot(_peer_id: int) -> int:
	return AIRoleSlots.Slot.NONE

func get_anchor(_peer_id: int, _snapshot: WorldSnapshot) -> Vector3:
	return Vector3.ZERO

func strong_x() -> float:
	return 1.0

func assigned_threat(_peer_id: int) -> int:
	return -1

func position_of(_peer_id: int) -> int:
	return 0

func is_one_timer_ready(_peer_id: int) -> bool:
	return false

func ping_move_target(_peer_id: int) -> Vector3:
	return Vector3.INF

func ping_shoot(_peer_id: int) -> bool:
	return false

func ping_pass_target(_peer_id: int) -> int:
	return -1

# Team-scoped (not per-peer): at most one bot is under a GET_PUCK retrieval order
# at a time, so the view freezes the ordered peer as a scalar rather than a dict.
func ping_chase_peer() -> int:
	return -1

func get_team_size() -> int:
	return GameRules.DEFAULT_TEAM_SIZE

func get_threat_shoot_base_by_opp() -> Dictionary[int, float]:
	return {}
