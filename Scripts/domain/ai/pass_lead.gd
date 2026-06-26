class_name AIPassLead

# Pass-leading for AI passers — the single source of truth shared by the
# carrier role's pass scoring (`AIRoleCarrier._compute_best_pass`) and the
# state machine's firing aim (`SkaterAgentStateMachine._pass_aim_point`).
# Both used to carry byte-for-byte copies of this; unifying them keeps the
# scored lead and the fired lead identical, so a pass can't be evaluated at
# one aim point and released at another.
#
# Two refinements over a naive `pos + vel·t` lead:
#
#   1. Intercept-time solve (AITrajectory.intercept_time): the flight time
#      is solved against the receiver's PREDICTED position, not their
#      current one, so a receiver skating away isn't under-led.
#
#   2. Along-velocity acceleration only (along_velocity_component): the
#      observed receiver acceleration is projected onto their travel
#      direction before extrapolation. A turning skater's acceleration is
#      largely centripetal (sideways); the ½·a·t² term along that vector
#      aims the pass off to the side of the curve, into ice the receiver
#      never enters ("pass to nobody"). Keeping only the speeding-up /
#      slowing-down component leads the cut without the overshoot.
#
# The receiver is aimed at via `blade_contact_world` (where the stick is,
# not body center), with a body-position fallback for the degenerate
# unpopulated case.

# Below this speed there's no reliable travel direction to project
# acceleration onto (you can't be mid-turn while standing still), so the
# raw accel — which here reads as "starting to move" — is kept as-is.
const MIN_SPEED_FOR_PROJECTION: float = 0.5


# Lead a pass to a moving receiver. Returns [lead_point: Vector3,
# flight_t: float] — the carrier needs the solved flight time downstream
# (opponent projection, goalie prediction, time-decay), so it's returned
# alongside the point rather than recomputed.
static func lead(shooter_pos: Vector3, receiver: SkaterNetworkState,
		accel: Vector3, proj_speed: float, max_lead_s: float) -> Array:
	var blade_world: Vector3 = receiver.blade_contact_world
	# Defensive fallback: blade_contact_world is a host-only field that
	# should always be populated on the host, but aim at body center is
	# vastly better than aim at center ice if it ever isn't.
	if blade_world == Vector3.ZERO:
		blade_world = receiver.position
	var a: Vector3 = along_velocity_component(accel, receiver.velocity)
	var flight_t: float = AITrajectory.intercept_time(
			shooter_pos, blade_world, receiver.velocity, a,
			proj_speed, max_lead_s)
	var point: Vector3 = AITrajectory.predict_at(
			blade_world, receiver.velocity, flight_t, 6, a)
	return [point, flight_t]


# Convenience for callers that only need the aim point (the firing path).
static func lead_point(shooter_pos: Vector3, receiver: SkaterNetworkState,
		accel: Vector3, proj_speed: float, max_lead_s: float) -> Vector3:
	return lead(shooter_pos, receiver, accel, proj_speed, max_lead_s)[0]


# Project `accel` onto the travel direction, keeping only the component
# parallel to `vel`. Discards the centripetal (turn) component. Near
# zero speed there's no direction to project onto, so `accel` is returned
# unchanged (see MIN_SPEED_FOR_PROJECTION).
static func along_velocity_component(accel: Vector3, vel: Vector3) -> Vector3:
	var speed: float = vel.length()
	if speed < MIN_SPEED_FOR_PROJECTION:
		return accel
	var dir: Vector3 = vel / speed
	return dir * accel.dot(dir)
