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


# ── resolve_contact: the whole-contact core the analytic goalie path calls ──

func test_resolve_contact_controlled_pad_steers_and_flags_deadened() -> void:
	# A medium pad save (under pad_max_incoming_speed) steers cornerward and is flagged
	# controlled, not a live rebound.
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(3.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD,
			Vector3(0, 0, 1), 1.0, 1, _cfg(), res)
	assert_true(res.deadened, "medium pad save is controlled")
	assert_false(res.caught)
	assert_almost_eq(res.velocity.length(), 5.0, 0.001, "steered at pad_steer_speed")


func test_resolve_contact_glove_catches() -> void:
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(2.0, 1.0, -30.0), GoalieSaveRules.SavePart.GLOVE,
			Vector3(0, 0, 1), 1.0, 1, _cfg(), res)
	assert_true(res.deadened)
	assert_true(res.caught, "a glove save is a catch (freezes the play)")
	assert_almost_eq(res.velocity.z, 0.0, 0.001, "caught puck killed")


func test_resolve_contact_hard_pad_kicks_a_live_rebound() -> void:
	# Above pad_max_incoming_speed the pad is beaten: a live rebound reflecting off the
	# contact face with PAD_RESTITUTION, not a steer.
	var res := GoalieSaveRules.ContactResult.new()
	var incoming := Vector3(0, 0, -40.0)  # hard, straight in; normal faces +z (toward puck)
	GoalieSaveRules.resolve_contact(
			incoming, GoalieSaveRules.SavePart.PAD, Vector3(0, 0, 1), 0.0, 1, _cfg(), res)
	assert_false(res.deadened, "hard shot beats the pad — live rebound")
	assert_false(res.caught)
	assert_gt(res.velocity.z, 0.0, "kicked back out")
	assert_almost_eq(res.velocity.z, 40.0 * GoalieSaveRules.PAD_RESTITUTION, 0.01,
			"rebounds at PAD_RESTITUTION (0.2)")


func test_resolve_contact_stick_is_always_a_live_redirect() -> void:
	# The stick never deadens, even on a slow puck — it redirects live at STICK_RESTITUTION.
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(0, 0, -10.0), GoalieSaveRules.SavePart.STICK, Vector3(0, 0, 1), 0.0, 1, _cfg(), res)
	assert_false(res.deadened, "stick is always live")
	assert_almost_eq(res.velocity.z, 10.0 * GoalieSaveRules.STICK_RESTITUTION, 0.01,
			"redirects at STICK_RESTITUTION (0.4)")


# ── Presented face: he has to be FACING it to absorb it (#556) ───────────────
# `contact_normal` points outward from his surface toward the puck, so a normal
# aligned with his facing was struck on the front and one opposed to it on the
# back. FACING, not the net — a goalie tracking a wraparound is turned, and the
# surface nearest his own goal can be the one his chest is pointed at.
# Local -Z is forward for the rig, so a goalie facing up-ice at the -Z net has
# world forward +z.

const FACING_UPICE := Vector3(0, 0, 1)


func test_a_shot_into_his_back_does_not_deaden() -> void:
	# The reported bug. The torso classifies as CHEST from any direction, so a
	# puck onto his back used to be absorbed dead — stopping on his spine instead
	# of caroming. He never saw it; it is not a save he made.
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, 12.0), GoalieSaveRules.SavePart.CHEST,
			Vector3(0, 0, -1), 0.0, 1, _cfg(), res, FACING_UPICE)
	assert_false(res.deadened, "a puck off his back is a carom, not a chest save")
	assert_false(res.caught)
	assert_gt(res.velocity.length(), 1.0, "and it keeps real pace, rather than dying")


func test_a_shot_into_his_chest_still_deadens() -> void:
	# The guard on the above: the real chest absorb must survive untouched.
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, -30.0), GoalieSaveRules.SavePart.CHEST,
			Vector3(0, 0, 1), 0.0, 1, _cfg(), res, FACING_UPICE)
	assert_true(res.deadened, "front-on chest contact absorbs, as it always did")


