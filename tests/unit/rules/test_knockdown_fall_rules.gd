extends GutTest

# KnockdownFallRules — the tipping-body knockdown fall. These tests pin the
# model's physical shape: the buckle delay, monotonic acceleration to the ice,
# restitution bounces that never pierce the settle plane, the shove-speed
# seeding, and the closed-form determinism the replay/reconcile paths rely on.

var _cfg: KnockdownFallRules.Config

func before_each() -> void:
	_cfg = KnockdownFallRules.Config.new()
	_cfg.buckle_seconds = 0.1
	_cfg.fall_accel = 6.0
	_cfg.settle_angle = 1.466
	_cfg.restitution = 0.3
	_cfg.rest_omega = 0.7
	_cfg.com_height = 0.95
	_cfg.max_entry_omega = 4.2
	_cfg.sprawl_in_seconds = 0.25
	_cfg.sprawl_splay = 0.31


# ── tilt_at ───────────────────────────────────────────────────────────────────

func test_upright_through_the_buckle() -> void:
	assert_almost_eq(KnockdownFallRules.tilt_at(0.0, 3.0, _cfg), 0.0, 0.0001,
			"no tilt at the instant of the hit")
	assert_almost_eq(KnockdownFallRules.tilt_at(0.09, 3.0, _cfg), 0.0, 0.0001,
			"knees buckle first — the tip starts after buckle_seconds")

func test_tilt_rises_monotonically_to_first_impact() -> void:
	# Scan stops safely short of first contact — restitution rebounds never dip
	# this far back up, so everything below the stop line is pre-impact flight.
	var stop: float = _cfg.settle_angle - 0.3
	var prev: float = 0.0
	var t: float = 0.1
	while prev < stop:
		t += 0.02
		if t > 5.0:
			fail_test("never approached the settle angle")
			return
		var tilt: float = KnockdownFallRules.tilt_at(t, 3.0, _cfg)
		assert_true(tilt >= prev - 0.0001,
				"the fall only accelerates toward the ice (t=%f)" % t)
		prev = tilt

func test_tilt_never_exceeds_settle() -> void:
	for i in range(400):
		var tilt: float = KnockdownFallRules.tilt_at(i * 0.01, 6.0, _cfg)
		assert_true(tilt <= _cfg.settle_angle + 0.0001,
				"the body never rotates through the ice (t=%f)" % (i * 0.01))

func test_bounce_lifts_off_the_ice_then_resettles() -> void:
	# A hard shove reaches the ice fast enough that the restitution rebound is
	# visible: some post-impact instant sits measurably above the ice again.
	var impact_t: float = _first_settle_time(6.0)
	var min_after: float = _cfg.settle_angle
	for i in range(40):
		min_after = minf(min_after,
				KnockdownFallRules.tilt_at(impact_t + 0.005 + i * 0.01, 6.0, _cfg))
	assert_true(min_after < _cfg.settle_angle - 0.01,
			"a hard fall rebounds off the ice after first contact")
	assert_almost_eq(KnockdownFallRules.tilt_at(10.0, 6.0, _cfg), _cfg.settle_angle,
			0.0001, "the body ends flat regardless of bounce history")

func test_zero_restitution_stays_down_from_first_contact() -> void:
	_cfg.restitution = 0.0
	var impact_t: float = _first_settle_time(6.0)
	for i in range(1, 30):
		assert_almost_eq(
				KnockdownFallRules.tilt_at(impact_t + i * 0.05, 6.0, _cfg),
				_cfg.settle_angle, 0.0001, "no restitution → no rebound")

func test_harder_shove_falls_faster() -> void:
	var soft: float = KnockdownFallRules.tilt_at(0.3, 1.0, _cfg)
	var hard: float = KnockdownFallRules.tilt_at(0.3, 4.0, _cfg)
	assert_true(hard > soft + 0.01,
			"the seeded tip rate scales with the hit's shove speed")

func test_entry_omega_cap() -> void:
	var capped: float = KnockdownFallRules.tilt_at(0.25, 100.0, _cfg)
	var at_cap: float = KnockdownFallRules.tilt_at(
			0.25, _cfg.max_entry_omega * _cfg.com_height, _cfg)
	assert_almost_eq(capped, at_cap, 0.0001,
			"an absurd shove clamps to max_entry_omega instead of spinning the body")

