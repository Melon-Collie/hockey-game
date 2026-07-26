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
const DEPTH: float = 1.016    # BASE_DEPTH (goal line to back frame)
const ICE_Y: float = 0.0175
# Effective whole-disc mouth after post + puck insets: |x| <= 0.820, y <= 1.1725.
# Cavity fallback bounds (endpoint fully inside the net): |x| <= 0.850,
# y <= 1.1725, depth in [0.065, 0.951].


func _crossed(prev: Vector3, curr: Vector3, facing: float = 1.0) -> bool:
	return GoalDetectionRules.crossed_into_net(
			prev, curr, GOAL_Z * signf(facing), facing,
			HALF_W, NET_H, POST_R, R, HH, DEPTH)


func _crossed_carried(prev: Vector3, curr: Vector3, facing: float = 1.0) -> bool:
	return GoalDetectionRules.crossed_into_net(
			prev, curr, GOAL_Z * signf(facing), facing,
			HALF_W, NET_H, POST_R, R, HH, DEPTH, true)


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


# ── Bent-path entries (post-and-in / bar-down) ────────────────────────────────

func test_post_and_in_counts_on_the_endpoint() -> void:
	# The straight prev -> curr segment pierces the plane at x = 0.84 — in the
	# pipe band, outside the tightened 0.82 mouth — but the puck finished fully
	# INSIDE the cavity. A real puck can only reach that endpoint by deflecting
	# in off the post (the panels are solid), so it's a goal. Rejecting it left
	# the puck sitting visibly in the net with no goal (locked out forever by
	# the freshness guard).
	assert_true(_crossed(
			Vector3(0.84, ICE_Y, GOAL_Z - 0.2),
			Vector3(0.84, ICE_Y, GOAL_Z + 0.2)))


func test_bar_down_counts_on_the_endpoint() -> void:
	# Clips the crossbar's underside right at the line: the straight segment
	# interpolates the crossing at y ~1.19 (above the 1.1725 bar clearance),
	# but the bar deflected the puck DOWN and it ended inside the net.
	assert_true(_crossed(
			Vector3(0.0, 1.20, GOAL_Z - 0.02),
			Vector3(0.0, 1.05, GOAL_Z + 0.30)))


func test_post_clank_deflected_wide_is_no_goal() -> void:
	# Rings the post band but caroms OUT beside the net: crossing point is in
	# the pipe band and the endpoint is not inside the cavity — no goal.
	assert_false(_crossed(
			Vector3(0.90, ICE_Y, GOAL_Z - 0.15),
			Vector3(1.05, ICE_Y, GOAL_Z + 0.15)))


# ── Endpoint-in-cavity but the straight segment came from OUTSIDE a solid face.
# The cavity fallback trusts "only route in is the mouth"; the straight segment
# we sample can straddle a solid side/back panel. These are the phantom
# "in from the back/side" goals — usually on a bot's exact angle — that the
# pipe-band crossing gate must reject. ────────────────────────────────────────

func test_slid_in_from_beside_the_net_is_no_goal() -> void:
	# Prev sits BESIDE the net at the goal line (x = 1.3, well outside the 0.915
	# post — over the side netting), curr ends inside the cavity. The straight
	# segment pierces the plane at x ~1.19, far outside the pipe band: the puck
	# never touched the frame, so a real disc would be stopped by the solid side
	# mesh. No goal.
	assert_false(_crossed(
			Vector3(1.3, ICE_Y, GOAL_Z - 0.05),
			Vector3(0.5, ICE_Y, GOAL_Z + 0.30)))


func test_sharp_angle_feed_from_behind_the_goal_line_is_no_goal() -> void:
	# A steep cross-crease feed threaded from a wide starting point at the line:
	# crosses the plane at x ~1.16 (outside the 1.01 pipe band) though the
	# endpoint lands in the cavity. Came from beyond a solid face — no goal.
	assert_false(_crossed(
			Vector3(1.2, ICE_Y, GOAL_Z - 0.02),
			Vector3(0.6, ICE_Y, GOAL_Z + 0.25)))


