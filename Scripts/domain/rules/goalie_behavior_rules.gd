class_name GoalieBehaviorRules

# Pure goalie AI math. Callers pass tracked puck state + geometry; these
# functions return classifications and targets. The Buckley-style depth
# chart and shot detection live here so we can test them without a scene.
#
# direction_sign convention (matches GoalieController: sign(-goal_line_z)):
#   -1  goalie defends the +Z goal (goal_line_z = +GOAL_LINE_Z)
#   +1  goalie defends the -Z goal (goal_line_z = -GOAL_LINE_Z)
# "Behind goal" therefore means:
#   (puck_z - goal_line_z) * direction_sign < 0

class ShotResult:
	var is_shot: bool = false
	var reaction_delay: float = 0.0
	var impact_x: float = 0.0
	var impact_y: float = 0.0
	var is_low: bool = false      # impact_y < low_shot_threshold
	var is_elevated: bool = false # impact_y >= elevated_threshold
	# Seconds until the puck crosses the goal line on its current heading.
	# Only meaningful when is_shot; lets callers gate on imminence (e.g. don't
	# start a reaction to a release that's still way out) without recomputing.
	var time_to_impact: float = 0.0

class ShotDetectionConfig:
	var shot_speed_threshold: float = 0.0
	var net_half_width: float = 0.0
	var net_margin: float = 0.0
	var reaction_delay: float = 0.0
	var low_shot_threshold: float = 0.0
	var elevated_threshold: float = 0.0
	# Gravity used for ballistic impact_y prediction. Linear extrapolation
	# (`y + vy * t`) overestimates landing height for long-range elevated
	# shots — they arc down to ice level before reaching the net but get
	# misclassified as elevated, so the goalie never drops butterfly.
	# Standard project gravity is 9.8 m/s²; pass 0 for legacy linear math.
	var gravity: float = 9.8

class DefensiveZoneConfig:
	var zone_post_z: float = 0.0
	var rvh_early_angle: float = 0.0  # degrees

class DepthConfig:
	var zone_post_z: float = 0.0
	var zone_aggressive_z: float = 0.0
	var zone_base_z: float = 0.0
	var zone_conservative_z: float = 0.0
	var depth_aggressive: float = 0.0
	var depth_base: float = 0.0
	var depth_conservative: float = 0.0
	var depth_defensive: float = 0.0

class ThreatConfig:
	var shooter_weight: float = 0.0   # 0 = pure puck, 1 = pure carrier body

# Is a released puck on course to hit this goalie's net? Returns a ShotResult.
# is_shot == false means not on net or below fake_threshold.
#
# Allocating convenience wrapper — for tests and non-hot-path callers. The
# per-tick goalie path calls detect_shot_into with a reused scratch instead.
static func detect_shot(
		puck_position: Vector3,
		puck_velocity: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		cfg: ShotDetectionConfig) -> ShotResult:
	return detect_shot_into(
			puck_position, puck_velocity, goal_line_z, goal_center_x, cfg,
			ShotResult.new())

# Scratch-filling variant: writes into `out` and returns it, so the goalie
# controller (which calls this every tick while reacting / on a loose puck)
# reuses one ShotResult instead of allocating one per tick (×2 goalies, and
# re-run per replayed input in reconcile). All fields are reset up front since
# the instance carries over between calls.
static func detect_shot_into(
		puck_position: Vector3,
		puck_velocity: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		cfg: ShotDetectionConfig,
		out: ShotResult) -> ShotResult:
	out.is_shot = false
	out.reaction_delay = 0.0
	out.impact_x = 0.0
	out.impact_y = 0.0
	out.is_low = false
	out.is_elevated = false
	out.time_to_impact = 0.0
	var result := out
	if puck_velocity.length() < cfg.shot_speed_threshold:
		return result
	if abs(puck_velocity.z) < 0.001:
		return result
	var t_to_goal: float = (goal_line_z - puck_position.z) / puck_velocity.z
	if t_to_goal <= 0.0:
		return result
	var impact_x: float = puck_position.x + puck_velocity.x * t_to_goal
	# Ballistic impact_y: include gravity so long-range elevated shots that
	# arc down to ice are correctly predicted as low. Without this, a shot
	# released with positive vy stays "elevated" in the goalie's read all
	# the way to the net even though physics has it landing at floor level.
	# Floor-clamped at 0 — once the puck would have hit the ice, it can't
	# arrive lower than that.
	var impact_y: float = puck_position.y + puck_velocity.y * t_to_goal \
			- 0.5 * cfg.gravity * t_to_goal * t_to_goal
	impact_y = maxf(impact_y, 0.0)
	if abs(impact_x - goal_center_x) > cfg.net_half_width + cfg.net_margin:
		return result
	result.is_shot = true
	result.reaction_delay = cfg.reaction_delay
	result.impact_x = impact_x
	result.impact_y = impact_y
	result.time_to_impact = t_to_goal
	result.is_low = impact_y < cfg.low_shot_threshold
	result.is_elevated = impact_y >= cfg.elevated_threshold
	return result

# Defensive zone — either behind the goal line or within zone_post_z at a
# sharp horizontal angle. Triggers RVH post-hug.
static func is_puck_in_defensive_zone(
		puck_position: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		direction_sign: int,
		cfg: DefensiveZoneConfig) -> bool:
	var behind_goal: bool = (puck_position.z - goal_line_z) * direction_sign < 0.0
	if behind_goal:
		return true
	var puck_z_dist: float = abs(puck_position.z - goal_line_z)
	if puck_z_dist > cfg.zone_post_z:
		return false
	var puck_angle: float = atan2(abs(puck_position.x - goal_center_x), maxf(puck_z_dist, 0.01))
	return puck_angle >= deg_to_rad(cfg.rvh_early_angle)

