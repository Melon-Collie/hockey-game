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
		board_friction: float = 0.0,
		board_margin: float = 0.0) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var p: Vector3 = pos
	var v: Vector3 = vel
	for i: int in range(steps):
		var stepped: Transform3D = _step(
				p, v, dt, decel_m_s2, bounce_factor, accel, max_speed_m_s, board_friction,
				board_margin)
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
		board_friction: float = 0.0,
		board_margin: float = 0.0) -> Vector3:
	var p: Vector3 = pos
	var v: Vector3 = vel
	for i: int in range(steps):
		var stepped: Transform3D = _step(
				p, v, dt, decel_m_s2, bounce_factor, accel, max_speed_m_s, board_friction,
				board_margin)
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
		board_friction: float = 0.0,
		board_margin: float = 0.0) -> Transform3D:
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
	# honoured; reflecting about the inward normal at the contact point reduces
	# to `v.x = -v.x·bounce` on a straight wall and reflects radially in the
	# corners. An axis-aligned rectangle instead would grant up to ~3.5 m of
	# phantom corner ice and carom off walls that are not there.
	# `board_margin` is the body's own half-extent, so its EDGE stops at the board
	# surface rather than its centre. A puck passes its radius here: without it the
	# disc's centre sat on the kickplate face and half of it was inside the wall,
	# which reads as the puck sinking into the boards — and got obvious once
	# players could work the wall freely. Skater approximations pass 0 (unchanged).
	# The margin also moves the CONTACT inward by the same amount, which is
	# physically right: a puck caroms when its edge meets the board, not its centre.
	var clamped_xz: Vector2 = GameRules.clamp_to_rink_inner(Vector2(p.x, p.z), board_margin)
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
# and board reflection so the projected trajectory matches the host drive's
# actual resolution of a freely sliding puck. Use this for chase
# intercepts, pass-in-flight reception, and rebound prediction —
# anywhere the AI is reasoning about where the puck WILL BE rather
# than where a body WILL BE.
static func predict_puck(pos: Vector3, vel: Vector3,
		steps: int, dt: float) -> Array[Vector3]:
	return predict(pos, vel, steps, dt,
			GameRules.PUCK_ICE_DECEL_M_S2,
			GameRules.PUCK_BOARD_BOUNCE,
			Vector3.ZERO, 0.0, GameRules.PUCK_BOARD_FRICTION,
			GameRules.PUCK_COLLISION_RADIUS)


static func predict_puck_at(pos: Vector3, vel: Vector3, lead_time_s: float,
		steps: int = 6) -> Vector3:
	if lead_time_s <= 0.0 or steps <= 0:
		return pos
	var dt: float = lead_time_s / float(steps)
	return predict_final(pos, vel, steps, dt,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.PUCK_BOARD_BOUNCE,
			Vector3.ZERO, 0.0, GameRules.PUCK_BOARD_FRICTION,
			GameRules.PUCK_COLLISION_RADIUS)


# One deterministic puck step (ice friction + rounded-corner board reflection),
# returning BOTH the new position AND velocity packed into a Transform3D
# (origin = position, basis.x = velocity — the same value-type, no-alloc convention
# _step / predict use internally). predict_final returns position only, so free-run
# callers that must carry velocity forward tick-by-tick need this.
#
# This is the shared atom of the deterministic puck (docs/netcode-determinism-
# migration.md): the sim the AI reasons with IS the sim that drives the loose puck
# on the host and predicts it on the client. Grounded (XZ) puck only — gravity/loft
# and goalie/net/pipe collision live in step_puck_3d and the collision rules.
static func step_puck(pos: Vector3, vel: Vector3, dt: float) -> Transform3D:
	return _step(pos, vel, dt,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.PUCK_BOARD_BOUNCE,
			Vector3.ZERO, 0.0, GameRules.PUCK_BOARD_FRICTION,
			GameRules.PUCK_COLLISION_RADIUS)


