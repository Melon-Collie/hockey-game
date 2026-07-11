extends GutTest

# GoalieSaveRules — controlled-save classification + rebound deadening.

func _cfg() -> GoalieSaveRules.DeadenConfig:
	var cfg := GoalieSaveRules.DeadenConfig.new()
	cfg.pad_max_incoming_speed = 28.0
	cfg.drop_speed = 1.2
	cfg.glove_retain = 0.0
	cfg.chest_retain = 0.12
	cfg.pad_steer_speed = 5.0
	cfg.steer_lateral_weight = 1.0
	cfg.steer_forward_weight = 0.35
	return cfg

# ── is_controlled_save ────────────────────────────────────────────────────────

func test_stick_never_controlled() -> void:
	# Stick redirects — never a controlled/deadened save, at any speed.
	assert_false(GoalieSaveRules.is_controlled_save(3.0, GoalieSaveRules.SavePart.STICK, _cfg()))
	assert_false(GoalieSaveRules.is_controlled_save(30.0, GoalieSaveRules.SavePart.STICK, _cfg()))

func test_glove_controlled_at_any_speed() -> void:
	# A catch kills the puck regardless of how hard it was shot.
	assert_true(GoalieSaveRules.is_controlled_save(5.0, GoalieSaveRules.SavePart.GLOVE, _cfg()))
	assert_true(GoalieSaveRules.is_controlled_save(34.0, GoalieSaveRules.SavePart.GLOVE, _cfg()))

func test_chest_controlled_at_any_speed() -> void:
	assert_true(GoalieSaveRules.is_controlled_save(34.0, GoalieSaveRules.SavePart.CHEST, _cfg()))

func test_pad_controlled_only_under_threshold() -> void:
	# Easy pad save deadens; a hard shot beats the pad and kicks out a rebound.
	assert_true(GoalieSaveRules.is_controlled_save(12.0, GoalieSaveRules.SavePart.PAD, _cfg()))
	assert_true(GoalieSaveRules.is_controlled_save(28.0, GoalieSaveRules.SavePart.PAD, _cfg()))
	assert_false(GoalieSaveRules.is_controlled_save(34.0, GoalieSaveRules.SavePart.PAD, _cfg()))

func test_blocker_controlled_only_under_threshold() -> void:
	assert_true(GoalieSaveRules.is_controlled_save(15.0, GoalieSaveRules.SavePart.BLOCKER, _cfg()))
	assert_false(GoalieSaveRules.is_controlled_save(40.0, GoalieSaveRules.SavePart.BLOCKER, _cfg()))

# ── deadened_velocity ─────────────────────────────────────────────────────

func test_glove_deadens_to_zero() -> void:
	# Glove retain 0 → the puck dies dead in the paint (a catch, minus the hold).
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(10.0, 4.0, -18.0), GoalieSaveRules.SavePart.GLOVE, 1.0, 1, _cfg())
	assert_almost_eq(v.length(), 0.0, 0.0001)

func test_chest_absorb_kills_goalward_and_vertical() -> void:
	# Absorbing surfaces zero z (goalward) and y so the puck can't trickle in or pop.
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(2.0, 5.0, -20.0), GoalieSaveRules.SavePart.CHEST, 1.0, 1, _cfg())
	assert_almost_eq(v.z, 0.0, 0.0001)
	assert_almost_eq(v.y, 0.0, 0.0001)

func test_chest_retains_clamped_lateral() -> void:
	# Chest retain 0.12 of 2 m/s lateral = 0.24, under the 1.2 clamp → kept.
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(2.0, 0.0, -20.0), GoalieSaveRules.SavePart.CHEST, 1.0, 1, _cfg())
	assert_almost_eq(v.x, 0.24, 0.0001)

func test_chest_clamps_lateral_to_drop_speed() -> void:
	# 0.12 of 20 m/s lateral = 2.4, clamped down to drop_speed 1.2 (sign preserved).
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(-20.0, 0.0, -20.0), GoalieSaveRules.SavePart.CHEST, 1.0, 1, _cfg())
	assert_almost_eq(v.x, -1.2, 0.0001)

# Steered pad/blocker saves — modern active-rebound doctrine (audit F12):
# controlled pad saves fire the puck cornerward on the contact side, with an
# out-of-crease forward bias, never back up the slot and never dead in the paint.

func test_pad_save_steers_toward_contact_side_corner() -> void:
	# Puck arrived on the goalie's +x side, goalie defends the -Z goal
	# (direction_sign +1 → forward is +Z): exit goes +x and +z at steer speed.
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(-3.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD, 1.0, 1, _cfg())
	assert_gt(v.x, 0.0, "steered toward the contact-side corner")
	assert_gt(v.z, 0.0, "forward component pushes OUT of the crease")
	assert_almost_eq(v.y, 0.0, 0.0001)
	assert_almost_eq(v.length(), 5.0, 0.0001)

func test_pad_steer_is_mostly_lateral() -> void:
	# Cornerward means lateral-dominant — the rebound goes to the corner, not
	# back up the middle of the slot.
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(0.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD, -1.0, 1, _cfg())
	assert_gt(absf(v.x), absf(v.z), "lateral component dominates the exit")
	assert_lt(v.x, 0.0, "follows the contact side")

func test_blocker_save_steers_like_pad() -> void:
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(4.0, 1.0, -25.0), GoalieSaveRules.SavePart.BLOCKER, 1.0, 1, _cfg())
	assert_gt(v.x, 0.0)
	assert_almost_eq(v.length(), 5.0, 0.0001)

func test_pad_steer_falls_back_to_incoming_lateral_sign() -> void:
	# Degenerate contact side (dead-centre) → direction follows the incoming
	# lateral drift so the result stays deterministic.
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(-6.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD, 0.0, 1, _cfg())
	assert_lt(v.x, 0.0)

func test_pad_steer_forward_sign_flips_with_goal_side() -> void:
	# The +Z-defending goalie (direction_sign -1) steers out toward -Z.
	var v := GoalieSaveRules.deadened_velocity(
			Vector3(0.0, 0.0, 20.0), GoalieSaveRules.SavePart.PAD, 1.0, -1, _cfg())
	assert_lt(v.z, 0.0, "out-of-crease is -Z for the +Z goal")
