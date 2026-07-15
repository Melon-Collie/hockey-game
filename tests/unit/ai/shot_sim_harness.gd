extends RefCounted

# ── Shooter-AI vs goalie-AI SHOT-OUTCOME sim ─────────────────────────────────
# Monte-Carlo harness that measures what actually HAPPENS to the bots' shots
# against a real, independently-modelled goalie — the goal / save / post / wide
# distribution I can't observe headless any other way. It's the data behind the
# make-probability shot change: run it, read the save rate, dial the tunables.
# No class_name (test infrastructure stays out of the global namespace);
# preloaded by the runner test.
#
# What runs REAL (from the production pure rules, NOT re-derived):
#   - Shot SELECTION: AIActionScoring.score_shoot decides whether the bot fires
#     from a spot, and best_shot_aim / best_shot_loft / best_shot_power_t pick
#     the exact aim point, loft class, and release pace — the same triple the
#     live bot commits. So the make-probability model + centred aim are exercised
#     through the real path.
#   - Execution scatter: one uniform ±shot_aim_error_rad sample per shot (the
#     production per-release model), seeded for determinism.
#   - Goalie SET position: GoalieBehaviorRules.compute_threat_position +
#     target_depth_for_puck_distance (the real depth chart) + target_arc_position
#     — the goalie squared on the challenge arc for that shooter, INDEPENDENT of
#     the shot score's own cover model (the point of the "real goalie" choice).
#   - Goalie REACH: GoalieBehaviorRules.reachable_lateral_distance with the real
#     push speed / lateral accel and the real leg/arm reaction delays + butterfly
#     drop, plus the goalie's real pose anatomy (pad span, glove reach, pad-top
#     seam) — assembled here from the goalie's own constants.
#   - Puck FLIGHT: launch pace from best_shot_power_t, a real loft parabola
#     (loft_vy + gravity), projected to the net plane.
#
# What is APPROXIMATED (so read RELATIVE deltas — soft-make on/off, bias, scatter
# — as more trustworthy than absolute rates):
#   - The goalie is SET for the shooter (no rush backflow / caught-moving read);
#     this is the "shot-outcome" scope by design.
#   - Reach is a lateral-band model: low band = pads (spreading to the butterfly
#     span over the drop) + lateral push; high band = glove/blocker deploy +
#     push; a small dead-centre five-hole leaks until the butterfly seals. No
#     post seals (RVH/VH), screens, slides beyond the push primitive, or rebounds
#     (a save is terminal — we're counting first-contact outcomes).
#   - Horizontal pace is treated as constant over the short flight (ice friction
#     on a flat shot is a few % over ~10 m and doesn't move the outcome class).

# AIActionScoring and GoalieBehaviorRules are referenced by their global
# class_name (their inner types — e.g. DepthConfig — don't resolve through a
# preload alias in a type position).

# ── Field / net geometry (GameRules mirrors) ─────────────────────────────────
const GOAL_LINE_Z: float = GameRules.GOAL_LINE_Z
const NET_HW: float = GameRules.NET_HALF_WIDTH          # 0.915 post centreline
const CROSSBAR: float = GameRules.NET_HEIGHT            # 1.22 pipe centreline
const POST_R: float = GameRules.NET_POST_RADIUS
const PUCK_R: float = GameRules.PUCK_COLLISION_RADIUS
const PAD_TOP: float = GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M   # 0.86 pad/torso seam
const GRAVITY: float = 9.8

# ── Goalie kinematics / anatomy (his own constants) ──────────────────────────
const LEG_DELAY: float = GameRules.DEFAULT_GOALIE_REACTION_DELAY_S     # 0.13
const ARM_DELAY: float = GameRules.DEFAULT_GOALIE_ARM_REACTION_DELAY_S # 0.18
const PUSH_SPEED: float = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S    # 3.8 lateral top
const LAT_ACCEL: float = GameRules.DEFAULT_GOALIE_LATERAL_ACCEL_M_S2   # 14.0 ramp
const BUTTERFLY_DROP: float = 0.20                    # pads-to-floor (controller default)
const ARM_DEPLOY: float = 0.09                        # glove extension ramp (AIShotAim.GOALIE_ARM_DEPLOY_S)
# Pose half-widths: standing pads at the ice, butterfly pad span (pad_local_offset
# 0.42 + butterfly_pad_half_width 0.42 = 0.84 to each post-ward edge), the set
# high half before the arm extends, and the arm's outward reach (glove_max_x_outward).
const STANDING_LOW_HALF: float = 0.45
const BUTTERFLY_LOW_HALF: float = 0.84
const HIGH_SET_HALF: float = 0.33
const ARM_REACH: float = 0.85
const FIVE_HALF: float = 0.09                         # dead-centre gap until the seal
# A caught-moving goalie (unsettled) reads the shot late — this much added
# reaction delay at unsettled=1 (a well-late read). This is where saves live: an
# unsettled goalie's window is open (the bot fires), but he recovers to the
# shots near his body while the corners beat him.
const UNSETTLE_REACT_PENALTY_S: float = 0.15
# A caught-moving goalie is also DISPLACED off his squared line (mid-slide from a
# lateral play). At unsettled=1 he's this far off — the open side the bot fires
# at, which his lateral push (in _reach_half) then races to recover. This is the
# cross-crease save geometry; a set goalie (offset 0) has no such race.
const CAUGHT_OFFSET_M: float = 1.0

