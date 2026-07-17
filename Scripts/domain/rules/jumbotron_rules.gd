class_name JumbotronRules

# Pure decision table for the arena jumbotron: which screen the board shows
# for a given game phase, plus the clock/period text formatting. The display
# side (Jumbotron actor) renders the mode; this stays engine-free so the
# what-shows-when logic is GUT-testable without a scene.

enum Mode { ATTRACT, LIVE, GOAL, BREAK, FINAL }


# `attract` = the board has no live game to show (the lobby backdrop pins
# this on, and a freshly built board stays attract until the first game
# signal arrives). Otherwise the phase decides: the GOAL screen spans the
# celebration AND the replay that follows it (spectator cams cut around
# during GOAL_SCORED, exactly when a real board holds the goal graphic).
static func screen_mode(phase: int, attract: bool) -> Mode:
	if attract:
		return Mode.ATTRACT
	match phase:
		GamePhase.Phase.GAME_OVER:
			return Mode.FINAL
		GamePhase.Phase.END_OF_PERIOD:
			return Mode.BREAK
		GamePhase.Phase.GOAL_CELEBRATION, GamePhase.Phase.GOAL_SCORED:
			return Mode.GOAL
		_:
			return Mode.LIVE


# Mirrors the HUD's clock format (ceil'd seconds as M:SS) so the board and
# the HUD never disagree on the displayed time.
static func clock_text(time_remaining: float) -> String:
	var secs: int = int(ceil(maxf(time_remaining, 0.0)))
	return "%d:%02d" % [secs / 60, secs % 60]


# Regulation is GameRules.NUM_PERIODS (3); anything past that is overtime.
# <= 0 guards the pre-sync default so a board never shows "OT" before the
# first period_synced lands.
static func period_text(period: int) -> String:
	if period <= 1:
		return "1ST"
	if period == 2:
		return "2ND"
	if period == 3:
		return "3RD"
	return "OT"
