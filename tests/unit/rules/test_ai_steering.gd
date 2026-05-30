extends GutTest

# AISteering is a pure function — these tests cover anchor pull, the
# four repel forces (teammate, opponent, board, shot-lane), and the
# unit-magnitude clamp.

const RINK_X: float = 13.0
const RINK_Z: float = 30.0
const NO_OPS: Array[Vector3] = []
const NO_LANE := Vector3.ZERO


func _move(self_pos: Vector3, anchor: Vector3,
		teammates: Array[Vector3] = NO_OPS,
		opponents: Array[Vector3] = NO_OPS,
		lane_a: Vector3 = NO_LANE,
		lane_b: Vector3 = NO_LANE) -> Vector2:
	return AISteering.compute_move_vector(
			self_pos, anchor, teammates, opponents, lane_a, lane_b, RINK_X, RINK_Z)


func test_no_movement_when_at_anchor() -> void:
	var pos := Vector3(0, 0, 0)
	var v := _move(pos, pos)
	assert_almost_eq(v.length(), 0.0, 0.01, "no force when self is on the anchor")


func test_attracts_toward_anchor_along_z() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var v := _move(pos, anchor)
	assert_almost_eq(v.x, 0.0, 0.05)
	assert_gt(v.y, 0.5, "Vector2.y maps to world Z; should be positive toward anchor")


func test_teammate_repel_pushes_away() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var teammate_at_anchor: Array[Vector3] = [Vector3(0, 0, 1)]  # blocking the path
	var v_solo := _move(pos, anchor)
	var v_blocked := _move(pos, anchor, teammate_at_anchor)
	assert_lt(v_blocked.y, v_solo.y, "teammate ahead should reduce the +Z pull")


func test_opponent_repel_stronger_than_teammate() -> void:
	# Opponent repel weight 0.6 vs teammate 0.55 — same configuration
	# should push the bot back harder when the obstacle is an opponent.
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var teammate_block: Array[Vector3] = [Vector3(0, 0, 1)]
	var opponent_block: Array[Vector3] = [Vector3(0, 0, 1)]
	var v_team := _move(pos, anchor, teammate_block)
	var v_opp := _move(pos, anchor, NO_OPS, opponent_block)
	assert_lt(v_opp.y, v_team.y, "opponent repel should push back harder than teammate at the same distance")


func test_board_repel_pushes_inward_at_x_wall() -> void:
	var pos := Vector3(RINK_X - 0.5, 0, 0)  # very close to +X board
	var anchor := Vector3(RINK_X - 0.5, 0, 0)
	var v := _move(pos, anchor)
	assert_lt(v.x, 0.0, "should be pushed toward -X (inward)")


func test_shot_lane_repel_pushes_perpendicular() -> void:
	# Lane along +Z from (0,0,0) to (0,0,10). Bot 1 m off the lane to +X
	# should be pushed away from the lane (toward more +X).
	var pos := Vector3(1.0, 0.0, 5.0)  # mid-lane, 1m off in +X
	var anchor := Vector3(1.0, 0.0, 5.0)  # anchor at self → no pull
	var lane_a := Vector3(0, 0, 0)
	var lane_b := Vector3(0, 0, 10)
	var v := _move(pos, anchor, NO_OPS, NO_OPS, lane_a, lane_b)
	assert_gt(v.x, 0.0, "perpendicular force should push away from the lane")


func test_output_magnitude_clamped_to_unit() -> void:
	var pos := Vector3(RINK_X - 0.1, 0, RINK_Z - 0.1)  # corner; many forces stack
	var anchor := Vector3(0, 0, 0)
	var v := _move(pos, anchor)
	assert_lte(v.length(), 1.0001, "move_vector must not exceed unit length")


func test_crease_repel_pushes_outward_inside_arc() -> void:
	# Bot inside the +Z crease, slightly off-center toward +X. Should be
	# pushed outward (–Z back toward center ice, +X is fine — it's already
	# off-axis but the dominant push is away from the goal center).
	var crease_pos := Vector3(0.5, 0, GameRules.GOAL_LINE_Z - 0.5)
	var anchor := crease_pos  # anchor at self → no attract pull
	var v := _move(crease_pos, anchor)
	assert_lt(v.y, 0.0, "should be pushed in -Z away from +Z goal")


