class_name GoaliePuckPlay
extends RefCounted

# Behind-net puck play — the tier-1 conservative rim stop, extracted from
# GoalieController (#519). "Stop it, leave it, get back": the goalie leaves the
# net ONLY to trap a rim behind it, never to carry or pass. The misplay-prone
# tiers of real puck handling are deliberately absent — an AI turnover behind the
# net is the most frustrating failure a goalie AI can produce, and a pure stop has
# no turnover mode. The only failure available is a bad GO decision, which is
# exactly what the races here pin.
#
# Everything is deliberately conservative:
#   - the forechecker is modelled at FULL SPRINT from the first instant (no
#     reaction delay, no acceleration ramp) — the fastest opponent physics allows,
#     so the pressure clock always UNDER-estimates the time available;
#   - the goalie's clock counts the WHOLE trip — out, the stop beat, and the
#     return to his post — before pressure arrives, not just the touch;
#   - the race is re-run every tick of the trip with a STRICTER margin (abort
#     hysteresis), so a conservative goalie visibly bails early rather than ever
#     getting caught out.
#
# ── Boundary ─────────────────────────────────────────────────────────────────
# This object owns the trip's DECISION, GEOMETRY and PHASE. It deliberately does
# NOT own:
#   - state-machine transitions (the controller drives GoalieStateMachine),
#   - body movement (the controller integrates position along `current_target`),
#   - puck mutations (the trap is REQUESTED via `wants_trap`, and the controller
#     performs it) — physics writes stay on the main thread by construction,
#     which is the split GoaliePerception / GoalieDecision generalises later.
# Pure value math otherwise: no scene lookups, no signals, no allocation per tick
# (the opponent scan is a caller-owned PackedVector3Array).

enum { PHASE_OUT, PHASE_STOP, PHASE_RETURN }

# ── Tuning (pushed in by GoalieController._configure_collaborators) ───────────
var skate_speed: float = 4.2         # m/s — goalies skate slower than skaters
var skate_accel: float = 8.0         # m/s² — out/back push ramp
var go_margin: float = 0.9           # s — surplus required to GO (INF = never)
var abort_margin: float = 0.45       # s — mid-trip floor; below it, bail
var stop_beat: float = 0.25          # s — settle the trap before turning back
var set_beat: float = 0.15           # s — must beat the rim to the spot by this
var capture_radius: float = 1.0      # m — paddle trap reach at the stop point
var min_puck_speed: float = 4.0      # m/s — slower pucks don't need a stop
var max_puck_speed: float = 22.0     # m/s — faster rims are shots/clears, stay home
var opponent_speed: float = 11.0     # m/s — assume full sprint (conservative bound)
var net_front_exclusion: float = 3.0 # m — opponent near the net front vetoes the trip
var cooldown_s: float = 4.0          # s — between trips (no dithering at the post)
var boards_inset: float = 0.7        # m — stop point this far inside the end boards
var post_clearance: float = 0.55     # m — waypoint this far outside the post
var stride_cadence: float = 2.4      # rad of stride phase per METRE travelled

# ── Geometry (set once by the controller at setup) ───────────────────────────
var goal_line_z: float = 0.0
var goal_center_x: float = 0.0
var direction_sign: int = 1
var net_half_width: float = 0.915
var home_depth: float = 0.2          # perpendicular depth of the "home" point

# ── Trip state ───────────────────────────────────────────────────────────────
var phase: int = PHASE_OUT
var stop_point: Vector2 = Vector2.ZERO
var waypoint: Vector2 = Vector2.ZERO
var home_point: Vector2 = Vector2.ZERO
var stop_timer: float = 0.0
var wait_timer: float = 0.0
var cooldown_timer: float = 0.0
var trapped: bool = false
var past_waypoint: bool = false
# Skating stride for the trip: phase advances with distance travelled (so the
# feet never treadmill) and the intensity envelope eases with speed, settling to
# zero at the stop point. Only the behind-net skate strides — crease movement
# (shuffle / T-push) is correctly a glide, which is why the goalie never strides
# in the crease.
var stride_phase: float = 0.0
var stride_intensity: float = 0.0
# Ramped skate speed for the trip, so the out/back legs accelerate like any push.
var move_speed: float = 0.0

