extends GutTest

# RagdollRules — the verlet solver behind the body-check knockdown pose, plus the
# math that maps its particles back onto the procedural rig.
#
# Two things are worth pinning here. First, the SOLVER INVARIANTS: segments must
# not stretch, the body must settle on the ice rather than sink through it or
# jitter forever, and the fall must scale with the hit rather than replaying one
# canned crumple. Second, the RIG MAPPING must exactly invert the euler rotations
# Godot applies to the rig — a sign error there is invisible in the numbers and
# obvious (and unshippable) on screen, so the round-trip is asserted directly
# against Basis.from_euler rather than against hand-computed angles.

var _cfg: RagdollRules.Config

const DT: float = 1.0 / 120.0

func before_each() -> void:
	_cfg = RagdollRules.Config.new()


func _fresh(strength: float = 1.0, vel: Vector3 = Vector3.ZERO,
		hit_dir: Vector3 = Vector3.BACK) -> RagdollRules.Body:
	var body := RagdollRules.Body.new()
	RagdollRules.seed_body(body, _cfg, Vector3.FORWARD, vel, hit_dir, strength)
	return body


func _run(body: RagdollRules.Body, seconds: float) -> void:
	RagdollRules.advance(body, _cfg, seconds, DT)


func _seg_len(body: RagdollRules.Body, a: int, b: int) -> float:
	return (body.pos[a] - body.pos[b]).length()


# ── Seeding ───────────────────────────────────────────────────────────────────

func test_seed_builds_a_standing_skeleton() -> void:
	var body := _fresh(0.0)
	assert_true(body.active, "seeding activates the body")
	assert_almost_eq(body.pos[RagdollRules.PELVIS].y, _cfg.stand_pelvis_y, 0.0001,
			"pelvis starts at the neutral standing height")
	assert_almost_eq(_seg_len(body, RagdollRules.CHEST, RagdollRules.PELVIS),
			_cfg.spine_len, 0.0001, "spine is at rest length")
	assert_almost_eq(_seg_len(body, RagdollRules.HEAD, RagdollRules.CHEST),
			_cfg.neck_len, 0.0001, "neck is at rest length")
	assert_almost_eq(_seg_len(body, RagdollRules.KNEE_L, RagdollRules.SKATE_L),
			_cfg.shin_len, 0.0001, "shin is at rest length")
	assert_almost_eq(body.pos[RagdollRules.SKATE_L].y,
			RagdollRules.neutral_skate_height(_cfg), 0.0001,
			"skates start at their neutral rig height (the boot centre, blade on the ice)")

func test_unhit_seed_is_a_true_rest_state() -> void:
	# A zero-strength seed must not sag: the skate contact plane is derived from
	# the same lengths that build the standing pose, so the chain is already in
	# equilibrium and gravity has nothing to close.
	var body := _fresh(0.0)
	var pelvis_y: float = body.pos[RagdollRules.PELVIS].y
	_run(body, 1.0)
	assert_almost_eq(body.pos[RagdollRules.PELVIS].y, pelvis_y, 0.02,
			"an unhit ragdoll stands still instead of collapsing")

func test_seed_launches_the_trunk_harder_than_the_legs() -> void:
	# The asymmetry between trunk and skate kick IS the tumble: without it a hit
	# would translate the whole body and never rotate it over the feet.
	var body := _fresh(1.0, Vector3.ZERO, Vector3.BACK)
	var trunk_v: Vector3 = body.pos[RagdollRules.CHEST] - body.prev[RagdollRules.CHEST]
	var skate_v: Vector3 = body.pos[RagdollRules.SKATE_L] - body.prev[RagdollRules.SKATE_L]
	assert_gt(trunk_v.z, skate_v.z, "the trunk is shoved harder than the skates")
	assert_almost_eq(skate_v.z / trunk_v.z, _cfg.leg_drag_frac, 0.0001,
			"the skates receive exactly leg_drag_frac of the trunk kick")

