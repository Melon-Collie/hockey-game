class_name AILoosePuckChase

# Pure-function election of which teammate should chase a loose puck. Two
# things it must get right, both of which a raw closest-to-puck distance gets
# wrong and both of which read as "bots are late to loose pucks":
#
#   - Velocity / facing. A bot nearer the puck but coasting AWAY is not the one
#     arriving first. Election uses AIActionScoring.time_to_arrive, which folds
#     momentum into the estimate.
#
#   - Flip-flop hesitation. Two near-equidistant bots will swap "closest" every
#     frame and each flicker CHASE_PUCK <-> OFF_PUCK, so neither commits and the
#     puck sits loose. Incumbent hysteresis pins the role to the current chaser
#     unless a challenger beats them by HYSTERESIS_S.
#
# Stateless: the caller owns the per-team `prev_elected` and feeds it back each
# frame for the hysteresis term. Lives in the domain layer so it's GUT-testable
# without the engine.

# Incumbent keeps the chase unless a challenger's intercept time beats
# it by more than this margin. Units are seconds so it composes with
# time_to_arrive directly. ≈ 1 m of positional difference at the
# calibrated ETA's close-range standing-start rate (matches
# AIRoleSlots.HYSTERESIS_PENALTY_S — re-derived with the phase-model
# time_to_arrive). Enough to kill frame-to-frame swapping between
# geometrically-similar bots without making the role stale when a
# genuinely better-placed teammate appears.
const HYSTERESIS_S: float = 0.2

# ── Path race ────────────────────────────────────────────────────────────────
# EVERY loose puck races on its friction + board-aware predicted path: at each
# step T of the walk, a skater makes the intercept iff his calibrated ETA to
# that point fits inside T. A current-position read lies about both ends of the
# race — the man chasing a puck's tail from a metre back "wins" a race the puck
# outruns him in, while the skater the puck is travelling TOWARD, whose true
# intercept is where it comes to him, reads as hopeless and declines.
#
# NO speed gate on the walk. A slow puck's path is not approximately its
# position: ICE_FRICTION 0.05 decelerates a puck at 0.49 m/s², so a 3.9 m/s
# roller travels 9.5 m inside the race horizon and takes 8 s to settle, and a
# bounded straight-line lead standing in for it runs through the boards.
const RACE_LOOKAHEAD_S: float = 3.0
# 0.25 s steps. The race read interpolates within the step it crosses in
# (path_intercept_time), so this is the resolution of the PATH, not of the
# answer — a coarser walk costs geometric fidelity, never race margin.
const RACE_STEPS: int = 12

# Above this the puck must be met EARLY — blade swung to the gate and the body
# set — so its intercept is judged with KILL_SETUP_MARGIN_S of arrival slack.
# Below it a skater can meet the puck exactly and the intercept converges on
# its own. This is a statement about the RECEPTION, not about whether the
# puck's path is worth predicting; see the block above for why those are
# separate questions.
const FAST_PUCK_SPEED_M_S: float = 4.0

# ── Race commitment (is that body actually going for the puck?) ─────────────
# First-stride floor: a skater actually running a race for a loose puck
# exceeds this closing speed toward it within his first strides; below it
# the body is standing or skating elsewhere — not a collector, whatever his
# hypothetical ETA says. Two consumers:
#   - the election (below): a HUMAN teammate can't be assigned by election,
#     so he only suppresses the bots while demonstrably playing the puck;
#   - the chase decline (AIRoleHelpers.loose_puck_race_lost): an opponent
#     who is NOT running the race must not talk our chaser out of it, or both
#     teams decline on hypothetical winners and nobody goes.
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
# arriving dead-even with a rim at pace corrals nothing). Zero slack is a
# treadmill: steering aims the body where it meets the puck exactly, execution
# slop misses by a hair, and the read re-solves to a new zero-slack point
# further along. The margin picks the point far enough along the path that the
# skater genuinely arrives EARLY and sets — the real wall-kill stance.
const KILL_SETUP_MARGIN_S: float = 0.25


static func is_fast_puck(puck_vel: Vector3) -> bool:
	return puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z \
			> FAST_PUCK_SPEED_M_S * FAST_PUCK_SPEED_M_S


# Arrival slack a race read must leave itself against this puck. One definition,
# shared by the election, the race-lost decline and the chase state's own
# lead-intercept, so they can never disagree about how early a given puck has to
# be met.
static func setup_margin(puck_vel: Vector3) -> float:
	return KILL_SETUP_MARGIN_S if is_fast_puck(puck_vel) else 0.0