# Buckley-chart target depth given horizontal distance from the goal line.
# Piecewise-linear interpolation across four zones. Callers smooth toward
# this target with their own lerp speed.
static func target_depth_for_puck_distance(puck_z_dist: float, cfg: DepthConfig) -> float:
	var t: float
	if puck_z_dist <= cfg.zone_post_z:
		t = puck_z_dist / cfg.zone_post_z
		return lerpf(cfg.depth_defensive, cfg.depth_aggressive, t)
	if puck_z_dist <= cfg.zone_aggressive_z:
		return cfg.depth_aggressive
	if puck_z_dist <= cfg.zone_base_z:
		t = (puck_z_dist - cfg.zone_aggressive_z) / (cfg.zone_base_z - cfg.zone_aggressive_z)
		return lerpf(cfg.depth_aggressive, cfg.depth_base, t)
	if puck_z_dist <= cfg.zone_conservative_z:
		t = (puck_z_dist - cfg.zone_base_z) / (cfg.zone_conservative_z - cfg.zone_base_z)
		return lerpf(cfg.depth_base, cfg.depth_conservative, t)
	# Beyond the conservative zone the chart FLOORS at conservative depth
	# (realism audit F8): a puck far away in FRONT of the net leaves a real
	# goalie resting at/near the paint watching the play — D (goal-line) depth
	# is for behind-net / post-integrated play, which the defensive-zone / RVH
	# paths own. The old taper walked the goalie back to his goal line during
	# neutral-zone play, which no goalie does.
	return cfg.depth_conservative

# Lateral X target using angle bisector: find the line from the puck that
# bisects the shooting angle between the two posts, then intersect it with
# the goalie's depth plane. This maximises net coverage from the goalie's
# position rather than simply projecting the puck's X onto the depth plane.
# direction_sign: sign(-goal_line_z) — determines which side of the goal
# the goalie stands on (same convention as GoalieController._direction_sign).
static func target_lateral_x(
		puck_position: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		current_depth: float,
		net_half_width: float,
		direction_sign: int) -> float:
	var px: float = puck_position.x
	var pz: float = puck_position.z
	var left_x: float  = goal_center_x - net_half_width
	var right_x: float = goal_center_x + net_half_width

	# 2D (XZ) vectors from puck to each post.
	var dlx: float = left_x  - px
	var dlz: float = goal_line_z - pz
	var drx: float = right_x - px
	var drz: float = goal_line_z - pz   # same Z for both posts

	var dl: float = sqrt(dlx * dlx + dlz * dlz)
	var dr: float = sqrt(drx * drx + drz * drz)
	if dl < 0.001 or dr < 0.001:
		return goal_center_x

	# Angle bisector direction (sum of unit vectors to each post).
	var bx: float = dlx / dl + drx / dr
	var bz: float = dlz / dl + drz / dr
	var blen: float = sqrt(bx * bx + bz * bz)
	if blen < 0.001:
		return goal_center_x   # perfectly centred — bisector undefined, stay put

	bx /= blen
	bz /= blen

	# Intersect the bisector ray with the goalie's depth plane.
	if abs(bz) < 0.001:
		return clampf(px, left_x, right_x)
	var goalie_z: float = goal_line_z + direction_sign * current_depth
	var t: float = (goalie_z - pz) / bz
	if t <= 0.0:
		return clampf(px, left_x, right_x)

	return clampf(px + bx * t, left_x, right_x)


# ── Threat position ──────────────────────────────────────────────────────────
# Goalies "play the chest, not the puck": carrier body is steady while the
# puck swings ±1.5 m during stickhandling. Blend the two so the goalie tracks
# a stable target. With no carrier (loose puck or shot in flight) the puck
# itself is the threat.
#
# carrier_present == false: returns puck_position regardless of weight.
# carrier_present == true:  threat = lerp(puck, carrier_body, shooter_weight).
static func compute_threat_position(
		puck_position: Vector3,
		carrier_body_position: Vector3,
		carrier_present: bool,
		shooter_weight: float) -> Vector3:
	if not carrier_present:
		return puck_position
	var w: float = clampf(shooter_weight, 0.0, 1.0)
	return puck_position.lerp(carrier_body_position, w)


# ── Arc-based positioning ────────────────────────────────────────────────────
# Real goalies skate the "challenge angle" arc — a constant-radius path
# around the goal center. This naturally pulls them back on sharp angles
# (they sit shallower in perpendicular depth as the puck moves wide), while
# the previous angle-bisector-on-fixed-depth math traced a near-straight line.
#
# `radius` is the distance from goal center; callers compute it with the
# existing depth chart against `threat_distance_to_goal`.
# Returns (x, z) world position. Clamps x to within the posts so the goalie
# never strays outside the net width on extreme angles.
static func target_arc_position(
		threat_position: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		direction_sign: int,
		radius: float,
		net_half_width: float) -> Vector2:
	var dx: float = threat_position.x - goal_center_x
	var dz: float = threat_position.z - goal_line_z
	var d: float = sqrt(dx * dx + dz * dz)
	if d < 0.001:
		return Vector2(goal_center_x, goal_line_z + direction_sign * radius)
	var ux: float = dx / d
	var uz: float = dz / d
	var goalie_x: float = goal_center_x + ux * radius
	var goalie_z: float = goal_line_z + uz * radius
	# Threat behind goal line: arc would pull goalie behind the net. Flatten
	# to the goal line so the goalie hugs the post-line rather than skating
	# behind it. RVH transitions handle the actual post-hug.
	var perp_depth: float = (goalie_z - goal_line_z) * direction_sign
	if perp_depth < 0.0:
		goalie_z = goal_line_z
	goalie_x = clampf(goalie_x, goal_center_x - net_half_width, goal_center_x + net_half_width)
	return Vector2(goalie_x, goalie_z)


# Euclidean distance from threat to goal center (XZ plane). Drives the depth
# chart for the arc — replaces the old "abs(puck.z - goal_line_z)" input
# which ignored lateral distance.
static func threat_distance_to_goal(
		threat_position: Vector3,
		goal_line_z: float,
		goal_center_x: float) -> float:
	var dx: float = threat_position.x - goal_center_x
	var dz: float = threat_position.z - goal_line_z
	return sqrt(dx * dx + dz * dz)