func test_seed_inherits_the_victims_own_momentum() -> void:
	var moving := _fresh(0.5, Vector3(4.0, 0.0, 0.0), Vector3.BACK)
	var still := _fresh(0.5, Vector3.ZERO, Vector3.BACK)
	var moving_v: Vector3 = (moving.pos[RagdollRules.CHEST] - moving.prev[RagdollRules.CHEST]) / DT
	var still_v: Vector3 = (still.pos[RagdollRules.CHEST] - still.prev[RagdollRules.CHEST]) / DT
	assert_almost_eq(moving_v.x - still_v.x, 4.0, 0.001,
			"a skater blown up while flying carries that momentum into the fall")

func test_zero_strength_hit_barely_disturbs_the_pose() -> void:
	var body := _fresh(0.0)
	for i: int in RagdollRules.PARTICLE_COUNT:
		assert_almost_eq((body.pos[i] - body.prev[i]).length(), 0.0, 0.0001,
				"a zero-strength seed imparts no velocity")


# ── Solver invariants ─────────────────────────────────────────────────────────

func test_segments_do_not_stretch_through_a_hard_fall() -> void:
	var body := _fresh(1.0, Vector3(6.0, 0.0, 0.0))
	_run(body, 1.5)
	# 6 relaxation iterations should hold the hard constraints to well under a
	# centimetre even after a full-strength tumble.
	assert_almost_eq(_seg_len(body, RagdollRules.CHEST, RagdollRules.PELVIS),
			_cfg.spine_len, 0.01, "spine holds its length")
	assert_almost_eq(_seg_len(body, RagdollRules.HEAD, RagdollRules.CHEST),
			_cfg.neck_len, 0.01, "neck holds its length")
	assert_almost_eq(_seg_len(body, RagdollRules.KNEE_L, RagdollRules.SKATE_L),
			_cfg.shin_len, 0.01, "left shin holds its length")
	assert_almost_eq(_seg_len(body, RagdollRules.KNEE_R, RagdollRules.SKATE_R),
			_cfg.shin_len, 0.01, "right shin holds its length")

func test_body_settles_on_the_ice_and_stays_there() -> void:
	var body := _fresh(1.0)
	_run(body, 3.0)
	for i: int in RagdollRules.PARTICLE_COUNT:
		assert_gt(body.pos[i].y, _cfg.particle_radius - 0.001,
				"particle %d never sinks through the ice" % i)
	assert_lt(body.pos[RagdollRules.PELVIS].y, _cfg.stand_pelvis_y * 0.6,
			"a full-strength knockdown ends up down, not standing")

func test_body_comes_to_rest() -> void:
	var body := _fresh(1.0)
	_run(body, 4.0)
	var speed: float = 0.0
	for i: int in RagdollRules.PARTICLE_COUNT:
		speed = maxf(speed, (body.pos[i] - body.prev[i]).length() / DT)
	assert_lt(speed, 0.5, "friction and damping bring the ragdoll to rest, no jitter")

func test_harder_hits_travel_further() -> void:
	# The whole point of seeding from the impulse: the fall must be a function of
	# the hit, not of a timer.
	var soft := _fresh(0.25)
	var hard := _fresh(1.0)
	_run(soft, 1.0)
	_run(hard, 1.0)
	var soft_d: float = absf(soft.pos[RagdollRules.CHEST].z)
	var hard_d: float = absf(hard.pos[RagdollRules.CHEST].z)
	assert_gt(hard_d, soft_d * 1.5,
			"a full-strength check throws the body markedly further than a glancing one")

func test_fall_direction_follows_the_hit() -> void:
	var pushed_back := _fresh(1.0, Vector3.ZERO, Vector3.BACK)
	var pushed_right := _fresh(1.0, Vector3.ZERO, Vector3.RIGHT)
	_run(pushed_back, 0.6)
	_run(pushed_right, 0.6)
	assert_gt(pushed_back.pos[RagdollRules.CHEST].z, 0.3,
			"a hit along +Z carries the chest along +Z")
	assert_gt(pushed_right.pos[RagdollRules.CHEST].x, 0.3,
			"a hit along +X carries the chest along +X")
	assert_almost_eq(pushed_right.pos[RagdollRules.CHEST].z, 0.0, 0.25,
			"and does not throw it sideways along the unhit axis")


# ── Determinism ───────────────────────────────────────────────────────────────