# ── Wrister pace band ────────────────────────────────────────────────────────
const WRISTER_MIN: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
const WRISTER_MAX: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S

# A spot's danger must clear this to count as a shot the bot would take (a nominal
# fire threshold standing in for the shoot-vs-carry compete — the OZ possession
# floor). The SHOOT RATE it produces is itself an output.
const SHOOT_MIN: float = 0.08

enum { GOAL, SAVE, POST, WIDE, NO_SHOT }


# Depth chart config from the controller's real defaults.
static func _depth_cfg() -> GoalieBehaviorRules.DepthConfig:
	var c := GoalieBehaviorRules.DepthConfig.new()
	c.zone_post_z = 2.0
	c.zone_aggressive_z = 8.0
	c.zone_base_z = 12.0
	c.zone_conservative_z = 20.0
	c.depth_aggressive = 1.75
	c.depth_base = 1.30
	c.depth_conservative = 0.70
	c.depth_defensive = 0.10
	return c


# Goalie set position (x on the challenge arc, z from the depth chart) for a
# shooter carrying the puck. Attacking goal at -Z (shooter shoots toward -Z).
static func goalie_set_pos(shooter: Vector3, goal: Vector3) -> Vector3:
	var dir_sign: int = int(signf(-goal.z))
	var threat: Vector3 = shooter   # carrier ≈ puck for a set-up shooter
	var threat_dist: float = GoalieBehaviorRules.threat_distance_to_goal(threat, goal.z, goal.x)
	var radius: float = GoalieBehaviorRules.target_depth_for_puck_distance(threat_dist, _depth_cfg())
	var xz: Vector2 = GoalieBehaviorRules.target_arc_position(
			threat, goal.z, goal.x, dir_sign, radius, NET_HW)
	return Vector3(xz.x, 0.0, xz.y)


# Lateral half-reach the goalie has covered around his set x by arrival time `t`,
# in the band `puck_y` sits in. Independent of the shot score's cover model.
# `unsettled` (0 set … 1 caught mid-slide) adds a late-read reaction delay.
static func _reach_half(puck_y: float, t: float, unsettled: float) -> float:
	var late: float = clampf(unsettled, 0.0, 1.0) * UNSETTLE_REACT_PENALTY_S
	if puck_y <= PAD_TOP:
		var t_low: float = maxf(0.0, t - LEG_DELAY - late)
		var push: float = GoalieBehaviorRules.reachable_lateral_distance(PUSH_SPEED, LAT_ACCEL, t_low)
		var drop_frac: float = clampf(t_low / BUTTERFLY_DROP, 0.0, 1.0)
		return lerpf(STANDING_LOW_HALF, BUTTERFLY_LOW_HALF, drop_frac) + push
	var t_high: float = maxf(0.0, t - ARM_DELAY - late)
	var deploy: float = clampf(t_high / ARM_DEPLOY, 0.0, 1.0)
	var push_h: float = GoalieBehaviorRules.reachable_lateral_distance(PUSH_SPEED, LAT_ACCEL, t_high)
	return HIGH_SET_HALF + (ARM_REACH - HIGH_SET_HALF) * deploy + push_h


# Launch pace (m/s) for a chosen power fraction over the wrister band.
static func _launch_speed(power_t: float) -> float:
	return WRISTER_MIN + clampf(power_t, 0.0, 1.0) * (WRISTER_MAX - WRISTER_MIN)


