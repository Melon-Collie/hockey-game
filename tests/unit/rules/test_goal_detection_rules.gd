extends GutTest

# GoalDetectionRules — center-based swept goal-line crossing that replaced the
# leaky Area3D sensor. Geometry mirrors HockeyGoal: the +Z net sits at
# z = GOAL_LINE_Z (facing +1), mouth centered on x = 0.
#
# Bounds passed by HockeyGoal (post inner face / under crossbar):
#   half_width  = POST_HALF_WIDTH - POST_RADIUS = 0.915 - 0.030 = 0.885
#   net_height  = NET_HEIGHT      - POST_RADIUS = 1.220 - 0.030 = 1.190
# Puck extents:  radius 0.065, half-height 0.0175. So the effective center bounds
# are |x| <= 0.820, y <= 1.1725, and "fully across" = center >= 0.065 past the line.

const GOAL_Z: float = GameRules.GOAL_LINE_Z          # 26.65
const HALF_W: float = 0.915   # POST_HALF_WIDTH (post centerline)
const NET_H: float = 1.220    # NET_HEIGHT (crossbar centerline)
const POST_R: float = 0.030   # POST_RADIUS
const R: float = 0.065        # GameRules.PUCK_COLLISION_RADIUS
const HH: float = 0.0175      # GameRules.PUCK_COLLISION_HALF_HEIGHT
const ICE_Y: float = 0.0175
# Effective whole-disc mouth after post + puck insets: |x| <= 0.820, y <= 1.1725.


func _crossed(prev: Vector3, curr: Vector3, facing: float = 1.0) -> bool:
	return GoalDetectionRules.crossed_into_net(
			prev, curr, GOAL_Z * signf(facing), facing,
			HALF_W, NET_H, POST_R, R, HH)


# ── The good case ─────────────────────────────────────────────────────────────

func test_clean_center_goal() -> void:
	# Prev fully in front of the line, curr fully across, dead center.
	assert_true(_crossed(
			Vector3(0.0, ICE_Y, GOAL_Z - 0.2),
			Vector3(0.0, ICE_Y, GOAL_Z + 0.2)))


func test_negative_end_goal() -> void:
	# The -Z net (facing -1): puck travels in -Z into it.
	assert_true(_crossed(
			Vector3(0.0, ICE_Y, -GOAL_Z + 0.2),
			Vector3(0.0, ICE_Y, -GOAL_Z - 0.2),
			-1.0))


func test_tight_inside_post_is_a_goal() -> void:
	# Center at x = 0.81, just inside the 0.82 clearance — a real post-and-in.
	assert_true(_crossed(
			Vector3(0.81, ICE_Y, GOAL_Z - 0.15),
			Vector3(0.81, ICE_Y, GOAL_Z + 0.15)))


func test_just_under_the_crossbar_is_a_goal() -> void:
	# Crosses at y = 1.17, under the 1.1725 effective bar — a top-shelf goal.
	assert_true(_crossed(
			Vector3(0.0, 1.17, GOAL_Z - 0.2),
			Vector3(0.0, 1.17, GOAL_Z + 0.2)))


func test_fast_shot_spanning_full_depth_in_one_tick() -> void:
	# ~63 m/s shot clears 0.53 m in one 120 Hz tick — the case an Area3D sensor
	# could tunnel straight through. Swept test still catches it.
	assert_true(_crossed(
			Vector3(0.0, ICE_Y, GOAL_Z - 0.4),
			Vector3(0.0, ICE_Y, GOAL_Z + 0.13)))


# ── False positives the old sensor allowed ────────────────────────────────────

func test_post_graze_crossing_outside_mouth_is_no_goal() -> void:
	# Puck rings the inside of the post: center crosses at x = 0.85 (> 0.82),
	# so the whole disc isn't between the posts. The old sensor scored this.
	assert_false(_crossed(
			Vector3(0.85, ICE_Y, GOAL_Z - 0.2),
			Vector3(0.85, ICE_Y, GOAL_Z + 0.2)))


func test_wide_of_the_post_is_no_goal() -> void:
	assert_false(_crossed(
			Vector3(1.2, ICE_Y, GOAL_Z - 0.2),
			Vector3(1.2, ICE_Y, GOAL_Z + 0.2)))


