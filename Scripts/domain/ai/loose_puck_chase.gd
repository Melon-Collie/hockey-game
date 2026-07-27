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

# ── Path race (fast pucks) ───────────────────────────────────────────────────
# Above FAST_PUCK_SPEED the puck's path diverges from its position inside
# the race horizon, and every current-position read lies: the man chasing a
# rim's tail from a metre back "wins" a race he can never finish (the puck
# outruns him too), while the far-side skater whose true intercept is where
# the wrap comes to him reads as hopeless — so he declines the chase and the
# rim rides the whole zone untouched. Fast pucks therefore race on the
# friction + board-aware predicted path: at each step T of the walk, a
# skater makes the intercept iff his calibrated ETA to that point fits
# inside T. Slow pucks keep the cheap bounded-lead read (path ≈ position).
const FAST_PUCK_SPEED_M_S: float = 4.0
const RACE_LOOKAHEAD_S: float = 3.0
# 0.25 s steps — fine enough that the RETRIEVAL enter margin (0.25 s) can
# still resolve between quantized path times.
const RACE_STEPS: int = 12

# ── Race commitment (is that body actually going for the puck?) ─────────────
# First-stride floor: a skater actually running a race for a loose puck
# exceeds this closing speed toward it within his first strides; below it
# the body is standing or skating elsewhere — not a collector, whatever his
# hypothetical ETA says. Two consumers, both fixing a "puck sits there while
# everyone stares" freeze:
#   - the election (below): a HUMAN teammate can't be assigned by election,
#     so he only suppresses the bots while demonstrably playing the puck;
#   - the chase decline (AIRoleHelpers.loose_puck_race_lost): an opponent
#     who is NOT running the race must not talk our chaser out of it — with
#     both teams declining on hypothetical winners, nobody ever went.
const RACE_COMMIT_MIN_CLOSING_M_S: float = 1.0


# On the point (inside the physical contest band — standing there IS the play,
# no motion needed) or genuinely closing on it.
static func committed_to_point(s: SkaterNetworkState, point: Vector3) -> bool:
	var dx: float = point.x - s.position.x
	var dz: float = point.z - s.position.z
	var d: float = sqrt(dx * dx + dz * dz)
	if d <= AIActionScoring.CHASE_CONTEST_MARGIN_M:
		return true
	return (s.velocity.x * dx + s.velocity.z * dz) / d \
			>= RACE_COMMIT_MIN_CLOSING_M_S


# On the puck (inside the physical contest band) or genuinely closing on it.
static func committed_to_race(s: SkaterNetworkState, puck_pos: Vector3) -> bool:
	return committed_to_point(s, puck_pos)
# Arrival slack a fast-puck intercept must clear: the reception setup time
# (swing the blade to the gate on the puck's line and get set — a body
# arriving dead-even with a rim at pace corrals nothing). A zero-slack
# intercept read fed steering aims the body where it meets the puck exactly,
# so any execution slop missed by a hair, re-solved to a new zero-slack
# point further along, and missed again — the sliding-intercept treadmill
# the breakout traces showed (kill reads hovering 1-2 s for three straight
# seconds while the rim stayed ahead). Requiring the margin picks the point
# far enough along the path that the skater genuinely arrives EARLY and
# sets — the real wall-kill stance.
const KILL_SETUP_MARGIN_S: float = 0.25


static func is_fast_puck(puck_vel: Vector3) -> bool:
	return puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z \
			> FAST_PUCK_SPEED_M_S * FAST_PUCK_SPEED_M_S


# Sprint-aware race cap for one candidate (BotSprintRules.race_speed): cruise
# and sprint ceiling from caps (league defaults when unset — a league body
# sprints), pool and lockout from the replicated skater state, race length
# approximated by the straight distance to the puck's current spot. THE seam
# through which Speed's sprint separation reaches every race read — election,
# RETRIEVAL margin, and the race-lost decline all price with it, so they
# can't disagree about who has the extra gear.
static func race_vmax(s: SkaterNetworkState, caps: AISkaterCaps,
		puck_pos: Vector3) -> float:
	var cruise: float = caps.max_speed if caps != null \
			else AIActionScoring.SKATER_REF_SPEED_M_S
	var mult: float = caps.sprint_speed_mult if caps != null \
			else AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
	return BotSprintRules.race_speed(cruise, mult, s.stamina, s.sprint_locked,
			Vector2(puck_pos.x - s.position.x, puck_pos.z - s.position.z).length())


