extends GutTest

# SkaterAgent — the InputState scratch buffer is reused across ticks, so
# _zero_input must reset every field a state-machine handler can set. A missed
# field latches: the regression this guards is quick_shot_pressed staying true
# after a bot's first pass/quick shot (added in the dedicated-button split),
# which made every subsequent carry tick fire an instant quick shot.


func test_zero_input_resets_every_field_the_sm_can_set() -> void:
	var agent := SkaterAgent.new()
	var input: InputState = agent._scratch_input
	input.move_vector = Vector2.ONE
	input.mouse_world_pos = Vector3.ONE
	input.mouse_screen_pos = Vector2.ONE
	input.shoot_pressed = true
	input.shoot_held = true
	input.slap_pressed = true
	input.slap_held = true
	input.brake = true
	input.sprint_held = true
	input.elevation_level = 2
	input.block_held = true
	input.stick_lift_held = true
	input.quick_shot_pressed = true

	agent._zero_input(input, 1.0 / 120.0, 12.5)

	assert_eq(input.delta, 1.0 / 120.0, "delta is stamped")
	assert_eq(input.host_timestamp, 12.5, "host_timestamp is stamped")
	assert_eq(input.move_vector, Vector2.ZERO)
	assert_eq(input.mouse_world_pos, Vector3.ZERO)
	assert_eq(input.mouse_screen_pos, Vector2.ZERO)
	assert_false(input.shoot_pressed)
	assert_false(input.shoot_held)
	assert_false(input.slap_pressed)
	assert_false(input.slap_held)
	assert_false(input.brake)
	assert_false(input.sprint_held)
	assert_eq(input.elevation_level, 0)
	assert_false(input.block_held)
	assert_false(input.stick_lift_held)
	assert_false(input.quick_shot_pressed,
			"quick-shot edge must not latch across ticks in the reused scratch buffer")
