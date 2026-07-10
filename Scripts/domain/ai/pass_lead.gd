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


# Lead a pass to a moving receiver. `launch_speed` is the puck's RELEASE speed;
# the lead accounts for it bleeding off to ice friction in flight (see
# effective_flight_speed). `receiver_caps` is the receiver's real attribute-scaled
# build (AISkaterCaps) — its Agility (max_accel) caps how hard it can keep
# accelerating into the lead, and its Speed (max_speed) caps how far ahead it can
# actually get. Null falls back to the league baseline (unwired / unit tests), so
# the lead is unchanged until a real receiver build is passed. Returns
# [lead_point: Vector3, flight_t: float] — the carrier needs the solved flight
# time downstream (opponent projection, goalie prediction, time-decay).
static func lead(shooter_pos: Vector3, receiver: SkaterNetworkState,
		accel: Vector3, launch_speed: float, max_lead_s: float,
		receiver_caps: AISkaterCaps = null) -> Array:
	var blade_world: Vector3 = receiver.blade_contact_world
	# Defensive fallback: blade_contact_world is a host-only field that
	# should always be populated on the host, but aim at body center is
	# vastly better than aim at center ice if it ever isn't.
	if blade_world == Vector3.ZERO:
		blade_world = receiver.position
	var a: Vector3 = along_velocity_component(accel, receiver.velocity)
	# A receiver can't out-accelerate its own thrust (Agility). Observed accel is
	# low-passed and can spike above what the body can pull, which over-leads a
	# low-Agility receiver into ice it can't reach. Cap the along-travel accel at
	# the receiver's real max_accel.
	var max_accel: float = receiver_caps.max_accel if receiver_caps != null \
			else GameRules.DEFAULT_SKATER_THRUST_M_S2
	if a.length() > max_accel:
		a = a.normalized() * max_accel
	# ...and can't be led past its own top speed. Cap at the LARGER of the
	# receiver's max_speed and its current speed, so a receiver already moving
	# faster (mid-sprint — sprint raises the real cap) is never under-led, while
	# the accel term can't push a cruising receiver beyond what it can reach.
	var speed_cap: float = maxf(
			_speed_xz(receiver.velocity),
			receiver_caps.max_speed if receiver_caps != null else GameRules.DEFAULT_SKATER_MAX_SPEED_M_S)
	# Friction-aware: the intercept solver treats the puck as constant-speed, so
	# feed it the puck's AVERAGE flight speed rather than the launch speed —
	# otherwise a long pass under-leads (the puck arrives later than launch/dist
	# implies). Distance to the receiver's current blade is a fine proxy for the
	# pass length (the intercept iteration then refines against receiver motion).
	var eff_speed: float = effective_flight_speed(
			launch_speed, shooter_pos.distance_to(blade_world))
	var flight_t: float = AITrajectory.intercept_time(
			shooter_pos, blade_world, receiver.velocity, a,
			eff_speed, max_lead_s, 6, speed_cap)
	var point: Vector3 = AITrajectory.predict_at(
			blade_world, receiver.velocity, flight_t, 6, a, speed_cap)
	return [point, flight_t]


static func _speed_xz(v: Vector3) -> float:
	return sqrt(v.x * v.x + v.z * v.z)


# Convenience for callers that only need the aim point (the firing path).
static func lead_point(shooter_pos: Vector3, receiver: SkaterNetworkState,
		accel: Vector3, launch_speed: float, max_lead_s: float,
		receiver_caps: AISkaterCaps = null) -> Vector3:
	return lead(shooter_pos, receiver, accel, launch_speed, max_lead_s, receiver_caps)[0]


# Average (time-mean) speed of a pass over `distance`, given it launches at
# `launch_speed` and sheds speed to constant Coulomb ice friction. Under constant
# deceleration velocity is linear in TIME, so the time-average is exactly
# (launch + arrival)/2 — and distance = avg_speed × flight_time, so using this as
# the intercept solver's constant speed reproduces the true flight time. Leading
# at the raw launch speed instead under-leads a long pass (aims behind a cutting
# receiver), since the puck is slower than launch for most of the flight.
static func effective_flight_speed(launch_speed: float, distance: float) -> float:
	var arrival_sq: float = launch_speed * launch_speed \
			- 2.0 * GameRules.PUCK_ICE_DECEL_M_S2 * maxf(distance, 0.0)
	var arrival: float = sqrt(arrival_sq) if arrival_sq > 0.0 else 0.0
	return (launch_speed + arrival) * 0.5


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
