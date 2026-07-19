extends GutTest

# PuckGeometryCollision.resolve_posts — analytic puck-vs-goal-post reflection (the "ping").
# Posts are vertical cylinders at x = ±NET_HALF_WIDTH, z = ±GOAL_LINE_Z; the test is a 2D
# XZ circle-vs-circle. These pin the hit test, the restitution reflection, the flush eject,
# the pass-through cases (open mouth, far from goal), and vertical-channel preservation.

const R: float = 0.065  # PUCK_COLLISION_RADIUS


func _post_x() -> float:
	return GameRules.NET_HALF_WIDTH


func test_head_on_post_reflects_with_restitution() -> void:
	# Puck just in front of the +x post at the +z goal, driven straight into it (+z).
	var post_z: float = GameRules.GOAL_LINE_Z
	var pos := Vector3(_post_x(), 0.0175, post_z - 0.09)
	var vel := Vector3(0, 0, 10)  # straight at the post
	var res := PuckGeometryCollision.Result.new()
	var hit: bool = PuckGeometryCollision.resolve_posts(pos, vel, R, res)
	assert_true(hit, "puck driven into the post contacts it")
	assert_lt(res.velocity.z, 0.0, "velocity reversed away from the post")
	assert_almost_eq(res.velocity.z, -10.0 * PuckGeometryCollision.POST_RESTITUTION, 0.01,
			"normal component rebounds at POST_RESTITUTION (0.55)")


func test_puck_ejected_flush_against_post() -> void:
	var post_z: float = GameRules.GOAL_LINE_Z
	var pos := Vector3(_post_x(), 0.0175, post_z - 0.09)
	var res := PuckGeometryCollision.Result.new()
	PuckGeometryCollision.resolve_posts(pos, Vector3(0, 0, 10), R, res)
	var d: float = Vector2(res.position.x - _post_x(), res.position.z - post_z).length()
	assert_almost_eq(d, R + GameRules.NET_POST_RADIUS, 1e-4,
			"ejected exactly to the combined radius (flush, no penetration)")


func test_open_mouth_passes_through() -> void:
	# Dead center between the posts, crossing the goal line — a puck headed into the net,
	# no post contact.
	var pos := Vector3(0.0, 0.0175, GameRules.GOAL_LINE_Z - 0.05)
	var res := PuckGeometryCollision.Result.new()
	var hit: bool = PuckGeometryCollision.resolve_posts(pos, Vector3(0, 0, 12), R, res)
	assert_false(hit, "a puck through the open mouth doesn't touch a post")


func test_far_from_goal_is_a_cheap_miss() -> void:
	var res := PuckGeometryCollision.Result.new()
	var hit: bool = PuckGeometryCollision.resolve_posts(
			Vector3(_post_x(), 0.0175, 0.0), Vector3(0, 0, 30), R, res)
	assert_false(hit, "mid-ice at the post's x is nowhere near the goal line")


func test_near_end_is_selected_by_z_sign() -> void:
	# The same lateral position at the -z goal must hit the -z posts.
	var post_z: float = -GameRules.GOAL_LINE_Z
	var pos := Vector3(_post_x(), 0.0175, post_z + 0.09)
	var res := PuckGeometryCollision.Result.new()
	var hit: bool = PuckGeometryCollision.resolve_posts(pos, Vector3(0, 0, -10), R, res)
	assert_true(hit, "posts at the -z goal are tested when the puck is at -z")
	assert_gt(res.velocity.z, 0.0, "reflected back toward center ice (+z)")


func test_vertical_velocity_preserved_on_post_hit() -> void:
	# A low airborne puck clipping a post keeps its vertical channel (deflect_velocity is
	# horizontal-only; the resolver carries vy through).
	var pos := Vector3(_post_x(), 0.5, GameRules.GOAL_LINE_Z - 0.09)
	var res := PuckGeometryCollision.Result.new()
	PuckGeometryCollision.resolve_posts(pos, Vector3(0, 2.5, 10), R, res)
	assert_almost_eq(res.velocity.y, 2.5, 1e-5, "vertical velocity untouched by the post reflection")


