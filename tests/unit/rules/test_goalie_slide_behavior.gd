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
	sb.pad_edge_extent = 0.84  # pad_local_offset (0.42) + butterfly_pad_half_extent (0.42)
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
	sb.commit_slide(0.0, 0.1, 0.5, 0.915, 0.0, 0.1)
	assert_eq(sb.velocity_x, 0.0, "no push-off until coil completes")
	assert_almost_eq(sb.coil_timer, sb.coil_duration, 0.001, "coil timer set")
	assert_eq(sb.dir, 1.0)
	assert_eq(sb.start_x, 0.0)
	assert_eq(sb.end_x, 0.5)
	assert_eq(sb.arc_t, 0.0)
	assert_eq(sb.cooldown_timer, 0.0)

func test_tick_coil_applies_pushoff_when_complete() -> void:
	sb.commit_slide(0.0, 0.1, 0.5, 0.915, 0.0, 0.1)
	# Tick the full coil duration in one step — coil should complete and
	# arm push-off velocity for the next translation tick.
	sb.tick_coil(sb.coil_duration + 0.001)
	assert_true(sb.is_coil_complete())
	assert_almost_eq(sb.velocity_x, 4.5, 0.001,
			"push-off velocity = slide_initial_speed when coil completes")

func test_commit_slide_leftward_direction_captured() -> void:
	sb.commit_slide(0.0, 0.1, -0.5, 0.915, 0.0, 0.1)
	assert_eq(sb.dir, -1.0)
	# Push-off picks up sign from `dir` when coil completes.
	sb.tick_coil(sb.coil_duration + 0.001)
	assert_lt(sb.velocity_x, 0.0, "leftward push-off is negative velocity")

func test_tick_coil_lerps_position_during_coil() -> void:
	# Coil ramps body from (coil_start_*) to (start_*) over coil_duration.
	# Halfway through, the body should be halfway between them.
	sb.commit_slide(0.0, 0.1, 0.5, 0.915, 0.4, 0.3)
	# Half-tick.
	var pos: Vector2 = sb.tick_coil(sb.coil_duration * 0.5)
	assert_almost_eq(pos.x, 0.2, 0.01, "x halfway between coil_start_x and start_x")
	assert_almost_eq(pos.y, 0.2, 0.01, "depth halfway between coil_start_depth and start_depth")
	assert_false(sb.is_coil_complete())

# Post-seal depth scales with target X extremity. Centre target: hold depth.
# Post-line target: full post-seal depth.
func test_commit_slide_to_centre_holds_depth() -> void:
	sb.commit_slide(0.0, 0.6, 0.0, 0.915, 0.0, 0.6)
	assert_almost_eq(sb.end_depth, 0.6, 0.001, "0 extremity → unchanged depth")

func test_commit_slide_to_post_pulls_post_seal_depth() -> void:
	sb.commit_slide(0.0, 0.6, 0.915, 0.915, 0.0, 0.6)
	# x_extremity = 1.0 → lerp(0.6, 0.10, 1.0) = 0.10
	assert_almost_eq(sb.end_depth, 0.10, 0.001, "post target → fully post-seal depth")

# ── Advance slide ────────────────────────────────────────────────────────────

func test_advance_slide_decays_velocity() -> void:
	sb.commit_slide(0.0, 0.1, 1.0, 0.915, 0.0, 0.1)
	# tick_coil runs first — it drains the coil and applies push-off.
	sb.tick_coil(sb.coil_duration)
	var v0: float = sb.velocity_x
	sb.advance_slide(0.1, 0.0, 0.915)
	# Decay = slide_friction * dt = 6.0 * 0.1 = 0.6
	assert_almost_eq(sb.velocity_x, v0 - 0.6, 0.001)

func test_advance_slide_progresses_arc() -> void:
	sb.commit_slide(0.0, 0.1, 1.0, 0.915, 0.0, 0.1)
	sb.tick_coil(sb.coil_duration)  # exit coil, arm push-off
	sb.advance_slide(0.05, 0.0, 0.915)
	assert_gt(sb.arc_t, 0.0)
	assert_lt(sb.arc_t, 1.0)

# When velocity decays below slide_min_speed, the slide snaps to its endpoint
# and the cooldown resets (allowing a follow-up slide).
func test_advance_slide_finishes_below_min_speed() -> void:
	sb.commit_slide(0.0, 0.1, 0.5, 0.915, 0.0, 0.1)
	sb.tick_coil(sb.coil_duration)  # exit coil, push-off armed
	# Tick enough to fully decay (initial speed 4.5; friction 6.0 → ~0.75s to zero)
	for _i in range(20):
		sb.advance_slide(0.05, 0.0, 0.915)
	assert_true(sb.is_slide_finished())
	assert_eq(sb.velocity_x, 0.0)
	assert_eq(sb.arc_t, 1.0)
	assert_eq(sb.cooldown_timer, 0.0, "cooldown reset on finish")