func test_zero_speed_still_falls() -> void:
	assert_almost_eq(KnockdownFallRules.tilt_at(10.0, 0.0, _cfg), _cfg.settle_angle,
			0.0001, "gravity alone completes the fall from a standstill hit")


# ── first_impact_time ─────────────────────────────────────────────────────────

func test_first_impact_matches_the_tilt_solve() -> void:
	for speed in [0.0, 3.0, 6.0]:
		var t_i: float = KnockdownFallRules.first_impact_time(speed, _cfg)
		assert_almost_eq(KnockdownFallRules.tilt_at(t_i, speed, _cfg),
				_cfg.settle_angle, 0.0001,
				"the closed-form impact time lands exactly on the settle plane")
		assert_true(KnockdownFallRules.tilt_at(t_i - 0.02, speed, _cfg)
				< _cfg.settle_angle - 0.0001,
				"and nothing touches the ice before it (speed=%f)" % speed)


# ── fold_at ───────────────────────────────────────────────────────────────────

func test_fold_is_the_reflexive_curl_in_the_air() -> void:
	assert_almost_eq(KnockdownFallRules.fold_at(0.0, 0.35, _cfg), 0.35, 0.0001,
			"an upright body holds the airborne curl")


func test_fold_resolves_to_the_ground_plane_at_settle() -> void:
	assert_almost_eq(KnockdownFallRules.fold_at(_cfg.settle_angle, 0.35, _cfg),
			PI / 2.0 - _cfg.settle_angle, 0.0001,
			"the landed fold is exactly the complement that lays the torso flat")


func test_torso_never_folds_through_the_ice() -> void:
	# The regression this model exists for: a fixed airborne curl held through
	# the landing put tilt + fold past π/2 on a full fall — head under the ice.
	for speed in [0.0, 3.0, 6.0]:
		for i in range(400):
			var tilt: float = KnockdownFallRules.tilt_at(i * 0.01, speed, _cfg)
			var fold: float = KnockdownFallRules.fold_at(tilt, 0.35, _cfg)
			assert_true(tilt + fold <= PI / 2.0 + 0.01,
					"tilt + fold stays at/above the ground plane (t=%f)" % (i * 0.01))


# ── buckle_angles ─────────────────────────────────────────────────────────────

func test_buckle_deficit_matches_the_drop() -> void:
	var b: Vector2 = KnockdownFallRules.buckle_angles(0.3, 0.31, 0.45)
	assert_almost_eq((0.31 + 0.45) * (1.0 - cos(b.x)), 0.3, 0.0001,
			"the collapse angle's leg-length deficit equals the crumple drop")
	assert_almost_eq(b.y, -2.0 * b.x, 0.0001,
			"the knee folds back by thigh + shin from vertical")


func test_zero_drop_stands_straight() -> void:
	var b: Vector2 = KnockdownFallRules.buckle_angles(0.0, 0.31, 0.45)
	assert_almost_eq(b.x, 0.0, 0.0001, "no drop, no buckle")
	assert_almost_eq(b.y, 0.0, 0.0001, "no drop, no knee fold")


# ── sprawl_into ───────────────────────────────────────────────────────────────

func _sprawl(elapsed: float, speed: float, dir: Vector2) -> KnockdownFallRules.SprawlPose:
	var out := KnockdownFallRules.SprawlPose.new()
	KnockdownFallRules.sprawl_into(out, elapsed, speed, dir, 0.3, 0.31, 0.45, _cfg)
	return out


# Elapsed at which the scatter has fully developed for this entry speed.
func _settled_sprawl_time(speed: float) -> float:
	return KnockdownFallRules.first_impact_time(speed, _cfg) \
			+ _cfg.sprawl_in_seconds + 0.1


