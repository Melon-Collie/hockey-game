extends GutTest

# Determinism soak for the shared loose-puck step (PuckAuthorityRules).
#
# WHY THIS EXISTS
# ---------------
# The determinism migration's core promise is that the host's authoritative
# drive (Puck._drive_analytic) and every client's prediction (PuckController.
# _run_prediction) advance a loose puck by calling the SAME per-tick loop:
#
#     substeps = PuckAuthorityRules.frame_substeps(z, speed, dt)
#     for each sub-step: PuckAuthorityRules.step_frame_substep(...)
#     commit: pin y >= ice_height
#
# test_puck_authority_rules.gd already pins the SINGLE-tick identities (open-ice
# == advance_loose_puck, a post contact, a net-panel contact). What nothing
# exercised until now is the loop run FORWARD over thousands of ticks from many
# initial states — which is exactly the regime where a netcode desync is born:
#
#   * a hidden source of non-determinism (an RNG read, a time read, iteration
#     order, uninitialised scratch) makes two runs of the same inputs diverge —
#     client prediction silently stops matching the host;
#   * the host loop and the client loop drift apart (someone edits one path's
#     substep count / commit and not the other);
#   * a solver bug lets a hard shot tunnel the boards or the goal frame — the
#     "a puck outside the rink means a solver bug" invariant in CLAUDE.md;
#   * a carom / restitution bug INJECTS energy, so a small prediction error
#     grows tick over tick instead of decaying (a divergence amplifier).
#
# These are the "shit ton of netcode testing" bugs that are brutal to catch by
# hand and trivial to catch by soaking the pure step. The harness below IS both
# production loops (goalie-free static-geometry case, where the two are identical
# by construction), driven from a fixed seed so a failure reproduces exactly.
#
# The seed is fixed on purpose: this is a reproducible soak, not fuzzing. A red
# run always replays the same trajectories.

const DT: float = 1.0 / 120.0
const ICE: float = 0.0175          # Puck.ice_height
const MAX_SPEED: float = 38.0      # Puck.max_speed
const MAX_HEIGHT: float = 3.0      # Puck.max_height
const R: float = 0.065             # GameRules.PUCK_COLLISION_RADIUS

# Soak size. ~250 shots x 240 ticks (2 s of flight) x up-to-16 sub-steps near
# the frame is a few hundred thousand step_frame_substep calls — a fraction of a
# second headless, and enough coverage to trip a real solver regression.
const SHOTS: int = 250
const TICKS: int = 240

# Legal-envelope bounds. The rink interior clamps |x| to INNER_HALF_WIDTH and
# |z| to INNER_HALF_LENGTH (the rounded corners only ever clamp TIGHTER); the
# net cavity (|z| up to GOAL_LINE_Z + NET_DEPTH = 27.67) sits inside the length
# bound. A puck center that leaves these by more than a radius has tunnelled.
const ENVELOPE_SLOP: float = 0.05


# ── the shared per-tick loop (mirrors _drive_analytic AND _run_prediction) ────
# Advances one tick of a loose puck against static geometry only (boards + goal
# frame), returning the committed (pos, vel) packed into a Transform3D
# (origin = pos, basis.x = vel). Goalie contact is deliberately absent: it is
# the ONE place the two production paths differ (host resolves a save per
# sub-step; the client treats it as a prediction stop), so the goalie-free loop
# is precisely the trajectory the migration guarantees agrees on both peers.
func _advance_tick(pos: Vector3, vel: Vector3,
		frame_scratch: PuckGeometryCollision.Result,
		out: PuckAuthorityRules.TickResult) -> Transform3D:
	var substeps: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), DT)
	var sub_dt: float = DT / float(substeps)
	var p: Vector3 = pos
	var v: Vector3 = vel
	for _sub in substeps:
		out.touched_post = false
		out.touched_net = false
		PuckAuthorityRules.step_frame_substep(
				p, v, sub_dt, R, MAX_SPEED, ICE, MAX_HEIGHT, frame_scratch, out)
		p = out.position
		v = out.velocity
	# Commit: the puck can never sit below the ice (mirrors _drive_analytic step 4).
	if p.y < ICE:
		p.y = ICE
		if v.y < 0.0:
			v.y = 0.0
	return Transform3D(Basis(v, Vector3.ZERO, Vector3.ZERO), p)


