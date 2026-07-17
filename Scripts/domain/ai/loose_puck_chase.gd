class_name AILoosePuckChase

# Pure-function election of which teammate should chase a loose puck.
# Replaces the raw straight-line "closest_to_puck_by_team" computation
# (formerly inline in GameManager._enrich_snapshot_for_ai) and fixes
# two failure modes that made bots late to loose pucks:
#
#   - Velocity / facing blindness: a bot nearer the puck but coasting
#     AWAY used to win the chase over a teammate already skating toward
#     it. Election now uses AIActionScoring.time_to_arrive, which folds
#     the bot's momentum into the estimate, so the teammate genuinely
#     arriving first gets the role.
#
#   - Flip-flop hesitation: with no stickiness, two near-equidistant
#     bots swapped "closest" every frame and each flickered
#     CHASE_PUCK <-> OFF_PUCK, so neither committed and the puck sat
#     loose. Incumbent hysteresis pins the role to the current chaser
#     unless a challenger beats them by HYSTERESIS_S.
#
# Stateless: the caller owns the per-team `prev_elected` and feeds it
# back each frame for the hysteresis term. Lives in the domain layer so
# it's GUT-testable without the engine.

# Incumbent keeps the chase unless a challenger's intercept time beats
# it by more than this margin. Units are seconds so it composes with
# time_to_arrive directly. ≈ 1 m of positional difference at the
# calibrated ETA's close-range standing-start rate (matches
# AIRoleSlots.HYSTERESIS_PENALTY_S — re-derived with the phase-model
# time_to_arrive). Enough to kill frame-to-frame swapping between
# geometrically-similar bots without making the role stale when a
# genuinely better-placed teammate appears. Tuning: raise toward 0.35
# if chasers still trade off mid-pursuit; lower toward 0.1 if a closer
# teammate takes too long to take over.
const HYSTERESIS_S: float = 0.2

# Single bounded round of puck lead so the election targets where the
# puck WILL be, not where it sits now — the difference that decides who
# wins a race for a puck squirting between two bots. Constant-velocity
# lead (the puck's friction decel is ignored at this horizon); capped at
# MAX_LEAD_S so a hard rim around the boards can't run the lead point
# away. The CHASE_PUCK state itself does the precise friction-aware
# lead-intercept once a bot is committed; this is only the coarse
# election lead.
const MAX_LEAD_S: float = 0.5


# Returns the peer_id that should chase the loose puck for this team, or
# -1 if the team has no eligible skater.
#   skater_states  — peer_id -> SkaterNetworkState (the full snapshot map)
#   teammate_ids   — this team's peer_ids
#   puck_pos/_vel  — loose puck world position and velocity (XZ used)
#   prev_elected   — last frame's elected chaser for this team (-1 if none)
#   puck_playable  — false for a DEAD loose puck (goalie smother / phase lock:
#                    pickup_locked with no carrier). Nobody can play a dead
#                    puck, so nobody is elected to chase it — every bot falls
#                    back to its positional role, which is the real behavior
#                    around a covered puck: attackers peel off the crease, the
#                    defense resets for the release instead of hovering over a
#                    puck they can't touch.
static func elect(
		skater_states: Dictionary,
		teammate_ids: Array,
		puck_pos: Vector3,
		puck_vel: Vector3,
		prev_elected: int,
		caps_by_peer: Dictionary = {},
		puck_playable: bool = true) -> int:
	if not puck_playable:
		return -1
	var best_pid: int = -1
	var best_t: float = INF
	for pid: int in teammate_ids:
		var s: SkaterNetworkState = skater_states.get(pid)
		if s == null:
			continue
		# Each candidate races at ITS real top speed (Speed) — a fast skater
		# genuinely reaches a loose puck first. Missing caps → league default.
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var max_speed: float = caps.max_speed if caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		var t: float = _intercept_time(s.position, s.velocity, puck_pos, puck_vel, max_speed)
		# Incumbent hysteresis: challengers pay HYSTERESIS_S, so the
		# current chaser keeps the role unless beaten by the margin.
		if pid != prev_elected:
			t += HYSTERESIS_S
		# Deterministic tie-break by lower peer_id (matches AIRoleSlots).
		if t < best_t or (t == best_t and (best_pid == -1 or pid < best_pid)):
			best_t = t
			best_pid = pid
	return best_pid


# Momentum-aware intercept time: lead the puck a coarse, bounded amount
# (its straight-line distance at ref skating speed, capped), then return
# the bot's momentum-aware time to that predicted point.
static func _intercept_time(bot_pos: Vector3, bot_vel: Vector3,
		puck_pos: Vector3, puck_vel: Vector3,
		max_speed: float = AIActionScoring.SKATER_REF_SPEED_M_S) -> float:
	var dx: float = puck_pos.x - bot_pos.x
	var dz: float = puck_pos.z - bot_pos.z
	var rough_dist: float = sqrt(dx * dx + dz * dz)
	var lead: float = minf(rough_dist / max_speed, MAX_LEAD_S)
	var predicted := Vector3(
			puck_pos.x + puck_vel.x * lead,
			0.0,
			puck_pos.z + puck_vel.z * lead)
	return AIActionScoring.time_to_arrive(bot_pos, predicted, bot_vel, max_speed)
