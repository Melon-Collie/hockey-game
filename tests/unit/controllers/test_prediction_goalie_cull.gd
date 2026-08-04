extends GutTest

# PuckController._reachable_goalies_for — the client re-predict's goalie filter.
# The per-tick range gate inside the prediction loop is near-EITHER goal line, so
# this filter is the only thing keeping the far-end goalie's ~8 boxes out of every
# predicted tick. It must never cull a goalie the span can actually reach, so the
# tests that matter are the ones at the boundary.

const _THRESH: float = GameRules.GOAL_LINE_Z - PuckAuthorityRules.GOALIE_DETECT_RANGE_Z


func _controller() -> PuckController:
	var pc := PuckController.new()
	autofree(pc)
	return pc


func _goalie_at_z(z: float) -> Node3D:
	var g := Node3D.new()
	g.position = Vector3(0.0, 0.0, z)
	add_child_autofree(g)
	return g


func _both_ends() -> Array:
	return [_goalie_at_z(GameRules.GOAL_LINE_Z), _goalie_at_z(-GameRules.GOAL_LINE_Z)]


func test_mid_ice_puck_at_rest_reaches_neither_goalie() -> void:
	var pc: PuckController = _controller()
	var out: Array = pc._reachable_goalies_for(
			_both_ends(), Vector3.ZERO, Vector3.ZERO, 0.5)
	assert_eq(out.size(), 0, "a puck parked at centre ice can reach no goalie")


func test_puck_in_a_zone_keeps_only_that_end() -> void:
	var pc: PuckController = _controller()
	var goalies: Array = _both_ends()
	var out: Array = pc._reachable_goalies_for(
			goalies, Vector3(0.0, 0.0, _THRESH + 1.0), Vector3.ZERO, 0.0)
	assert_eq(out.size(), 1, "only the same-end goalie survives")
	assert_eq(out[0], goalies[0], "and it is the +Z one")


func test_negative_end_keeps_only_the_negative_goalie() -> void:
	var pc: PuckController = _controller()
	var goalies: Array = _both_ends()
	var out: Array = pc._reachable_goalies_for(
			goalies, Vector3(0.0, 0.0, -(_THRESH + 1.0)), Vector3.ZERO, 0.0)
	assert_eq(out.size(), 1)
	assert_eq(out[0], goalies[1], "the -Z goalie, not its mirror")


# ── Boundary: the arithmetic these guard is `start.z * sign + travel > thresh` ──

func test_contact_just_inside_the_range_boundary_survives_the_cull() -> void:
	var pc: PuckController = _controller()
	var goalies: Array = _both_ends()
	# A hair past the gate the prediction loop itself uses. If the filter is off
	# by even a little in the conservative direction, this goalie disappears and
	# the client stops predicting a save it should hold for.
	var out: Array = pc._reachable_goalies_for(
			goalies, Vector3(0.0, 0.0, _THRESH + 0.001), Vector3.ZERO, 0.0)
	assert_eq(out.size(), 1, "a puck just inside the detect range keeps its goalie")


func test_a_span_that_travels_into_range_keeps_the_goalie() -> void:
	var pc: PuckController = _controller()
	var goalies: Array = _both_ends()
	# Starts 10 m short of the gate, carrying enough speed to cross it well
	# within the span — the case a start-position-only filter would wrongly cull.
	var out: Array = pc._reachable_goalies_for(
			goalies, Vector3(0.0, 0.0, _THRESH - 10.0), Vector3(0.0, 0.0, 40.0), 0.5)
	assert_eq(out.size(), 1, "the end the span skates into is kept")
	assert_eq(out[0], goalies[0])


func test_travel_bound_is_direction_agnostic() -> void:
	var pc: PuckController = _controller()
	var goalies: Array = _both_ends()
	# Same geometry, but the velocity points AWAY from the +Z end. The bound is
	# deliberately unsigned — it must still keep the goalie rather than reason
	# about a direction that board caroms can reverse mid-span.
	var out: Array = pc._reachable_goalies_for(
			goalies, Vector3(0.0, 0.0, _THRESH - 10.0), Vector3(0.0, 0.0, -40.0), 0.5)
	assert_true(goalies[0] in out, "an away-facing puck still can't cull its own end")


func test_a_fast_span_from_centre_ice_keeps_both_ends() -> void:
	var pc: PuckController = _controller()
	var out: Array = pc._reachable_goalies_for(
			_both_ends(), Vector3.ZERO, Vector3(0.0, 0.0, 40.0), 2.0)
	assert_eq(out.size(), 2, "a long fast span can reach either end — cull nothing")


func test_vertical_speed_does_not_buy_horizontal_reach() -> void:
	var pc: PuckController = _controller()
	# A puck popped straight up at centre ice travels no z. The bound uses the
	# full speed, so it over-keeps rather than under-keeps — assert only that it
	# stays conservative (never culls) rather than pinning the loose direction.
	var out: Array = pc._reachable_goalies_for(
			_both_ends(), Vector3(0.0, 0.0, _THRESH - 0.5), Vector3(0.0, 30.0, 0.0), 0.1)
	assert_true(out.size() >= 1, "the near end is never culled")


func test_nulls_in_the_provider_list_are_skipped() -> void:
	var pc: PuckController = _controller()
	var out: Array = pc._reachable_goalies_for(
			[null, _goalie_at_z(GameRules.GOAL_LINE_Z)],
			Vector3(0.0, 0.0, _THRESH + 1.0), Vector3.ZERO, 0.0)
	assert_eq(out.size(), 1, "a freed goalie slot doesn't reach the sweep")
