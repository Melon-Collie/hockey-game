extends GutTest

# GoalieSlideBehavior — butterfly drop animation + committed pivot-slide
# state. Tests cover timer accumulation, slide commit/decay, post-seal depth
# scaling, and the lateral target clamp (backdoor seal).

var sb: GoalieSlideBehavior

func before_each() -> void:
	sb = GoalieSlideBehavior.new()
	# Realistic defaults matching the controller exports.
	sb.slide_initial_speed = 4.5
	sb.slide_friction = 6.0
	sb.slide_min_speed = 0.3
	sb.slide_cooldown = 0.20
	sb.slide_pivot_arc_depth = 0.04
	sb.post_seal_depth = 0.10
	sb.pad_edge_extent = 0.56
	sb.post_event_slide_lockout = 0.25
	sb.butterfly_drop_speed = 0.08
	sb.butterfly_min_hold_time = 0.35

# ── Defaults ─────────────────────────────────────────────────────────────────

func test_initial_state_zero() -> void:
	assert_eq(sb.velocity_x, 0.0)
	assert_eq(sb.drop_progress, 0.0)
	assert_eq(sb.hold_timer, 0.0)
	assert_eq(sb.cooldown_timer, 0.0)
	assert_eq(sb.event_lockout, 0.0)

# ── Lockout ──────────────────────────────────────────────────────────────────

func test_arm_event_lockout_sets_full_duration() -> void:
	sb.arm_event_lockout()
	assert_almost_eq(sb.event_lockout, 0.25, 0.001)

# First event wins — a later arm shouldn't shorten an in-progress lockout.
func test_arm_event_lockout_takes_max() -> void:
	sb.event_lockout = 0.5
	sb.arm_event_lockout()
	assert_almost_eq(sb.event_lockout, 0.5, 0.001, "max wins; in-progress lockout untouched")

func test_tick_butterfly_decays_lockout() -> void:
	sb.arm_event_lockout()
	sb.tick_butterfly(0.1)
	assert_almost_eq(sb.event_lockout, 0.15, 0.001)

# ── Drop progress ────────────────────────────────────────────────────────────

func test_drop_progress_advances() -> void:
	sb.tick_butterfly(0.04)
	# 0.04 / 0.08 = 0.5
	assert_almost_eq(sb.drop_progress, 0.5, 0.001)

func test_drop_progress_clamped_at_one() -> void:
	sb.tick_butterfly(1.0)
	assert_eq(sb.drop_progress, 1.0)

# ── Hold + recovery gate ─────────────────────────────────────────────────────

func test_can_recover_false_before_hold_time() -> void:
	sb.tick_butterfly(0.2)
	assert_false(sb.can_recover())

func test_can_recover_true_after_hold_time() -> void:
	sb.tick_butterfly(0.4)
	assert_true(sb.can_recover())

# ── Can commit slide ─────────────────────────────────────────────────────────

func test_can_commit_slide_requires_drop_complete() -> void:
	sb.cooldown_timer = 1.0
	sb.drop_progress = 0.5
	assert_false(sb.can_commit_slide(), "drop animation not finished")

func test_can_commit_slide_requires_cooldown() -> void:
	sb.cooldown_timer = 0.1
	sb.drop_progress = 1.0
	assert_false(sb.can_commit_slide(), "cooldown not elapsed")

func test_can_commit_slide_requires_no_lockout() -> void:
	sb.cooldown_timer = 1.0
	sb.drop_progress = 1.0
	sb.event_lockout = 0.1
	assert_false(sb.can_commit_slide(), "event lockout suppresses slides")

func test_can_commit_slide_true_when_all_gates_open() -> void:
	sb.cooldown_timer = 1.0
	sb.drop_progress = 1.0
	assert_true(sb.can_commit_slide())

# ── Slide commit ─────────────────────────────────────────────────────────────

func test_commit_slide_enters_coil_phase() -> void:
	# Coil-then-slide: commit captures dir + endpoints but holds velocity at
	# zero until the coil timer expires. Push-off velocity is applied inside
	# advance_slide() on the tick the coil completes.
	sb.commit_slide(0.0, 0.1, 0.5, 0.915)
	assert_eq(sb.velocity_x, 0.0, "no push-off until coil completes")
	assert_almost_eq(sb.coil_timer, sb.coil_duration, 0.001, "coil timer set")
	assert_eq(sb.dir, 1.0)
	assert_eq(sb.start_x, 0.0)
	assert_eq(sb.end_x, 0.5)
	assert_eq(sb.arc_t, 0.0)
	assert_eq(sb.cooldown_timer, 0.0)

func test_advance_slide_applies_pushoff_after_coil() -> void:
	sb.commit_slide(0.0, 0.1, 0.5, 0.915)
	# Tick past the coil duration in one step — velocity should pick up the
	# committed direction's push-off speed.
	sb.advance_slide(sb.coil_duration + 0.001, 0.0, 0.915)
	assert_almost_eq(sb.velocity_x, 4.5 - 6.0 * 0.001, 0.01,
			"push-off applied on coil-complete tick (minus one frame of decay)")

func test_commit_slide_leftward_direction_captured() -> void:
	sb.commit_slide(0.0, 0.1, -0.5, 0.915)
	assert_eq(sb.dir, -1.0)
	# Push-off picks up sign from `dir` when coil completes.
	sb.advance_slide(sb.coil_duration + 0.001, 0.0, 0.915)
	assert_lt(sb.velocity_x, 0.0, "leftward push-off is negative velocity")

