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
		accel: Vector3 = Vector3.ZERO,
		max_speed_m_s: float = 0.0) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var p: Vector3 = pos
	var v: Vector3 = vel
	for i: int in range(steps):
		var stepped: Transform3D = _step(
				p, v, dt, decel_m_s2, bounce_factor, accel, max_speed_m_s)
		p = stepped.origin
		v = stepped.basis.x
		out.append(p)
	return out


# Final position after `steps` of the same integration, WITHOUT building the
# per-step array. predict_at / predict_puck_at / intercept_time only need the
# endpoint, so this spares them the Array[Vector3] allocation on the 60 Hz
# per-bot paths (steering lead, pass / chase / body-check intercept). Shares the
# exact per-step math with predict() via _step, so it can never drift from it.
static func predict_final(pos: Vector3, vel: Vector3,
		steps: int, dt: float,
		decel_m_s2: float = 0.0,
		bounce_factor: float = 0.0,
		accel: Vector3 = Vector3.ZERO,
		max_speed_m_s: float = 0.0) -> Vector3:
	var p: Vector3 = pos
	var v: Vector3 = vel
	for i: int in range(steps):
		var stepped: Transform3D = _step(
				p, v, dt, decel_m_s2, bounce_factor, accel, max_speed_m_s)
		p = stepped.origin
		v = stepped.basis.x
	return p


# Single source of truth for one integration step. Advances (pos, vel) one dt
# and returns the stepped state packed into a Transform3D — a VALUE type, so no
# heap allocation (origin = new position, basis.x = new velocity). Both predict()
# and predict_final() unpack from this, so the array and endpoint-only paths use
# identical physics.
static func _step(p: Vector3, v: Vector3, dt: float,
		decel_m_s2: float, bounce_factor: float,
		accel: Vector3, max_speed_m_s: float) -> Transform3D:
	# Apply control acceleration BEFORE the position step so the step uses the
	# velocity the body has during it. Forward-Euler is off by 0.5·a·dt² from the
	# exact closed form per step, dwarfed by the pass / chase windows where this
	# is used (≤0.6 s for passes, ≤1.5 s for chase).
	if accel != Vector3.ZERO:
		v += accel * dt
	# Top-speed cap (a skater can't be accelerated past its own max_speed).
	# 0 = uncapped (default, all non-pass callers). Only ever REDUCES an over-
	# cap speed, so passing a cap ≥ the body's current speed never slows a
	# body already moving faster (e.g. sprinting) — see AIPassLead.
	if max_speed_m_s > 0.0:
		var v_cap_mag: float = sqrt(v.x * v.x + v.z * v.z)
		if v_cap_mag > max_speed_m_s:
			var cap_scale: float = max_speed_m_s / v_cap_mag
			v.x *= cap_scale
			v.z *= cap_scale
	p += v * dt

	# Board interaction. With a bounce factor, REFLECT velocity off the boards
	# (puck caroms). Without, CLAMP position to the rink (skater approximation
	# — no reflection). Both use clamp_to_rink_inner so the rounded corners are
	# honoured: the old bounce path reflected off an axis-aligned RECTANGLE,
	# giving predicted pucks up to ~3.5 m of phantom corner ice and caroms off
	# walls that aren't there. Reflecting about the inward normal at the contact
	# point reduces to the exact old `v.x = -v.x·bounce` on a straight wall and
	# reflects radially in the corners.
	var clamped_xz: Vector2 = GameRules.clamp_to_rink_inner(Vector2(p.x, p.z))
	if bounce_factor > 0.0:
		var outward := Vector2(p.x - clamped_xz.x, p.z - clamped_xz.y)
		if outward.length_squared() > 1e-9:
			var n := outward.normalized()
			var v_xz := Vector2(v.x, v.z)
			var vn: float = v_xz.dot(n)
			if vn > 0.0:  # moving outward into the boards
				v_xz -= (1.0 + bounce_factor) * vn * n
				v.x = v_xz.x
				v.z = v_xz.y
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

	return Transform3D(Basis(v, Vector3.ZERO, Vector3.ZERO), p)


# Convenience: position at a single lead time. Matches the common case
# of "where will this skater be in T seconds" without forcing callers
# to pick a step count. Steps default to 6 — granular enough that the
# rink clamp catches mid-flight wall contact, cheap enough at 6 Hz.
#
# Constant velocity + optional constant acceleration, no friction,
# no bounce. Use `predict_puck_at` for puck-specific physics.
static func predict_at(pos: Vector3, vel: Vector3, lead_time_s: float,
		steps: int = 6, accel: Vector3 = Vector3.ZERO,
		max_speed_m_s: float = 0.0) -> Vector3:
	if lead_time_s <= 0.0 or steps <= 0:
		return pos
	var dt: float = lead_time_s / float(steps)
	return predict_final(pos, vel, steps, dt, 0.0, 0.0, accel, max_speed_m_s)


# Solve the lead time so a constant-speed projectile fired from
# `shooter_pos` and a target moving at `target_vel` (+ optional `accel`)
# arrive at the same point. The naive `dist_to_current / speed` is wrong
# whenever the target moves radially: a receiver skating AWAY makes the
# real intercept distance longer (puck under-leads, lands behind them);
# skating toward shrinks it (over-leads). Two fixed-point iterations
# refine the straight-line guess against the predicted intercept point —
# converges fast and is trivial at the 6 Hz brain tick. Clamped to
# `max_lead_s` so a target fleeing faster than the projectile doesn't
# diverge. Returns 0 for a non-positive projectile speed.
static func intercept_time(shooter_pos: Vector3, target_pos: Vector3,
		target_vel: Vector3, accel: Vector3,
		proj_speed: float, max_lead_s: float, steps: int = 6,
		max_speed_m_s: float = 0.0) -> float:
	if proj_speed <= 0.0:
		return 0.0
	var t: float = clampf(
			shooter_pos.distance_to(target_pos) / proj_speed, 0.0, max_lead_s)
	for _i: int in range(2):
		var pred: Vector3 = predict_at(target_pos, target_vel, t, steps, accel, max_speed_m_s)
		t = clampf(shooter_pos.distance_to(pred) / proj_speed, 0.0, max_lead_s)
	return t


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
	return predict_final(pos, vel, steps, dt,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.PUCK_BOARD_BOUNCE)
