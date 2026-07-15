extends GutTest

# GameRules.push_out_of_net — analytic goal-net exclusion projection. Keeps a
# skater's CharacterBody cylinder out of the concave net pocket (the boards-style
# wedge that freezes a skater the goalie shoves across the goal line).
#
# Geometry under test (near/positive-Z net):
#   GOAL_LINE_Z        = 26.65   front face (open mouth) — NOT radius-inset
#   NET_DEPTH          =  1.02   back panel at |z| = 27.67 (+ radius)
#   NET_BACK_HALF_WIDTH=  1.02   side panels at |x| = 1.02 (+ radius)

const TOL: float = 0.001
const GOAL_Z: float = 26.65
const BACK_HW: float = 1.02
const DEPTH: float = 1.02

# ── Points outside the box are untouched ──────────────────────────────────────

func test_center_ice_unchanged() -> void:
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.0, 0.0))
	assert_almost_eq(r.x, 0.0, TOL, "x")
	assert_almost_eq(r.y, 0.0, TOL, "z")

func test_in_front_of_goal_line_unchanged() -> void:
	# A skater in the crease (in front of the goal line) must not be pushed.
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.0, 26.0))
	assert_almost_eq(r.x, 0.0, TOL, "x")
	assert_almost_eq(r.y, 26.0, TOL, "z unchanged (crease play untouched)")

func test_wide_of_net_unchanged() -> void:
	# A wraparound skater going around the net at |x| beyond the side panel.
	var r: Vector2 = GameRules.push_out_of_net(Vector2(1.5, 27.0))
	assert_almost_eq(r.x, 1.5, TOL, "x unchanged")
	assert_almost_eq(r.y, 27.0, TOL, "z unchanged")

func test_behind_net_unchanged() -> void:
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.0, 28.5))
	assert_almost_eq(r.x, 0.0, TOL, "x")
	assert_almost_eq(r.y, 28.5, TOL, "z unchanged (behind the net)")

# ── Inside the pocket → ejected along the nearest face ────────────────────────

func test_just_past_goal_line_ejected_to_mouth() -> void:
	# The reported case: shoved just across the goal line — front face is nearest,
	# so eject back out toward center ice (the open mouth).
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.0, 26.75))
	assert_almost_eq(r.x, 0.0, TOL, "x held")
	assert_almost_eq(r.y, GOAL_Z, TOL, "z ejected to goal line")

func test_deep_in_pocket_ejected_out_back() -> void:
	# Near the back panel — back face is nearest.
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.0, 27.6))
	assert_almost_eq(r.y, GOAL_Z + DEPTH, TOL, "z ejected to back face (radius 0)")

func test_near_side_panel_ejected_sideways() -> void:
	# Center deep enough that a side face is the nearest exit.
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.95, 27.15))
	assert_almost_eq(r.x, BACK_HW, TOL, "x ejected to +side face")
	assert_almost_eq(r.y, 27.15, TOL, "z held during a sideways eject")

func test_negative_side_ejects_negative() -> void:
	var r: Vector2 = GameRules.push_out_of_net(Vector2(-0.95, 27.15))
	assert_almost_eq(r.x, -BACK_HW, TOL, "x ejected to -side face")

# ── Radius insets the closed faces (not the open mouth) ───────────────────────

func test_radius_insets_back_and_sides_not_front() -> void:
	var radius: float = 0.35
	# Front (mouth) face is NOT inset — a body centered on the goal line is clear.
	var front: Vector2 = GameRules.push_out_of_net(Vector2(0.0, GOAL_Z), radius)
	assert_almost_eq(front.y, GOAL_Z, TOL, "center on goal line is outside → untouched")
	# Back panel inset by radius: the body edge stops at 27.67, center at 27.67+r.
	var back: Vector2 = GameRules.push_out_of_net(Vector2(0.0, 27.9), radius)
	assert_almost_eq(back.y, GOAL_Z + DEPTH + radius, TOL, "back face inset by radius")
	# Side panel inset by radius.
	var side: Vector2 = GameRules.push_out_of_net(Vector2(1.3, 27.15), radius)
	assert_almost_eq(side.x, BACK_HW + radius, TOL, "side face inset by radius")

# ── The far (negative-Z) net mirrors the near net ─────────────────────────────

func test_far_net_ejects_with_sign_preserved() -> void:
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.0, -26.75))
	assert_almost_eq(r.y, -GOAL_Z, TOL, "far net front eject keeps the -Z sign")

func test_far_net_front_untouched() -> void:
	var r: Vector2 = GameRules.push_out_of_net(Vector2(0.0, -26.0))
	assert_almost_eq(r.y, -26.0, TOL, "far crease untouched")
