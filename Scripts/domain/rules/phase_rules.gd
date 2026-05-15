class_name PhaseRules

# Pure rules about game phases — which phases suppress movement, which are
# "dead puck" (cosmetic freeze / position reset). Extracted from GameManager
# so controllers and tests can ask these questions without reaching into
# the orchestrator.

# Phases during which player movement and input are suppressed.
# GOAL_CELEBRATION is deliberately NOT in this list — it's the post-goal beat
# where players can still skate around, even though the puck is dead.
static func is_dead_puck_phase(phase: GamePhase.Phase) -> bool:
	return (phase == GamePhase.Phase.GOAL_SCORED
		or phase == GamePhase.Phase.FACEOFF_PREP
		or phase == GamePhase.Phase.END_OF_PERIOD
		or phase == GamePhase.Phase.GAME_OVER)

# Convenience: same as is_dead_puck_phase for the given phase.
static func is_movement_locked(phase: GamePhase.Phase) -> bool:
	return is_dead_puck_phase(phase)

# Phases during which a loose puck cannot be picked up. Superset of
# is_dead_puck_phase that adds GOAL_CELEBRATION (movement allowed, but the
# puck sits in the net with pickup_locked = true until the replay starts).
static func is_puck_pickup_locked_phase(phase: GamePhase.Phase) -> bool:
	return is_dead_puck_phase(phase) or phase == GamePhase.Phase.GOAL_CELEBRATION
