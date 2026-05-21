extends GutTest

# GoalieStateMachine — owns the current state enum + recovery timer. Tiny
# wrapper; tests cover transition_to behavior and helper queries.

var sm: GoalieStateMachine

func before_each() -> void:
	sm = GoalieStateMachine.new()

func test_initial_state_is_standing() -> void:
	assert_eq(sm.current, GoalieStateMachine.State.STANDING)
	assert_eq(sm.recovery_timer, 0.0)

func test_is_upright_for_standing() -> void:
	assert_true(sm.is_upright())

func test_is_upright_for_ready() -> void:
	sm.current = GoalieStateMachine.State.READY
	assert_true(sm.is_upright())

func test_is_upright_false_for_recovering() -> void:
	sm.current = GoalieStateMachine.State.RECOVERING
	assert_false(sm.is_upright(), "RECOVERING is the vulnerable stand-up window; not upright")

func test_is_upright_false_for_butterfly() -> void:
	sm.current = GoalieStateMachine.State.BUTTERFLY
	assert_false(sm.is_upright())

func test_is_butterfly() -> void:
	assert_false(sm.is_butterfly())
	sm.current = GoalieStateMachine.State.BUTTERFLY
	assert_true(sm.is_butterfly())

func test_is_rvh() -> void:
	assert_false(sm.is_rvh())
	sm.current = GoalieStateMachine.State.RVH_LEFT
	assert_true(sm.is_rvh())
	sm.current = GoalieStateMachine.State.RVH_RIGHT
	assert_true(sm.is_rvh())

func test_transition_to_changes_state() -> void:
	var changed: bool = sm.transition_to(GoalieStateMachine.State.READY)
	assert_true(changed)
	assert_eq(sm.current, GoalieStateMachine.State.READY)

func test_transition_to_same_state_is_no_op() -> void:
	var changed: bool = sm.transition_to(GoalieStateMachine.State.STANDING)
	assert_false(changed, "no-op transition returns false")

# Signal emission — `transitioned` only fires when state actually changes.
func test_transition_to_emits_signal() -> void:
	watch_signals(sm)
	sm.transition_to(GoalieStateMachine.State.BUTTERFLY)
	assert_signal_emitted_with_parameters(
			sm, "transitioned",
			[GoalieStateMachine.State.STANDING, GoalieStateMachine.State.BUTTERFLY])

func test_transition_to_same_state_does_not_emit() -> void:
	watch_signals(sm)
	sm.transition_to(GoalieStateMachine.State.STANDING)
	assert_signal_not_emitted(sm, "transitioned")

func test_reset_returns_to_standing() -> void:
	sm.current = GoalieStateMachine.State.BUTTERFLY
	sm.recovery_timer = 1.0
	sm.reset()
	assert_eq(sm.current, GoalieStateMachine.State.STANDING)
	assert_eq(sm.recovery_timer, 0.0)

# Reset is a hard reset — explicitly does NOT fire the signal so listeners
# don't churn on game-state resets (faceoffs, period start, etc.).
func test_reset_does_not_emit_signal() -> void:
	sm.current = GoalieStateMachine.State.BUTTERFLY
	watch_signals(sm)
	sm.reset()
	assert_signal_not_emitted(sm, "transitioned")

# Enum integer values are duplicated as constants in
# `domain/ai/role_behaviors/carrier.gd`. If these break, that file's constants
# need updating too (it can't import controllers).
func test_enum_int_values_match_carrier_constants() -> void:
	assert_eq(GoalieStateMachine.State.STANDING as int, 0)
	assert_eq(GoalieStateMachine.State.BUTTERFLY as int, 1)
	assert_eq(GoalieStateMachine.State.RECOVERING as int, 2)
	assert_eq(GoalieStateMachine.State.RVH_LEFT as int, 3)
	assert_eq(GoalieStateMachine.State.RVH_RIGHT as int, 4)
	assert_eq(GoalieStateMachine.State.READY as int, 5)
	assert_eq(GoalieStateMachine.State.SLIDING as int, 6)