func test_pin_curled_past_the_post_into_cavity_is_no_goal() -> void:
	# A carried/pinned puck (teleported, not collision-constrained) curled from
	# outside the post into the cavity: crossing at x ~1.08, outside the band.
	# The blade net-clamp is meant to stop this, but detection must not award it
	# on the endpoint even if a pin slips through.
	assert_false(_crossed(
			Vector3(1.10, ICE_Y, GOAL_Z - 0.01),
			Vector3(0.70, ICE_Y, GOAL_Z + 0.20)))


func test_diagonal_post_and_in_grazing_the_pipe_still_counts() -> void:
	# A genuine bank-in: the puck angles in touching the post (crossing at
	# x ~0.99, inside the 1.01 pipe band — its center overlaps the pipe) and
	# ends inside the cavity. This is exactly what the cavity fallback exists
	# for, so the pipe-band gate must still let it through.
	assert_true(_crossed(
			Vector3(1.0, ICE_Y, GOAL_Z - 0.02),
			Vector3(0.7, ICE_Y, GOAL_Z + 0.40)))


# ── Carried (pinned) puck: only a real mouth crossing counts ──────────────────
# A carried puck is teleported to the blade each tick, not collision-constrained,
# so the "panels are solid → only route is the mouth" assumption behind the
# cavity fallback does not hold. A carried puck must cross the actual mouth
# opening (point_in_mouth); the endpoint-in-cavity fallback is disabled for it.

func test_carried_clean_mouth_tuck_still_counts() -> void:
	# A legit wraparound / jam: the pinned puck's center crosses the goal-line
	# plane inside the mouth. Still a goal — point_in_mouth catches it.
	assert_true(_crossed_carried(
			Vector3(0.0, ICE_Y, GOAL_Z - 0.05),
			Vector3(0.0, ICE_Y, GOAL_Z + 0.10)))


func test_carried_tight_post_tuck_still_counts() -> void:
	# Tucked in tight to the post but still through the opening (center x = 0.80,
	# inside the 0.82 mouth clearance).
	assert_true(_crossed_carried(
			Vector3(0.80, ICE_Y, GOAL_Z - 0.05),
			Vector3(0.80, ICE_Y, GOAL_Z + 0.10)))


func test_carried_curled_into_cavity_from_the_side_is_no_goal() -> void:
	# The bot case: the pinned puck is dragged from beside the post into the
	# cavity, crossing the plane at x ~0.95 (outside the 0.82 mouth) but ending
	# its center inside the cavity. As a FREE puck this passes the cavity
	# fallback (a plausible post-and-in); as a CARRIED puck the pin was placed
	# there, not deflected, so it must not score.
	assert_false(_crossed_carried(
			Vector3(1.0, ICE_Y, GOAL_Z - 0.02),
			Vector3(0.7, ICE_Y, GOAL_Z + 0.40)))
	# Same segment, FREE puck: still a goal (post-and-in), so the two paths
	# genuinely diverge and the carried flag is what gates it.
	assert_true(_crossed(
			Vector3(1.0, ICE_Y, GOAL_Z - 0.02),
			Vector3(0.7, ICE_Y, GOAL_Z + 0.40)))


func test_carried_behind_the_net_endpoint_in_cavity_is_no_goal() -> void:
	# Pinned puck swung from behind-the-goal-line beside the post into the
	# cavity: post-and-in-shaped endpoint, but carried, so no goal.
	assert_false(_crossed_carried(
			Vector3(0.84, ICE_Y, GOAL_Z - 0.10),
			Vector3(0.84, ICE_Y, GOAL_Z + 0.20)))


# ── False positives the old sensor allowed ────────────────────────────────────


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
	# Crosses at y = 1.25, above the 1.1725 effective bar. The cavity fallback
	# doesn't rescue it either — the endpoint is above the top netting.
	assert_false(_crossed(
			Vector3(0.0, 1.25, GOAL_Z - 0.2),
			Vector3(0.0, 1.25, GOAL_Z + 0.2)))