# ── Distance-scaled chest tracking ───────────────────────────────────────────
# A real goalie plays the shooter's CHEST at range — the puck-on-a-string is
# irrelevant until it's in tight — and only tracks the PUCK itself at the
# doorstep. Returns 0 at/under `near` (full puck tracking) ramping to 1 at/over
# `far` (play the chest). Callers lerp `shooter_weight` toward its chest ceiling
# by this factor AND fade the jittery puck-velocity lead out by it, so a
# stickhandle at the point stops wobbling the goalie's body.
static func chest_tracking_factor(carrier_dist_to_goal: float, near: float, far: float) -> float:
	if far <= near:
		return 0.0
	return clampf((carrier_dist_to_goal - near) / (far - near), 0.0, 1.0)


# ── Sealing-pad squaring ─────────────────────────────────────────────────────
# The butterfly toe-out (pads yawed so the toes point outward) steers rebounds
# to the corners, but that same yaw angles a pad off the goal-line plane — so
# when a pad is pressed to its post, the angle opens a seam the puck slips
# through beside the post. This kills the toe-out on a pad as it reaches its
# post: `shortfall_to_post` is how far the pad's outer edge still is from the
# post (0 = edge on the post), and within `square_range` of the post the toe-out
# ramps to 0 (flat, square seal). Pads still steering the slot keep full toe-out.
static func sealed_pad_toe_out(shortfall_to_post: float, base_toe_out: float, square_range: float) -> float:
	if square_range <= 0.0:
		return base_toe_out
	var seal_t: float = clampf((square_range - shortfall_to_post) / square_range, 0.0, 1.0)
	return base_toe_out * (1.0 - seal_t)


# ── Butterfly slide commit ───────────────────────────────────────────────────
# Once a goalie drops to butterfly they cannot stand-skate — lateral movement
# is exclusively via butterfly slide: plant outside leg, push off, slide on
# the inside pad in a STRAIGHT LINE until friction stops them. The destination
# is picked once at slide-start and committed.
#
# Destination = arc position at butterfly_depth for the current threat. This
# is what the goalie "thinks" the shot threat is, and where they push off
# toward. If the threat moves mid-slide the goalie cannot correct — that's
# the realism win (cross-passes beat committed slides).
static func compute_slide_destination(
		threat_position: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		direction_sign: int,
		butterfly_radius: float,
		net_half_width: float) -> Vector2:
	return target_arc_position(
			threat_position, goal_line_z, goal_center_x,
			direction_sign, butterfly_radius, net_half_width)




# ── Universal puck reaction trigger ──────────────────────────────────────────
# Any puck on track to cross the goal line within the net soon should put the
# goalie into shot-reaction mode, not just classified `detect_shot()` releases.
# This covers board bounces, poke-strips, deflections, and slow tricklers that
# arrive at the net without an explicit release event.
#
# Urgency is NOT a function of raw speed — a puck dribbling at the 5-hole from a
# foot out is more urgent than a rocket from the blue line, not less. The real
# gates are: (1) on-net trajectory, (2) time-to-impact <= max_time_to_impact.
# Speed only matters insofar as it sets the ETA (slow + far = long ETA, ignored;
# slow + close = short ETA, react). `min_speed` is a tiny anti-jitter floor to
# skip essentially-stationary pucks whose direction wobbles, NOT an urgency cut.
#
# Returns true if the puck will cross the goal line within net width + margin in
# <= max_time_to_impact seconds. Caller still uses detect_shot() for impact_y
# classification (low vs elevated) once reacting.
class UniversalReactionConfig:
	var min_speed: float = 1.0           # m/s — anti-jitter floor, not an urgency gate
	var max_time_to_impact: float = 0.6  # s — react once a goal is this imminent
	var net_half_width: float = 0.0
	var net_margin: float = 0.0


static func should_react_to_puck(
		puck_position: Vector3,
		puck_velocity: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		cfg: UniversalReactionConfig) -> bool:
	if puck_velocity.length() < cfg.min_speed:
		return false
	if abs(puck_velocity.z) < 0.001:
		return false
	var t: float = (goal_line_z - puck_position.z) / puck_velocity.z
	if t <= 0.0 or t > cfg.max_time_to_impact:
		return false
	var impact_x: float = puck_position.x + puck_velocity.x * t
	return abs(impact_x - goal_center_x) <= cfg.net_half_width + cfg.net_margin


# ── Cross-crease pass detection ──────────────────────────────────────────────
# Backdoor passes are the slide-trigger blind spot today: the puck whips across
# the slot toward a receiver on the far post, but the *carrier* hasn't moved
# (they just passed), so threat-position-based triggers miss it. Reading puck
# velocity directly catches the pass at the moment of release.
#
# Returns the puck's lateral velocity component (signed X) if the puck is in
# the slot zone (in front of the goal, within slot_z_depth) AND moving
# primarily sideways (|vx| >= |vz| * lateral_ratio). Else 0.
#
# direction_sign: +1 / -1 depending on which goal the goalie defends (see
# top-of-file).  slot_z_depth measures how deep into the offensive zone the
# pass-detection window extends (typical: ~5m, matching the slot region).
static func lateral_puck_velocity_in_slot(
		puck_position: Vector3,
		puck_velocity: Vector3,
		goal_line_z: float,
		direction_sign: int,
		slot_z_depth: float,
		lateral_ratio: float) -> float:
	# In front of the goal? Per the direction_sign convention at the top of
	# this file, `(puck_z - goal_line_z) * direction_sign > 0` means the puck
	# is on the goalie's side of the goal line (NOT behind it).
	var puck_in_front: float = (puck_position.z - goal_line_z) * direction_sign
	if puck_in_front <= 0.0 or puck_in_front > slot_z_depth:
		return 0.0
	var forward_speed: float = absf(puck_velocity.z)
	if absf(puck_velocity.x) < forward_speed * lateral_ratio:
		return 0.0
	return puck_velocity.x