func test_slide_along_the_side_of_the_net_is_no_goal() -> void:
	# Puck slides laterally beside the net (constant z beyond the line, moving in
	# +x). No inward z-crossing this tick → not a goal, however far into the side
	# netting it drifts. The old volume sensor scored this from the side face.
	assert_false(_crossed(
			Vector3(1.0, ICE_Y, GOAL_Z + 0.2),
			Vector3(1.3, ICE_Y, GOAL_Z + 0.2)))


func test_over_the_crossbar_is_no_goal() -> void:
	# Crosses at y = 1.25, above the 1.1725 effective bar.
	assert_false(_crossed(
			Vector3(0.0, 1.25, GOAL_Z - 0.2),
			Vector3(0.0, 1.25, GOAL_Z + 0.2)))


# ── Direction / freshness guards ──────────────────────────────────────────────

func test_puck_pulled_back_out_is_no_goal() -> void:
	# Fully in the net last tick, dragged back toward center this tick — the
	# reverse crossing must never score.
	assert_false(_crossed(
			Vector3(0.0, ICE_Y, GOAL_Z + 0.2),
			Vector3(0.0, ICE_Y, GOAL_Z - 0.2)))


func test_fed_across_from_behind_the_net_is_no_goal() -> void:
	# Centering feed threaded across the mouth from behind the line (moving -Z
	# while facing is +1): crosses the plane the wrong way.
	assert_false(_crossed(
			Vector3(0.3, ICE_Y, GOAL_Z + 0.3),
			Vector3(-0.3, ICE_Y, GOAL_Z - 0.3)))


func test_already_in_net_no_fresh_crossing() -> void:
	# Both ticks fully across — no new crossing edge, so no (double) goal.
	assert_false(_crossed(
			Vector3(0.0, ICE_Y, GOAL_Z + 0.2),
			Vector3(0.0, ICE_Y, GOAL_Z + 0.4)))


func test_not_yet_fully_across_is_no_goal() -> void:
	# Leading edge is over the line but the center is only 0.03 past it (< 0.065
	# radius): the whole puck hasn't crossed yet.
	assert_false(_crossed(
			Vector3(0.0, ICE_Y, GOAL_Z - 0.05),
			Vector3(0.0, ICE_Y, GOAL_Z + 0.03)))


func test_approaching_but_short_of_the_line_is_no_goal() -> void:
	assert_false(_crossed(
			Vector3(0.0, ICE_Y, GOAL_Z - 0.5),
			Vector3(0.0, ICE_Y, GOAL_Z - 0.2)))


func test_crossing_at_the_x_clearance_boundary() -> void:
	# Center exactly on the 0.82 boundary counts (<=); a hair outside does not.
	var on_edge: float = HALF_W - POST_R - R  # 0.820
	assert_true(_crossed(
			Vector3(on_edge, ICE_Y, GOAL_Z - 0.2),
			Vector3(on_edge, ICE_Y, GOAL_Z + 0.2)))
	assert_false(_crossed(
			Vector3(on_edge + 0.01, ICE_Y, GOAL_Z - 0.2),
			Vector3(on_edge + 0.01, ICE_Y, GOAL_Z + 0.2)))


# ── Shared mouth predicate (used by live, penalty, tutorial) ──────────────────

func _in_mouth(x: float, y: float) -> bool:
	return GoalDetectionRules.point_in_mouth(x, y, HALF_W, NET_H, POST_R, R, HH)


func test_point_in_mouth_center() -> void:
	assert_true(_in_mouth(0.0, ICE_Y))


func test_point_in_mouth_rejects_post_graze() -> void:
	# x = 0.85 is inside the post centerline (0.915) but the disc is on the pipe.
	assert_false(_in_mouth(0.85, ICE_Y))


func test_point_in_mouth_accepts_tight_post_and_in() -> void:
	assert_true(_in_mouth(0.81, ICE_Y))


func test_point_in_mouth_rejects_over_the_bar() -> void:
	assert_false(_in_mouth(0.0, 1.25))


func test_point_in_mouth_accepts_just_under_the_bar() -> void:
	assert_true(_in_mouth(0.0, 1.17))


func test_diagonal_entry_uses_the_interpolated_crossing_point() -> void:
	# Puck angles in: at prev it's wide (x = 1.0) but by the time its center
	# reaches the goal-line plane it has come to x = 0.6 — inside the 0.82 mouth.
	# The interpolated crossing point, not the endpoints, decides.
	assert_true(_crossed(
			Vector3(1.0, ICE_Y, GOAL_Z - 0.3),
			Vector3(0.2, ICE_Y, GOAL_Z + 0.3)))
