extends GutTest

# GameRules.push_out_of_net — analytic goal-net exclusion projection. Keeps a
# skater's body disc out of the concave net pocket (the boards-style
# wedge that freezes a skater the goalie shoves across the goal line).
#
# Geometry under test (near/positive-Z net):
#   GOAL_LINE_Z          front face (open mouth) — NOT radius-inset
#   NET_DEPTH            back panel at |z| = GOAL_LINE_Z + NET_DEPTH (+ radius)
#   NET_BACK_HALF_WIDTH  side panels at |x| = NET_BACK_HALF_WIDTH (+ radius)
#
# Derived from GameRules rather than restated as literals: test_net_geometry_mirrors
# is what pins those constants, so this file is free to test the projection alone.
# Restating them here meant a constant could move and leave this test asserting the
# old geometry against the new function.

const TOL: float = 0.001
const GOAL_Z: float = GameRules.GOAL_LINE_Z
const BACK_HW: float = GameRules.NET_BACK_HALF_WIDTH
const DEPTH: float = GameRules.NET_DEPTH

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
	# Back panel inset by radius: the body edge stops at the back face, center at +r.
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

# ── net_proximity ─────────────────────────────────────────────────────────────
# The board_proximity analog for the net footprint: away-from-net normal scaled
# by closeness (0 at `probe` away → 1 against a panel), Euclidean closest-point,
# open mouth reports nothing.

func test_proximity_zero_far_from_net() -> void:
	assert_eq(GameRules.net_proximity(Vector2(0.0, 0.0), 2.0), Vector2.ZERO,
			"center ice — no net within probe")

func test_proximity_zero_in_front_of_the_mouth() -> void:
	assert_eq(GameRules.net_proximity(Vector2(0.0, 26.0), 2.0), Vector2.ZERO,
			"the mouth is open — a crease skater gets no report at any range")

func test_proximity_beside_the_net_points_away_laterally() -> void:
	# 1.0 m off the +x side panel with a 2.0 m probe → closeness 0.5, pure +x.
	var p: Vector2 = GameRules.net_proximity(Vector2(BACK_HW + 1.0, 27.0), 2.0)
	assert_almost_eq(p.x, 0.5, TOL, "half-probe from the side panel → closeness 0.5, +x")
	assert_almost_eq(p.y, 0.0, TOL, "pure lateral — no z component beside the panel")

func test_proximity_behind_the_net_points_out_back() -> void:
	# 0.5 m behind the back panel with a 2.0 m probe → closeness 0.75, +z.
	var p: Vector2 = GameRules.net_proximity(Vector2(0.0, GOAL_Z + DEPTH + 0.5), 2.0)
	assert_almost_eq(p.x, 0.0, TOL, "no lateral component dead behind the net")
	assert_almost_eq(p.y, 0.75, TOL, "quarter-probe gap → closeness 0.75, away out back")

func test_proximity_corner_is_euclidean() -> void:
	# Diagonally off the back corner: 0.6 right of the side, 0.8 past the back →
	# 1.0 m Euclidean. A face-distance box would report each axis separately.
	var p: Vector2 = GameRules.net_proximity(
			Vector2(BACK_HW + 0.6, GOAL_Z + DEPTH + 0.8), 2.0)
	assert_almost_eq(p.length(), 0.5, TOL, "1.0 m Euclidean on a 2.0 m probe → closeness 0.5")
	assert_almost_eq(p.angle(), Vector2(0.6, 0.8).angle(), TOL,
			"direction is the true corner diagonal")

func test_proximity_far_net_mirrors_sign() -> void:
	var p: Vector2 = GameRules.net_proximity(Vector2(0.0, -(GOAL_Z + DEPTH + 0.5)), 2.0)
	assert_almost_eq(p.y, -0.75, TOL, "far-net report points away in -z")

func test_proximity_zero_probe_is_silent() -> void:
	assert_eq(GameRules.net_proximity(Vector2(0.0, 28.0), 0.0), Vector2.ZERO,
			"zero probe never reports")