# ── Loose-puck clear ─────────────────────────────────────────────────────────
# A slow loose puck sitting in the blue paint should be swept to the corner,
# not left in front of the goalie for an opponent to bang in (the classic
# "stop the 5-hole shot, then poke the rebound in as the goalie stands up"
# pattern). The sweep is mostly lateral — toward the boards on the side the
# puck already sits — with a forward component (out of the crease, away from
# the goal line) so the puck is cleared toward the corner rather than fed back
# up the slot where it could be one-timed.
#
# A dead-centre puck (|offset| <= center_deadband) has no natural side, so it's
# pushed toward `default_side` (the goalie's stick side) instead of the
# direction being undefined / flickering on float jitter.
#
# direction_sign convention per the top of this file: forward (away from the
# goal line, into the rink) is the +direction_sign Z direction.
# Returns a world-space velocity (y = 0); zero if the inputs degenerate.
static func compute_clear_velocity(
		puck_position: Vector3,
		goal_center_x: float,
		direction_sign: int,
		lateral_weight: float,
		forward_weight: float,
		clear_speed: float,
		center_deadband: float,
		default_side: float,
		forced_side: float = 0.0) -> Vector3:
	# `forced_side` (non-zero) overrides the natural side pick — used by the
	# lane-aware sweep to try the OPPOSITE corner when the natural exit lane is
	# covered by an opponent's stick.
	var side: float
	if forced_side != 0.0:
		side = signf(forced_side)
	else:
		var offset_x: float = puck_position.x - goal_center_x
		side = signf(offset_x) if absf(offset_x) > center_deadband else signf(default_side)
	if side == 0.0:
		side = 1.0
	var dir := Vector3(side * lateral_weight, 0.0, float(direction_sign) * forward_weight)
	var dlen: float = dir.length()
	if dlen < 0.0001:
		return Vector3.ZERO
	return (dir / dlen) * clear_speed


# ── Sweep-lane reachability ──────────────────────────────────────────────────
# Can an opponent get a stick on the swept puck's exit path? Same grounded
# reachability shape as the bot AI's lane model (AIActionScoring.lane_clear),
# reduced to the goalie's short-range case: opponents treated as static over
# the short flight, scalar loop over a caller-owned PackedVector3Array (no
# allocation — this runs at the sweep/cover decision, which can persist for
# ticks during a scramble). An opponent intercepts iff, when the puck passes
# their closest-approach point, their blade reach plus the lateral distance
# they can close in the remaining time covers the miss distance. All three
# parameters are physical: a blade's reach, a competitive read delay, and the
# lateral close pace (~half top skating speed — you slide into a lane, you
# don't sprint at it). Real doctrine hook (audit follow-up): the sweep is only
# the correct clear when the corner lane is OPEN; a covered lane is what makes
# smothering the correct read.
class SweepLaneConfig:
	var stick_reach: float = 1.3       # m — lane defender blade reach
	var reaction_delay: float = 0.08   # s — competitive read before closing starts
	var close_speed: float = 4.5       # m/s — lateral close pace (~half top speed)
	var max_flight_time: float = 1.0   # s — only the exit's first stretch matters

static func sweep_lane_blocked(
		puck_position: Vector3,
		exit_velocity: Vector3,
		opponent_positions: PackedVector3Array,
		cfg: SweepLaneConfig) -> bool:
	var speed: float = sqrt(exit_velocity.x * exit_velocity.x + exit_velocity.z * exit_velocity.z)
	if speed < 0.001:
		return false
	var dirx: float = exit_velocity.x / speed
	var dirz: float = exit_velocity.z / speed
	for opp in opponent_positions:
		var relx: float = opp.x - puck_position.x
		var relz: float = opp.z - puck_position.z
		var along: float = relx * dirx + relz * dirz
		if along <= 0.0:
			continue  # behind the exit — can't intercept
		var t: float = along / speed
		if t > cfg.max_flight_time:
			continue  # too far downrange to matter
		var miss: float = absf(relx * -dirz + relz * dirx)
		var reach: float = cfg.stick_reach \
				+ cfg.close_speed * maxf(t - cfg.reaction_delay, 0.0)
		if miss < reach:
			return true
	return false


# ── Puck at rest ON the goalie (the pad-shelf smother) ───────────────────────
# The puck's collision mask excludes skater bodies, so the goalie is the ONLY
# body in the game that can support a puck off the ice: a loose puck that is
# off the ice, essentially motionless, and inside the goalie's horizontal body
# footprint must be sitting ON him (classically: a deadened save settling on
# top of the butterfly pads). That puck is unplayable through every normal
# path — grounded blades can't reach an "airborne" puck and the crease sweep
# refuses pucks above the ice — and in real hockey it's a covered puck anyway,
# so the caller answers it with the smother. All inputs are physical
# measurements: `min_height` is the sweepable-ice ceiling (below it the sweep
# owns the puck), `max_height` the pad/lap shelf envelope the glove can
# actually pin, `body_radius` the butterfly's horizontal span. Near-rest is
# enforced by the caller's dwell (a puck must HOLD this window, not cross it),
# so `max_speed` only excludes clearly-live pucks.
static func puck_resting_on_goalie(
		puck_position: Vector3,
		puck_speed: float,
		goalie_position: Vector3,
		min_height: float,
		max_height: float,
		body_radius: float,
		max_speed: float) -> bool:
	if puck_speed > max_speed:
		return false
	var height: float = puck_position.y - goalie_position.y
	if height < min_height or height > max_height:
		return false
	var dx: float = puck_position.x - goalie_position.x
	var dz: float = puck_position.z - goalie_position.z
	return dx * dx + dz * dz <= body_radius * body_radius


