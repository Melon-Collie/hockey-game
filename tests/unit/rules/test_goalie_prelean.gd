extends GutTest

# GoalieBodyConfigBuilder._apply_prelean — the pre-lean pose layer. The goalie
# reads a charging shot's windup and leans PARTWAY toward where it's currently
# aimed before release. These tests lock in the invariants that keep it a
# read/counter-read rather than a flat buff:
#   - directional lean drifts the relevant hand toward the predicted corner,
#   - it's PARTIAL (strength < 1 never reaches the full reach target),
#   - it tracks the LIVE predicted aim (a switched aim leans the other way —
#     the property that lets a tricky release beat the lean),
#   - the non-directional fallback only raises the hands (no lateral drift),
#   - it no-ops when inactive / zero-strength / already reacting.
#
# Coordinates use the +Z-defending goalie convention (direction_sign = +1, the
# pose's local +X = world -X), goalie centered at current_x = 0.

const State := GoalieStateMachine.State


func _builder() -> GoalieBodyConfigBuilder:
	return GoalieBodyConfigBuilder.new()


func _base_inputs() -> GoalieBodyConfigBuilder.Inputs:
	var i := GoalieBodyConfigBuilder.Inputs.new()
	i.state = State.STANDING
	i.current_x = 0.0
	i.direction_sign = 1
	i.prelean_active = true
	i.prelean_directional = true
	i.prelean_strength = 0.35
	i.prelean_ready_lift = 0.06
	return i


# Build a STANDING config so we have the real resting glove/blocker positions to
# compare the leaned pose against.
func _resting() -> GoalieBodyConfig:
	var b := _builder()
	var i := GoalieBodyConfigBuilder.Inputs.new()
	i.state = State.STANDING
	var c := GoalieBodyConfig.new()
	b._set_standing_pose(c, i)
	return c


func test_glove_side_shot_drifts_glove_outward_partially() -> void:
	var rest := _resting()
	var b := _builder()
	var c := GoalieBodyConfig.new()
	b._set_standing_pose(c, GoalieBodyConfigBuilder.Inputs.new())
	var inputs := _base_inputs()
	# Predicted impact to the glove side. World +X maps to goalie-local -X (glove
	# side) for direction_sign = +1, so a +X world impact pulls the glove out.
	inputs.prelean_impact_x = 0.8
	inputs.prelean_impact_y = 1.3
	b._apply_prelean(c, inputs)
	# Glove moved toward its outward (-X) extension, but only partway.
	assert_lt(c.glove_pos.x, rest.glove_pos.x, "glove drifts toward the glove-side corner")
	assert_gt(c.glove_pos.x, b.glove_max_x_outward, "lean is partial — never reaches full extension")
	# Glove rose toward the predicted (elevated) impact height.
	assert_gt(c.glove_pos.y, rest.glove_pos.y, "glove rises toward an elevated predicted impact")


func test_blocker_side_shot_drifts_blocker() -> void:
	var rest := _resting()
	var b := _builder()
	var c := GoalieBodyConfig.new()
	b._set_standing_pose(c, GoalieBodyConfigBuilder.Inputs.new())
	var inputs := _base_inputs()
	# World -X → goalie-local +X (blocker side).
	inputs.prelean_impact_x = -0.8
	inputs.prelean_impact_y = 1.3
	b._apply_prelean(c, inputs)
	assert_gt(c.blocker_pos.x, rest.blocker_pos.x, "blocker drifts toward the blocker-side corner")
	assert_lt(c.blocker_pos.x, b.blocker_max_x_outward, "lean is partial")


