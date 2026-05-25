class_name WorldSnapshot
extends RefCounted

# Flat snapshot of all actor states at a single host timestamp.
# Used by StateBufferManager.get_state_at() for lag-compensated rewind (Phase 7).

var host_timestamp: float = 0.0
var skater_states: Dictionary[int, SkaterNetworkState] = {}  # peer_id -> state
var puck_state: PuckNetworkState = null
var goalie_states: Dictionary[int, GoalieNetworkState] = {}  # team_id -> state

# AI-helper caches — populated by GameManager once per host physics frame
# on the live `current_snapshot` only. Lag-comp rewind snapshots
# (PickupClaimResolver / PokeClaimResolver) leave these empty; AI code
# shouldn't consume rewind snapshots anyway. Read via `.get(team_id, ...)`.
var teammate_ids_by_team: Dictionary[int, Array] = {}     # team_id -> Array[int] (peer_ids)
var closest_to_puck_by_team: Dictionary[int, int] = {}    # team_id -> peer_id (-1 if team empty)

func get_skater_state(peer_id: int) -> SkaterNetworkState:
	return skater_states.get(peer_id)
