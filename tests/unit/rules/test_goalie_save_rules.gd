extends GutTest

# GoalieSaveRules — the puck's rebound off a goalie surface, and the one save
# outcome that is not a rebound.

const FACING := Vector3(0.0, 0.0, 1.0)      # he faces +Z
const SQUARE_N := Vector3(0.0, 0.0, 1.0)    # a face pointing back at the shooter


func _res() -> GoalieSaveRules.ContactResult:
	return GoalieSaveRules.ContactResult.new()


func _square(part: int, speed: float) -> Vector3:
	return GoalieSaveRules.rebound_velocity(Vector3(0.0, 0.0, -speed), part, SQUARE_N)

# ── rebound_velocity: the contact ────────────────────────────────────────────

func test_a_square_hit_comes_straight_back_off_the_face() -> void:
	var v: Vector3 = _square(GoalieSaveRules.SavePart.PAD, 20.0)
	assert_gt(v.z, 0.0, "reversed out along the face normal")
	assert_almost_eq(v.x, 0.0, 0.0001, "nothing lateral appears from nowhere")
	assert_almost_eq(v.y, 0.0, 0.0001)
	assert_lt(v.length(), 20.0, "and it lost energy doing it")


func test_a_separating_puck_is_left_alone() -> void:
	# Re-testing a puck already ejected off a face must not reflect it again.
	var out := Vector3(0.0, 0.0, 6.0)
	var v: Vector3 = GoalieSaveRules.rebound_velocity(
			out, GoalieSaveRules.SavePart.PAD, SQUARE_N)
	assert_eq(v, out)


func test_the_vertical_channel_survives_the_contact() -> void:
	# The goalie's faces are tilted and his body is tall, so a rebound has to be
	# able to leave the ice. deflect_velocity (the blade's) is horizontal-only and
	# would flatten this.
	var v: Vector3 = GoalieSaveRules.rebound_velocity(
			Vector3(0.0, 3.0, -20.0), GoalieSaveRules.SavePart.PAD, SQUARE_N)
	assert_gt(v.y, 0.0, "a puck rising into the pad keeps rising off it")


func test_a_tilted_face_sends_the_puck_where_it_points() -> void:
	# The whole reason this is a contact: WHERE the rebound goes is the surface's
	# orientation, which is the pose's job, not a steering constant's.
	var canted := Vector3(1.0, 0.0, 1.0).normalized()
	var v: Vector3 = GoalieSaveRules.rebound_velocity(
			Vector3(0.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD, canted)
	assert_gt(v.x, 0.0, "a pad canted to the corner sends it to that corner")


func test_an_unknown_part_falls_back_inside_the_table() -> void:
	# Puck._classify_save_part defaults unclassified bodies to PAD; a part index
	# off the end must not index out of MATERIALS.
	var v: Vector3 = GoalieSaveRules.rebound_velocity(
			Vector3(0.0, 0.0, -20.0), 99, SQUARE_N)
	assert_gt(v.z, 0.0)
	assert_lt(v.length(), 20.0)

# ── The material table ───────────────────────────────────────────────────────

func test_surfaces_rank_stiffest_to_softest() -> void:
	var stick: float = _square(GoalieSaveRules.SavePart.STICK, 20.0).length()
	var blocker: float = _square(GoalieSaveRules.SavePart.BLOCKER, 20.0).length()
	var pad: float = _square(GoalieSaveRules.SavePart.PAD, 20.0).length()
	var glove: float = _square(GoalieSaveRules.SavePart.GLOVE, 20.0).length()
	var chest: float = _square(GoalieSaveRules.SavePart.CHEST, 20.0).length()
	assert_gt(stick, blocker)
	assert_gt(blocker, pad)
	assert_gt(pad, chest)
	assert_gt(chest, glove, "an unclosed glove is the softest thing on him")


func test_the_table_covers_every_save_part() -> void:
	# MATERIALS is indexed by the enum, so a part added without a row would read
	# another surface's numbers — or run off the end.
	assert_eq(GoalieSaveRules.MATERIALS.size(),
			GoalieSaveRules.SavePart.size() * GoalieSaveRules.MAT_STRIDE,
			"one row per SavePart")


func test_every_row_deadens_rather_than_amplifies() -> void:
	# A goalie surface can never hand the puck more than it arrived with, at any
	# speed. A restitution over 1.0 in the table would do exactly that.
	for part: int in GoalieSaveRules.SavePart.size():
		for speed: float in [2.0, 12.0, 26.0, 40.0]:
			assert_lt(_square(part, speed).length(), speed,
					"part %d at %.0f m/s leaves slower than it arrived" % [part, speed])


func test_a_harder_shot_keeps_a_smaller_share_but_leaves_faster() -> void:
	var soft: float = _square(GoalieSaveRules.SavePart.PAD, 8.0).length()
	var hard: float = _square(GoalieSaveRules.SavePart.PAD, 34.0).length()
	assert_lt(hard / 34.0, soft / 8.0, "COR falls as the impact hardens")
	assert_gt(hard, soft, "but the absolute rebound still grows with the shot")

# ── resolve_contact ──────────────────────────────────────────────────────────

func test_a_glove_he_is_facing_is_a_catch() -> void:
	var r := _res()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, -25.0), GoalieSaveRules.SavePart.GLOVE,
			SQUARE_N, r, FACING)
	assert_true(r.caught, "he closed his hand on it")
	assert_eq(r.velocity, Vector3.ZERO, "held, not drifting out of the glove")