# The shared predicted path for one race — memoized on the exact puck state,
# because every consumer in one AI tick (both teams' elections, the brain's
# RETRIEVAL read, each chaser's race-lost decline) races the SAME puck: one
# walk per tick, not one per caller. Callers must treat the returned array
# as read-only.
static var _traj_cache_pos: Vector3 = Vector3.INF
static var _traj_cache_vel: Vector3 = Vector3.INF
static var _traj_cache: Array[Vector3] = []


static func race_trajectory(puck_pos: Vector3, puck_vel: Vector3) -> Array[Vector3]:
	if puck_pos == _traj_cache_pos and puck_vel == _traj_cache_vel:
		return _traj_cache
	_traj_cache_pos = puck_pos
	_traj_cache_vel = puck_vel
	_traj_cache = AITrajectory.predict_puck(puck_pos, puck_vel, RACE_STEPS,
			RACE_LOOKAHEAD_S / float(RACE_STEPS))
	return _traj_cache


# Earliest time (s) this skater can meet the puck ON its predicted path,
# arriving with the KILL_SETUP_MARGIN_S of slack that makes the contact a
# set-and-corral instead of a dead heat. Quantized to the walk's step
# times. When no step is makeable the race resolves at the settled end of
# the walk: the skater collects the puck where it stops (or exits the
# horizon), arriving no earlier than the horizon itself.
static func path_intercept_time(traj: Array[Vector3], step_dt: float,
		skater_pos: Vector3, skater_vel: Vector3, max_speed: float) -> float:
	for i: int in traj.size():
		var t_step: float = (i + 1) * step_dt
		var t_set: float = t_step - KILL_SETUP_MARGIN_S
		if t_set <= 0.0:
			continue
		# Exact prune: even at a flying top-speed start, ETA ≥ dist / v_max —
		# skip the full phase-model call when that bound alone misses T.
		var dx: float = traj[i].x - skater_pos.x
		var dz: float = traj[i].z - skater_pos.z
		var reach: float = max_speed * t_set
		if dx * dx + dz * dz > reach * reach:
			continue
		if AIActionScoring.time_to_arrive(
				skater_pos, traj[i], skater_vel, max_speed) <= t_set:
			return t_step
	var horizon: float = traj.size() * step_dt
	return maxf(horizon, AIActionScoring.time_to_arrive(
			skater_pos, traj[-1], skater_vel, max_speed))


# The path point a path_intercept_time result names — the spot on the walk the
# skater actually meets the puck at. Callers that need to ask something ABOUT
# the intercept (is that body committed to going there?) map the quantized time
# back through this so they can never disagree with the race read that produced
# it. Times past the horizon resolve at the settled end of the walk.
static func path_intercept_point(traj: Array[Vector3], step_dt: float,
		t: float) -> Vector3:
	if traj.is_empty():
		return Vector3.INF
	return traj[clampi(int(round(t / step_dt)) - 1, 0, traj.size() - 1)]


# ── Incidental reach (a free puck at your feet is yours) ─────────────────────
# One stride beyond the blade. The election answers "who runs the RACE", which
# is the right question for a puck 15 m away and the wrong one for a puck
# rolling past a defenceman's skates: he watched it go by because a teammate
# owned a better ETA to it, and nobody plays a puck they could have reached
# without moving. This is the band inside which the election doesn't apply —
# whoever the puck comes to plays it. Bounded to reach + a stride so it stays
# "extend the stick", never a second chaser abandoning his job.
const INCIDENTAL_STRIDE_M: float = 1.5