# Deep slide (committed from challenge depth): progress is normalized by the
# FULL path length, so the metre-plus depth leg travels at the push speed
# instead of riding the short lateral leg's schedule. Backward speed is
# bounded by the push speed, and the trip takes real time.

func test_deep_slide_depth_speed_bounded_by_push_speed() -> void:
	# Challenge depth 1.3 → post seal: lateral leg 0.355, depth leg ~1.2.
	# Pre-fix, depth completed on the lateral schedule — an effective
	# ~15 m/s backward snap. Path-normalized, no tick may move depth
	# faster than the push speed (4.5 m/s).
	sb.commit_slide(0.0, 1.3, 0.355, 0.915, 0.0, 1.3)
	sb.tick_coil(sb.coil_duration)
	var dt: float = 1.0 / 120.0
	var prev_depth: float = 1.3
	var max_depth_rate: float = 0.0
	for _i in range(120):
		var pos: Vector2 = sb.advance_slide(dt, 0.0, 0.915)
		max_depth_rate = maxf(max_depth_rate, absf(pos.y - prev_depth) / dt)
		prev_depth = pos.y
		if sb.is_slide_finished():
			break
	assert_lt(max_depth_rate, sb.slide_initial_speed + 0.5,
			"depth never outruns the push speed (plus the pivot-bow ripple)")

func test_deep_slide_takes_real_travel_time() -> void:
	# Path ≈ 1.25 m at 4.5 m/s decaying 6 m/s² → ~0.32 s. The pre-fix
	# lateral-normalized advance finished the same slide in ~0.08 s.
	sb.commit_slide(0.0, 1.3, 0.355, 0.915, 0.0, 1.3)
	sb.tick_coil(sb.coil_duration)
	var dt: float = 1.0 / 120.0
	var ticks: int = 0
	while not sb.is_slide_finished() and ticks < 240:
		sb.advance_slide(dt, 0.0, 0.915)
		ticks += 1
	assert_true(sb.is_slide_finished(), "friction budget still completes the deep path")
	assert_gt(ticks * dt, 0.25, "a challenge-depth slide is a visible trip, not a snap")

func test_deep_slide_path_is_the_committed_diagonal() -> void:
	# Mid-slide the body sits on the straight start→end line (± the small
	# pivot bow): depth progress tracks lateral progress 1:1 in arc terms.
	sb.commit_slide(0.0, 1.3, 0.355, 0.915, 0.0, 1.3)
	sb.tick_coil(sb.coil_duration)
	var dt: float = 1.0 / 120.0
	for _i in range(15):
		sb.advance_slide(dt, 0.0, 0.915)
	var pos: Vector2 = sb.advance_slide(dt, 0.0, 0.915)
	var t_x: float = (pos.x - 0.0) / 0.355
	var line_depth: float = lerpf(1.3, sb.end_depth, t_x)
	assert_almost_eq(pos.y, line_depth, sb.slide_pivot_arc_depth + 0.001,
			"depth stays on the straight committed line, within the pivot bow")


# Position is clamped to the post line — slide arcing wider than the net is
# pinned at ±net_half_width.
func test_advance_slide_clamps_x_to_post() -> void:
	sb.commit_slide(0.0, 0.1, 5.0, 0.915, 0.0, 0.1)  # ridiculous target outside the net
	sb.tick_coil(sb.coil_duration)  # exit coil, push-off armed
	for _i in range(20):
		sb.advance_slide(0.05, 0.0, 0.915)
	assert_lte(sb.velocity_x, 0.0, "velocity decayed to zero or below")
	# end_x was 5.0 but position clamps at net_half_width
	# (the snap-to-endpoint on finish sets x to end_x; the in-flight position
	# uses clampf. Once finished, the controller transitions out of SLIDING.)

# ── Lateral target clamp ─────────────────────────────────────────────────────

# Backdoor seal: clamp slide target so pad EDGE lands on post (not pad center).
# net_half_width = 0.915, pad_edge_extent = 0.84 (pad_local_offset 0.42 +
# butterfly_pad_half_extent 0.42) → max body_x = 0.075.
func test_clamp_lateral_target_to_pad_edge_line() -> void:
	var result: float = sb.clamp_lateral_target(2.0, 0.0, 0.915, 0.84)
	assert_almost_eq(result, 0.075, 0.001)

func test_clamp_lateral_target_passes_through_mid_net() -> void:
	var result: float = sb.clamp_lateral_target(0.05, 0.0, 0.915, 0.84)
	assert_almost_eq(result, 0.05, 0.001, "mid-net targets pass through unchanged")

func test_clamp_lateral_target_negative_side() -> void:
	var result: float = sb.clamp_lateral_target(-2.0, 0.0, 0.915, 0.84)
	assert_almost_eq(result, -0.075, 0.001)

# ── Reset / enter_fresh_butterfly ────────────────────────────────────────────

func test_reset_clears_all_state() -> void:
	sb.commit_slide(0.0, 0.1, 0.5, 0.915, 0.0, 0.1)
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