func test_a_glove_struck_from_behind_is_not_a_catch() -> void:
	# A catch freezes the play, so a back-side glove contact granting one is the
	# most expensive version of this bug.
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, 15.0), GoalieSaveRules.SavePart.GLOVE,
			Vector3(0, 0, -1), 1.0, 1, _cfg(), res, FACING_UPICE)
	assert_false(res.caught, "he cannot catch what he is not facing")
	assert_false(res.deadened)


func test_a_pad_struck_from_behind_is_not_steered_out() -> void:
	# The pad steer fires the puck cornerward with an out-of-crease bias off
	# `direction_sign` alone, so a back-struck pad used to invent a save out of
	# geometry — pushing the puck away from the net whichever way it was going.
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, 8.0), GoalieSaveRules.SavePart.PAD,
			Vector3(0, 0, -1), 1.0, 1, _cfg(), res, FACING_UPICE)
	assert_false(res.deadened, "no cornerward steer off the back of a pad")
	assert_almost_eq(res.velocity.length(), 8.0 * GoalieSaveRules.PAD_RESTITUTION,
			0.01, "it reflects at PAD_RESTITUTION like any other live carom")


func test_a_turned_goalie_absorbs_what_he_is_looking_at() -> void:
	# The case that made "facing" the right test rather than "play side". He has
	# rotated to play a puck behind his net, so his chest points at his own goal
	# line. A puck into that chest is a real smother even though the normal points
	# the "wrong" way relative to the rink.
	var facing_own_goal := Vector3(0, 0, -1)
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, 20.0), GoalieSaveRules.SavePart.CHEST,
			Vector3(0, 0, -1), 0.0, 1, _cfg(), res, facing_own_goal)
	assert_true(res.deadened, "turned toward it, that IS his chest")
	# ...and the same contact with him facing up-ice is his back.
	var res2 := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, 20.0), GoalieSaveRules.SavePart.CHEST,
			Vector3(0, 0, -1), 0.0, 1, _cfg(), res2, FACING_UPICE)
	assert_false(res2.deadened, "same contact, turned away — a carom")


func test_a_side_on_contact_is_not_a_controlled_save() -> void:
	# Exactly perpendicular to his facing — his shoulder. You cannot smother with
	# a shoulder.
	var res := GoalieSaveRules.ContactResult.new()
	GoalieSaveRules.resolve_contact(
			Vector3(-20.0, 0.0, 0.0), GoalieSaveRules.SavePart.CHEST,
			Vector3(1, 0, 0), 1.0, 1, _cfg(), res, FACING_UPICE)
	assert_false(res.deadened, "side-on is a carom")


func test_no_facing_supplied_keeps_the_old_behaviour() -> void:
	# The parameter defaults to zero for callers that have no facing to offer, and
	# a zero facing must not silently disable every controlled save.
	assert_true(GoalieSaveRules.is_face_presented(Vector3(0, 0, -1), Vector3.ZERO))
	assert_true(GoalieSaveRules.is_face_presented(Vector3(0, 0, 1), FACING_UPICE))
	assert_false(GoalieSaveRules.is_face_presented(Vector3(0, 0, -1), FACING_UPICE))


func test_resolve_contact_live_glance_keeps_tangential_pace() -> void:
	# A hard puck glancing off the pad at an angle keeps its along-face pace (a live rebound
	# to the corner, not a dead stop).
	var res := GoalieSaveRules.ContactResult.new()
	# Mostly lateral travel (+x), small into-face component (-z); normal +z.
	GoalieSaveRules.resolve_contact(
			Vector3(30.0, 0.0, -6.0), GoalieSaveRules.SavePart.PAD, Vector3(0, 0, 1), 1.0, 1, _cfg(), res)
	assert_gt(res.velocity.x, 25.0, "tangential pace largely retained on a glance")