# ── Board-aware reception gate ──────────────────────────────────────────────
# Where a loose puck comes into a receiver's reach, solved on the puck's REAL
# path instead of the straight ray off its current velocity.
#
# For a puck in open ice a straight ray off the current velocity agrees with the
# real path. On a RIM it does not: the path bends through the board carom and
# bleeds speed to board friction, so the ray leaves the rink mid-corner. Clamping
# it back onto the ice keeps two lies that decide the play — the ARRIVAL TIME is
# measured along the chord instead of around the arc, and the INCOMING DIRECTION
# is the pre-carom one, so the receiver squares his blade to a line the puck is
# no longer travelling.
#
# Walks the same friction + rounded-corner-carom integration everything else
# already trusts and reports the first point on that path the blade can touch —
# the gate the blade should wait at. With no such point it reports the closest
# approach instead, so a receiver still has somewhere honest to aim while the
# body keeps closing.
#
# It is a RENDEZVOUS: the reach circle rides `from_vel` down the walk, so the
# answer is where the puck's path meets the body's, not where it meets the spot
# the body happens to occupy at the instant of asking. A meeting point is a fact
# about two futures, and a present-frame solve cannot see one — a body metres
# off the line never has the puck's path enter a circle drawn where it is
# STANDING, so the walk finds no entry at all and falls back to the
# closest-approach foot, aiming the blade at ice the arm cannot reach until the
# last few ticks. Against a cursor that slews ~0.33 m per tick (blade speed
# ~10 m/s at 30 Hz) the stick is still swinging when the puck arrives. Ridden,
# the same meet is available from the first tick and always sits somewhere the
# arm can be, so the blade spends the approach in the pose it will catch in.
#
# The body is projected at CONSTANT velocity, the same read `_has_man_to_beat`
# and the protect screen use, and only for `ride_s` — after that it is treated
# as parked. The bound matters because a receiver is steering while this runs,
# so its present velocity is a claim with a shelf life, and the walk's horizon
# (2 s) is well past it. Callers pass the PASSER's own lead bound
# (AIRoleCarrier.PASS_LEAD_MAX_S), which makes the two halves of a pass agree on
# how much of the receiver's motion is real: the feed is aimed at most that far
# ahead of him, so he may set up at most that far ahead of himself.
#
# Results land in statics (single-threaded AI tick, same convention as
# AIActionScoring.resolve_feed_keeper): one solve serves the stance, the timing
# gate and the blade aim, with no per-call allocation on a per-tick path.
static var gate_point: Vector3 = Vector3.INF   # where the puck meets the reach
static var gate_velocity: Vector3 = Vector3.ZERO   # its travel there (post-carom)
static var gate_time_s: float = 0.0            # when it gets there
static var gate_in_reach: bool = false         # true = a real entry, not just closest
# The meet in the BODY's frame — the puck's offset from the body AT the meet,
# i.e. where the blade has to be relative to the chest when the puck shows up.
# `gate_point` is the same event in world coordinates, and the two consumers
# want different ones: the STANCE and the timing gate are about a patch of ice
# (world), while the BLADE AIM is a cursor the IK chases out of a body that is
# still skating (relative). Aiming the cursor at the world meet parks it on ice
# the arm cannot reach until the body arrives, and a reaching-for-nothing blade
# is not on the puck when the puck comes. Held as an offset the blade rides the
# body rigidly, which is the most stable pose there is, and lands exactly on the
# meet as the body gets there. With `from_vel`
# ZERO the body does not move, so `from_pos + gate_offset == gate_point` and
# nothing about the frozen solve changes.
static var gate_offset: Vector3 = Vector3.ZERO
# Does the path bring the puck CLOSER than it is right now? The board-aware
# answer to "is this coming to me", which a dot product against the current
# velocity gets wrong on exactly the play that matters: a rim heading away
# down the far wall is closing on the receiver, it just has a corner to turn
# first. False means the puck is genuinely leaving and there is nothing to set
# up for.
static var gate_closes: bool = false