# Sprint-aware race cap for one candidate (BotSprintRules.race_speed): cruise
# and sprint ceiling from caps (league defaults when unset — a league body
# sprints), pool and lockout from the replicated skater state, race length
# approximated by the straight distance to the puck's current spot. THE seam
# through which Speed's sprint separation reaches every race read: the election
# and the race-lost decline both price with it, so they cannot disagree about
# who has the extra gear.
static func race_vmax(s: SkaterNetworkState, caps: AISkaterCaps,
		puck_pos: Vector3) -> float:
	var cruise: float = caps.max_speed if caps != null \
			else AIActionScoring.SKATER_REF_SPEED_M_S
	var mult: float = caps.sprint_speed_mult if caps != null \
			else AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
	return BotSprintRules.race_speed(cruise, mult, s.stamina, s.sprint_locked,
			Vector2(puck_pos.x - s.position.x, puck_pos.z - s.position.z).length())


# ── Why the `reach` argument below is for the SELF read only ────────────────
# A skater meets a loose puck when his BLADE touches it, not when his navel
# lands on it, so the intercept a body STEERS to must not charge the last
# stick-length as travel: without reach the solve pushed the meeting point
# downstream, and the man who would have swept the puck up on the way past
# instead read himself as late and aimed further along.
#
# The COMPARATIVE reads — the election, best_intercept_time, the race-lost
# decline — deliberately leave it at 0. Two reasons, and the second is the
# load-bearing one:
#   - Reach is nearly common to all racers, so it barely moves a RANKING; it
#     is the absolute arrival that it corrects.
#   - It destroys the resolution the election depends on. Every body within a
#     stick of the puck solves to t = 0, so bots the sub-step interpolation
#     exists to separate all tie and fall through to the peer-id tie-break —
#     the exact defect that interpolation was added to fix. Measured, putting
#     reach in the election left a crossing cutter unattended (D-zone coverage
#     fixture: 2.49 uncovered attackers/tick against a 2.2 bar).
# "Is this puck inside my stick" is already its own read (puck_comes_to_reach),
# which overrides the election rather than competing inside it.


# The shared predicted path for one race — memoized on the exact puck state,
# because every consumer in one AI tick (both teams' elections, each chaser's
# race-lost decline, every reach-band read) races the SAME puck: one walk per
# tick, not one per caller. Callers must treat the returned array as
# read-only.
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
# arriving with `margin` of slack (see setup_margin) so a fast contact is a
# set-and-corral instead of a dead heat. `puck_pos` is the walk's origin — the
# path point at t=0, which the sub-step solve below needs as its left endpoint.
# When no step is makeable the race resolves at the settled end of the walk: the
# skater collects the puck where it stops (or exits the horizon), arriving no
# earlier than the horizon itself.
#
# `accel` is the redirect authority the ETA prices the cross-momentum shed at.
# Cross-player callers (the election, which must rank every bot on one shared
# baseline) leave it at the league default; a bot solving its OWN chase passes
# its attribute-scaled max_accel, exactly as time_to_arrive documents.
static func path_intercept_time(traj: Array[Vector3], step_dt: float,
		puck_pos: Vector3, skater_pos: Vector3, skater_vel: Vector3,
		max_speed: float, margin: float = KILL_SETUP_MARGIN_S,
		accel: float = AIActionScoring.SHED_ACCEL_DEFAULT_M_S2,
		reach: float = 0.0) -> float:
	if traj.is_empty():
		return INF
	for i: int in traj.size():
		var t_step: float = (i + 1) * step_dt
		var t_set: float = t_step - margin
		if t_set <= 0.0:
			continue
		# Exact prune: even at a flying top-speed start, ETA ≥ (dist − reach) /
		# v_max — skip the full phase-model call when that bound alone misses T.
		# The blade span widens the bound; leaving it off the prune would drop
		# steps the reach-aware ETA below would have made.
		var dx: float = traj[i].x - skater_pos.x
		var dz: float = traj[i].z - skater_pos.z
		var span: float = max_speed * t_set + reach
		if dx * dx + dz * dz > span * span:
			continue
		var eta: float = _reach_eta(
				skater_pos, traj[i], skater_vel, max_speed, accel, reach)
		if eta > t_set:
			continue
		# Crossing found — now solve WHERE in the step it happens. Returning
		# t_step would quantize every race read to the walk's grid, ~2 m of
		# skating at 0.25 s, so bots separated by less than a step read as tied
		# and the election falls through to its peer-id tie-break.
		# Linear-interpolate the arrival slack s(t) = (t − margin) − ETA(t)
		# across the step it changes sign in. Exact for a settled puck: s is
		# then linear in t, so the crossing IS the skater's ETA.
		var prev_t: float = i * step_dt
		var prev_point: Vector3 = traj[i - 1] if i > 0 else puck_pos
		var prev_slack: float = (prev_t - margin) - _reach_eta(
				skater_pos, prev_point, skater_vel, max_speed, accel, reach)
		if prev_slack >= 0.0:
			return prev_t   # already makeable at the left endpoint
		return prev_t + (t_step - prev_t) * (-prev_slack / (t_set - eta - prev_slack))
	var horizon: float = traj.size() * step_dt
	return maxf(horizon, _reach_eta(
			skater_pos, traj[-1], skater_vel, max_speed, accel, reach))