# ── Net-front jam (seal the ice) ─────────────────────────────────────────────
# Should the goalie drop to butterfly to SEAL a net-front scramble? A doorstep
# jam is a BATTLE — a loose puck with an opponent on it, or a slow opposing
# carrier with a defender's stick in the fight — sealed low so pucks don't go
# through the STANDING 5-hole during the chaos (Hockey Canada: a puck within
# ~2 stick lengths in a battle gets the blocking butterfly). A jam always has
# two parties; that's what separates it from the two controlled-possession
# cases coaches teach staying up against: a carrier ATTACKING with speed
# (above `carrier_max_speed` — force the release), and an UNCONTESTED slow
# carrier in tight — the penalty-shot-style 1v1, where the goalie stays up,
# stays patient, and makes the shooter commit first (the deke-breaks-wide
# race and the release reaction own the commit; carrier speed alone can't
# tell a dangler choosing to be slow from a carrier pinned in a scrum).
#
# `nearest_contestant_dist_to_puck` is the other party of the would-be battle:
# for a loose puck, the nearest OPPOSING skater (someone to whack it); for an
# opposing carrier, the nearest DEFENDING skater (someone fighting him for
# it). INF means nobody is contesting.
class CreaseJamConfig:
	var puck_distance: float = 2.0       # m — puck-to-goalie threshold
	var opponent_distance: float = 1.5   # m — contestant-to-puck battle range
	var carrier_max_speed: float = 3.0   # m/s — above this a carrier is attacking, not jamming

static func is_crease_jam(
		puck_position: Vector3,
		goalie_position: Vector3,
		goal_line_z: float,
		direction_sign: int,
		has_opposing_carrier: bool,
		carrier_speed: float,
		nearest_contestant_dist_to_puck: float,
		cfg: CreaseJamConfig) -> bool:
	# In front of the goal line only — behind-net plays are RVH's job.
	if (puck_position.z - goal_line_z) * direction_sign <= 0.0:
		return false
	if goalie_position.distance_to(puck_position) > cfg.puck_distance:
		return false
	if has_opposing_carrier:
		# A slow carrier is only a jam when a defender is IN the battle. Slow
		# and uncontested is the 1v1 dangler → stay up, force the first move.
		return carrier_speed <= cfg.carrier_max_speed \
				and nearest_contestant_dist_to_puck <= cfg.opponent_distance
	# Loose puck — needs an opponent close enough to whack it for it to be a jam.
	return nearest_contestant_dist_to_puck <= cfg.opponent_distance


# ── Screen occlusion (grounded sightline model) ──────────────────────────────
# A body between the shooter and the goalie hides the puck: the goalie can't start
# their read until they SEE the puck leave the shadow of the screener. This returns
# that pickup delay in SECONDS, built from geometry + shot speed rather than a flat
# "screened → +X ms" fudge. The grounding: the puck starts at the shooter (behind
# the screen) and flies toward the net; the goalie can't see it until it passes the
# screener. A body planted at the NET FRONT (doorstep) hides the puck until it has
# flown almost the whole way in — the deadly screen — while a body up near the
# shooter is passed early and barely delays the read. Longer flight to reach the
# screener = longer the puck is hidden, so the delay is grounded, not a curve.
#
# Evaluated in the XZ plane (bodies + shots live on the ice). A screener at S
# occludes the puck while the puck is still farther from the net than S; the puck
# emerges — and the goalie picks it up — once it reaches S's along-shot position,
# so that screener's delay is (release→S along-shot distance) / shot speed. It only
# counts if S sits ON the sightline (within `screener_radius` of the shot line) and
# BETWEEN the shooter and the goalie. The worst (longest-hiding) screener wins; the
# shooter self-excludes (it sits at the release point, along ≈ 0 < min_along). The
# caller clamps the result to a cap (and to the flight time). Returns 0 for a clean
# look. No allocation (scalar loop over the caller-owned positions array).
class ScreenConfig:
	var screener_radius: float = 0.6   # m — body half-width that blocks the sightline
	var min_along: float = 0.6         # m — exclude the shooter / bodies right on the puck

static func screen_occlusion_delay(
		puck_position: Vector3,
		puck_velocity: Vector3,
		goalie_position: Vector3,
		screener_positions: PackedVector3Array,
		cfg: ScreenConfig) -> float:
	var speed: float = sqrt(puck_velocity.x * puck_velocity.x + puck_velocity.z * puck_velocity.z)
	if speed < 0.001:
		return 0.0
	var vhx: float = puck_velocity.x / speed
	var vhz: float = puck_velocity.z / speed
	var radius: float = maxf(cfg.screener_radius, 0.0001)
	# How far along the shot the goalie sits — a screener must be nearer than this
	# (a body level with or behind the goalie can't hide an incoming puck).
	var goalie_along: float = (goalie_position.x - puck_position.x) * vhx \
			+ (goalie_position.z - puck_position.z) * vhz
	if goalie_along <= cfg.min_along:
		return 0.0
	var worst: float = 0.0
	for s in screener_positions:
		var relx: float = s.x - puck_position.x
		var relz: float = s.z - puck_position.z
		# Along-shot distance to the screener, and perpendicular distance to the
		# shot line (perp basis of (vhx, vhz) is (-vhz, vhx)).
		var along: float = relx * vhx + relz * vhz
		if along <= cfg.min_along or along >= goalie_along:
			continue
		var perp: float = absf(relx * -vhz + relz * vhx)
		if perp >= radius:
			continue
		var delay: float = along / speed
		if delay > worst:
			worst = delay
	return worst


# ── Standing push kinematics ─────────────────────────────────────────────────
# Lateral distance a standing goalie covers in `t` seconds pushing from rest:
# accelerate at `accel` up to `max_speed`, then hold. Mirrors the move_toward
# ramp in GoalieController._move_along_arc, so race math built on this matches
# what the live push can actually deliver (the from-rest ramp is a big share of
# short races — omitting it flattered the goalie by ~v²/2a metres).
static func reachable_lateral_distance(max_speed: float, accel: float, t: float) -> float:
	if t <= 0.0 or max_speed <= 0.0:
		return 0.0
	if accel <= 0.0:
		return max_speed * t
	var t_ramp: float = max_speed / accel
	if t <= t_ramp:
		return 0.5 * accel * t * t
	return max_speed * t - 0.5 * max_speed * t_ramp