# ── Requests to the controller (read after `advance`) ────────────────────────
# The trap is a PHYSICS write, so it is requested rather than performed here.
var wants_trap: bool = false
# The trip is over and the goalie is home — the controller hands control back to
# the normal defensive-zone logic.
var arrived_home: bool = false


func reset() -> void:
	phase = PHASE_OUT
	stop_timer = 0.0
	wait_timer = 0.0
	cooldown_timer = 0.0
	trapped = false
	past_waypoint = false
	stride_phase = 0.0
	stride_intensity = 0.0
	move_speed = 0.0
	wants_trap = false
	arrived_home = false


func tick_cooldown(delta: float) -> void:
	if cooldown_timer > 0.0:
		cooldown_timer = maxf(cooldown_timer - delta, 0.0)


# Signed distance (m) of a point IN FRONT of the goal line — positive on the
# goalie's play side, negative behind the net.
func _front_of_goal_m(z: float) -> float:
	return (z - goal_line_z) * direction_sign


# CHEAP pre-check — pure value math, NO opponent scan. This is polled every host
# tick from the upright and RVH branches, so the scan behind `should_go` must stay
# behind it: gathering skater positions unconditionally at 120 Hz x 2 goalies is a
# hot-path cost for a decision that almost always rejects on geometry alone.
# Callers MUST gate `should_go` on this.
func may_consider(puck_pos: Vector3, puck_vel: Vector3) -> bool:
	if is_inf(go_margin):
		return false   # tier gate: only the top skill profile plays the puck
	if cooldown_timer > 0.0:
		return false
	# Behind the goal line only, and genuinely rimming (speed window).
	if _front_of_goal_m(puck_pos.z) >= 0.0:
		return false
	var speed: float = sqrt(puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z)
	if speed < min_puck_speed or speed > max_puck_speed:
		return false
	# The rim must still be COMING to the stop point.
	var stop: Vector2 = _stop_point()
	var to_stop := Vector2(stop.x - puck_pos.x, stop.y - puck_pos.z)
	return puck_vel.x * to_stop.x + puck_vel.z * to_stop.y > 0.0


# Fixed stop point: directly behind the net, just inside the end boards — where a
# real goalie traps the around-the-boards rim.
func _stop_point() -> Vector2:
	var boards_z: float = float(-direction_sign) * GameRules.RINK_HALF_LENGTH
	return Vector2(goal_center_x, boards_z + float(direction_sign) * boards_inset)