func test_no_crease_force_at_center_ice() -> void:
	# Origin straddles the half-space split (signf(0)=0). No crease force.
	var v := _move(Vector3.ZERO, Vector3(0, 0, 5))
	# v should match the no-crease behavior — the +Z anchor pulls along +y.
	assert_gt(v.y, 0.5, "no crease repel at center ice; only anchor pull remains")


func test_no_crease_force_at_neutral_zone() -> void:
	# Bot in the neutral zone (z=0). No crease force.
	var pos := Vector3(2.0, 0, 0.0)
	var v := _move(pos, pos)  # anchor at self
	assert_almost_eq(v.length(), 0.0, 0.01, "no force at neutral zone")


func test_ignores_teammates_outside_repel_radius() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var far_teammate: Array[Vector3] = [Vector3(0, 0, 1.0 + AISteering.TEAMMATE_REPEL_RADIUS + 0.1)]
	var v_with := _move(pos, anchor, far_teammate)
	var v_solo := _move(pos, anchor)
	assert_almost_eq(v_with.x, v_solo.x, 0.001)
	assert_almost_eq(v_with.y, v_solo.y, 0.001)


# brake_pivot tests — direction reversal helper layered on top of the
# potential-field steering output.

func test_brake_pivot_passes_through_when_below_min_speed() -> void:
	var desired := Vector2(1.0, 0.0)
	var slow_velocity := Vector2(-(AISteering.BRAKE_PIVOT_MIN_SPEED - 0.5), 0.0)
	var v := AISteering.brake_pivot(desired, slow_velocity)
	assert_almost_eq(v.x, desired.x, 0.001, "below min speed, return desired unchanged")
	assert_almost_eq(v.y, desired.y, 0.001)


func test_brake_pivot_passes_through_for_small_angle() -> void:
	# Velocity and desired both forward — small angle, no brake.
	var desired := Vector2(1.0, 0.0)
	var velocity := Vector2(8.0, 0.0)  # well above min speed
	var v := AISteering.brake_pivot(desired, velocity)
	assert_almost_eq(v.x, desired.x, 0.001, "aligned velocity does not trigger brake")
	assert_almost_eq(v.y, desired.y, 0.001)


func test_brake_pivot_inverts_to_velocity_on_reversal() -> void:
	# Velocity strongly forward, desired strongly backward (180°). Brake
	# fires — output should oppose velocity at the same magnitude as desired.
	var desired := Vector2(-1.0, 0.0)
	var velocity := Vector2(8.0, 0.0)
	var v := AISteering.brake_pivot(desired, velocity)
	# -velocity_dir * desired.length() = (-1, 0) * 1.0 = (-1, 0).
	assert_almost_eq(v.x, -1.0, 0.001, "brake pushes opposite to velocity")
	assert_almost_eq(v.y, 0.0, 0.001)


func test_brake_pivot_passes_through_at_perpendicular() -> void:
	# 90° angle is below the 120° threshold — should pass through.
	var desired := Vector2(0.0, 1.0)
	var velocity := Vector2(8.0, 0.0)
	var v := AISteering.brake_pivot(desired, velocity)
	assert_almost_eq(v.x, desired.x, 0.001)
	assert_almost_eq(v.y, desired.y, 0.001)


func test_brake_pivot_preserves_desired_magnitude() -> void:
	# Half-magnitude desired should produce half-magnitude brake output.
	var desired := Vector2(-0.5, 0.0)
	var velocity := Vector2(8.0, 0.0)
	var v := AISteering.brake_pivot(desired, velocity)
	assert_almost_eq(v.length(), 0.5, 0.001, "brake matches desired magnitude")


func test_brake_pivot_handles_zero_desired() -> void:
	var desired := Vector2.ZERO
	var velocity := Vector2(8.0, 0.0)
	var v := AISteering.brake_pivot(desired, velocity)
	assert_almost_eq(v.length(), 0.0, 0.001, "zero desired stays zero")


