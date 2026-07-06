extends GutTest

# HockeyStopRules — pure decisions for the cosmetic hockey-stop pose.
# Frame convention: −Z forward, +X right; effort in [−1, +1] with −1 =
# braking hard; yaw is lower-body rotation.y (positive = legs toward −X).

const THR: float = 0.55      # engage effort fraction
const MIN_SPEED: float = 3.0
const MAX_YAW: float = 70.0 * PI / 180.0


# ── Engagement ────────────────────────────────────────────────────────────────

func test_engages_when_braking_hard_at_speed() -> void:
	assert_true(HockeyStopRules.should_engage(-0.8, 6.0, THR, MIN_SPEED))


func test_no_engage_when_coasting() -> void:
	# Coast/glide decel never reaches the effort bar.
	assert_false(HockeyStopRules.should_engage(-0.3, 6.0, THR, MIN_SPEED))


func test_no_engage_below_speed_floor() -> void:
	assert_false(HockeyStopRules.should_engage(-1.0, 1.0, THR, MIN_SPEED))


func test_no_engage_while_driving() -> void:
	assert_false(HockeyStopRules.should_engage(0.9, 8.0, THR, MIN_SPEED))


# ── Release hysteresis ────────────────────────────────────────────────────────

func test_holds_between_engage_and_release_bounds() -> void:
	# Effort recovered above the engage bar but below the release bar:
	# an engaged stop must HOLD (no chatter at the threshold).
	var effort: float = -THR * 0.7
	assert_false(HockeyStopRules.should_engage(effort, 6.0, THR, MIN_SPEED))
	assert_false(HockeyStopRules.should_release(effort, 6.0, THR, MIN_SPEED))


func test_releases_when_brake_eases_off() -> void:
	assert_true(HockeyStopRules.should_release(-0.1, 6.0, THR, MIN_SPEED))


func test_releases_when_stopped() -> void:
	assert_true(HockeyStopRules.should_release(-1.0, 0.5, THR, MIN_SPEED))


# ── Side latch ────────────────────────────────────────────────────────────────

func test_latch_follows_lateral_drift() -> void:
	assert_eq(HockeyStopRules.latch_side(Vector3(2.0, 0.0, -5.0)), 1.0,
			"drift right plants the right side")
	assert_eq(HockeyStopRules.latch_side(Vector3(-2.0, 0.0, -5.0)), -1.0,
			"drift left plants the left side")


func test_latch_defaults_right_when_straight() -> void:
	assert_eq(HockeyStopRules.latch_side(Vector3(0.0, 0.0, -5.0)), 1.0)


# ── Stop yaw ──────────────────────────────────────────────────────────────────

func test_forward_travel_turns_legs_to_cap() -> void:
	# Straight-ahead travel wants a ±90° turn; the cap clips it to ±70°.
	var vel := Vector3(0.0, 0.0, -6.0)
	assert_almost_eq(HockeyStopRules.stop_yaw(vel, 1.0, MAX_YAW), -MAX_YAW, 0.0001,
			"right-side stop turns legs clockwise (negative rotation.y)")
	assert_almost_eq(HockeyStopRules.stop_yaw(vel, -1.0, MAX_YAW), MAX_YAW, 0.0001,
			"left-side stop mirrors")


func test_diagonal_travel_lands_inside_cap() -> void:
	# Travel 45° right of forward, right-side stop: legs need 90 + 45 = 135°
	# body angle... wrapped/clamped — but a LEFT-side stop needs only 45°,
	# landing inside the cap un-clipped.
	var vel := Vector3(4.0, 0.0, -4.0)  # 45° right of forward
	var yaw_left: float = HockeyStopRules.stop_yaw(vel, -1.0, MAX_YAW)
	assert_almost_eq(yaw_left, deg_to_rad(45.0), 0.0001,
			"left-side stop across a right-diagonal is a 45° turn")


func test_backward_travel_wraps_to_near_perpendicular() -> void:
	# Skating straight backward: the perpendicular wraps to the near side
	# instead of winding up a >180° turn, then clips to the cap.
	var vel := Vector3(0.0, 0.0, 6.0)
	var yaw: float = HockeyStopRules.stop_yaw(vel, 1.0, MAX_YAW)
	assert_almost_eq(absf(yaw), MAX_YAW, 0.0001, "capped near-side perpendicular")


func test_no_yaw_at_standstill() -> void:
	assert_eq(HockeyStopRules.stop_yaw(Vector3.ZERO, 1.0, MAX_YAW), 0.0)


func test_yaw_ignores_vertical_velocity() -> void:
	var flat: float = HockeyStopRules.stop_yaw(Vector3(2.0, 0.0, -5.0), 1.0, MAX_YAW)
	var bumpy: float = HockeyStopRules.stop_yaw(Vector3(2.0, -3.0, -5.0), 1.0, MAX_YAW)
	assert_eq(flat, bumpy)
