class_name GamePhase

# Domain enum for the game's phase FSM. Lives in the domain layer so rules and
# the eventual GameStateMachine can reference it without going through
# GameManager.
#
# Usage: `GamePhase.Phase.PLAYING` from anywhere in the project.

enum Phase {
	PLAYING,           # normal gameplay
	GOAL_SCORED,       # dead puck, replay cinematic plays here
	FACEOFF_PREP,      # players teleporting, puck resetting
	FACEOFF,           # puck live at center, waiting for pickup or timeout
	END_OF_PERIOD,     # clock hit zero; brief pause before next-period faceoff
	GAME_OVER,         # all periods done; locked until manual reset
	GOAL_CELEBRATION,  # post-goal beat between PLAYING and GOAL_SCORED — movement
	                   # allowed (NOT in dead-puck phase), puck pickup-locked, top
	                   # banner + VFX play. Auto-advances to GOAL_SCORED after
	                   # GameRules.GOAL_CELEBRATION_DURATION; replay starts then.
	                   # Ordinal 6 (added at end) so existing serialized phases
	                   # in .mreplay files stay valid.
}