# Returns gate_in_reach. `reach` is the receiver's comfortable blade extension.
# `from_vel` rides the reach circle down the walk for `ride_s` (see above); ZERO
# reproduces the frozen-body solve exactly.
#
# Each walk step is tested as a SEGMENT, not a sample point: a 20 m/s feed
# crosses metres per step, so a point-sampled walk fine enough to never skip
# through a ~1 m reach circle would cost several times the steps. Segment entry
# is exact at any step size (the ray/circle root gives the sub-step crossing),
# which keeps the walk coarse enough to run per-tick per-receiver. With the body
# riding, the segment is taken in the BODY's frame — its endpoints are the
# puck's offsets from the body at each end of the step, both moving linearly
# within it — so the same quadratic stays exact and `u` maps straight back onto
# the puck's world span.
static func solve_reception_gate(puck_pos: Vector3, puck_vel: Vector3,
		from_pos: Vector3, reach: float,
		horizon_s: float, steps: int,
		from_vel: Vector3 = Vector3.ZERO, ride_s: float = INF) -> bool:
	gate_point = puck_pos
	gate_velocity = puck_vel
	gate_time_s = 0.0
	gate_in_reach = false
	gate_closes = false
	gate_offset = Vector3(puck_pos.x - from_pos.x, 0.0, puck_pos.z - from_pos.z)
	if steps <= 0 or horizon_s <= 0.0:
		return false
	var reach_sq: float = reach * reach
	var dt: float = horizon_s / float(steps)
	var p: Vector3 = puck_pos
	var v: Vector3 = puck_vel
	# Body offset per step, and the running body position down the walk. The ride
	# stops after `ride_s` — past that the body's present velocity is no longer
	# evidence, so it holds where the bound left it.
	var bx: float = from_pos.x
	var bz: float = from_pos.z
	var bstep_x: float = from_vel.x * dt
	var bstep_z: float = from_vel.z * dt
	var ride_steps: int = steps if is_inf(ride_s) else int(ride_s / dt)
	# Already on the blade — the gate is the puck itself.
	var ax: float = p.x - bx
	var az: float = p.z - bz
	var start_sq: float = ax * ax + az * az
	if start_sq <= reach_sq:
		gate_in_reach = true
		gate_closes = true
		return true
	var best_sq: float = INF
	for i: int in steps:
		var stepped: Transform3D = step_puck(p, v, dt)
		var q: Vector3 = stepped.origin
		var qv: Vector3 = stepped.basis.x
		var step_bx: float = bstep_x if i < ride_steps else 0.0
		var step_bz: float = bstep_z if i < ride_steps else 0.0
		# Relative span across this step: puck offset from the body at the step's
		# start and at its end, with the body having moved one step in between.
		var fx: float = p.x - bx
		var fz: float = p.z - bz
		var dx: float = (q.x - step_bx) - p.x
		var dz: float = (q.z - step_bz) - p.z
		# The puck's own world span, which is what `u` is reported against.
		var wx: float = q.x - p.x
		var wz: float = q.z - p.z
		var aa: float = dx * dx + dz * dz
		var u_near: float = 0.0
		if aa > 1e-9:
			var b: float = fx * dx + fz * dz
			var c: float = fx * fx + fz * fz - reach_sq
			var disc: float = b * b - aa * c
			if disc >= 0.0:
				var u: float = (-b - sqrt(disc)) / aa
				if u >= 0.0 and u <= 1.0:
					gate_point = Vector3(p.x + wx * u, 0.0, p.z + wz * u)
					gate_offset = Vector3(fx + dx * u, 0.0, fz + dz * u)
					gate_velocity = v.lerp(qv, u)
					gate_time_s = (float(i) + u) * dt
					gate_in_reach = true
					gate_closes = true
					return true
			# Closest approach on this segment, for the no-entry fallback.
			u_near = clampf(-b / aa, 0.0, 1.0)
		var nx: float = fx + dx * u_near
		var nz: float = fz + dz * u_near
		var n_sq: float = nx * nx + nz * nz
		if n_sq < best_sq:
			best_sq = n_sq
			gate_point = Vector3(p.x + wx * u_near, 0.0, p.z + wz * u_near)
			gate_offset = Vector3(nx, 0.0, nz)
			gate_velocity = v.lerp(qv, u_near)
			gate_time_s = (float(i) + u_near) * dt
		p = q
		v = qv
		bx += step_bx
		bz += step_bz
	gate_closes = best_sq < start_sq
	return false


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
# just the grounded slide. Matches Puck.gd's drive:
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
			Vector3(0.0, -GameRules.GRAVITY_M_S2, 0.0), 0.0, GameRules.PUCK_BOARD_FRICTION,
			GameRules.PUCK_COLLISION_RADIUS)
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