func test_endpoint_behind_the_net_is_no_goal() -> void:
	# A segment that pierces the pipe band and ends BEHIND the back frame
	# (deeper than DEPTH - R) is outside the cavity — never a goal.
	assert_false(_crossed(
			Vector3(0.85, ICE_Y, GOAL_Z - 0.1),
			Vector3(0.85, ICE_Y, GOAL_Z + DEPTH + 0.1)))


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
	# Center exactly on the 0.82 boundary counts (<=) via the clean-crossing
	# test alone. Past it the pipe band begins: a straight-line crossing there
	# is only a goal if the endpoint finished inside the cavity (see the
	# post-and-in / deflected-wide tests); an endpoint outside the cavity's
	# 0.85 x-bound stays a no-goal however the plane was pierced.
	var on_edge: float = HALF_W - POST_R - R  # 0.820
	assert_true(_crossed(
			Vector3(on_edge, ICE_Y, GOAL_Z - 0.2),
			Vector3(on_edge, ICE_Y, GOAL_Z + 0.2)))
	assert_false(_crossed(
			Vector3(0.90, ICE_Y, GOAL_Z - 0.2),
			Vector3(0.90, ICE_Y, GOAL_Z + 0.2)))


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


# ── Shared "inside the net" predicate (client render park) ────────────────────
# center_inside_net is the position-only form of the cavity test. The client's
# prediction uses it to decide whether to park a puck at the mouth instead of
# rendering it inside the net; the band BEHIND the net must never qualify.

func _inside_net(center: Vector3, facing: float = 1.0) -> bool:
	return GoalDetectionRules.center_inside_net(
			center, GOAL_Z * signf(facing), facing,
			HALF_W, NET_H, POST_R, R, HH, DEPTH)


func test_inside_net_center_of_the_cavity() -> void:
	assert_true(_inside_net(Vector3(0.0, ICE_Y, GOAL_Z + 0.3)))


func test_inside_net_just_past_the_line() -> void:
	# The park's whole point is catching the puck as it enters — depth need only
	# be >= 0 here (the crossing rule's own freshness bound is separate).
	assert_true(_inside_net(Vector3(0.0, ICE_Y, GOAL_Z + 0.01)))


func test_inside_net_deep_but_in_front_of_the_back_frame() -> void:
	assert_true(_inside_net(Vector3(0.0, ICE_Y, GOAL_Z + DEPTH - R - 0.01)))


func test_inside_net_rejects_behind_the_net() -> void:
	# THE client phantom-goal regression: puck rimmed/dumped behind the cage, so
	# past the goal line and within the post width, but beyond the back frame.
	# Parking this at the mouth is what rendered a puck sitting in the net on
	# clients while the host had it behind the net (and scored nothing).
	assert_false(_inside_net(Vector3(0.3, ICE_Y, GOAL_Z + DEPTH + 0.2)))
	assert_false(_inside_net(Vector3(0.0, ICE_Y, GOAL_Z + 2.0)))
	# Same at the -Z end.
	assert_false(_inside_net(Vector3(0.3, ICE_Y, -GOAL_Z - DEPTH - 0.2), -1.0))


func test_inside_net_rejects_beside_the_net() -> void:
	assert_false(_inside_net(Vector3(1.0, ICE_Y, GOAL_Z + 0.3)))


func test_inside_net_rejects_over_the_crossbar() -> void:
	assert_false(_inside_net(Vector3(0.0, 1.25, GOAL_Z + 0.3)))


func test_inside_net_rejects_in_front_of_the_line() -> void:
	assert_false(_inside_net(Vector3(0.0, ICE_Y, GOAL_Z - 0.05)))


func test_inside_net_rejects_wrong_end() -> void:
	# A puck deep in the +Z net is not inside the -Z net.
	assert_false(_inside_net(Vector3(0.0, ICE_Y, GOAL_Z + 0.3), -1.0))
