extends RefCounted

# ── Full-rush shooter-AI vs goalie-AI sim ────────────────────────────────────
# The shot-outcome sim (shot_sim_harness.gd) showed a SET goalie is save-poor —
# bot saves are a caught-moving phenomenon. This harness generates that state
# HONESTLY: a real tracking goalie is stepped tick-by-tick along a scripted
# carrier rush (arc-square positioning limited by his real lateral push ramp, so
# he LAGS a fast lateral play), and the shot is fired against wherever the
# tracking actually left him — mid-slide, recovering, or beaten. The save race is
# emergent, not a fabricated offset, so the outcome rates are trustworthy (the
# thing the shot-outcome sim couldn't give). No class_name; preloaded by the test.
#
# REAL: goalie arc/depth positioning + accel-limited lateral tracking
# (GoalieBehaviorRules, via shot_sim_harness constants); real shot selection at
# release against his actual position; real scatter + loft flight (Shot.flight);
# the moving-goalie recovery race over the puck's flight (body slide integrated
# with the reaction delay, + pad/glove pose reach).
#
# APPROXIMATED: the carrier PATH is scripted (straight drive / diagonal /
# cross-crease carry / cross-crease pass), not a live SkaterAgentStateMachine —
# the point is to exercise the goalie's tracking under known rush shapes, not to
# re-decide the carry. A shot is terminal (no rebounds). One shooter, one goalie.
#
# TRUST THE TIER GRADIENT, NOT THE PER-SCENARIO RATE. Known limits found while
# building it:
#   - Outcomes come out near-binary per scenario (a fixed goalie state either
#     beats the small scatter or doesn't), so a single scenario's % is coarse.
#   - Cross-crease plays over-SAVE here: the post-clamped, reaction-lagged goalie
#     stays near centre rather than being pinned to a post, and his modelled
#     in-flight lateral recovery is generous — so the back-door goal a real
#     cross-seam should produce reads as a save. A faithful cross-crease rate
#     needs the live skater brain + GoalieController, not a scripted path.
#   - The aggregate ALL-row depends on the (arbitrary, equal-weighted) scenario
#     mix. What's robust across mixes is the ORDERING: a sharper tier converts a
#     higher share, and the goalie is active on every tier.

const Shot := preload("res://tests/unit/ai/shot_sim_harness.gd")

const DT: float = 1.0 / 120.0
# Lateral-tracking P-gain: far from the square target the desired push saturates
# at the top speed; near it, it eases so he settles without wild overshoot.
const TRACK_GAIN: float = 9.0
# Depth easing rate (depth is far less contested than the lateral line).
const DEPTH_RATE: float = 6.0
const CARRY_SPEED: float = 7.0        # bot skate pace on a rush (m/s)
# The goalie tracks where the play WAS a reaction-time ago, not where it is — the
# reason a fast lateral play (cross-crease) beats him: he commits to the puck's
# old side and can't re-square in time. Without this lag he catches every play.
const REACT_TICKS: int = 16           # ≈ LEG_DELAY (0.13 s) at 120 Hz


# One tracking step: accel-limited lateral push toward the arc-square for the
# carrier, plus eased depth. State is Vector3(x, z, vx).
static func goalie_step(state: Vector3, carrier: Vector3, goal: Vector3, dt: float) -> Vector3:
	var target: Vector3 = Shot.goalie_set_pos(carrier, goal)
	var desired_vx: float = clampf((target.x - state.x) * TRACK_GAIN,
			-Shot.PUSH_SPEED, Shot.PUSH_SPEED)
	var vx: float = move_toward(state.z, desired_vx, Shot.LAT_ACCEL * dt)
	var x: float = state.x + vx * dt
	var z: float = lerpf(state.y, target.z, clampf(dt * DEPTH_RATE, 0.0, 1.0))
	return Vector3(x, z, vx)


# Where the goalie's BODY arrives laterally by the time the puck crosses, given
# he's at `gx` moving `gvx` at release and redirects toward the puck's `cross_x`
# after his reaction delay. This is the recovery race: sliding the right way he
# arrives; caught sliding the wrong way he can't reverse in time.
static func _body_arrival_x(gx: float, gvx: float, cross_x: float,
		flight_t: float, react: float) -> float:
	var x: float = gx
	var vx: float = gvx
	var elapsed: float = 0.0
	while elapsed < flight_t:
		var step: float = minf(DT, flight_t - elapsed)
		if elapsed >= react:
			var desired: float = clampf((cross_x - x) * TRACK_GAIN,
					-Shot.PUSH_SPEED, Shot.PUSH_SPEED)
			vx = move_toward(vx, desired, Shot.LAT_ACCEL * step)
		x += vx * step
		elapsed += step
	return x


# Pose half-reach (limb extension around the body) in the puck's band at arrival —
# the pads spread to the butterfly span over the drop, the glove deploys high.
static func _pose_half(puck_y: float, flight_t: float) -> float:
	if puck_y <= Shot.PAD_TOP:
		var drop: float = clampf(maxf(0.0, flight_t - Shot.LEG_DELAY) / Shot.BUTTERFLY_DROP,
				0.0, 1.0)
		return lerpf(Shot.STANDING_LOW_HALF, Shot.BUTTERFLY_LOW_HALF, drop)
	var deploy: float = clampf(maxf(0.0, flight_t - Shot.ARM_DELAY) / Shot.ARM_DEPLOY,
			0.0, 1.0)
	return Shot.HIGH_SET_HALF + (Shot.ARM_REACH - Shot.HIGH_SET_HALF) * deploy