func test_glancing_hit_keeps_tangential_pace() -> void:
	# A puck grazing the side of the post (mostly tangential travel) keeps most of its speed —
	# a ping that stays live, not a dead stop.
	var post_z: float = GameRules.GOAL_LINE_Z
	# Approach the +x post from its outer (+x) side, moving mostly +z (tangential to the
	# contact normal, which points +x).
	var pos := Vector3(_post_x() + 0.085, 0.0175, post_z)
	var res := PuckGeometryCollision.Result.new()
	var hit: bool = PuckGeometryCollision.resolve_posts(pos, Vector3(0, 0, 14), R, res)
	assert_true(hit)
	assert_gt(res.velocity.length(), 10.0, "tangential glance keeps most of its pace")


# ── Crossbar (Y-Z circle; unreachable at today's loft but authored for future tuning) ──

func test_crossbar_reflects_a_rising_puck_down() -> void:
	# A puck rising straight into the crossbar underside rebounds downward at POST_RESTITUTION.
	var pos := Vector3(0.0, GameRules.NET_HEIGHT - 0.09, GameRules.GOAL_LINE_Z)
	var res := PuckGeometryCollision.Result.new()
	var hit: bool = PuckGeometryCollision.resolve_crossbar(pos, Vector3(0, 12, 0), R, res)
	assert_true(hit, "puck driven up into the crossbar contacts it")
	assert_lt(res.velocity.y, 0.0, "rebounds downward off the bar")
	assert_almost_eq(res.velocity.y, -12.0 * PuckGeometryCollision.POST_RESTITUTION, 0.01,
			"vertical rebounds at POST_RESTITUTION")


func test_crossbar_keeps_along_bar_x_channel() -> void:
	var pos := Vector3(0.2, GameRules.NET_HEIGHT - 0.09, GameRules.GOAL_LINE_Z)
	var res := PuckGeometryCollision.Result.new()
	PuckGeometryCollision.resolve_crossbar(pos, Vector3(3, 12, 0), R, res)
	assert_almost_eq(res.velocity.x, 3.0, 1e-5, "motion along the bar (X) is untouched")


func test_crossbar_misses_beyond_crown_width() -> void:
	# Outside the crossbar span (|x| > crown half-width) — the corner bend / post region.
	var pos := Vector3(GameRules.NET_CROWN_HALF_WIDTH + 0.1, GameRules.NET_HEIGHT, GameRules.GOAL_LINE_Z)
	var res := PuckGeometryCollision.Result.new()
	assert_false(PuckGeometryCollision.resolve_crossbar(pos, Vector3(0, 10, 0), R, res))


func test_crossbar_ignores_a_grounded_puck() -> void:
	# The everyday case: a puck on the ice is nowhere near the 1.22 m bar.
	var pos := Vector3(0.0, 0.0175, GameRules.GOAL_LINE_Z)
	var res := PuckGeometryCollision.Result.new()
	assert_false(PuckGeometryCollision.resolve_crossbar(pos, Vector3(0, 0, 10), R, res))


# ── Top net panel (horizontal plane at NET_HEIGHT over the roof) ──

func test_top_net_absorbs_a_rising_puck() -> void:
	# A puck rising into the net roof rebounds down, softly (NET_RESTITUTION 0.05).
	var pos := Vector3(0.0, GameRules.NET_HEIGHT - 0.01, GameRules.GOAL_LINE_Z + 0.3)
	var res := PuckGeometryCollision.Result.new()
	var hit: bool = PuckGeometryCollision.resolve_top_net(pos, Vector3(2, 8, 0), res)
	assert_true(hit, "puck into the roof from below contacts it")
	assert_lt(res.velocity.y, 0.0, "rebounds downward")
	assert_almost_eq(res.velocity.y, -8.0 * PuckGeometryCollision.NET_RESTITUTION, 0.01,
			"vertical absorbed at NET_RESTITUTION (0.05)")
	assert_almost_eq(res.velocity.x, 2.0, 1e-5, "horizontal motion preserved")


func test_top_net_misses_in_front_of_the_goal_line() -> void:
	# Over the mouth (in front of the goal line) there is no roof — a lofted shot on net.
	var pos := Vector3(0.0, GameRules.NET_HEIGHT, GameRules.GOAL_LINE_Z - 0.3)
	var res := PuckGeometryCollision.Result.new()
	assert_false(PuckGeometryCollision.resolve_top_net(pos, Vector3(0, 5, 0), res))


func test_top_net_ignores_a_low_puck() -> void:
	var pos := Vector3(0.0, 0.3, GameRules.GOAL_LINE_Z + 0.3)
	var res := PuckGeometryCollision.Result.new()
	assert_false(PuckGeometryCollision.resolve_top_net(pos, Vector3(0, 2, 0), res))
