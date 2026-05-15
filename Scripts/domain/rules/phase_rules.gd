class_name PhaseRules

# Pure rules about game phases — which phases suppress movement, which are
# "dead puck" (cosmetic freeze / position reset). Extracted from GameManager
# so controllers and tests can ask these questions without reaching into
# the orchestrator.

# Phases during which player movement and input are suppressed.
static func is_dead_puck_phase(phase: GamePhase.Phase) -> bool:
	return (phase == GamePhase.Phase.GOAL_SCORED
		or phase == GamePhase.Phase.FACEOFF_PREP
		or phase == GamePhase.Phase.END_OF_PERIOD
		or phase == GamePhase.Phase.GAME_OVER)

# Convenience: same as is_dead_puck_phase for the given phase.
static func is_movement_locked(phase: GamePhase.Phase) -> bool:
	return is_dead_puck_phase(phase)

# True for phases where body translation is locked but the player should still
# be able to angle their stick via mouse — today that's FACEOFF_PREP, so
# centers can pre-aim the draw during the countdown. Goal celebration and
# end-of-period keep stick frozen for stillness.
static func allows_blade_aim_during_lock(phase: GamePhase.Phase) -> bool:
	return phase == GamePhase.Phase.FACEOFF_PREP