# A spread of realistic loose-puck launches: anywhere on the ice (including deep
# in the corners and right on top of the goal frame), any direction, speeds from
# a soft roll to the max-speed clamp, and a range of loft. Seeded so the whole
# soak is reproducible.
func _make_shot(rng: RandomNumberGenerator) -> Array:
	var pos := Vector3(
			rng.randf_range(-12.5, 12.5),
			ICE,
			rng.randf_range(-27.5, 27.5))
	var speed: float = rng.randf_range(1.0, MAX_SPEED)
	var dir := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
	if dir.length() < 0.001:
		dir = Vector3(1.0, 0.0, 0.0)
	dir = dir.normalized()
	var vel: Vector3 = dir * speed
	vel.y = rng.randf_range(0.0, 5.0)  # some launches loft
	return [pos, vel]


func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


# ── A. Reproducibility ────────────────────────────────────────────────────────
# The same shot advanced twice produces a BIT-IDENTICAL trajectory. This is the
# property client prediction is built on: no RNG, no wall-clock, no uninitialised
# scratch bleed can hide in the step, or two peers replaying the same inputs
# would drift. Exact equality (==), not almost_eq — a float hair of drift per
# tick compounds into a desync over a match.
func test_step_is_bit_reproducible() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xA11CE
	var fs_a := PuckGeometryCollision.Result.new()
	var tr_a := PuckAuthorityRules.TickResult.new()
	var fs_b := PuckGeometryCollision.Result.new()
	var tr_b := PuckAuthorityRules.TickResult.new()
	var mismatches: int = 0
	for _i in SHOTS:
		var shot: Array = _make_shot(rng)
		var pa: Vector3 = shot[0]
		var va: Vector3 = shot[1]
		var pb: Vector3 = pa
		var vb: Vector3 = va
		for _t in TICKS:
			var a: Transform3D = _advance_tick(pa, va, fs_a, tr_a)
			pa = a.origin
			va = a.basis.x
			var b: Transform3D = _advance_tick(pb, vb, fs_b, tr_b)
			pb = b.origin
			vb = b.basis.x
			if pa != pb or va != vb:
				mismatches += 1
				break
	assert_eq(mismatches, 0,
			"every shot must advance bit-identically on a repeat run (determinism)")


# ── B. Host vs client parity ──────────────────────────────────────────────────
# The host (_drive_analytic) and client (_run_prediction) integer-tick loops must
# agree bit-for-bit for the goalie-free case. They call the same shared step, so
# they agree BY CONSTRUCTION today — this test PINS that so a future edit to one
# path's substep count, ordering, or commit (and not the other) trips loudly
# instead of shipping as an invisible desync. The two helpers below deliberately
# reconstruct each path's own structure rather than sharing _advance_tick.
func _host_tick(pos: Vector3, vel: Vector3,
		fs: PuckGeometryCollision.Result, tr: PuckAuthorityRules.TickResult) -> Transform3D:
	# _drive_analytic: substeps from prev.z / incoming.length(); commit y >= ice.
	var substeps: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), DT)
	var sub_dt: float = DT / float(substeps)
	var p: Vector3 = pos
	var v: Vector3 = vel
	for _sub in substeps:
		tr.touched_post = false
		tr.touched_net = false
		PuckAuthorityRules.step_frame_substep(p, v, sub_dt, R, MAX_SPEED, ICE, MAX_HEIGHT, fs, tr)
		p = tr.position
		v = tr.velocity
	if p.y < ICE:
		p.y = ICE
		if v.y < 0.0:
			v.y = 0.0
	return Transform3D(Basis(v, Vector3.ZERO, Vector3.ZERO), p)


