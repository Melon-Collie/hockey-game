extends GutTest

# JumbotronRules — the pure what-shows-when table plus the clock/period text
# formatting the board shares with the HUD's conventions.


func test_attract_overrides_every_phase() -> void:
	for phase: int in GamePhase.Phase.values():
		assert_eq(JumbotronRules.screen_mode(phase, true),
				JumbotronRules.Mode.ATTRACT,
				"attract lock should win in phase %d" % phase)


func test_phase_mode_table() -> void:
	var expected: Dictionary = {
		GamePhase.Phase.PLAYING: JumbotronRules.Mode.LIVE,
		GamePhase.Phase.FACEOFF_PREP: JumbotronRules.Mode.LIVE,
		GamePhase.Phase.FACEOFF: JumbotronRules.Mode.LIVE,
		GamePhase.Phase.GOAL_CELEBRATION: JumbotronRules.Mode.GOAL,
		GamePhase.Phase.GOAL_SCORED: JumbotronRules.Mode.GOAL,
		GamePhase.Phase.END_OF_PERIOD: JumbotronRules.Mode.BREAK,
		GamePhase.Phase.GAME_OVER: JumbotronRules.Mode.FINAL,
	}
	for phase: int in expected:
		assert_eq(JumbotronRules.screen_mode(phase, false), expected[phase],
				"wrong mode for phase %d" % phase)


func test_clock_text_matches_hud_format() -> void:
	assert_eq(JumbotronRules.clock_text(0.0), "0:00")
	assert_eq(JumbotronRules.clock_text(125.0), "2:05")
	assert_eq(JumbotronRules.clock_text(240.0), "4:00")
	# Ceil'd like the HUD: 59.2 s displays as 1:00, not 0:59.
	assert_eq(JumbotronRules.clock_text(59.2), "1:00")
	assert_eq(JumbotronRules.clock_text(-3.0), "0:00")


func test_period_text() -> void:
	assert_eq(JumbotronRules.period_text(1), "1ST")
	assert_eq(JumbotronRules.period_text(2), "2ND")
	assert_eq(JumbotronRules.period_text(3), "3RD")
	assert_eq(JumbotronRules.period_text(4), "OT")
	assert_eq(JumbotronRules.period_text(7), "OT")
	# Pre-sync default (0) must not read as overtime.
	assert_eq(JumbotronRules.period_text(0), "1ST")