# GO decision. Fills the trip geometry (stop / waypoint / home) as a side effect
# when it returns true; `begin()` then just commits. Assumes `may_consider` has
# already passed (it re-derives nothing expensive, but it does not re-check the
# cheap gates). The caller is also expected to have rejected the scene-level
# cases — reacting to a shot, a carried or locked puck.
func should_go(puck_pos: Vector3, puck_vel: Vector3, goalie_pos: Vector3,
		opponents: PackedVector3Array) -> bool:
	var speed: float = sqrt(puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z)
	var stop: Vector2 = _stop_point()
	# Net-front veto + nearest pressure. One scan, no allocation.
	var net_front := Vector2(goal_center_x, goal_line_z + float(direction_sign) * 1.0)
	var nearest_to_stop: float = INF
	for opp in opponents:
		var flat := Vector2(opp.x, opp.z)
		if flat.distance_to(net_front) < net_front_exclusion:
			return false   # someone lurking at the empty net — never leave
		nearest_to_stop = minf(nearest_to_stop, flat.distance_to(stop))
	# Trip geometry: around the post on the rim's incoming side, never through the
	# net. Home is the front of the crease; the defensive-zone logic takes back
	# over (RVH etc.) once the goalie is home.
	var side: float = signf(puck_pos.x - goal_center_x)
	if side == 0.0:
		side = 1.0
	var wp := Vector2(goal_center_x + side * (net_half_width + post_clearance), goal_line_z)
	var home := Vector2(goal_center_x, goal_line_z + float(direction_sign) * home_depth)
	var pos := Vector2(goalie_pos.x, goalie_pos.z)
	var t_out: float = GoalieBehaviorRules.travel_time_from_rest(
			pos.distance_to(wp) + wp.distance_to(stop), skate_speed, skate_accel)
	var t_back: float = GoalieBehaviorRules.travel_time_from_rest(
			stop.distance_to(wp) + wp.distance_to(home), skate_speed, skate_accel)
	# Must beat the rim there SET, and win the whole-trip race with the fat margin.
	var puck_dist: float = Vector2(puck_pos.x, puck_pos.z).distance_to(stop)
	if not GoalieBehaviorRules.can_beat_puck_to_stop(t_out, puck_dist, speed, set_beat):
		return false
	if not GoalieBehaviorRules.puck_play_race_clear(
			t_out, t_back, stop_beat, nearest_to_stop, opponent_speed, go_margin):
		return false
	stop_point = stop
	waypoint = wp
	home_point = home
	return true


func begin() -> void:
	phase = PHASE_OUT
	past_waypoint = false
	trapped = false
	stop_timer = 0.0
	wait_timer = 0.0
	stride_phase = 0.0
	stride_intensity = 0.0
	move_speed = 0.0
	wants_trap = false
	arrived_home = false


# Mid-trip abort race — the conservative heart of the feature. Re-run every tick
# with the STRICTER abort margin (hysteresis in the safe direction) against the
# goalie's CURRENT remaining path: a forechecker who accelerates, a weird bounce,
# or a shrinking window sends him straight home. Bailing early reads as a smart
# goalie; getting caught out reads as a broken one.
func abort_needed(goalie_pos: Vector3, opponents: PackedVector3Array) -> bool:
	var net_front := Vector2(goal_center_x, goal_line_z + float(direction_sign) * 1.0)
	var nearest_to_stop: float = INF
	for opp in opponents:
		var flat := Vector2(opp.x, opp.z)
		if flat.distance_to(net_front) < net_front_exclusion:
			return true
		nearest_to_stop = minf(nearest_to_stop, flat.distance_to(stop_point))
	var pos := Vector2(goalie_pos.x, goalie_pos.z)
	var l_out: float = 0.0
	if phase == PHASE_OUT:
		l_out = pos.distance_to(stop_point) if past_waypoint \
				else pos.distance_to(waypoint) + waypoint.distance_to(stop_point)
	var l_back: float = stop_point.distance_to(waypoint) + waypoint.distance_to(home_point)
	var t_out: float = GoalieBehaviorRules.travel_time_from_rest(
			l_out, skate_speed, skate_accel)
	var t_back: float = GoalieBehaviorRules.travel_time_from_rest(
			l_back, skate_speed, skate_accel)
	return not GoalieBehaviorRules.puck_play_race_clear(
			t_out, t_back, stop_beat, nearest_to_stop, opponent_speed, abort_margin)


# Current movement target: the post waypoint until passed, then the phase's
# endpoint (stop point out, home point back). STOP holds at the spot.
func current_target(current_x: float, goalie_z: float) -> Vector2:
	if phase == PHASE_STOP:
		return stop_point
	var final_target: Vector2 = stop_point if phase == PHASE_OUT else home_point
	if not past_waypoint:
		var pos := Vector2(current_x, goalie_z)
		if pos.distance_to(waypoint) < WAYPOINT_ARRIVE_M:
			past_waypoint = true
		else:
			return waypoint
	return final_target


func go_home() -> void:
	phase = PHASE_RETURN
	past_waypoint = false