# The defining property: the lean follows the LIVE predicted aim, so flipping the
# aim flips which way the goalie leans. A player who drags one way then releases
# the other moves the impact off the lean — the tricky release beats the read.
func test_lean_tracks_live_aim_direction() -> void:
	var b := _builder()
	var glove_side := GoalieBodyConfig.new()
	b._set_standing_pose(glove_side, GoalieBodyConfigBuilder.Inputs.new())
	var i1 := _base_inputs()
	i1.prelean_impact_x = 0.8       # glove side
	i1.prelean_impact_y = 1.3
	b._apply_prelean(glove_side, i1)

	var blocker_side := GoalieBodyConfig.new()
	b._set_standing_pose(blocker_side, GoalieBodyConfigBuilder.Inputs.new())
	var i2 := _base_inputs()
	i2.prelean_impact_x = -0.8      # blocker side (flicked the other way)
	i2.prelean_impact_y = 1.3
	b._apply_prelean(blocker_side, i2)

	# Body roll (body_rot.z) leans opposite directions for the two aims.
	assert_ne(signf(glove_side.body_rot.z), signf(blocker_side.body_rot.z),
			"opposite aims lean the body opposite ways — late release beats the lean")


func test_higher_strength_leans_further() -> void:
	var b := _builder()
	var weak := GoalieBodyConfig.new()
	b._set_standing_pose(weak, GoalieBodyConfigBuilder.Inputs.new())
	var i_weak := _base_inputs()
	i_weak.prelean_strength = 0.2
	i_weak.prelean_impact_x = 0.8
	i_weak.prelean_impact_y = 1.3
	b._apply_prelean(weak, i_weak)

	var strong := GoalieBodyConfig.new()
	b._set_standing_pose(strong, GoalieBodyConfigBuilder.Inputs.new())
	var i_strong := _base_inputs()
	i_strong.prelean_strength = 0.6
	i_strong.prelean_impact_x = 0.8
	i_strong.prelean_impact_y = 1.3
	b._apply_prelean(strong, i_strong)

	assert_lt(strong.glove_pos.x, weak.glove_pos.x,
			"higher strength commits more of the reach")


func test_non_directional_only_raises_hands() -> void:
	var rest := _resting()
	var b := _builder()
	var c := GoalieBodyConfig.new()
	b._set_standing_pose(c, GoalieBodyConfigBuilder.Inputs.new())
	var inputs := _base_inputs()
	inputs.prelean_directional = false   # remote shooter — no aim on the wire
	b._apply_prelean(c, inputs)
	# Hands rise, but no lateral drift (no predicted corner to lean toward).
	assert_gt(c.glove_pos.y, rest.glove_pos.y, "glove rises for the readiness tell")
	assert_gt(c.blocker_pos.y, rest.blocker_pos.y, "blocker rises for the readiness tell")
	assert_almost_eq(c.glove_pos.x, rest.glove_pos.x, 0.0001, "no lateral drift without an aim")
	assert_almost_eq(c.blocker_pos.x, rest.blocker_pos.x, 0.0001, "no lateral drift without an aim")


func test_inactive_or_reacting_is_noop() -> void:
	var rest := _resting()
	# Inactive.
	var b := _builder()
	var c1 := GoalieBodyConfig.new()
	b._set_standing_pose(c1, GoalieBodyConfigBuilder.Inputs.new())
	var i1 := _base_inputs()
	i1.prelean_active = false
	i1.prelean_impact_x = 0.8
	b._apply_prelean(c1, i1)
	assert_almost_eq(c1.glove_pos.x, rest.glove_pos.x, 0.0001, "inactive pre-lean is a no-op")

	# Already reacting — the real reaction reach owns the arms.
	var c2 := GoalieBodyConfig.new()
	b._set_standing_pose(c2, GoalieBodyConfigBuilder.Inputs.new())
	var i2 := _base_inputs()
	i2.reacting_to_shot = true
	i2.prelean_impact_x = 0.8
	b._apply_prelean(c2, i2)
	assert_almost_eq(c2.glove_pos.x, rest.glove_pos.x, 0.0001, "pre-lean yields to an active reaction")


func test_zero_strength_is_noop() -> void:
	var rest := _resting()
	var b := _builder()
	var c := GoalieBodyConfig.new()
	b._set_standing_pose(c, GoalieBodyConfigBuilder.Inputs.new())
	var inputs := _base_inputs()
	inputs.prelean_strength = 0.0
	inputs.prelean_impact_x = 0.8
	b._apply_prelean(c, inputs)
	assert_almost_eq(c.glove_pos.x, rest.glove_pos.x, 0.0001, "zero strength leans nothing")