# ── Released-puck landing, closed form ───────────────────────────────────────
# Where a released puck comes to REST, and whether it crossed a goal line on the
# way. The dump eval wants both: it prices its concession (chase_recovery /
# turnover_cost / position_potential) at the spot it AIMS at, which is a place
# the puck passes through at speed rather than one it stops at.
#
# Closed form rather than a stepped walk because the answer is wanted per
# delivery inside the carrier's compete. The walk costs ~1 us per step
# (benchmarks/test_ai_micro_benchmark.gd) and a full runout is ~270 steps — the
# same cost class as the entire controlled_space fan. Between board contacts the
# motion is a straight line under constant deceleration, so each leg is exact
# arithmetic and only the contacts need solving; a release resolves in at most
# _RELEASE_MAX_LEGS of them.
#
# Board geometry mirrors GameRules.clamp_to_rink_inner exactly — straight side
# and end walls plus the four corner ARCS, every extent inset by the puck's own
# radius exactly as the stepped sim's board_margin insets it. The arcs are not
# optional detail here: a rim fired into a corner is the delivery the whole model
# exists to price, and treating the corner as a square would put its contact
# metres away at the wrong incidence. The inset is not optional either: this
# solver's answers are compared against the stepped walk's, and a radius per
# contact compounds down a multi-bounce rim.

# A release stops resolving after this many board contacts, then finishes as a
# straight slide clamped to the surface. The cap is generous because a CORNER
# rim genuinely bounces many times: each contact there is near-tangential, and a
# glancing carom sheds almost nothing (see _bounce_velocity), so a puck can walk
# the whole arc in small steps. A cap of 4 stranded such a puck in the corner
# while the stepped walk carried it out to the far end. Even at this cap a
# release resolves for a fraction of the stepped walk's ~270 steps.
const _RELEASE_MAX_LEGS: int = 12
# Below this the puck is done sliding; further legs are noise.
const _RELEASE_MIN_SPEED_M_S: float = 0.2
# Push the puck this far off a board after a contact before searching for the
# next one. Without it the post-bounce point sits exactly on the boundary and
# the next intersection solves at t ~ 0, burning the leg budget in place.
const _RELEASE_BOARD_EPS_M: float = 0.005


# Distance a puck launched at `speed` slides before ice friction stops it: the
# v^2 / 2a runout. This is the whole reason a hard clear ices — at the
# quick-pass pace it is ~200 m, more than three rink lengths, so the puck does
# not settle anywhere near where it was aimed.
static func puck_runout_m(speed: float) -> float:
	if speed <= 0.0:
		return 0.0
	return speed * speed / (2.0 * GameRules.PUCK_ICE_DECEL_M_S2)


# Inverse of the above: the fastest launch whose runout dies within
# `distance_m`. Fed the distance to the far goal line, this is the icing bound
# on a straight clear — no search, one sqrt.
static func puck_launch_speed_for_runout(distance_m: float) -> float:
	if distance_m <= 0.0:
		return 0.0
	return sqrt(2.0 * GameRules.PUCK_ICE_DECEL_M_S2 * distance_m)


# Distance along `dir` (unit, XZ) from `p` to the first inner-board contact, and
# the inward normal there. Packed into a Vector3 (t, normal_x, normal_z) to stay
# a value type on the compete path; t = INF when the ray leaves no board within
# `max_t`. Mirrors clamp_to_rink_inner's straight-wall + corner-arc geometry.
#
# `margin` insets every extent by the body's own half-extent, exactly as
# clamp_to_rink_inner does: the puck caroms on its EDGE, so its centre stops a
# radius short of the kickplate. The corner CENTRES are invariant under the
# inset (only the arc radius shrinks), which is why the straight-span tests below
# still read CORNER_CENTER_*.
static func _first_board_hit(p: Vector2, dir: Vector2, max_t: float,
		margin: float = 0.0) -> Vector3:
	var half_w: float = GameRules.INNER_HALF_WIDTH - margin
	var half_l: float = GameRules.INNER_HALF_LENGTH - margin
	var corner_r: float = GameRules.INNER_CORNER_RADIUS - margin
	var best_t: float = INF
	var best_n := Vector2.ZERO
	# Straight walls. Each is only a real contact where the crossing point is
	# still on the STRAIGHT span (inside the corner centres) — past that the arc
	# is nearer and owns the contact.
	for sx: float in [-1.0, 1.0]:
		if dir.x * sx <= 0.0:
			continue
		var t: float = (sx * half_w - p.x) / dir.x
		if t >= 0.0 and t < best_t and t <= max_t \
				and absf(p.y + dir.y * t) <= GameRules.CORNER_CENTER_Z:
			best_t = t
			best_n = Vector2(-sx, 0.0)
	for sz: float in [-1.0, 1.0]:
		if dir.y * sz <= 0.0:
			continue
		var t: float = (sz * half_l - p.y) / dir.y
		if t >= 0.0 and t < best_t and t <= max_t \
				and absf(p.x + dir.x * t) <= GameRules.CORNER_CENTER_X:
			best_t = t
			best_n = Vector2(0.0, -sz)
	# Corner arcs: ray vs the circle the arc lies on, taking the FAR root (the
	# puck starts inside the arc, so the outbound crossing is the contact).
	for cx: float in [-1.0, 1.0]:
		for cz: float in [-1.0, 1.0]:
			var c := Vector2(cx * GameRules.CORNER_CENTER_X, cz * GameRules.CORNER_CENTER_Z)
			var m: Vector2 = p - c
			var b: float = m.dot(dir)
			var disc: float = b * b - (m.length_squared() - corner_r * corner_r)
			if disc < 0.0:
				continue
			var t: float = -b + sqrt(disc)
			if t < 0.0 or t >= best_t or t > max_t:
				continue
			# Only the quadrant this arc actually spans is real board.
			var hit: Vector2 = p + dir * t
			if hit.x * cx < GameRules.CORNER_CENTER_X or hit.y * cz < GameRules.CORNER_CENTER_Z:
				continue
			best_t = t
			best_n = (c - hit).normalized()
	return Vector3(best_t, best_n.x, best_n.y)