# Arrival tolerances (m) along the trip. Distinct because they answer different
# questions: rounding the post only needs the goalie clear of it, arriving at the
# stop point must be tight enough that the paddle actually covers the rim's line,
# and getting home just needs to be inside the crease before control hands back.
const WAYPOINT_ARRIVE_M: float = 0.25
const STOP_ARRIVE_M: float = 0.2
const HOME_ARRIVE_M: float = 0.25
# Extra beat (s) the STOP phase waits beyond the rim's own flight time before
# giving up on a puck that took a weird bounce and never arrived.
const RIM_WAIT_SLACK_S: float = 0.6


# Per-tick trip logic. OUT: skate the waypoint path, aborting on any shrinking
# race. STOP: paddle down, trap the rim when it arrives (a rim that never shows
# times out). RETURN: home via the waypoint, then hand back. The stopped puck is
# left where it lies — "stop it, leave it, get back" — for the breakout D.
#
# Sets `wants_trap` when the controller should kill the rim dead at the paddle,
# and `arrived_home` when the trip is over. Both are cleared on entry each tick.
func advance(delta: float, goalie_pos: Vector3, puck_pos: Vector3,
		puck_speed: float, puck_carried: bool, opponents: PackedVector3Array) -> void:
	wants_trap = false
	arrived_home = false
	if puck_carried and phase != PHASE_RETURN:
		go_home()
		return
	match phase:
		PHASE_OUT:
			if abort_needed(goalie_pos, opponents):
				go_home()
				return
			var pos := Vector2(goalie_pos.x, goalie_pos.z)
			if pos.distance_to(stop_point) < STOP_ARRIVE_M:
				phase = PHASE_STOP
				trapped = false
				# Wait for the rim only as long as its own flight plus a beat.
				var flat := Vector2(puck_pos.x, puck_pos.z)
				wait_timer = flat.distance_to(stop_point) / maxf(puck_speed, 0.5) \
						+ RIM_WAIT_SLACK_S
		PHASE_STOP:
			if abort_needed(goalie_pos, opponents):
				go_home()
				return
			if not trapped:
				var close: bool = goalie_pos.distance_to(puck_pos) <= capture_radius
				if close and _front_of_goal_m(puck_pos.z) < 0.0:
					wants_trap = true      # the controller kills the rim at the paddle
					trapped = true
					stop_timer = stop_beat
				else:
					wait_timer -= delta
					if wait_timer <= 0.0:
						go_home()
			else:
				stop_timer -= delta
				if stop_timer <= 0.0:
					go_home()
		PHASE_RETURN:
			var pos := Vector2(goalie_pos.x, goalie_pos.z)
			if pos.distance_to(home_point) < HOME_ARRIVE_M:
				cooldown_timer = cooldown_s
				arrived_home = true


# Advance the skate along `target`, returning the next (x, z). Accel-ramped like
# every other goalie push; also advances the stride envelope, whose phase rides
# the distance ACTUALLY covered so the feet never treadmill.
func step_toward(delta: float, current_x: float, goalie_z: float,
		target: Vector2) -> Vector2:
	var cur := Vector2(current_x, goalie_z)
	move_speed = move_toward(move_speed, skate_speed, skate_accel * delta)
	var step: float = move_speed * delta
	var d: float = cur.distance_to(target)
	var next: Vector2 = target if d <= step else cur + (target - cur) * (step / maxf(d, 0.0001))
	stride_phase = wrapf(stride_phase + cur.distance_to(next) * stride_cadence, 0.0, TAU)
	var stride_target: float = 0.0
	if phase != PHASE_STOP:
		stride_target = clampf(move_speed / maxf(skate_speed, 0.001), 0.0, 1.0)
	stride_intensity = lerpf(stride_intensity, stride_target, STRIDE_EASE_PER_S * delta)
	return next


# How fast the stride envelope eases toward its target (1/s). Cosmetic only.
const STRIDE_EASE_PER_S: float = 6.0


func is_stopping() -> bool:
	return phase == PHASE_STOP
