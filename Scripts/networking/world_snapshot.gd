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
# Per-skater smoothed acceleration (XZ, m/s²), a GLOBAL dead-reckoning read
# shared by every bot instead of each bot recomputing the identical velocity
# diff every tick. Populated by reference from the host's AIAccelerationTracker
# on `current_snapshot` only (empty on rewind snapshots). Read via `.get(pid,
# Vector3.ZERO)`. Feeds receiver-lead in pass scoring / PASS_PRESSED aim.
var accel_by_peer: Dictionary[int, Vector3] = {}          # peer_id -> smoothed accel

# Bot reaction-delay support. `puck_state.carrier_peer_id` on the AI snapshot
# carries the DEBOUNCED (delayed) carrier so all AI consumers react to
# possession changes a beat late (see GameManager._apply_bot_carrier_reaction_
# delay). This field stashes the REAL current carrier so a bot can still read
# its OWN possession instantly (proprioception — you know the moment the puck
# is on your stick). -1 = loose.
var real_puck_carrier_peer_id: int = -1

func get_skater_state(peer_id: int) -> SkaterNetworkState:
	return skater_states.get(peer_id)
