class_name CarveRules

# Pure math for the carve/crossover gait trigger: real crossovers are how a
# skater TURNS at speed, not how they strafe — so the engagement signal is
# path curvature (turn rate of the travel direction), derived from velocity
# history exactly like the gait's effort signal. Velocity is replicated, so
# every machine (local, bot, remote, replay) reads the identical carve with
# nothing new on the wire. The lateral-velocity scissor gait stays for
# aim-locked strafing, which genuinely is a shuffle.
#
# Frame: XZ plane vectors as Vector2(x, z). Sign convention (pinned by
# tests): turning toward +X (the skater's right when travelling toward −Z)
# yields a POSITIVE turn rate.


# Signed turn rate of the travel direction in rad/s. Zero when either sample
# is too slow to carry a meaningful direction — at a near-standstill the
# velocity direction is noise, and a carve read from noise flails the legs.
static func turn_rate(prev_vel_xz: Vector2, vel_xz: Vector2,
		delta: float, min_speed: float) -> float:
	if delta <= 0.0:
		return 0.0
	if prev_vel_xz.length() < min_speed or vel_xz.length() < min_speed:
		return 0.0
	return prev_vel_xz.angle_to(vel_xz) / delta


# Normalized signed carve engagement in [−1, +1]: the fraction of a full
# crossover-cadence turn this curvature represents. ref_turn_rate is the
# turn rate treated as a full carve; speed below min_speed gates to zero
# (slow pivots are steps, not crossovers).
static func carve_target(p_turn_rate: float, ground_speed: float,
		ref_turn_rate: float, min_speed: float) -> float:
	if ground_speed < min_speed:
		return 0.0
	return clampf(p_turn_rate / maxf(ref_turn_rate, 0.001), -1.0, 1.0)


# Signed carve INTENT from held movement input across the travel line — "I'm
# trying to turn" fires the crossovers before the path visibly bends, while
# curvature (above) sustains them once the arc is real; the gait combines the
# two by larger magnitude. Same sign convention as turn_rate (positive =
# toward the traveller's right). The squared response keeps near-parallel
# input — ordinary drive corrections — from flickering the gait, and a fully
# perpendicular hold reads as a full carve.
static func intent_carve(travel_xz: Vector2, intent_xz: Vector2,
		ground_speed: float, min_speed: float) -> float:
	if ground_speed < min_speed:
		return 0.0
	if travel_xz.length_squared() < 0.01 or intent_xz.length_squared() < 0.0025:
		return 0.0
	var t_dir: Vector2 = travel_xz.normalized()
	var i_dir: Vector2 = intent_xz.normalized()
	var cross: float = t_dir.x * i_dir.y - t_dir.y * i_dir.x
	return cross * absf(cross)