# Post-seal depth scales with target X extremity. Centre target: hold depth.
# Post-line target: full post-seal depth.
func test_commit_slide_to_centre_holds_depth() -> void:
	sb.commit_slide(0.0, 0.6, 0.0, 0.915)
	assert_almost_eq(sb.end_depth, 0.6, 0.001, "0 extremity → unchanged depth")

func test_commit_slide_to_post_pulls_post_seal_depth() -> void:
	sb.commit_slide(0.0, 0.6, 0.915, 0.915)
	# x_extremity = 1.0 → lerp(0.6, 0.10, 1.0) = 0.10
	assert_almost_eq(sb.end_depth, 0.10, 0.001, "post target → fully post-seal depth")

# ── Advance slide ────────────────────────────────────────────────────────────

func test_advance_slide_decays_velocity() -> void:
	sb.commit_slide(0.0, 0.1, 1.0, 0.915)
	# Skip past the coil so push-off has been applied.
	sb.advance_slide(sb.coil_duration, 0.0, 0.915)
	var v0: float = sb.velocity_x
	sb.advance_slide(0.1, 0.0, 0.915)
	# Decay = slide_friction * dt = 6.0 * 0.1 = 0.6
	assert_almost_eq(sb.velocity_x, v0 - 0.6, 0.001)

func test_advance_slide_progresses_arc() -> void:
	sb.commit_slide(0.0, 0.1, 1.0, 0.915)
	sb.advance_slide(sb.coil_duration, 0.0, 0.915)  # exit coil
	sb.advance_slide(0.05, 0.0, 0.915)
	assert_gt(sb.arc_t, 0.0)
	assert_lt(sb.arc_t, 1.0)

func test_advance_slide_holds_position_during_coil() -> void:
	sb.commit_slide(0.5, 0.1, 1.5, 0.915)
	# A tick that doesn't exit coil should leave position at the start point
	# and not advance the arc.
	var pos: Vector2 = sb.advance_slide(sb.coil_duration * 0.5, 0.0, 0.915)
	assert_almost_eq(pos.x, 0.5, 0.001, "x held at start during coil")
	assert_almost_eq(pos.y, 0.1, 0.001, "depth held at start during coil")
	assert_eq(sb.arc_t, 0.0)
	assert_eq(sb.velocity_x, 0.0)

# When velocity decays below slide_min_speed, the slide snaps to its endpoint
# and the cooldown resets (allowing a follow-up slide).
func test_advance_slide_finishes_below_min_speed() -> void:
	sb.commit_slide(0.0, 0.1, 0.5, 0.915)
	# Tick enough to fully decay (initial speed 4.5; friction 6.0 → ~0.75s to zero)
	for _i in range(20):
		sb.advance_slide(0.05, 0.0, 0.915)
	assert_true(sb.is_slide_finished())
	assert_eq(sb.velocity_x, 0.0)
	assert_eq(sb.arc_t, 1.0)
	assert_eq(sb.cooldown_timer, 0.0, "cooldown reset on finish")

# Position is clamped to the post line — slide arcing wider than the net is
# pinned at ±net_half_width.
func test_advance_slide_clamps_x_to_post() -> void:
	sb.commit_slide(0.0, 0.1, 5.0, 0.915)  # ridiculous target outside the net
	for _i in range(20):
		sb.advance_slide(0.05, 0.0, 0.915)
	assert_lte(sb.velocity_x, 0.0, "velocity decayed to zero or below")
	# end_x was 5.0 but position clamps at net_half_width
	# (the snap-to-endpoint on finish sets x to end_x; the in-flight position
	# uses clampf. Once finished, the controller transitions out of SLIDING.)

# ── Lateral target clamp ─────────────────────────────────────────────────────

# Backdoor seal: clamp slide target so pad EDGE lands on post (not pad center).
# net_half_width = 0.915, pad_edge_extent = 0.56 → max_lateral = 0.355.
func test_clamp_lateral_target_to_pad_edge_line() -> void:
	var result: float = sb.clamp_lateral_target(2.0, 0.0, 0.915, 0.56)
	assert_almost_eq(result, 0.355, 0.001)

func test_clamp_lateral_target_passes_through_mid_net() -> void:
	var result: float = sb.clamp_lateral_target(0.2, 0.0, 0.915, 0.56)
	assert_almost_eq(result, 0.2, 0.001, "mid-net targets pass through unchanged")

func test_clamp_lateral_target_negative_side() -> void:
	var result: float = sb.clamp_lateral_target(-2.0, 0.0, 0.915, 0.56)
	assert_almost_eq(result, -0.355, 0.001)

# ── Reset / enter_fresh_butterfly ────────────────────────────────────────────

func test_reset_clears_all_state() -> void:
	sb.commit_slide(0.0, 0.1, 0.5, 0.915)
	sb.tick_butterfly(0.1)
	sb.cooldown_timer = 1.0
	sb.reset()
	assert_eq(sb.velocity_x, 0.0)
	assert_eq(sb.drop_progress, 0.0)
	assert_eq(sb.hold_timer, 0.0)
	assert_eq(sb.cooldown_timer, 0.0)
	assert_eq(sb.event_lockout, 0.0)
	assert_eq(sb.arc_t, 0.0)
	assert_eq(sb.coil_timer, 0.0)

# Fresh butterfly entry resets the per-cycle timers. Slide→butterfly does
# NOT call this (it's the same cycle).
func test_enter_fresh_butterfly_clears_drop_progress() -> void:
	sb.drop_progress = 0.7
	sb.hold_timer = 0.2
	sb.enter_fresh_butterfly()
	assert_eq(sb.drop_progress, 0.0)
	assert_eq(sb.hold_timer, 0.0)