# Velocity after a board contact, using the same restitution + Coulomb
# tangential bleed as the stepped model (AITrajectory._step) so the closed form
# can never disagree with the walk: the normal component reverses scaled by
# PUCK_BOARD_BOUNCE, and the along-board component sheds in proportion to the
# NORMAL impulse. That proportionality is why bounce COUNT is not a speed
# proxy — a glancing rim keeps nearly all its speed however many times it
# grazes, while one square hit sheds most of it.
static func _bounce_velocity(v: Vector2, inward_normal: Vector2) -> Vector2:
	var vn: float = v.dot(inward_normal)
	if vn >= 0.0:
		return v
	var out: Vector2 = v - (1.0 + GameRules.PUCK_BOARD_BOUNCE) * vn * inward_normal
	var v_tan: Vector2 = out - out.dot(inward_normal) * inward_normal
	var t_speed: float = v_tan.length()
	if t_speed > 1e-6:
		var drop: float = GameRules.PUCK_BOARD_FRICTION \
				* (1.0 + GameRules.PUCK_BOARD_BOUNCE) * absf(vn)
		out += v_tan * (maxf(t_speed - drop, 0.0) / t_speed - 1.0)
	return out


# Where a release comes to rest, and WHEN it reaches a given line.
#
# `hang_s` is airborne time (a chip / saucer): during it the puck carries its
# launch speed with NO ice friction — height is why a flip covers ground a slide
# cannot — and only then begins to run out.
#
# Returns a Transform3D (a value type, so nothing allocates on the compete path
# — the same packing rationale as _step's return):
#   origin   — the settle point
#   basis.x  — (crossed, time_to_cross_s, total_time_s)
#
# `ice_line_z` / `ice_line_dir` (+1 = the line sits at greater z) name a line to
# time the crossing of; pass dir = 0.0 to skip it. TIME is the point of this,
# not the bare fact of crossing: hybrid icing is a RACE judged at the moment the
# puck crosses the goal line (GameStateMachine.check_icing_for_loose_puck —
# each team's closest body to the end-zone dot, ties to the defence). A puck
# that takes long enough to get there is one the forecheck wins, and a won race
# is not an infraction at all, it is a dump-in with pressure arriving. So what
# the dump eval needs is the clock, and a delivery earns its legality by taking
# a longer PATH rather than by being weaker.
static func puck_release_landing(origin: Vector3, vel: Vector3, hang_s: float,
		ice_line_z: float = 0.0, ice_line_dir: float = 0.0) -> Transform3D:
	var p := Vector2(origin.x, origin.z)
	var v := Vector2(vel.x, vel.z)
	var cross_t: float = INF
	var elapsed: float = 0.0
	# Airborne leg: straight and frictionless, boards ignored (the puck is above
	# the kickplate and the glass is not modelled as a carom surface here).
	if hang_s > 0.0 and v.length() > _RELEASE_MIN_SPEED_M_S:
		var air_end: Vector2 = p + v * hang_s
		if ice_line_dir != 0.0:
			var f: float = _segment_line_fraction(p, air_end, ice_line_z, ice_line_dir)
			if f >= 0.0:
				cross_t = elapsed + hang_s * f
		# Landed a hair INSIDE the boundary the leg loop searches, for the same
		# reason the bounce below pushes off the board — and here it is not an
		# efficiency guard but a correctness one. clamp_to_rink_inner returns a
		# Vector2, whose float32 components round the exact boundary to EITHER
		# side; land a rounding-width outside it and every straight-wall solve in
		# _first_board_hit yields a negative t while every corner root falls
		# behind the origin, so the search reports NO BOARD AT ALL and the puck
		# slides its whole runout — ~200 m at pass pace — clean through the wall.
		p = GameRules.clamp_to_rink_inner(air_end,
				GameRules.PUCK_COLLISION_RADIUS + _RELEASE_BOARD_EPS_M)
		elapsed += hang_s
	for _leg: int in _RELEASE_MAX_LEGS:
		var speed: float = v.length()
		if speed <= _RELEASE_MIN_SPEED_M_S:
			break
		var dir: Vector2 = v / speed
		var runout: float = puck_runout_m(speed)
		var hit: Vector3 = _first_board_hit(p, dir, runout,
				GameRules.PUCK_COLLISION_RADIUS)
		var leg_len: float = runout if is_inf(hit.x) else hit.x
		var leg_end: Vector2 = p + dir * leg_len
		# Time to slide leg_len under constant decel: the root of
		# leg_len = v*t - a*t^2/2 . A full runout leg simply takes v/a.
		var leg_t: float = _slide_time(speed, leg_len)
		if ice_line_dir != 0.0 and is_inf(cross_t):
			var f: float = _segment_line_fraction(p, leg_end, ice_line_z, ice_line_dir)
			if f >= 0.0:
				cross_t = elapsed + _slide_time(speed, leg_len * f)
		p = leg_end
		elapsed += leg_t
		if is_inf(hit.x):
			v = Vector2.ZERO
			break
		# Speed surviving the slide to the board, then the contact itself.
		var at_board: float = sqrt(maxf(
				speed * speed - 2.0 * GameRules.PUCK_ICE_DECEL_M_S2 * leg_len, 0.0))
		var inward := Vector2(hit.y, hit.z)
		v = _bounce_velocity(dir * at_board, inward)
		p += inward * _RELEASE_BOARD_EPS_M
	# Legs exhausted with the puck still alive (a corner walker): finish it as a
	# straight slide clamped to the surface rather than stranding it at the last
	# contact, which would report a puck still doing several m/s as settled.
	var tail_speed: float = v.length()
	if tail_speed > _RELEASE_MIN_SPEED_M_S:
		var tail: Vector2 = p + v / tail_speed * puck_runout_m(tail_speed)
		if ice_line_dir != 0.0 and is_inf(cross_t):
			var f: float = _segment_line_fraction(p, tail, ice_line_z, ice_line_dir)
			if f >= 0.0:
				cross_t = elapsed + _slide_time(tail_speed, p.distance_to(tail) * f)
		elapsed += tail_speed / GameRules.PUCK_ICE_DECEL_M_S2
		p = GameRules.clamp_to_rink_inner(tail, GameRules.PUCK_COLLISION_RADIUS)
	return Transform3D(
			Basis(Vector3(0.0 if is_inf(cross_t) else 1.0,
					0.0 if is_inf(cross_t) else cross_t, elapsed),
					Vector3.ZERO, Vector3.ZERO),
			Vector3(p.x, 0.0, p.y))


# Time to slide `dist` starting at `speed` under the ice decel — the root of
# dist = speed*t - a*t^2/2. Clamped at the stopping time, so asking for the
# whole runout (or beyond) returns speed/a rather than a NaN off a negative
# discriminant.
static func _slide_time(speed: float, dist: float) -> float:
	var a: float = GameRules.PUCK_ICE_DECEL_M_S2
	var stop_t: float = speed / a
	if dist <= 0.0:
		return 0.0
	var disc: float = speed * speed - 2.0 * a * dist
	if disc <= 0.0:
		return stop_t
	return minf((speed - sqrt(disc)) / a, stop_t)


# Fraction along segment a->b at which it first reaches `line_z` on the `dir`
# side, or -1.0 if it never does. 0.0 when `a` is already past the line.
static func _segment_line_fraction(a: Vector2, b: Vector2,
		line_z: float, dir: float) -> float:
	var a_past: float = a.y * dir - line_z * dir
	var b_past: float = b.y * dir - line_z * dir
	if a_past >= 0.0:
		return 0.0
	if b_past < 0.0:
		return -1.0
	return a_past / (a_past - b_past)