# Solve where a sampled shot crosses the net plane. Returns
# Vector3(cross_x, cross_y, flight_t); flight_t < 0 signals a degenerate release
# (no crossing). Shared by the static classifier and the rush harness.
static func flight(shooter: Vector3, goal: Vector3, aim: Vector3,
		loft_level: int, power_t: float, err_rad: float) -> Vector3:
	var to_aim := Vector2(aim.x - shooter.x, aim.z - shooter.z)
	if to_aim.length() < 0.001:
		return Vector3(0.0, 0.0, -1.0)
	var ang: float = to_aim.angle() + err_rad
	var hdir := Vector2(cos(ang), sin(ang))          # unit XZ heading
	var dz: float = goal.z - shooter.z
	if absf(hdir.y) < 0.0001 or signf(hdir.y) != signf(dz):
		return Vector3(0.0, 0.0, -1.0)
	var travel: float = dz / hdir.y                  # horizontal distance to the plane
	var cross_x: float = shooter.x + hdir.x * travel
	# Loft parabola: split the launch pace into horizontal + vertical (loft_vy).
	var speed: float = _launch_speed(power_t)
	var loft_vy: float = ShotMechanics._loft_vy(loft_level,
			GameRules.DEFAULT_LOFT_VY_LOW_M_S, GameRules.DEFAULT_LOFT_VY_HIGH_M_S)
	var v_h: float = sqrt(maxf(speed * speed - loft_vy * loft_vy, 1.0))
	var flight_t: float = absf(travel) / v_h
	var cross_y: float = maxf(0.0, loft_vy * flight_t - 0.5 * GRAVITY * flight_t * flight_t)
	return Vector3(cross_x, cross_y, flight_t)


# On/off-net verdict for a crossing point: POST, WIDE, or -1 (on net, undecided —
# the caller resolves the reach). Shared with the rush harness.
static func net_verdict(cross_x: float, cross_y: float) -> int:
	if absf(cross_x) > NET_HW - PUCK_R or cross_y > CROSSBAR - PUCK_R:
		if absf(cross_x) <= NET_HW + POST_R + PUCK_R and cross_y <= CROSSBAR + POST_R:
			return POST
		return WIDE
	return -1


# Classify ONE sampled shot against a SET goalie. `err_rad` is this release's
# sampled aim error; `unsettled` (0 set … 1 caught mid-slide) delays his read.
static func classify_shot(shooter: Vector3, goal: Vector3, goalie: Vector3,
		aim: Vector3, loft_level: int, power_t: float, err_rad: float,
		unsettled: float) -> int:
	var f: Vector3 = flight(shooter, goal, aim, loft_level, power_t, err_rad)
	if f.z < 0.0:
		return WIDE
	var cross_x: float = f.x
	var cross_y: float = f.y
	var flight_t: float = f.z
	var nv: int = net_verdict(cross_x, cross_y)
	if nv != -1:
		return nv
	# On net: does the goalie's positioned reach get there in time?
	var lateral_off: float = absf(cross_x - goalie.x)
	var seal_delay: float = clampf(unsettled, 0.0, 1.0) * UNSETTLE_REACT_PENALTY_S
	if cross_y <= PAD_TOP and lateral_off < FIVE_HALF \
			and flight_t < LEG_DELAY + BUTTERFLY_DROP + seal_delay:
		return GOAL   # dead-centre low slips the five-hole before the seal
	if lateral_off <= _reach_half(cross_y, flight_t, unsettled):
		return SAVE
	return GOAL


# Run `samples` scatter draws for a shooter spot with a given profile, returning
# a counts dict keyed by the outcome enum (plus "shots" = non-NO_SHOT total).
static func run_spot(shooter: Vector3, goal: Vector3, profile: BotSkillProfile,
		unsettled: float, samples: int, rng: RandomNumberGenerator) -> Dictionary:
	var counts := {GOAL: 0, SAVE: 0, POST: 0, WIDE: 0, NO_SHOT: 0, "shots": 0}
	var goalie: Vector3 = goalie_set_pos(shooter, goal)
	# Caught-moving displacement: push him off his squared line toward +x (the bot
	# fires the opened −x side; his push recovers). Clamp inside the posts.
	goalie.x = clampf(goalie.x + clampf(unsettled, 0.0, 1.0) * CAUGHT_OFFSET_M,
			-NET_HW, NET_HW)
	var spread: float = profile.shot_aim_error_rad
	# Would the bot even fire? Real selection, spread- AND unsettled-aware (a
	# caught-moving goalie opens the window, so more marginal shots clear the bar).
	var danger: float = AIActionScoring.score_shoot(shooter, goal, goalie, NET_HW, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, [], -1.0, false, 0.0, false, spread)
	if danger < SHOOT_MIN:
		counts[NO_SHOT] = samples
		return counts
	var aim: Vector3 = AIActionScoring.best_shot_aim(shooter, goal, goalie, NET_HW,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, -1.0, false, spread)
	var loft: int = AIActionScoring.best_shot_loft(shooter, goal, goalie, NET_HW,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, -1.0, false, 0.0, false, spread)
	var power_t: float = AIActionScoring.best_shot_power_t(shooter, goal, goalie, NET_HW,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, -1.0, false, 0.0, false, spread)
	for _i: int in samples:
		var err: float = rng.randf_range(-spread, spread)
		var outcome: int = classify_shot(
				shooter, goal, goalie, aim, loft, power_t, err, unsettled)
		counts[outcome] += 1
		counts["shots"] += 1
	return counts