func test_identical_seeds_produce_identical_falls() -> void:
	# The property every peer and every goal replay depends on.
	var a := _fresh(0.8, Vector3(3.0, 0.0, -2.0), Vector3.BACK)
	var b := _fresh(0.8, Vector3(3.0, 0.0, -2.0), Vector3.BACK)
	_run(a, 1.2)
	_run(b, 1.2)
	for i: int in RagdollRules.PARTICLE_COUNT:
		assert_eq(a.pos[i], b.pos[i], "particle %d matches bit-for-bit" % i)

func test_catch_up_matches_continuous_simulation() -> void:
	# A peer that observes the knockdown late fast-forwards to the state everyone
	# else is already in. Same dt, same step count, so it must land identically.
	var live := _fresh(0.9, Vector3.ZERO, Vector3.BACK)
	var late := _fresh(0.9, Vector3.ZERO, Vector3.BACK)
	for _i: int in 60:
		RagdollRules.step(live, _cfg, DT)
	RagdollRules.advance(late, _cfg, 60.0 * DT, DT)
	for i: int in RagdollRules.PARTICLE_COUNT:
		assert_eq(live.pos[i], late.pos[i], "particle %d matches after catch-up" % i)

func test_advance_is_bounded_against_a_pathological_span() -> void:
	var body := _fresh(1.0)
	# Must return rather than spinning the solver for an unbounded step count.
	RagdollRules.advance(body, _cfg, 1000.0, DT)
	assert_true(is_finite(body.pos[RagdollRules.PELVIS].y),
			"a pathological catch-up span stays finite and bounded")

func test_inactive_body_does_not_integrate() -> void:
	var body := RagdollRules.Body.new()
	body.pos[RagdollRules.PELVIS] = Vector3(0.0, 1.0, 0.0)
	body.prev[RagdollRules.PELVIS] = Vector3(0.0, 1.0, 0.0)
	RagdollRules.step(body, _cfg, DT)
	assert_eq(body.pos[RagdollRules.PELVIS], Vector3(0.0, 1.0, 0.0),
			"an unseeded body is inert — gravity does not pull it")


# ── Rig mapping ───────────────────────────────────────────────────────────────

func test_upright_pose_maps_to_a_neutral_rig() -> void:
	var body := _fresh(0.0)
	var lean: Vector2 = RagdollRules.torso_lean(body, Basis.IDENTITY)
	assert_almost_eq(lean.x, 0.0, 0.0001, "an upright spine has no pitch")
	assert_almost_eq(lean.y, 0.0, 0.0001, "an upright spine has no roll")
	var left: Vector3 = RagdollRules.leg_angles(body, Basis.IDENTITY, true)
	assert_almost_eq(left.z, 0.0, 0.0001, "a straight leg has no knee flex")
	assert_almost_eq(RagdollRules.body_drop(body, _cfg), 0.0, 0.0001,
			"a standing pelvis has no drop")

func test_torso_lean_signs_match_the_rig_convention() -> void:
	# SkaterPoseCoordinator's convention: negative rotation.x pitches the torso
	# top toward local -Z (forward), negative rotation.z rolls it toward +X.
	var body := _fresh(0.0)
	var pelvis: Vector3 = body.pos[RagdollRules.PELVIS]
	# Chest displaced forward (-Z) → the torso is pitched forward → negative x.
	body.pos[RagdollRules.CHEST] = pelvis + Vector3(0.0, 0.4, -0.2)
	assert_lt(RagdollRules.torso_lean(body, Basis.IDENTITY).x, 0.0,
			"a chest fallen forward reads as negative pitch")
	# Chest displaced to +X → rolled toward +X → negative z.
	body.pos[RagdollRules.CHEST] = pelvis + Vector3(0.2, 0.4, 0.0)
	assert_lt(RagdollRules.torso_lean(body, Basis.IDENTITY).y, 0.0,
			"a chest fallen to the right reads as negative roll")