# True when the loose puck's own predicted path crosses inside this skater's
# reach band early enough for him to meet it there. Two physical quantities and
# nothing else: the band is his blade reach plus one stride, and the timing test
# is his calibrated ETA against the puck's own time to the crossing point.
#
# Segment-wise (closest approach along each step of the walk, not the sampled
# endpoints): at rim speeds the puck covers ~3.75 m per 0.25 s step, so a
# point-sampled band test would step clean OVER a skater the puck passes a
# metre from. No KILL_SETUP_MARGIN_S here — that margin buys the setup skate for
# a kill you have to travel to, and a puck arriving inside your own reach needs
# no travel, just the stick out.
static func puck_comes_to_reach(
		puck_pos: Vector3, puck_vel: Vector3,
		self_pos: Vector3, self_vel: Vector3,
		max_speed: float, reach: float) -> bool:
	var band: float = reach + INCIDENTAL_STRIDE_M
	var band2: float = band * band
	var traj: Array[Vector3] = race_trajectory(puck_pos, puck_vel)
	var step_dt: float = RACE_LOOKAHEAD_S / float(RACE_STEPS)
	var prev: Vector3 = puck_pos
	for i: int in traj.size():
		var f: float = _segment_meet_fraction(prev, traj[i], self_pos)
		var meet := Vector3(prev.x + (traj[i].x - prev.x) * f, 0.0,
				prev.z + (traj[i].z - prev.z) * f)
		prev = traj[i]
		var dx: float = meet.x - self_pos.x
		var dz: float = meet.z - self_pos.z
		if dx * dx + dz * dz > band2:
			continue
		if AIActionScoring.time_to_arrive(self_pos, meet, self_vel, max_speed) \
				<= (i + f) * step_dt:
			return true
	return false


# ── Teammate yield (don't stab at your own teammate's puck) ──────────────────
# A contested pickup is a possession FIGHT, and it is symmetric by design: two
# blades on the same loose puck, nobody awarded it, the puck squirting free
# biased toward the stronger blade. That is right for opponents and right for a
# genuine jam — three sticks whacking at a puck in the crease SHOULD leave it
# loose. What it is not right for is our own two bots converging and mutually
# denying each other: that isn't a jam, it's a coordination failure, and it read
# in-game as two players arriving together and both missing.
#
# So the fix belongs upstream of the contest, not in it. Don't put your blade in
# when a teammate's blade is already first to the puck — he takes it, you
# support, which is what the players would do. The contest rule is untouched and
# still fires on every real jam, faceoff draws included.
#
# Deadlock-free by construction: yielding requires the OTHER blade to be nearer
# the puck by more than YIELD_MARGIN_M, and that relation cannot hold in both
# directions at once, so two bots can never both yield and leave the puck.
const YIELD_MARGIN_M: float = 0.25
# How near a teammate's blade must be to the puck to be "on it" at all. Outside
# this he isn't about to take anything, so he can't make anyone yield. Sized
# just past the pickup radius (PuckController.PICKUP_RADIUS, 0.5 m) so it covers
# the blade that is about to make contact and nothing further out.
const YIELD_CONTEST_M: float = 0.7


# Is a teammate's blade clearly first to this loose puck? Reads the host-only
# `blade_contact_world` (the AI runs host-side, so it is populated); a zero
# blade means the field is absent and we simply don't yield.
static func teammate_first_to_puck(
		skater_states: Dictionary, teammate_ids: Array, self_pid: int,
		self_blade: Vector3, puck_pos: Vector3) -> bool:
	var mine: float = _xz_dist(self_blade, puck_pos)
	for pid: int in teammate_ids:
		if pid == self_pid:
			continue
		var s: SkaterNetworkState = skater_states.get(pid)
		if s == null or s.is_ghost:
			continue
		var blade: Vector3 = s.blade_contact_world
		if blade == Vector3.ZERO:
			continue
		var theirs: float = _xz_dist(blade, puck_pos)
		if theirs <= YIELD_CONTEST_M and theirs < mine - YIELD_MARGIN_M:
			return true
	return false