# ── Behind-net puck play (tier-1 conservative rim stop) ──────────────────────
# The goalie leaves the net ONLY to stop a rim behind it — "stop it, leave it,
# get back" — never to carry or pass (the misplay-prone tiers of real puck
# handling are deliberately absent: an AI turnover behind the net is the most
# frustrating failure a goalie AI can produce, and a pure stop has no turnover
# mode; the only failure is a bad GO decision, which is what these races pin).
# Everything is deliberately conservative:
#   - the forechecker is modeled at FULL SPRINT from the first instant (no
#     reaction delay, no acceleration ramp) — the fastest opponent physics
#     allows, so the pressure clock always under-estimates the available time;
#   - the goalie's clock counts the WHOLE trip — out, the stop beat, and the
#     return to his post — before pressure arrives, not just the touch;
#   - callers re-run the race mid-trip with a stricter margin (abort
#     hysteresis): a conservative goalie visibly bails early rather than ever
#     getting caught out.

# Travel time from rest over `dist` with an accel ramp to `max_speed` — the
# inverse of reachable_lateral_distance, for the skate out/back legs.
static func travel_time_from_rest(dist: float, max_speed: float, accel: float) -> float:
	if dist <= 0.0:
		return 0.0
	if max_speed <= 0.0:
		return INF
	if accel <= 0.0:
		return dist / max_speed
	var t_ramp: float = max_speed / accel
	var d_ramp: float = 0.5 * accel * t_ramp * t_ramp
	if dist <= d_ramp:
		return sqrt(2.0 * dist / accel)
	return t_ramp + (dist - d_ramp) / max_speed


# Can the goalie be at the stop point, SET, before the rim arrives? A stop the
# goalie reaches late is a deflection risk, not a stop — no-go.
static func can_beat_puck_to_stop(
		t_goalie_out: float, puck_dist_to_stop: float, puck_speed: float,
		set_beat: float) -> bool:
	return t_goalie_out + set_beat <= puck_dist_to_stop / maxf(puck_speed, 0.1)


# The conservative go/no-go race: the nearest opponent — sprinting flat-out
# from this instant — must not reach the stop point until the goalie's ENTIRE
# trip (out + stop beat + return to post) plus `margin` has elapsed. Callers
# pass a fat margin for the GO decision and a smaller one for the mid-trip
# ABORT check (hysteresis in the safe direction).
static func puck_play_race_clear(
		t_goalie_out: float, t_return: float, stop_beat: float,
		nearest_opp_dist_to_stop: float, opp_sprint_speed: float,
		margin: float) -> bool:
	var t_pressure: float = nearest_opp_dist_to_stop / maxf(opp_sprint_speed, 0.1)
	return t_pressure > t_goalie_out + stop_beat + t_return + margin


# ── Beaten-wide detection (drop-and-seal trigger) ────────────────────────────
# A carrier driving laterally across the crease face beats a standing goalie to
# the short side when the goalie physically can't stay square: the tuck point
# is the post on the side the carrier is moving toward, and this is a straight
# race to it. The goalie's required travel is the true 2D distance from their
# challenge position back to the post seal spot, less pad reach — being out on
# the arc is exactly what makes the reach-around work, so the retreat distance
# must count. When the race is lost, standing tracking is unwinnable and the
# correct read is drop + butterfly-slide post seal (the caller's job).
#
# THE TUCK IS PLAYED BY THE PUCK, NOT THE BODY — the point of no return. A
# body driving toward a post with the puck still on the far side (the classic
# forehand-drag drive: skate across, puck trailing, wrap to the backhand once
# the goalie sells out) has committed NOTHING — the wrap/cut-back is free, and
# a pads-first commit at that moment is exactly what the move is fishing for.
# The commit gate is therefore positional on the PUCK: it must already be past
# the goalie's standing sealing reach on the drive side. Beyond that line the
# attacker has genuinely spent the play — bringing the puck back means the
# full trip around the body from deep — so committing there is safe by
# geometry, not by guessing intent. The race clock runs from the puck too
# (its lateral distance to the post at the drive speed), since the puck's
# arrival at the tuck point is what scores.
#
# Deliberately NOT triggered by: the puck trailing the drive (above), slow
# lateral movement (min_lateral_speed — a drive, not a dangle's shuffle; stay
# up and force the release), threats outside max_threat_distance (a fast cut
# at the top of the slot has too many options to commit against), or threats
# behind the goal line (RVH's job).
class BeatenWideConfig:
	var goalie_lateral_speed: float = 0.0  # m/s — standing T-push cap
	var goalie_lateral_accel: float = 0.0  # m/s² — push-off ramp from rest
	var reach_half_width: float = 0.0      # m — standing pad coverage half-extent
	var min_lateral_speed: float = 0.0     # m/s — carrier must be genuinely driving
	var max_threat_distance: float = 0.0   # m — Euclidean threat→goal in-tight gate

static func is_beaten_wide(
		threat_position: Vector3,
		puck_position: Vector3,
		threat_velocity_x: float,
		goalie_position: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		direction_sign: int,
		net_half_width: float,
		cfg: BeatenWideConfig) -> bool:
	# In front of the goal line only — behind-net drives are RVH's job.
	if (threat_position.z - goal_line_z) * direction_sign <= 0.0:
		return false
	if threat_distance_to_goal(threat_position, goal_line_z, goal_center_x) \
			> cfg.max_threat_distance:
		return false
	if absf(threat_velocity_x) < cfg.min_lateral_speed:
		return false
	var drive_sign: float = signf(threat_velocity_x)
	# Point of no return: the PUCK must already be past the goalie's standing
	# sealing reach on the drive side. Trailing puck → the cut-back is free →
	# stay up and shuffle with the play (see the header).
	var seal_edge_x: float = goalie_position.x + drive_sign * cfg.reach_half_width
	if (puck_position.x - seal_edge_x) * drive_sign <= 0.0:
		return false
	# Tuck point: the post on the side the carrier is driving toward. The race
	# clock runs from the PUCK — its arrival at the tuck point is what scores.
	var post_x: float = goal_center_x + drive_sign * net_half_width
	var t_arrive: float = maxf((post_x - puck_position.x) / threat_velocity_x, 0.0)
	var dx: float = post_x - goalie_position.x
	var dz: float = goal_line_z - goalie_position.z
	var needed: float = sqrt(dx * dx + dz * dz) - cfg.reach_half_width
	if needed <= 0.0:
		return false  # pad already covers the tuck point
	return needed > reachable_lateral_distance(
			cfg.goalie_lateral_speed, cfg.goalie_lateral_accel, t_arrive)