func test_leg_angles_invert_the_rigs_euler_rotation() -> void:
	# The mapping must be the exact inverse of what Skater.set_leg_swing applies:
	# leg rotation = (pitch, 0, roll) in YXZ order about a -Y rest direction. Build
	# a known thigh direction with Basis.from_euler, read it back, and require the
	# solved angles to reproduce it. This is the assertion a sign flip fails.
	for probe: Vector2 in [Vector2(0.4, 0.0), Vector2(0.0, 0.3),
			Vector2(-0.5, 0.25), Vector2(0.7, -0.35)]:
		var body := _fresh(0.0)
		var basis := Basis.from_euler(Vector3(probe.x, 0.0, probe.y))
		var thigh_dir: Vector3 = basis * Vector3.DOWN
		var pelvis: Vector3 = body.pos[RagdollRules.PELVIS]
		body.pos[RagdollRules.KNEE_L] = pelvis + thigh_dir * _cfg.thigh_len
		# Keep the shin colinear so the knee reads zero and only the leg angles matter.
		body.pos[RagdollRules.SKATE_L] = body.pos[RagdollRules.KNEE_L] + thigh_dir * _cfg.shin_len
		var solved: Vector3 = RagdollRules.leg_angles(body, Basis.IDENTITY, true)
		var rebuilt: Vector3 = Basis.from_euler(Vector3(solved.x, 0.0, solved.y)) * Vector3.DOWN
		assert_almost_eq(rebuilt.x, thigh_dir.x, 0.001,
				"thigh x reproduced for probe %s" % probe)
		assert_almost_eq(rebuilt.y, thigh_dir.y, 0.001,
				"thigh y reproduced for probe %s" % probe)
		assert_almost_eq(rebuilt.z, thigh_dir.z, 0.001,
				"thigh z reproduced for probe %s" % probe)
		assert_almost_eq(solved.z, 0.0, 0.001,
				"a colinear shin reads as zero knee flex for probe %s" % probe)

func test_knee_flex_is_signed_about_the_legs_own_axis() -> void:
	var body := _fresh(0.0)
	var knee: Vector3 = body.pos[RagdollRules.KNEE_L]
	# Skate swung behind the knee (+Z) → the heel comes up, a positive flex in
	# the same sense the gait's knee bend uses.
	body.pos[RagdollRules.SKATE_L] = knee + Vector3(0.0, -0.3, 0.2)
	var back: Vector3 = RagdollRules.leg_angles(body, Basis.IDENTITY, true)
	body.pos[RagdollRules.SKATE_L] = knee + Vector3(0.0, -0.3, -0.2)
	var fwd: Vector3 = RagdollRules.leg_angles(body, Basis.IDENTITY, true)
	assert_ne(signf(back.z), signf(fwd.z),
			"flexing the shin fore vs aft flips the sign of the knee angle")

func test_mapping_is_expressed_in_the_skaters_local_frame() -> void:
	# The rig setters take local euler angles, so a rotated skater must produce
	# the same numbers for the same body-relative pose.
	var body := _fresh(0.0)
	var pelvis: Vector3 = body.pos[RagdollRules.PELVIS]
	var yaw := Basis(Vector3.UP, PI * 0.5)
	# A chest leaning along the ROTATED body's forward axis.
	body.pos[RagdollRules.CHEST] = pelvis + yaw * Vector3(0.0, 0.4, -0.2)
	var lean: Vector2 = RagdollRules.torso_lean(body, yaw)
	assert_lt(lean.x, 0.0, "still reads as a forward pitch in the rotated frame")
	assert_almost_eq(lean.y, 0.0, 0.001, "and carries no spurious roll")

func test_body_drop_tracks_the_pelvis_sinking() -> void:
	var body := _fresh(1.0)
	_run(body, 1.5)
	var drop: float = RagdollRules.body_drop(body, _cfg)
	assert_gt(drop, 0.3, "a knocked-down body has visibly dropped")
	assert_lte(drop, _cfg.stand_pelvis_y,
			"drop never exceeds the standing height (never reads below the ice)")

func test_body_drop_is_never_negative() -> void:
	var body := _fresh(0.0)
	body.pos[RagdollRules.PELVIS] = Vector3(0.0, _cfg.stand_pelvis_y + 0.5, 0.0)
	assert_almost_eq(RagdollRules.body_drop(body, _cfg), 0.0, 0.0001,
			"a pelvis above standing height clamps to zero rather than lifting the rig")
