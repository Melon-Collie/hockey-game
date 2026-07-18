extends GutTest

# The net as a carry/blade obstacle (AIActionScoring.carry_path_blocked_by_net
# / net_safe_blade_target): the cage is a solid frame the carry model has to
# see. A carried traverse can't pass through it, and the carry cursor must
# never ask the blade IK to reach through it — stick-on-net contact dislodges
# the carried puck (the behind-the-net giveaway).

const GOAL_Z: float = GameRules.GOAL_LINE_Z


# ── carry_path_blocked_by_net ─────────────────────────────────────────────────

func test_route_through_the_cage_is_blocked() -> void:
	# From behind the +Z net straight up-ice: through the frame.
	assert_true(AIActionScoring.carry_path_blocked_by_net(
			Vector3(0, 0, GOAL_Z + 2.0), Vector3(0, 0, GOAL_Z - 4.0)),
			"a straight route through the cage is not a carry")


func test_route_across_the_front_of_the_net_is_clear() -> void:
	# Wing to wing through the slot — in FRONT of the goal line, never
	# touching the frame.
	assert_false(AIActionScoring.carry_path_blocked_by_net(
			Vector3(-6, 0, GOAL_Z - 3.0), Vector3(6, 0, GOAL_Z - 3.0)),
			"the slot is open ice; only the cage itself blocks")


func test_route_around_the_post_is_clear() -> void:
	# From beside the cage, wide of the post, out front: the walkout line.
	assert_false(AIActionScoring.carry_path_blocked_by_net(
			Vector3(2.5, 0, GOAL_Z + 1.0), Vector3(2.5, 0, GOAL_Z - 2.0)),
			"wide of the inflated frame — the legal way out")


func test_far_route_ignores_both_nets() -> void:
	assert_false(AIActionScoring.carry_path_blocked_by_net(
			Vector3(-5, 0, 0), Vector3(5, 0, 2)),
			"nowhere near a cage")


# ── net_safe_blade_target ─────────────────────────────────────────────────────

func test_blade_aim_through_own_cage_is_swung_around_a_post() -> void:
	# Carrier behind their own +Z net aiming up-ice (the DZ carry that kept
	# getting the blade stuck in the mesh): the chord crosses the cage, so the
	# target swings to a post-side tangent. Property check: the RESULT's chord
	# no longer crosses, and the aim distance is preserved.
	var from := Vector3(0.3, 0, GOAL_Z + 1.9)
	var through := Vector3(0.3, 0, GOAL_Z + 0.6)   # cursor ring point inside the cage
	var out: Vector3 = AIActionScoring.net_safe_blade_target(from, through)
	assert_ne(out, through, "a crossing chord must be redirected")
	assert_almost_eq(
			Vector2(out.x - from.x, out.z - from.z).length(),
			Vector2(through.x - from.x, through.z - from.z).length(), 0.01,
			"redirect preserves the aim-ring distance")
	assert_eq(out, AIActionScoring.net_safe_blade_target(from, out),
			"the redirected target is itself net-safe (idempotent)")


func test_blade_aim_swings_toward_the_nearer_post() -> void:
	# Carrier behind the net, offset toward +X: the shorter way around is the
	# +X post — the swing must pick it, not the far side.
	var from := Vector3(1.0, 0, GOAL_Z + 1.9)
	var through := Vector3(0.8, 0, GOAL_Z + 0.6)
	var out: Vector3 = AIActionScoring.net_safe_blade_target(from, through)
	assert_gt(out.x, through.x, "swings around the near (+X) post side")


func test_non_crossing_blade_aim_is_untouched() -> void:
	var from := Vector3(0, 0, 0)
	var target := Vector3(0.5, 0, -1.2)
	assert_eq(AIActionScoring.net_safe_blade_target(from, target), target,
			"open-ice aims pass through unchanged")


func test_pinned_against_the_mesh_slides_the_aim_laterally() -> void:
	# Body inside the inflated frame region (pressed against the back of the
	# cage): no tangent exists — the aim slides toward the near post-side
	# exit instead of pointing into the mesh.
	var from := Vector3(0.6, 0, GOAL_Z + GameRules.NET_DEPTH + 0.1)
	var through := Vector3(0.6, 0, GOAL_Z + 0.2)
	var out: Vector3 = AIActionScoring.net_safe_blade_target(from, through)
	assert_gt(out.x, from.x + 0.5, "slides laterally toward the +X post exit")
	assert_almost_eq(out.z, from.z, 0.01, "no component into the mesh")