func test_sprawl_is_pure_buckle_before_first_impact() -> void:
	var p: KnockdownFallRules.SprawlPose = _sprawl(0.05, 3.0, Vector2(1, 0))
	var buckle: Vector2 = KnockdownFallRules.buckle_angles(0.3, 0.31, 0.45)
	assert_almost_eq(p.l_pitch, buckle.x, 0.0001, "in flight the body falls as one rod")
	assert_almost_eq(p.r_pitch, buckle.x, 0.0001, "both legs hold the same buckle")
	assert_almost_eq(p.l_roll, 0.0, 0.0001, "no scatter before the impact")
	assert_almost_eq(p.l_knee, p.r_knee, 0.0001, "symmetric until the limbs land")


func test_sprawl_scatters_after_impact_and_frees_the_top_leg() -> void:
	# Falling toward +X lands on the right side — the LEFT leg is on top, free
	# to extend; the right stays pinned under the body and folds deeper.
	var t: float = _settled_sprawl_time(3.0)
	var p: KnockdownFallRules.SprawlPose = _sprawl(t, 3.0, Vector2(1, 0))
	var buckle: Vector2 = KnockdownFallRules.buckle_angles(0.3, 0.31, 0.45)
	assert_true(absf(p.l_knee) < absf(buckle.y) - 0.01, "the free leg straightens")
	assert_true(absf(p.r_knee) > absf(buckle.y) + 0.01, "the pinned leg folds deeper")
	assert_true(p.l_roll < -0.01, "the free left leg splays outward (−X)")


func test_sprawl_side_follows_the_fall_lean() -> void:
	var t: float = _settled_sprawl_time(3.0)
	var right_free: KnockdownFallRules.SprawlPose = _sprawl(t, 3.0, Vector2(-1, 0))
	assert_true(right_free.r_roll > 0.01, "falling toward −X frees the right leg (+X splay)")
	assert_true(absf(right_free.l_knee) > absf(right_free.r_knee),
			"and pins the left one")


func test_harder_hits_sprawl_wider() -> void:
	var soft: KnockdownFallRules.SprawlPose = _sprawl(_settled_sprawl_time(1.0), 1.0, Vector2(1, 0))
	var hard: KnockdownFallRules.SprawlPose = _sprawl(_settled_sprawl_time(6.0), 6.0, Vector2(1, 0))
	assert_true(absf(hard.l_roll) > absf(soft.l_roll) + 0.01,
			"the splay scales with the entry tip rate")


func test_sprawl_knees_only_fold_backward() -> void:
	for speed in [0.0, 2.0, 6.0]:
		for i in range(40):
			var p: KnockdownFallRules.SprawlPose = _sprawl(i * 0.1, speed, Vector2(0.7, 0.7))
			assert_true(p.l_knee <= 0.0001 and p.r_knee <= 0.0001,
					"a knee never hyper-extends forward (t=%f)" % (i * 0.1))


func test_sprawl_is_deterministic() -> void:
	var a: KnockdownFallRules.SprawlPose = _sprawl(1.2, 3.0, Vector2(1, 0))
	var b: KnockdownFallRules.SprawlPose = _sprawl(1.2, 3.0, Vector2(1, 0))
	assert_eq(a.l_pitch, b.l_pitch, "same inputs, same pose — replay-safe")
	assert_eq(a.l_roll, b.l_roll, "same inputs, same pose — replay-safe")
	assert_eq(a.r_knee, b.r_knee, "same inputs, same pose — replay-safe")


# ── getup_scale ───────────────────────────────────────────────────────────────

func test_getup_scale_endpoints_and_monotonic() -> void:
	assert_almost_eq(KnockdownFallRules.getup_scale(0.0), 0.0, 0.0001, "fully up at 0")
	assert_almost_eq(KnockdownFallRules.getup_scale(1.0), 1.0, 0.0001, "fully down at 1")
	var prev: float = 0.0
	for i in range(1, 11):
		var s: float = KnockdownFallRules.getup_scale(i * 0.1)
		assert_true(s >= prev, "the get-up envelope never reverses")
		prev = s


# ── brace_at ──────────────────────────────────────────────────────────────────

func test_brace_ramps_in_over_brace_in_seconds() -> void:
	assert_almost_eq(KnockdownFallRules.brace_at(0.0, 1.0, 0.15), 0.0, 0.0001,
			"the pull-in is a reaction, not a snap")
	assert_almost_eq(KnockdownFallRules.brace_at(0.075, 1.0, 0.15), 0.5, 0.0001,
			"halfway through the ramp")
	assert_almost_eq(KnockdownFallRules.brace_at(0.5, 1.0, 0.15), 1.0, 0.0001,
			"fully braced once the ramp completes")