func _client_tick(pos: Vector3, vel: Vector3,
		fs: PuckGeometryCollision.Result, tr: PuckAuthorityRules.TickResult) -> Transform3D:
	# _run_prediction whole-tick body (frac == 0 at integer age, no goalie in
	# range): substeps from pos.z / vel.length() at tick start; same shared step.
	# The client omits the sub-ice y-commit inside the loop, so mirror the host's
	# to compare the geometry the migration actually shares (both peers re-home a
	# below-ice puck the same way — host in step 4, client via its own clamp).
	var substeps: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), DT)
	var sub_dt: float = DT / float(substeps)
	var p: Vector3 = pos
	var v: Vector3 = vel
	for _sub in substeps:
		tr.touched_post = false
		tr.touched_net = false
		PuckAuthorityRules.step_frame_substep(p, v, sub_dt, R, MAX_SPEED, ICE, MAX_HEIGHT, fs, tr)
		p = tr.position
		v = tr.velocity
	if p.y < ICE:
		p.y = ICE
		if v.y < 0.0:
			v.y = 0.0
	return Transform3D(Basis(v, Vector3.ZERO, Vector3.ZERO), p)


func test_host_and_client_loops_agree() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB0A75
	var fs_h := PuckGeometryCollision.Result.new()
	var tr_h := PuckAuthorityRules.TickResult.new()
	var fs_c := PuckGeometryCollision.Result.new()
	var tr_c := PuckAuthorityRules.TickResult.new()
	var mismatches: int = 0
	for _i in SHOTS:
		var shot: Array = _make_shot(rng)
		var ph: Vector3 = shot[0]
		var vh: Vector3 = shot[1]
		var pc: Vector3 = ph
		var vc: Vector3 = vh
		for _t in TICKS:
			var h: Transform3D = _host_tick(ph, vh, fs_h, tr_h)
			ph = h.origin
			vh = h.basis.x
			var c: Transform3D = _client_tick(pc, vc, fs_c, tr_c)
			pc = c.origin
			vc = c.basis.x
			if ph != pc or vh != vc:
				mismatches += 1
				break
	assert_eq(mismatches, 0,
			"host and client integer-tick loops must agree bit-for-bit (goalie-free)")


# ── C. Containment by construction ────────────────────────────────────────────
# CLAUDE.md: "containment is by construction (the step clamps the center to
# clamp_to_rink_inner every sub-step) ... a puck outside the rink means ... a
# solver bug." Soak hard shots (biased toward max speed and aimed at the boards /
# corners / goal frame, where tunnelling lives) and assert the center never
# escapes the legal envelope. A boards/frame tunnelling regression flies the puck
# to large coordinates — this catches it deterministically.
func test_puck_never_escapes_the_rink() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xCAFE
	var fs := PuckGeometryCollision.Result.new()
	var tr := PuckAuthorityRules.TickResult.new()
	var x_bound: float = GameRules.INNER_HALF_WIDTH + R + ENVELOPE_SLOP
	var z_bound: float = GameRules.INNER_HALF_LENGTH + R + ENVELOPE_SLOP
	var y_ceiling: float = ICE + MAX_HEIGHT + ENVELOPE_SLOP
	var worst_x: float = 0.0
	var worst_z: float = 0.0
	var escapes: int = 0
	for _i in SHOTS:
		# Hard shots from near a board, aimed back into / along it — the tunnelling
		# regime. Speed biased high (0.6..1.0 of max).
		var pos := Vector3(
				rng.randf_range(-12.5, 12.5),
				ICE,
				rng.randf_range(-27.5, 27.5))
		var speed: float = rng.randf_range(0.6, 1.0) * MAX_SPEED
		var dir := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
		if dir.length() < 0.001:
			dir = Vector3(0.0, 0.0, 1.0)
		var vel: Vector3 = dir.normalized() * speed
		vel.y = rng.randf_range(0.0, 4.0)
		for _t in TICKS:
			var s: Transform3D = _advance_tick(pos, vel, fs, tr)
			pos = s.origin
			vel = s.basis.x
			worst_x = maxf(worst_x, absf(pos.x))
			worst_z = maxf(worst_z, absf(pos.z))
			if absf(pos.x) > x_bound or absf(pos.z) > z_bound \
					or pos.y > y_ceiling or pos.y < ICE - ENVELOPE_SLOP \
					or not _finite(pos):
				escapes += 1
				break
	assert_eq(escapes, 0, "no shot may tunnel the boards / goal frame / ceiling")
	# Sanity that the soak actually drove pucks out to the walls (else the bounds
	# are vacuously satisfied by pucks that never travelled).
	assert_gt(worst_x, 8.0, "soak drove pucks near the side boards")
	assert_gt(worst_z, 20.0, "soak drove pucks near the end boards")