# ── Rush retreat (speed-matched backflow) ────────────────────────────────────
# Real breakaway/rush teaching: start at aggressive depth as the rush enters the
# zone, then back in MATCHING THE SHOOTER'S SPEED — crease-top as the attacker
# reaches the hash marks, goal-line depth as they reach the crease (USA Hockey /
# Edge Ice Academy; audit F5). Two grounded pieces:
#   rush_retreat_depth  — the depth the backflow curve wants at this attacker
#                         distance (piecewise linear through the three anchors).
#   rush_retreat_rate   — the retreat SPEED that tracks that curve exactly for a
#                         given closing speed: |d(depth)/d(dist)| × closing. This
#                         is what makes the retreat speed-matched instead of a
#                         lerp-lag artifact — a fast rush produces a fast backflow,
#                         a slow walk-in a slow one, and the goalie is never
#                         stranded out at challenge depth by smoothing lag.
class RushRetreatConfig:
	var engage_distance: float = 8.0   # m — backflow begins (attacker inside this)
	var mid_distance: float = 4.5      # m — "hash marks": be back at crease-top here
	var arrive_distance: float = 1.5   # m — attacker at the crease: be at D depth
	var depth_engage: float = 0.0      # anchor depths (callers pass the chart's A/B/D)
	var depth_mid: float = 0.0
	var depth_arrive: float = 0.0

static func rush_retreat_depth(threat_dist: float, cfg: RushRetreatConfig) -> float:
	if threat_dist >= cfg.engage_distance:
		return cfg.depth_engage
	if threat_dist >= cfg.mid_distance:
		var t: float = (threat_dist - cfg.mid_distance) \
				/ maxf(cfg.engage_distance - cfg.mid_distance, 0.001)
		return lerpf(cfg.depth_mid, cfg.depth_engage, t)
	if threat_dist >= cfg.arrive_distance:
		var t2: float = (threat_dist - cfg.arrive_distance) \
				/ maxf(cfg.mid_distance - cfg.arrive_distance, 0.001)
		return lerpf(cfg.depth_arrive, cfg.depth_mid, t2)
	return cfg.depth_arrive

# Retreat rate (m/s of depth change) that keeps the goalie ON the backflow curve
# while the attacker closes at `closing_speed`: the local curve slope × closing.
# Returns 0 for a non-closing attacker or outside the curve's sloped segments.
static func rush_retreat_rate(
		threat_dist: float, closing_speed: float, cfg: RushRetreatConfig) -> float:
	if closing_speed <= 0.0:
		return 0.0
	var slope: float
	if threat_dist >= cfg.engage_distance or threat_dist < cfg.arrive_distance:
		return 0.0
	if threat_dist >= cfg.mid_distance:
		slope = (cfg.depth_engage - cfg.depth_mid) \
				/ maxf(cfg.engage_distance - cfg.mid_distance, 0.001)
	else:
		slope = (cfg.depth_mid - cfg.depth_arrive) \
				/ maxf(cfg.mid_distance - cfg.arrive_distance, 0.001)
	return absf(slope) * closing_speed


# ── Lateral tracking cap (the deke / walkout answer) ────────────────────────
# The deepest challenge radius from which the goalie can still STAY SQUARE to a
# carrier moving the puck laterally — the anticipatory answer to "how far out dare
# I come against someone who can take it around me?"
#
# This is a RATE constraint, not a race, and that distinction is the whole model.
# A pass is a discrete event: it happens, then the goalie reacts, so the backdoor
# cap prices it as react-delay + travel (see backdoor_depth_cap). A deke or walkout
# is CONTINUOUS — the goalie tracks it the whole way — so there is no reaction
# delay to pay, only the question of whether he can turn as fast as the puck.
#
# Geometry: staying square to a threat `d` away moving laterally at `v` means
# holding an angular rate of v/d. At challenge radius r that costs a linear
# push of r·v/d, so the constraint is
#     r · v / d  <=  push_speed        =>     r <= push_speed · d / v
# which says exactly what it should: the closer the carrier and the faster he moves
# it across, the less depth you can afford. Coming out is a bet that he shoots
# rather than moves — and this is the price of that bet.
#
# Returns INF when nothing binds (a stationary or slow carrier). Replaces the old
# `pull-per-m/s-of-deficit` curve, which was a shape parameter standing in for this.
static func lateral_tracking_cap(
		threat_dist: float, lateral_speed: float, push_speed: float) -> float:
	var v: float = absf(lateral_speed)
	if v < 0.001 or threat_dist <= 0.0 or push_speed <= 0.0:
		return INF
	return push_speed * threat_dist / v


# ── Cross-crease save-selection fork ─────────────────────────────────────────
# Real save selection on a cross-crease pass is a time race (audit F3): stay on
# your FEET when the push can arrive set before the one-timer; go PADS-FIRST
# SLIDE (arrive-and-seal) when the pass has already won — a beaten goalie arrives
# late but sealed along the ice, taking away the low far-side finish, instead of
# arriving late upright mid-T-push with the bottom of the net open.
#
# Race: time available = puck flight to the crossing point + the receiver's
# release swing (the read delay was already spent by the caller before asking).
# Distance needed = lateral gap to the crossing minus standing pad coverage.
# Lost when the accel-ramped standing push can't cover it in time.
static func cross_crease_race_lost(
		target_x: float,
		puck_x: float,
		puck_vx: float,
		goalie_x: float,
		reach_half_width: float,
		release_time: float,
		goalie_lateral_speed: float,
		goalie_lateral_accel: float) -> bool:
	var needed: float = absf(target_x - goalie_x) - reach_half_width
	if needed <= 0.0:
		return false  # already covering the crossing point
	var t_pass: float = absf(target_x - puck_x) / maxf(absf(puck_vx), 0.001)
	var t_avail: float = t_pass + release_time
	return needed > reachable_lateral_distance(
			goalie_lateral_speed, goalie_lateral_accel, t_avail)