func test_brace_releases_through_the_getup() -> void:
	assert_almost_eq(KnockdownFallRules.brace_at(1.0, 0.0, 0.15), 0.0, 0.0001,
			"brace is gone when the get-up completes")
	assert_true(KnockdownFallRules.brace_at(1.0, 0.5, 0.15) < 1.0,
			"brace eases out with the same envelope as the tilt")


# ── wall_safe_fall_dir ────────────────────────────────────────────────────────
# proximity is a BoardPlayRules.board_proximity result: the INWARD normal (away
# from the wall) scaled by closeness 0..1. These tests use a wall to the +X side,
# so inward is −X and the into-wall direction is +X.

func test_wall_untouched_when_clear() -> void:
	var dir := Vector2(1, 0)
	assert_eq(KnockdownFallRules.wall_safe_fall_dir(dir, Vector2.ZERO), dir,
			"no boards within reach → the fall direction is the hit's")

func test_wall_untouched_when_falling_away() -> void:
	var away := Vector2(-1, 0)
	assert_eq(KnockdownFallRules.wall_safe_fall_dir(away, Vector2(-0.9, 0)), away,
			"falling away from a nearby wall is never fought")

func test_against_the_glass_falls_parallel() -> void:
	var out: Vector2 = KnockdownFallRules.wall_safe_fall_dir(
			Vector2(1, 0), Vector2(-1, 0))
	assert_almost_eq(out.dot(Vector2(1, 0)), 0.0, 0.0001,
			"pinned to the boards → the body lies along them, zero into-wall")
	assert_almost_eq(out.length(), 1.0, 0.0001, "still a unit direction")

func test_partial_gap_budgets_the_into_wall_component() -> void:
	# Boards at 40% of the body reach away → closeness 0.6, so the gap absorbs
	# an into-wall component of 0.4 and no more.
	var out: Vector2 = KnockdownFallRules.wall_safe_fall_dir(
			Vector2(1, 0), Vector2(-0.6, 0))
	assert_almost_eq(out.dot(Vector2(1, 0)), 0.4, 0.0001,
			"into-wall component clamped to the fraction the gap can absorb")
	assert_almost_eq(out.length(), 1.0, 0.0001, "still a unit direction")

func test_wall_keeps_the_leaned_tangent_side() -> void:
	var leaning_pos_y: Vector2 = KnockdownFallRules.wall_safe_fall_dir(
			Vector2(1, 0.2).normalized(), Vector2(-1, 0))
	var leaning_neg_y: Vector2 = KnockdownFallRules.wall_safe_fall_dir(
			Vector2(1, -0.2).normalized(), Vector2(-1, 0))
	assert_true(leaning_pos_y.y > 0.9, "sweeps onto the wall line the short way (+)")
	assert_true(leaning_neg_y.y < -0.9, "sweeps onto the wall line the short way (−)")

func test_wall_dead_perpendicular_tie_break_is_deterministic() -> void:
	var a: Vector2 = KnockdownFallRules.wall_safe_fall_dir(Vector2(1, 0), Vector2(-1, 0))
	var b: Vector2 = KnockdownFallRules.wall_safe_fall_dir(Vector2(1, 0), Vector2(-1, 0))
	assert_eq(a, b, "a dead-perpendicular shove resolves the same way every call")
	assert_almost_eq(a.length(), 1.0, 0.0001, "and stays unit")


# First elapsed at which the tilt is within grab distance of the settle angle.
# The grid can straddle the exact touch instant (the impact is a kink, not a
# dwell), so the threshold is loose — callers treat this as "at/just past first
# contact", not an exact impact time.
func _first_settle_time(entry_speed: float) -> float:
	for i in range(1, 1000):
		var t: float = i * 0.005
		if KnockdownFallRules.tilt_at(t, entry_speed, _cfg) >= _cfg.settle_angle - 0.02:
			return t
	return 5.0
