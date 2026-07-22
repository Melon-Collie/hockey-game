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
		max_speed_m_s: float = 0.0,
		board_friction: float = 0.0) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var p: Vector3 = pos
	var v: Vector3 = vel
	for i: int in range(steps):
		var stepped: Transform3D = _step(
				p, v, dt, decel_m_s2, bounce_factor, accel, max_speed_m_s, board_friction)
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
		max_speed_m_s: float = 0.0,
		board_friction: float = 0.0) -> Vector3:
	var p: Vector3 = pos
	var v: Vector3 = vel
	for i: int in range(steps):
		var stepped: Transform3D = _step(
				p, v, dt, decel_m_s2, bounce_factor, accel, max_speed_m_s, board_friction)
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
		accel: Vector3, max_speed_m_s: float,
		board_friction: float = 0.0) -> Transform3D:
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
				# Reflect the normal (into-board) component with restitution.
				v_xz -= (1.0 + bounce_factor) * vn * n
				# Board friction (Coulomb): bleed the ALONG-board (tangential) speed by an
				# amount proportional to the normal impulse — what actually kills a hard
				# rim-around. A glancing carom (small vn) barely slows; a square hit sheds
				# more. Applied to the post-reflection tangential component (reflection
				# leaves it unchanged), clamped so it can't reverse.
				if board_friction > 0.0:
					var v_tan := v_xz - v_xz.dot(n) * n
					var t_speed: float = v_tan.length()
					if t_speed > 1e-6:
						var drop: float = board_friction * (1.0 + bounce_factor) * vn
						var new_t: float = maxf(t_speed - drop, 0.0)
						v_xz += v_tan * (new_t / t_speed - 1.0)
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
			GameRules.PUCK_BOARD_BOUNCE,
			Vector3.ZERO, 0.0, GameRules.PUCK_BOARD_FRICTION)


static func predict_puck_at(pos: Vector3, vel: Vector3, lead_time_s: float,
		steps: int = 6) -> Vector3:
	if lead_time_s <= 0.0 or steps <= 0:
		return pos
	var dt: float = lead_time_s / float(steps)
	return predict_final(pos, vel, steps, dt,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.PUCK_BOARD_BOUNCE,
			Vector3.ZERO, 0.0, GameRules.PUCK_BOARD_FRICTION)


# One deterministic puck step (ice friction + rounded-corner board reflection),
# returning BOTH the new position AND velocity packed into a Transform3D
# (origin = position, basis.x = velocity — the same value-type, no-alloc convention
# _step / predict use internally). predict_final returns position only, so free-run
# callers that must carry velocity forward tick-by-tick need this.
#
# This is the shared atom of the determinism migration (docs/netcode-determinism-
# migration.md, docs/netcode-phase0-shadow-puck-spec.md): the Phase-0 shadow-puck
# comparator free-runs the loose puck by chaining this, and the eventual Phase-1
# deterministic puck sim is built on it — so the sim the AI already trusts to match
# Jolt IS the sim that would drive the puck. Grounded (XZ) puck only; gravity/loft
# and goalie/net/pipe collision are later-phase additions.
static func step_puck(pos: Vector3, vel: Vector3, dt: float) -> Transform3D:
	return _step(pos, vel, dt,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.PUCK_BOARD_BOUNCE,
			Vector3.ZERO, 0.0, GameRules.PUCK_BOARD_FRICTION)


# Puck rest height on the ice — disc bottom on y=0, cylinder half-height above (matches
# Puck.ice_height / GameRules.PUCK_START_POS.y). A puck at this height with no vertical
# speed is grounded; anything higher or moving vertically is airborne (ballistic).
const PUCK_REST_HEIGHT_M: float = 0.0175
# A puck this far above rest, OR with |vy| above this, integrates ballistically. Small
# enough that any real loft (launch vy ≥ ~2 m/s) is airborne and a pinned-to-ice puck
# (vy == 0) is grounded; large enough to ignore float noise on a resting puck.
const _AIRBORNE_POS_EPS_M: float = 0.001
const _AIRBORNE_VY_EPS_M_S: float = 0.05


# step_puck with a vertical (gravity) channel — the airborne extension of the puck atom,
# so loft shots, saucer passes, and rebounds off the goalie's glove are modeled too, not
# just the grounded slide. Matches Jolt + Puck.gd:
#  - AIRBORNE (off the ice or moving vertically): ballistic — gravity on Y, board
#    reflection on XZ, and NO ice friction (no ice contact means no normal force, so a
#    puck in flight keeps its horizontal pace).
#  - LANDING: the puck lands and slides — Puck.gd zeroes linear_velocity.y and pins the
#    height the instant it's back on the ice, so there is NO vertical restitution/bounce.
#  - GROUNDED (at rest height, no vertical speed): identical to step_puck (ice friction +
#    board reflection); the height passes through unchanged.
# Returns (pos, vel) packed into a Transform3D (origin = pos, basis.x = vel) — the same
# value-type, no-alloc convention as _step / step_puck.
static func step_puck_3d(pos: Vector3, vel: Vector3, dt: float,
		rest_height: float = PUCK_REST_HEIGHT_M) -> Transform3D:
	if not is_puck_airborne(pos, vel, rest_height):
		return step_puck(pos, vel, dt)
	# Ballistic step: reuse _step (which reflects XZ off the rounded-corner boards and
	# preserves Y) with a downward gravity accel and zero ice friction.
	var stepped: Transform3D = _step(pos, vel, dt,
			0.0, GameRules.PUCK_BOARD_BOUNCE,
			Vector3(0.0, -GameRules.GRAVITY_M_S2, 0.0), 0.0, GameRules.PUCK_BOARD_FRICTION)
	var p: Vector3 = stepped.origin
	var v: Vector3 = stepped.basis.x
	if p.y <= rest_height:
		p.y = rest_height
		v.y = 0.0
	return Transform3D(Basis(v, Vector3.ZERO, Vector3.ZERO), p)


# Whether a puck at (pos, vel) integrates ballistically (off the ice or moving
# vertically) vs slides on the ice. The branch step_puck_3d uses — exposed so callers
# that bucket airborne vs grounded (the shadow comparator) share the exact same test.
static func is_puck_airborne(pos: Vector3, vel: Vector3,
		rest_height: float = PUCK_REST_HEIGHT_M) -> bool:
	return pos.y > rest_height + _AIRBORNE_POS_EPS_M or absf(vel.y) > _AIRBORNE_VY_EPS_M_S
