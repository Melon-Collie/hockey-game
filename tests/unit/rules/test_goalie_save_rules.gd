extends GutTest

# GoalieSaveRules — controlled-save classification + rebound deadening.

func _cfg() -> GoalieSaveRules.DeadenConfig:
	var cfg := GoalieSaveRules.DeadenConfig.new()
	cfg.pad_max_incoming_speed = 22.0
	cfg.drop_speed = 1.2
	cfg.glove_retain = 0.0
	cfg.chest_retain = 0.12
	cfg.pad_retain = 0.35
	cfg.blocker_retain = 0.45
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
	assert_true(GoalieSaveRules.is_controlled_save(22.0, GoalieSaveRules.SavePart.PAD, _cfg()))
	assert_false(GoalieSaveRules.is_controlled_save(28.0, GoalieSaveRules.SavePart.PAD, _cfg()))

func test_blocker_controlled_only_under_threshold() -> void:
	assert_true(GoalieSaveRules.is_controlled_save(15.0, GoalieSaveRules.SavePart.BLOCKER, _cfg()))
	assert_false(GoalieSaveRules.is_controlled_save(30.0, GoalieSaveRules.SavePart.BLOCKER, _cfg()))

# ── deadened_velocity ─────────────────────────────────────────────────────────

func test_glove_deadens_to_zero() -> void:
	# Glove retain 0 → the puck dies dead in the paint.
	var v := GoalieSaveRules.deadened_velocity(Vector3(10.0, 4.0, -18.0), GoalieSaveRules.SavePart.GLOVE, _cfg())
	assert_almost_eq(v.length(), 0.0, 0.0001)

func test_deaden_kills_goalward_and_vertical() -> void:
	# z (goalward) and y (vertical) are always zeroed so it can't trickle in or pop.
	var v := GoalieSaveRules.deadened_velocity(Vector3(2.0, 5.0, -20.0), GoalieSaveRules.SavePart.PAD, _cfg())
	assert_almost_eq(v.z, 0.0, 0.0001)
	assert_almost_eq(v.y, 0.0, 0.0001)

func test_deaden_retains_clamped_lateral() -> void:
	# Pad retain 0.35 of 2 m/s lateral = 0.7, under the 1.2 clamp → kept.
	var v := GoalieSaveRules.deadened_velocity(Vector3(2.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD, _cfg())
	assert_almost_eq(v.x, 0.7, 0.0001)

func test_deaden_clamps_lateral_to_drop_speed() -> void:
	# 0.35 of 20 m/s lateral = 7, clamped down to drop_speed 1.2 (sign preserved).
	var v := GoalieSaveRules.deadened_velocity(Vector3(-20.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD, _cfg())
	assert_almost_eq(v.x, -1.2, 0.0001)