# offside_brake tests — body-level guard against skating across the
# attacking blue line before the puck. Team 0 (own_goal_dir = +1)
# attacks -Z, so its attacking blue line is at -BLUE_LINE_Z and "toward
# the zone" is -Z. The puck is "near side" (offside risk) while
# puck_z >= -BLUE_LINE_Z.

const TEAM0_DIR: float = 1.0   # own net +Z, attacks -Z
const TEAM1_DIR: float = -1.0  # own net -Z, attacks +Z
const NEAR_PUCK_Z: float = 0.0 # center ice — near side for both teams


func test_offside_brake_noop_for_carrier() -> void:
	# Carrier is never offside — even barreling across, no brake.
	var desired := Vector2(0.0, -1.0)
	var pos := Vector3(0.0, 0.0, -7.0)
	var vel := Vector3(0.0, 0.0, -8.0)
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, true)
	assert_eq(v, desired, "carrier is exempt from the offside brake")


func test_offside_brake_noop_when_puck_already_across() -> void:
	# Puck already in the attacking zone (z < -BLUE_LINE_Z) → entering is
	# legal, no brake even at speed toward the line.
	var desired := Vector2(0.0, -1.0)
	var pos := Vector3(0.0, 0.0, -7.0)
	var vel := Vector3(0.0, 0.0, -8.0)
	var puck_across: float = -GameRules.BLUE_LINE_Z - 2.0
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, puck_across, false)
	assert_eq(v, desired, "no brake once the puck has entered the zone")


func test_offside_brake_noop_when_moving_away_from_line() -> void:
	# Retreating toward our own end (v toward zone <= 0) → leave the
	# steering alone so the bot can tag back / recover.
	var desired := Vector2(0.0, 1.0)
	var pos := Vector3(0.0, 0.0, -7.0)
	var vel := Vector3(0.0, 0.0, 5.0)  # +Z, away from the -Z zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_eq(v, desired, "no brake when already moving away from the line")


func test_offside_brake_noop_with_room_to_stop() -> void:
	# Far from the line and slow — stopping distance clears the line by
	# more than the margin, so the bot is free to keep its target.
	var desired := Vector2(0.0, -1.0)
	var pos := Vector3(0.0, 0.0, 0.0)   # center ice, ~7.3 m from the line
	var vel := Vector3(0.0, 0.0, -2.0)  # slow toward the zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_eq(v, desired, "plenty of room to stop → no brake")


func test_offside_brake_engages_on_fast_approach() -> void:
	# Near the line and fast toward the zone — stopping distance would
	# carry the body across, so brake away from the line (+Z for team 0).
	var desired := Vector2(0.0, -1.0)  # bot wants to keep driving into the zone
	var pos := Vector3(0.0, 0.0, -5.0) # ~2.3 m from the -7.29 line
	var vel := Vector3(0.0, 0.0, -8.0) # 8 m/s toward the zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_gt(v.y, 0.0, "team 0 should brake back toward +Z to avoid crossing the -Z blue line")


func test_offside_brake_engages_team1_mirrored() -> void:
	# Mirror for team 1 (attacks +Z, line at +BLUE_LINE_Z): brake toward -Z.
	var desired := Vector2(0.0, 1.0)
	var pos := Vector3(0.0, 0.0, 5.0)
	var vel := Vector3(0.0, 0.0, 8.0)  # toward the +Z zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM1_DIR, NEAR_PUCK_Z, false)
	assert_lt(v.y, 0.0, "team 1 should brake back toward -Z to avoid crossing the +Z blue line")


func test_offside_brake_preserves_lateral_intent() -> void:
	# When braking, the lateral (x) component of the desired move is kept
	# so the bot can still adjust its width along the line.
	var desired := Vector2(0.6, -1.0)
	var pos := Vector3(0.0, 0.0, -5.0)
	var vel := Vector3(0.0, 0.0, -8.0)
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_gt(v.x, 0.0, "lateral intent is preserved through the brake")
	assert_gt(v.y, 0.0, "depth component still brakes back from the line")
