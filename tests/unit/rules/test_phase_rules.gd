extends GutTest

# PhaseRules — pure static functions classifying game phases. Dead-puck phases
# are ones where player movement should be frozen (score pause, faceoff prep).

func test_playing_is_not_dead_puck() -> void:
	assert_false(PhaseRules.is_dead_puck_phase(GamePhase.Phase.PLAYING))

func test_faceoff_is_not_dead_puck() -> void:
	assert_false(PhaseRules.is_dead_puck_phase(GamePhase.Phase.FACEOFF))

func test_goal_scored_is_dead_puck() -> void:
	assert_true(PhaseRules.is_dead_puck_phase(GamePhase.Phase.GOAL_SCORED))

func test_faceoff_prep_is_dead_puck() -> void:
	assert_true(PhaseRules.is_dead_puck_phase(GamePhase.Phase.FACEOFF_PREP))

func test_end_of_period_is_dead_puck() -> void:
	assert_true(PhaseRules.is_dead_puck_phase(GamePhase.Phase.END_OF_PERIOD))

func test_game_over_is_dead_puck() -> void:
	assert_true(PhaseRules.is_dead_puck_phase(GamePhase.Phase.GAME_OVER))

func test_goal_celebration_is_not_dead_puck() -> void:
	# Celebration is the post-goal beat where players still skate around — only
	# the GOAL_SCORED replay phase that follows is movement-locked.
	assert_false(PhaseRules.is_dead_puck_phase(GamePhase.Phase.GOAL_CELEBRATION))

func test_movement_locked_matches_dead_puck() -> void:
	for phase in [
		GamePhase.Phase.PLAYING,
		GamePhase.Phase.GOAL_SCORED,
		GamePhase.Phase.FACEOFF_PREP,
		GamePhase.Phase.FACEOFF,
		GamePhase.Phase.END_OF_PERIOD,
		GamePhase.Phase.GAME_OVER,
		GamePhase.Phase.GOAL_CELEBRATION,
	]:
		assert_eq(
			PhaseRules.is_movement_locked(phase),
			PhaseRules.is_dead_puck_phase(phase),
			"is_movement_locked should match is_dead_puck_phase for phase %d" % phase)

# ── is_puck_pickup_locked_phase ─────────────────────────────────────────────
# Superset of is_dead_puck_phase that adds GOAL_CELEBRATION. The puck sits in
# the net during celebration with pickup_locked = true even though players are
# still free to skate; the codec uses this to decide pickup_locked on clients.

func test_pickup_locked_includes_all_dead_puck_phases() -> void:
	for phase in [
		GamePhase.Phase.GOAL_SCORED,
		GamePhase.Phase.FACEOFF_PREP,
		GamePhase.Phase.END_OF_PERIOD,
		GamePhase.Phase.GAME_OVER,
	]:
		assert_true(PhaseRules.is_puck_pickup_locked_phase(phase),
			"dead-puck phase %d should also be pickup-locked" % phase)

func test_pickup_locked_includes_goal_celebration() -> void:
	assert_true(PhaseRules.is_puck_pickup_locked_phase(GamePhase.Phase.GOAL_CELEBRATION))

func test_pickup_unlocked_during_active_play() -> void:
	assert_false(PhaseRules.is_puck_pickup_locked_phase(GamePhase.Phase.PLAYING))
	assert_false(PhaseRules.is_puck_pickup_locked_phase(GamePhase.Phase.FACEOFF))

# ── allows_blade_aim_during_lock ────────────────────────────────────────────
# Stick aim stays live only during FACEOFF_PREP so centers can pre-angle the
# draw during the countdown. Every other locked phase keeps sticks frozen.

func test_faceoff_prep_allows_blade_aim() -> void:
	assert_true(PhaseRules.allows_blade_aim_during_lock(GamePhase.Phase.FACEOFF_PREP))

func test_goal_scored_does_not_allow_blade_aim() -> void:
	assert_false(PhaseRules.allows_blade_aim_during_lock(GamePhase.Phase.GOAL_SCORED))

func test_end_of_period_does_not_allow_blade_aim() -> void:
	assert_false(PhaseRules.allows_blade_aim_during_lock(GamePhase.Phase.END_OF_PERIOD))

func test_game_over_does_not_allow_blade_aim() -> void:
	assert_false(PhaseRules.allows_blade_aim_during_lock(GamePhase.Phase.GAME_OVER))
