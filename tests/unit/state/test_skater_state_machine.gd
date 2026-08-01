extends GutTest

# SkaterStateMachine.state_has_puck — the pure predicate that gates the committed-
# check split (a carrier can brace but can't deliver an offensive check). Locks
# which states count as "handling the puck" so the gate can't silently drift if the
# enum grows.

func test_carry_and_puck_windups_have_puck() -> void:
	assert_true(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.SKATING_WITH_PUCK),
			"carrying has the puck")
	assert_true(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.WRISTER_AIM),
			"wrister aim holds the puck")
	assert_true(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK),
			"slapper wind-up with the puck holds it")


func test_empty_handed_states_have_no_puck() -> void:
	assert_false(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.SKATING_WITHOUT_PUCK),
			"skating without the puck")
	assert_false(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK),
			"a one-timer wind-up does NOT hold the puck yet")
	assert_false(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.FOLLOW_THROUGH),
			"mid follow-through the puck is gone")
	assert_false(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.SHOT_BLOCKING),
			"a shot-blocker has no puck")
	assert_false(SkaterStateMachine.state_has_puck(SkaterStateMachine.State.ONE_TIMER_RETENTION),
			"the one-timer hold is reached from both wind-ups, so it cannot promise a puck")


# state_pins_puck — the goalie's threat tracking asks this to know when a
# position-derived puck velocity would double-count the carrier's own motion.
# The retention hold keeps the wind-up's rigid pin, so it belongs with them.
func test_pinning_states() -> void:
	assert_true(SkaterStateMachine.state_pins_puck(SkaterStateMachine.State.WRISTER_AIM),
			"the wrister freezes the blade at the shot origin")
	assert_true(SkaterStateMachine.state_pins_puck(SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK),
			"the slapper wind-up pins to a skater-local offset")
	assert_true(SkaterStateMachine.state_pins_puck(SkaterStateMachine.State.ONE_TIMER_RETENTION),
			"the one-timer hold keeps that same pin while the shaft loads")
	assert_false(SkaterStateMachine.state_pins_puck(SkaterStateMachine.State.SKATING_WITH_PUCK),
			"ordinary carry rides a live, sweeping blade")
	assert_false(SkaterStateMachine.state_pins_puck(SkaterStateMachine.State.FOLLOW_THROUGH),
			"mid follow-through there is nothing pinned")


# The wire packs shot_state into 3 bits, so the enum must stay within 8 values —
# a ninth silently truncates on decode and every peer reads a different pose.
func test_state_enum_fits_the_three_bit_wire_field() -> void:
	assert_eq(SkaterStateMachine.State.size(), 8,
			"shot_state has 3 bits in WorldStateCodec's skater flags byte")
	for value: int in SkaterStateMachine.State.values():
		assert_eq(value & 0x07, value,
				"State value %d survives the 3-bit mask" % value)