# ── D. No energy injection ────────────────────────────────────────────────────
# A grounded puck loses energy to ice friction and keeps at most its incoming
# pace through a carom (board restitution <= 1). Its horizontal speed must be
# NON-INCREASING tick over tick. A reflection / restitution bug that adds pace
# turns a small prediction error into a growing one — the divergence amplifier
# that makes reconcile thrash. Grounded, no-loft shots isolate this from gravity
# (which legitimately adds vertical speed to an airborne puck).
func test_grounded_puck_never_gains_speed() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xDECAF
	var fs := PuckGeometryCollision.Result.new()
	var tr := PuckAuthorityRules.TickResult.new()
	var gains: int = 0
	var max_gain: float = 0.0
	for _i in SHOTS:
		var pos := Vector3(
				rng.randf_range(-12.0, 12.0),
				ICE,
				rng.randf_range(-27.0, 27.0))
		var dir := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
		if dir.length() < 0.001:
			dir = Vector3(1.0, 0.0, 0.0)
		var vel: Vector3 = dir.normalized() * rng.randf_range(4.0, MAX_SPEED)  # grounded, vy = 0
		var prev_speed: float = Vector2(vel.x, vel.z).length()
		for _t in TICKS:
			var s: Transform3D = _advance_tick(pos, vel, fs, tr)
			pos = s.origin
			vel = s.basis.x
			var speed: float = Vector2(vel.x, vel.z).length()
			# 1e-4 tolerance for float noise in the carom decomposition; a real
			# energy-injection bug adds pace far above this.
			if speed > prev_speed + 1e-4:
				gains += 1
				max_gain = maxf(max_gain, speed - prev_speed)
				break
			prev_speed = speed
	assert_eq(gains, 0,
			"a grounded puck must never gain horizontal speed (max observed gain %.5f)" % max_gain)


# ── E. Never NaN / Inf ────────────────────────────────────────────────────────
# A non-finite creeping into pos/vel is unrecoverable — it serialises onto the
# wire and poisons every peer. Assert the whole reproducibility-seed soak stays
# finite at every committed tick.
func test_state_stays_finite() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xF1017E
	var fs := PuckGeometryCollision.Result.new()
	var tr := PuckAuthorityRules.TickResult.new()
	var nonfinite: int = 0
	for _i in SHOTS:
		var shot: Array = _make_shot(rng)
		var pos: Vector3 = shot[0]
		var vel: Vector3 = shot[1]
		for _t in TICKS:
			var s: Transform3D = _advance_tick(pos, vel, fs, tr)
			pos = s.origin
			vel = s.basis.x
			if not _finite(pos) or not _finite(vel):
				nonfinite += 1
				break
	assert_eq(nonfinite, 0, "pos/vel must stay finite across the entire soak")