# Classify one sampled shot against the MOVING goalie (state x,z,vx at release).
static func _classify(shooter: Vector3, goal: Vector3, g: Vector3,
		aim: Vector3, loft: int, power_t: float, err: float) -> int:
	var f: Vector3 = Shot.flight(shooter, goal, aim, loft, power_t, err)
	if f.z < 0.0:
		return Shot.WIDE
	var nv: int = Shot.net_verdict(f.x, f.y)
	if nv != -1:
		return nv
	var react: float = Shot.LEG_DELAY if f.y <= Shot.PAD_TOP else Shot.ARM_DELAY
	var arrival: float = _body_arrival_x(g.x, g.z, f.x, f.z, react)
	if absf(f.x - arrival) <= _pose_half(f.y, f.z):
		return Shot.SAVE
	return Shot.GOAL


# Run one rush: step the goalie down `path` (per-tick carrier positions), then
# fire `samples` shots from the last waypoint against his tracked state.
static func run_rush(path: Array, goal: Vector3, profile: BotSkillProfile,
		samples: int, rng: RandomNumberGenerator) -> Dictionary:
	var counts := {Shot.GOAL: 0, Shot.SAVE: 0, Shot.POST: 0, Shot.WIDE: 0,
			Shot.NO_SHOT: 0, "shots": 0}
	if path.is_empty():
		return counts
	# Goalie state packs (x, depth, lateral-velocity) into a Vector3. He starts
	# set for the rush's first frame, then tracks it (his push ramp makes him lag).
	var set0: Vector3 = Shot.goalie_set_pos(path[0], goal)
	var state := Vector3(set0.x, set0.z, 0.0)
	# Track the REACTION-LAGGED carrier position (where the play was, not is).
	for i: int in range(1, path.size()):
		state = goalie_step(state, path[maxi(0, i - REACT_TICKS)], goal, DT)
	var shooter: Vector3 = path[path.size() - 1]
	# How caught he is — a mid-slide goalie is unsettled; the bot reads it.
	var unsettled: float = clampf(absf(state.z) / Shot.PUSH_SPEED, 0.0, 1.0)
	var goalie := Vector3(state.x, 0.0, state.y)   # (x, 0, z) for the scoring calls
	var spread: float = profile.shot_aim_error_rad
	var danger: float = AIActionScoring.score_shoot(shooter, goal, goalie, Shot.NET_HW, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, [], -1.0, false, 0.0, false, spread)
	if danger < Shot.SHOOT_MIN:
		counts[Shot.NO_SHOT] = samples
		return counts
	# Aim ACROSS THE GRAIN of the goalie's slide (his velocity is state.z) — the
	# real bot's _shot_aim_point read, so it fires at the side he has to reverse to
	# reach, not where he's already recovering. Loft/power still from the hole model.
	var aim: Vector3 = AIShotAim.compute_open_net_aim(shooter, goalie, goal.z,
			Shot.NET_HW, AIActionScoring.GOALIE_SHADOW_HALF_M,
			AIShotAim.DEFAULT_CORNER_BIAS, state.z)
	var loft: int = AIActionScoring.best_shot_loft(shooter, goal, goalie, Shot.NET_HW,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, -1.0, false, 0.0, false, spread)
	var power_t: float = AIActionScoring.best_shot_power_t(shooter, goal, goalie, Shot.NET_HW,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, -1.0, false, 0.0, false, spread)
	# The goalie keeps sliding at release velocity: pass his (x, vx) via `state`.
	for _i: int in samples:
		var err: float = rng.randf_range(-spread, spread)
		var outcome: int = _classify(
				shooter, goal, Vector3(state.x, 0.0, state.z), aim, loft, power_t, err)
		counts[outcome] += 1
		counts["shots"] += 1
	return counts


# ── Rush path builders (per-tick carrier positions toward the -Z net) ────────
# A straight skate from `start` to `release` at CARRY_SPEED, one point per tick.
static func drive(start: Vector3, release: Vector3) -> Array:
	var path: Array = []
	var d: float = start.distance_to(release)
	var ticks: int = maxi(1, int(d / (CARRY_SPEED * DT)))
	for i: int in ticks + 1:
		path.append(start.lerp(release, float(i) / float(ticks)))
	return path


# A cross-crease PASS: the puck jumps laterally at pass pace (fast — the goalie
# can't follow), then the shot fires from the catch spot. `hold` ticks let the
# goalie commit to the puck's start before the seam opens.
static func cross_seam_pass(from_pos: Vector3, to_pos: Vector3, hold_ticks: int) -> Array:
	var path: Array = []
	for _i: int in hold_ticks:
		path.append(from_pos)
	var pass_speed: float = 28.0   # a hard cross-seam feed — outruns the push
	var d: float = from_pos.distance_to(to_pos)
	var ticks: int = maxi(1, int(d / (pass_speed * DT)))
	for i: int in ticks + 1:
		path.append(from_pos.lerp(to_pos, float(i) / float(ticks)))
	return path
