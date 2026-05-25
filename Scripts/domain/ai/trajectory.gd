class_name AITrajectory

# Forward-simulate a skater / puck position N steps ahead. Returns
# the position at each step (index 0 = t=dt, index N-1 = t=N*dt).
# Callers either pluck a single step (man-to-man lead) or scan the
# whole array (intercept search, lane prediction).
#
# Two physics models, picked via the `decel_m_s2` and `bounce_factor`
# parameters:
#
# - Skater / generic body (decel = 0, bounce = 0): constant velocity
#   with rink CLAMPING. A skater hugging the boards isn't actually
#   at pos + vel × 0.5s — they bounce / scrape — and an unclamped
#   lead would put the defender's anchor inside the boards. Clamp is
#   the safe approximation.
#
# - Puck (decel = PUCK_ICE_DECEL, bounce = PUCK_BOARD_BOUNCE):
#   Coulomb friction decelerates the velocity opposite to its
#   direction each step (matching how ICE_FRICTION × gravity slows a
#   sliding puck), and board contact REFLECTS the perpendicular
#   velocity component scaled by the restitution coefficient. The
#   `predict_puck_at` convenience wires these directly from
#   GameRules so callers don't have to remember the constants.
#
# Cost is trivial — a few skaters × 6 steps at 6 Hz brain tick.

static func predict(pos: Vector3, vel: Vector3,
		steps: int, dt: float,
		decel_m_s2: float = 0.0,
		bounce_factor: float = 0.0,
		accel: Vector3 = Vector3.ZERO) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var p: Vector3 = pos
	var v: Vector3 = vel
	for i: int in range(steps):
		# Apply control acceleration BEFORE the position step so the
		# i-th sample uses the velocity that the body has during that
		# step. Forward-Euler is off by 0.5·a·dt² from the exact
		# closed form per step, dwarfed by the pass / chase windows
		# where this is used (≤0.6 s for passes, ≤1.5 s for chase).
		if accel != Vector3.ZERO:
			v += accel * dt
		p += v * dt

		# Board interaction. With a bounce factor, REFLECT perpendicular
		# velocity (puck caroms off boards). Without, CLAMP position to
		# the rink (skater approximation — no reflection).
		if bounce_factor > 0.0:
			if absf(p.x) > GameRules.INNER_HALF_WIDTH:
				p.x = signf(p.x) * GameRules.INNER_HALF_WIDTH
				v.x = -v.x * bounce_factor
			if absf(p.z) > GameRules.INNER_HALF_LENGTH:
				p.z = signf(p.z) * GameRules.INNER_HALF_LENGTH
				v.z = -v.z * bounce_factor
		else:
			var clamped_xz: Vector2 = GameRules.clamp_to_rink_inner(Vector2(p.x, p.z))
			p = Vector3(clamped_xz.x, p.y, clamped_xz.y)

		# Coulomb friction — decelerate XZ speed opposite to its
		# direction, clamping at zero so a slow puck eventually stops
		# rather than going backward.
		if decel_m_s2 > 0.0:
			var v_xz_mag: float = sqrt(v.x * v.x + v.z * v.z)
			if v_xz_mag > 0.001:
				var decel_amount: float = decel_m_s2 * dt
				if v_xz_mag <= decel_amount:
					v.x = 0.0
					v.z = 0.0
				else:
					var scale: float = (v_xz_mag - decel_amount) / v_xz_mag
					v.x *= scale
					v.z *= scale

		out.append(p)
	return out


# Convenience: position at a single lead time. Matches the common case
# of "where will this skater be in T seconds" without forcing callers
# to pick a step count. Steps default to 6 — granular enough that the
# rink clamp catches mid-flight wall contact, cheap enough at 6 Hz.
#
# Constant velocity + optional constant acceleration, no friction,
# no bounce. Use `predict_puck_at` for puck-specific physics.
static func predict_at(pos: Vector3, vel: Vector3, lead_time_s: float,
		steps: int = 6, accel: Vector3 = Vector3.ZERO) -> Vector3:
	if lead_time_s <= 0.0 or steps <= 0:
		return pos
	var dt: float = lead_time_s / float(steps)
	var traj: Array[Vector3] = predict(pos, vel, steps, dt, 0.0, 0.0, accel)
	return traj[traj.size() - 1]


# Puck-physics-aware forward simulation. Applies Coulomb ice friction
# and board reflection so the projected trajectory matches Jolt's
# actual resolution of a freely sliding puck. Use this for chase
# intercepts, pass-in-flight reception, and rebound prediction —
# anywhere the AI is reasoning about where the puck WILL BE rather
# than where a body WILL BE.
static func predict_puck(pos: Vector3, vel: Vector3,
		steps: int, dt: float) -> Array[Vector3]:
	return predict(pos, vel, steps, dt,
			GameRules.PUCK_ICE_DECEL_M_S2,
			GameRules.PUCK_BOARD_BOUNCE)


static func predict_puck_at(pos: Vector3, vel: Vector3, lead_time_s: float,
		steps: int = 6) -> Vector3:
	if lead_time_s <= 0.0 or steps <= 0:
		return pos
	var dt: float = lead_time_s / float(steps)
	var traj: Array[Vector3] = predict_puck(pos, vel, steps, dt)
	return traj[traj.size() - 1]