static func _xz_dist(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


# Geometry only: does the walk ever bring the puck inside `band` of `pos`?
# The "does he even have to MOVE to play this?" half of puck_comes_to_reach,
# without the timing test — which is the right question for a body whose
# commitment we're judging rather than our own arrival.
static func path_enters_band(traj: Array[Vector3], puck_pos: Vector3,
		pos: Vector3, band: float) -> bool:
	var band2: float = band * band
	var prev: Vector3 = puck_pos
	for i: int in traj.size():
		var f: float = _segment_meet_fraction(prev, traj[i], pos)
		var dx: float = prev.x + (traj[i].x - prev.x) * f - pos.x
		var dz: float = prev.z + (traj[i].z - prev.z) * f - pos.z
		prev = traj[i]
		if dx * dx + dz * dz <= band2:
			return true
	return false


# Fraction along segment a→b (clamped to the segment) closest to `pos`, XZ only.
static func _segment_meet_fraction(a: Vector3, b: Vector3, pos: Vector3) -> float:
	var seg_x: float = b.x - a.x
	var seg_z: float = b.z - a.z
	var seg_len2: float = seg_x * seg_x + seg_z * seg_z
	if seg_len2 <= 0.000001:
		return 0.0
	return clampf(((pos.x - a.x) * seg_x + (pos.z - a.z) * seg_z) / seg_len2,
			0.0, 1.0)


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
#   human_ids      — teammate_ids under HUMAN control. Election can't make a
#                    human skate: he suppresses the bots only while he is
#                    demonstrably playing the puck (committed_to_race) — a
#                    human standing over a loose puck ignoring it used to
#                    freeze every bot out of the pickup.
#   camped_ids     — teammates opted out of loose-puck work (the one-timer
#                    camp veto). Electing one anyway froze the whole team:
#                    the camper refused the chase and nobody else was
#                    elected. Skipped so the next-best teammate goes; if the
#                    filters exclude EVERYONE the raw election runs instead
#                    (someone must own the read — the camper's own veto
#                    still governs its behavior, exactly as before).
static func elect(
		skater_states: Dictionary,
		teammate_ids: Array,
		puck_pos: Vector3,
		puck_vel: Vector3,
		prev_elected: int,
		caps_by_peer: Dictionary = {},
		puck_playable: bool = true,
		human_ids: Array = [],
		camped_ids: Array = []) -> int:
	if not puck_playable:
		return -1
	# Fast puck → the shared path walk (see the path-race block above).
	var traj: Array[Vector3] = []
	if is_fast_puck(puck_vel):
		traj = race_trajectory(puck_pos, puck_vel)
	var step_dt: float = RACE_LOOKAHEAD_S / float(RACE_STEPS)
	var best_pid: int = -1
	var best_t: float = INF
	for pid: int in teammate_ids:
		var s: SkaterNetworkState = skater_states.get(pid)
		if s == null:
			continue
		if not camped_ids.is_empty() and camped_ids.has(pid):
			continue
		if not human_ids.is_empty() and human_ids.has(pid) \
				and not committed_to_race(s, puck_pos):
			continue
		# Each candidate races at ITS real sprint-aware race cap (Speed +
		# the stamina-gated sprint gear) — a fast skater genuinely reaches
		# a loose puck first. Missing caps → league default.
		var max_speed: float = race_vmax(s, caps_by_peer.get(pid), puck_pos)
		var t: float = path_intercept_time(traj, step_dt, s.position, s.velocity, max_speed) \
				if not traj.is_empty() \
				else _intercept_time(s.position, s.velocity, puck_pos, puck_vel, max_speed)
		# Incumbent hysteresis: challengers pay HYSTERESIS_S, so the
		# current chaser keeps the role unless beaten by the margin.
		if pid != prev_elected:
			t += HYSTERESIS_S
		# Deterministic tie-break by lower peer_id (matches AIRoleSlots).
		if t < best_t or (t == best_t and (best_pid == -1 or pid < best_pid)):
			best_t = t
			best_pid = pid
	if best_pid == -1 and (not camped_ids.is_empty() or not human_ids.is_empty()):
		# Filters excluded every teammate — fall back to the raw election.
		return elect(skater_states, teammate_ids, puck_pos, puck_vel,
				prev_elected, caps_by_peer)
	return best_pid


# Raw best intercept time (seconds) among `ids` to the loose puck — the
# race-read half of the election, with no hysteresis and no winner identity.
# Used by the TeamBrain's RETRIEVAL upgrade (docs/breakout-plan.md Phase A)
# to compare OUR best against THEIRS with the same intercept model the
# chase election runs, so "who wins the race" and "who is elected to run
# it" can never disagree. INF when no eligible skater.
static func best_intercept_time(
		skater_states: Dictionary,
		ids: Array,
		puck_pos: Vector3,
		puck_vel: Vector3,
		caps_by_peer: Dictionary = {}) -> float:
	var traj: Array[Vector3] = []
	if is_fast_puck(puck_vel):
		traj = race_trajectory(puck_pos, puck_vel)
	var step_dt: float = RACE_LOOKAHEAD_S / float(RACE_STEPS)
	var best_t: float = INF
	for pid: int in ids:
		var s: SkaterNetworkState = skater_states.get(pid)
		if s == null:
			continue
		var max_speed: float = race_vmax(s, caps_by_peer.get(pid), puck_pos)
		var t: float = path_intercept_time(traj, step_dt, s.position, s.velocity, max_speed) \
				if not traj.is_empty() \
				else _intercept_time(s.position, s.velocity, puck_pos, puck_vel, max_speed)
		if t < best_t:
			best_t = t
	return best_t


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