# ETA for the BLADE to touch `point`, rather than for the body to land on it.
# The destination is the nearest spot on the reach circle around `point` — the
# path point pulled `reach` back along the approach line — so the last stick-
# length is never charged as travel. Already inside reach is 0: the stick is on
# it now.
static func _reach_eta(from_pos: Vector3, point: Vector3, vel: Vector3,
		max_speed: float, accel: float, reach: float) -> float:
	if reach <= 0.0:
		return AIActionScoring.time_to_arrive(from_pos, point, vel, max_speed, accel)
	var dx: float = point.x - from_pos.x
	var dz: float = point.z - from_pos.z
	var d: float = sqrt(dx * dx + dz * dz)
	if d <= reach:
		return 0.0
	var f: float = (d - reach) / d
	return AIActionScoring.time_to_arrive(from_pos,
			Vector3(from_pos.x + dx * f, point.y, from_pos.z + dz * f),
			vel, max_speed, accel)


# The path point a path_intercept_time result names — the spot on the walk the
# skater actually meets the puck at. Callers that need to ask something ABOUT
# the intercept (is that body committed to going there? where do I steer?) map
# the time back through this so they can never disagree with the race read that
# produced it. Times past the horizon resolve at the settled end of the walk.
#
# INTERPOLATED, because the time it maps is a sub-step solve: snapping to the
# nearest sample threw away exactly the precision path_intercept_time exists to
# recover, and at 0.25 s steps that is up to ~1 m of aim error at rim speeds.
# `puck_pos` is the walk's origin (the path point at t=0), so an intercept
# inside the first step — a puck arriving at a skater who is already there,
# which is the whole near-puck regime — resolves between the puck's spot NOW
# and traj[0] rather than being clamped forward onto traj[0].
static func path_intercept_point(traj: Array[Vector3], step_dt: float,
		puck_pos: Vector3, t: float) -> Vector3:
	if traj.is_empty():
		return Vector3.INF
	# traj[i] is the path at (i+1)*step_dt, so time t sits at index t/step_dt − 1;
	# index −1 is the origin.
	var idx: float = t / step_dt - 1.0
	var hi: int = clampi(int(ceil(idx)), 0, traj.size() - 1)
	var lo: int = hi - 1
	var from: Vector3 = traj[lo] if lo >= 0 else puck_pos
	return from.lerp(traj[hi], clampf(idx - float(lo), 0.0, 1.0))


# ── Incidental reach (a free puck at your feet is yours) ─────────────────────
# One stride beyond the blade — the band inside which the election does not
# apply, because whoever the puck comes to plays it. Bounded to reach + a stride
# so it stays "extend the stick", never a second chaser abandoning his job.
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
# The contested-pickup rule stays symmetric — two blades on one loose puck means
# nobody is awarded it — so a bot keeps its blade OUT when a teammate's is
# already first to the puck, upstream of the contest rather than inside it.
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
#                    human skate, so he suppresses the bots only while he is
#                    demonstrably playing the puck (committed_to_race).
#   camped_ids     — teammates opted out of loose-puck work (the one-timer
#                    camp veto). Skipped, so the next-best teammate goes and
#                    a camper cannot be elected into a chase it will refuse.
#                    If the filters exclude EVERYONE the raw election runs
#                    instead — someone must own the read, and the camper's
#                    own veto still governs its behavior.
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
	# Every loose puck races on the shared path walk (see the path-race block
	# above) — memoized on the puck state, so both teams' elections, every
	# chaser's decline and every reach-band read share ONE walk per tick.
	var traj: Array[Vector3] = race_trajectory(puck_pos, puck_vel)
	var step_dt: float = RACE_LOOKAHEAD_S / float(RACE_STEPS)
	var margin: float = setup_margin(puck_vel)
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
		var t: float = path_intercept_time(traj, step_dt, puck_pos,
				s.position, s.velocity, max_speed, margin)
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
# Lets a caller compare OUR best against THEIRS through the same intercept model
# the election runs, so "who wins the race" and "who is elected to run it" can
# never disagree. INF when no eligible skater.
static func best_intercept_time(
		skater_states: Dictionary,
		ids: Array,
		puck_pos: Vector3,
		puck_vel: Vector3,
		caps_by_peer: Dictionary = {}) -> float:
	var traj: Array[Vector3] = race_trajectory(puck_pos, puck_vel)
	var step_dt: float = RACE_LOOKAHEAD_S / float(RACE_STEPS)
	var margin: float = setup_margin(puck_vel)
	var best_t: float = INF
	for pid: int in ids:
		var s: SkaterNetworkState = skater_states.get(pid)
		if s == null:
			continue
		var max_speed: float = race_vmax(s, caps_by_peer.get(pid), puck_pos)
		var t: float = path_intercept_time(traj, step_dt, puck_pos,
				s.position, s.velocity, max_speed, margin)
		if t < best_t:
			best_t = t
	return best_t
