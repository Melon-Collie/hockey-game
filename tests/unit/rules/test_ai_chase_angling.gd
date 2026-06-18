extends GutTest

# Pure-function test for SkaterAgentStateMachine._angle_intercept_inside,
# the chase-angle bias that funnels an opposing carrier toward the
# boards instead of letting them cut to center ice.

const BIAS: float = SkaterAgentStateMachine.CHASE_ANGLE_BIAS_M


func test_carrier_on_positive_x_biases_intercept_toward_center() -> void:
	# Carrier on the +X side of the rink — bias must be -X so the bot
	# meets them between the carrier and center ice.
	var target := Vector3(5.0, 0.0, 0.0)
	var carrier := Vector3(5.0, 0.0, 0.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_almost_eq(biased.x, target.x - BIAS, 0.001)
	assert_eq(biased.z, target.z, "Z is unchanged by lateral angling")


func test_carrier_on_negative_x_biases_toward_center() -> void:
	var target := Vector3(-5.0, 0.0, 10.0)
	var carrier := Vector3(-5.0, 0.0, 10.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_almost_eq(biased.x, target.x + BIAS, 0.001)


func test_carrier_near_center_skips_bias() -> void:
	# When the carrier is within CHASE_ANGLE_BIAS_M of center, there's
	# no inside to take away — applying the bias would overshoot to the
	# wrong side and OPEN the middle, the opposite of what we want.
	var target := Vector3(0.5, 0.0, 0.0)
	var carrier := Vector3(0.5, 0.0, 0.0)  # |x| < BIAS = 1.5
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_eq(biased, target, "centered carrier produces no bias")


func test_carrier_at_bias_boundary_skips_bias() -> void:
	# Exactly at the boundary: <= guard means no bias.
	var target := Vector3(BIAS, 0.0, 0.0)
	var carrier := Vector3(BIAS, 0.0, 0.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_eq(biased, target)


func test_bias_does_not_modify_y_or_z() -> void:
	var target := Vector3(8.0, 0.0, -5.0)
	var carrier := Vector3(8.0, 0.0, -5.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_eq(biased.y, 0.0)
	assert_eq(biased.z, -5.0)


# ── Deflect-lift: chasing bot raises its blade for airborne pucks ─────────────
# A grounded blade can't touch an airborne puck (saucer / elevated clear),
# so the chasing bot lifts to knock it down — but only for a LOOSE puck,
# only when it's actually airborne, and only within deflect reach.

func _make_snapshot(puck_pos: Vector3, carrier_peer_id: int) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	var puck := PuckNetworkState.new()
	puck.position = puck_pos
	puck.carrier_peer_id = carrier_peer_id
	snap.puck_state = puck
	return snap


func test_puck_is_airborne_threshold() -> void:
	var sm := SkaterAgentStateMachine.new()
	var resting := PuckNetworkState.new()
	resting.position = GameRules.PUCK_START_POS  # on the ice
	assert_false(sm._puck_is_airborne(resting), "a resting puck is not airborne")
	var high := PuckNetworkState.new()
	high.position = Vector3(0.0, 0.5, 0.0)
	assert_true(sm._puck_is_airborne(high), "a lofted puck is airborne")


func test_lift_to_deflect_airborne_loose_puck_in_reach() -> void:
	var sm := SkaterAgentStateMachine.new()
	var self_pos := Vector3(0.0, 0.0, 0.0)
	# Airborne, loose, ~0.5 m away — well inside DEFLECT_LIFT_REACH_M.
	var snap: WorldSnapshot = _make_snapshot(Vector3(0.5, 0.4, 0.0), -1)
	assert_true(sm._should_lift_to_deflect(snap, self_pos),
			"lift for a loose airborne puck within reach")


func test_no_lift_for_grounded_loose_puck() -> void:
	var sm := SkaterAgentStateMachine.new()
	var self_pos := Vector3(0.0, 0.0, 0.0)
	# Loose and in reach but on the ice — normal grounded corral, no lift.
	var snap: WorldSnapshot = _make_snapshot(Vector3(0.5, GameRules.PUCK_START_POS.y, 0.0), -1)
	assert_false(sm._should_lift_to_deflect(snap, self_pos),
			"a grounded puck is corralled flat, not deflected")


func test_no_lift_for_carried_puck() -> void:
	var sm := SkaterAgentStateMachine.new()
	var self_pos := Vector3(0.0, 0.0, 0.0)
	# Airborne and in reach but carried — can't be deflected.
	var snap: WorldSnapshot = _make_snapshot(Vector3(0.5, 0.4, 0.0), 7)
	assert_false(sm._should_lift_to_deflect(snap, self_pos),
			"a carried puck is not a deflect target")


func test_no_lift_for_airborne_puck_out_of_reach() -> void:
	var sm := SkaterAgentStateMachine.new()
	var self_pos := Vector3(0.0, 0.0, 0.0)
	var far: float = SkaterAgentStateMachine.DEFLECT_LIFT_REACH_M + 2.0
	var snap: WorldSnapshot = _make_snapshot(Vector3(far, 0.4, 0.0), -1)
	assert_false(sm._should_lift_to_deflect(snap, self_pos),
			"don't lift for an airborne puck beyond deflect reach")
