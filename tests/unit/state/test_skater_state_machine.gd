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