# ── Backdoor-aware depth cap ─────────────────────────────────────────────────
# A goalie who sees a one-timer threat on the weak side doesn't challenge the
# carrier as far out: depth trades shot-angle coverage against the time to
# re-square across to the new shot line when the pass goes. Grounded race:
#   time the play needs   = pass flight (puck→shooter / pass_speed)
#                           + the receiver's release swing
#   time the goalie loses = read delay before the push engages
#   coverable distance    = reachable_lateral_distance over what's left
# At challenge radius r along the goal→threat ray, the goalie sits r·sin(θ)
# off the goal→shooter shot line (θ between the two rays), so the cap solves
# r·sin(θ) <= coverable — the largest radius from which he still arrives.
# θ→0 (shooter on the carrier's line) needs no re-square → INF, no cap;
# an unwinnable race returns 0 (caller floors at its defensive depth). The
# result only ever *repositions* — the actual cross-crease save still runs the
# honest react/push race, so respecting the backdoor opens the carrier's
# direct-shot angle instead of buffing the goalie into a wall.
class BackdoorThreatConfig:
	var pass_speed: float = 0.0            # m/s — assumed feed pace (puck flight)
	var release_time: float = 0.0          # s — receiver's one-timer swing
	var react_delay: float = 0.0           # s — goalie read before the push engages
	var goalie_lateral_speed: float = 0.0  # m/s — standing T-push cap
	var goalie_lateral_accel: float = 0.0  # m/s² — push-off ramp from rest
	var max_shooter_distance: float = 0.0  # m — shooter→goal eligibility radius

static func backdoor_depth_cap(
		puck_position: Vector3,
		threat_position: Vector3,
		shooter_position: Vector3,
		goal_line_z: float,
		goal_center_x: float,
		direction_sign: int,
		cfg: BackdoorThreatConfig) -> float:
	# Live one-timer option only: in front of the goal line (no shooting angle
	# from behind it) and inside the scoring area.
	if (shooter_position.z - goal_line_z) * direction_sign <= 0.0:
		return INF
	var sx: float = shooter_position.x - goal_center_x
	var sz: float = shooter_position.z - goal_line_z
	var shooter_dist: float = sqrt(sx * sx + sz * sz)
	if shooter_dist > cfg.max_shooter_distance or shooter_dist < 0.001:
		return INF
	var tx: float = threat_position.x - goal_center_x
	var tz: float = threat_position.z - goal_line_z
	var threat_dist: float = sqrt(tx * tx + tz * tz)
	if threat_dist < 0.001:
		return INF
	# sin(θ) between goal→threat and goal→shooter (2D cross product). Near-zero
	# means the shooter sits on the carrier's shot line — challenging the
	# carrier already covers him, no cap.
	var sin_theta: float = absf((tx * sz - tz * sx) / (threat_dist * shooter_dist))
	if sin_theta < 0.01:
		return INF
	var pdx: float = shooter_position.x - puck_position.x
	var pdz: float = shooter_position.z - puck_position.z
	var pass_dist: float = sqrt(pdx * pdx + pdz * pdz)
	var move_time: float = pass_dist / maxf(cfg.pass_speed, 0.001) \
			+ cfg.release_time - cfg.react_delay
	var coverable: float = reachable_lateral_distance(
			cfg.goalie_lateral_speed, cfg.goalie_lateral_accel, move_time)
	return coverable / sin_theta


# ── Movement read penalty ─────────────────────────────────────────────────────
# A goalie is only sharp when set — square and stopped. Caught mid-push, sliding,
# or standing back up, they read the shot late. Returns extra read latency in
# seconds, scaled by how unset the goalie is: `planar_speed` (lateral/depth
# motion) ramps it toward `max_delay` at `reference_speed`, and `scrambling`
# (recovering / mid-slide posture) floors the unset-ness at `scramble_unset`.
# This only ever ADDS delay while the goalie is in motion — a set goalie reads
# at the base delay — so it opens scoring windows without buffing the save.
class MovementReadConfig:
	var reference_speed: float = 2.5    # m/s — planar speed that counts as fully moving
	var max_delay: float = 0.12         # s — read latency when fully unset
	var scramble_unset: float = 1.0     # unset floor (0..1) while recovering / scrambling

static func movement_read_penalty(planar_speed: float, scrambling: bool, cfg: MovementReadConfig) -> float:
	var unset: float = clampf(planar_speed / maxf(cfg.reference_speed, 0.0001), 0.0, 1.0)
	if scrambling:
		unset = maxf(unset, cfg.scramble_unset)
	return unset * cfg.max_delay


# ── Five-hole gap ─────────────────────────────────────────────────────────────
# The physical width (m) of the slot between the goalie's pads, from the
# replicated pose. Mirrors the live pad geometry (Goalie.tscn pad boxes 0.28
# wide; GoalieBodyConfigBuilder standing pad centers x = ±(0.22 + openness),
# butterfly pads rotated flat with their inner ends at ±openness):
#   standing family — inner edges sit ±(0.08 + openness) → gap 0.16 + 2·openness
#     (≈ 0.20 m at the 0.02 resting openness): a REAL slot, ice to pad-top,
#     guarded only by the stick blade (0.07 m tall) at ice level.
#   down family (butterfly / slide / RVH) — the rotated pads seal the ice; the
#     residual gap is the openness alone (≈ 0 set, up to ~0.36 mid-slide).
# `openness` is GoalieNetworkState.five_hole_openness; `is_down` is its
# is_down() stance family.
const PAD_BOX_WIDTH_M: float = 0.28
const STANDING_PAD_CENTER_X_M: float = 0.22

static func five_hole_gap_m(is_down: bool, openness: float) -> float:
	var op: float = maxf(openness, 0.0)
	if is_down:
		return 2.0 * op
	return 2.0 * (STANDING_PAD_CENTER_X_M + op) - PAD_BOX_WIDTH_M