func test_a_glove_struck_from_behind_is_leather_not_a_catch() -> void:
	# You cannot catch what you are not looking at — and the back of a glove is
	# just a material.
	var r := _res()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, -25.0), GoalieSaveRules.SavePart.GLOVE,
			Vector3(0.0, 0.0, -1.0), r, Vector3(0.0, 0.0, 1.0))
	assert_false(r.caught)
	assert_gt(r.velocity.length(), 0.0, "it bounced off the leather")


func test_a_side_on_glove_contact_is_not_a_catch() -> void:
	# Threshold-free: exactly side-on is not presented, and you cannot catch with
	# the edge of your hand.
	var r := _res()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, -20.0), GoalieSaveRules.SavePart.GLOVE,
			Vector3(1.0, 0.0, 0.0), r, FACING)
	assert_false(r.caught)


func test_only_the_glove_ever_ends_the_play() -> void:
	for part: int in GoalieSaveRules.SavePart.size():
		if part == GoalieSaveRules.SavePart.GLOVE:
			continue
		var r := _res()
		GoalieSaveRules.resolve_contact(
				Vector3(0.0, 0.0, -12.0), part, SQUARE_N, r, FACING)
		assert_false(r.caught, "part %d rebounds, it does not hold" % part)
		assert_gt(r.velocity.length(), 0.0, "part %d leaves the puck live" % part)


func test_no_facing_supplied_lets_every_face_present() -> void:
	# Callers with no facing to offer (fixtures) get the permissive read rather
	# than a silent no-catch.
	var r := _res()
	GoalieSaveRules.resolve_contact(
			Vector3(0.0, 0.0, -20.0), GoalieSaveRules.SavePart.GLOVE,
			SQUARE_N, r, Vector3.ZERO)
	assert_true(r.caught)


func test_resolve_contact_matches_rebound_velocity_for_every_non_catch() -> void:
	# resolve_contact must not have a second opinion about the physics.
	var incoming := Vector3(4.0, 1.0, -18.0)
	var n := Vector3(0.2, 0.3, 0.9).normalized()
	for part: int in [GoalieSaveRules.SavePart.STICK, GoalieSaveRules.SavePart.PAD,
			GoalieSaveRules.SavePart.BLOCKER, GoalieSaveRules.SavePart.CHEST]:
		var r := _res()
		GoalieSaveRules.resolve_contact(incoming, part, n, r, FACING)
		assert_almost_eq(
				r.velocity.distance_to(
						GoalieSaveRules.rebound_velocity(incoming, part, n)),
				0.0, 0.0001, "part %d" % part)

# ── is_face_presented ────────────────────────────────────────────────────────

func test_face_presented_reads_facing_not_the_net() -> void:
	# A goalie turned to play a wraparound presents the surface nearest his own
	# goal; what he can catch is what he is looking at.
	var turned := Vector3(1.0, 0.0, 0.0)
	assert_true(GoalieSaveRules.is_face_presented(Vector3(1.0, 0.0, 0.0), turned))
	assert_false(GoalieSaveRules.is_face_presented(Vector3(-1.0, 0.0, 0.0), turned))


func test_face_presented_ignores_the_vertical() -> void:
	# Facing is a heading. A straight-up normal is neither front nor back, so it
	# is not presented.
	assert_false(GoalieSaveRules.is_face_presented(
			Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0)))
