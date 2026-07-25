extends GutTest

# ── THE MID-DROP PAD GAP ─────────────────────────────────────────────────────
# Reported from real play: the low glove-side goal is not the puck squeezing
# between set legs. It goes through the pads AS THEY ARE ROTATING DOWN — a pad
# swinging from vertical to flat neither blocks the standing lane nor seals the
# ice, so there is a window that exists only DURING the drop.
#
# Measured, and it is exactly that. Held 0.25 s windup, FLAT, 78 mph, dot line:
#
#    aim_x   drop@arrival   outcome   part
#   +0.10       0.12         save     STICK
#   +0.26       0.12         save     STICK
#   +0.30       0.50         GOAL      -     <- pad half-rotated
#   +0.34       0.50         GOAL      -
#   +0.42       0.50         GOAL      -
#   +0.50       0.21         save     PAD
#
# Every goal sits at drop_progress ~= 0.50, the pad exactly half way down. The
# saves either side are at 0.12-0.21, where it is still standing and blocks.
# The held windup is what opens it: the hold gives him time to COMMIT the drop,
# so the release arrives mid-rotation. Cold, he is either still standing or
# already sealed.
#
# This is beatable-realism working as intended — the grounded ~0.2 s butterfly
# drop is documented as the reason clean low shots beat a purely reactive
# goalie, and this is a human finding that counter.
#
# ── THE GAP IS ONE-SIDED, AND THAT IS CORRECT ────────────────────────────────
# Predicted from play before measuring: the blocker side does NOT leak the same
# way, because the stick rides up during the drop but stays on the ice longer,
# so it covers that gap. Measured across both sides:
#
#   BLOCKER  -0.50 .. -0.10   all STICK saves,  drop@end 0.12
#   GLOVE    +0.30 .. +0.42   GOAL,             drop@end 0.50
#
# The mechanism is in the drop column. Blocker-side saves all end at drop 0.12:
# the blade INTERCEPTS EARLY, before the rotation has gone anywhere, so the drop
# never becomes relevant. Glove side has nothing to meet the puck early, so it
# travels on while the pad rotates through 0.50 and slips under.
#
# So the keeper ALREADY HAS A WEAK SIDE, and it is the one a real goalie has:
# low glove side, during the drop, with the stick guarding the other. An earlier
# note on this branch proposed "give the stick a weak side" on the theory that it
# covered both sides symmetrically — that theory was wrong. The stick is properly
# one-sided; what looked symmetric was angle compression in tight funnelling
# every aim through its central band.
#
# THE MODEL GAP: AIActionScoring._pad_half_extent is a BINARY STEP —
# |sin(roll)| > 0.707 returns the splayed half-length, otherwise the narrow box
# half-width. There is no intermediate pad state, and the switch sits at 45 deg,
# which is precisely where drop_progress 0.5 puts the pad. So the planner flips
# from "narrow" to "wide" exactly across the window and can never see the leak.
# The bots cannot find the seam a human uses, because their pad model has no
# rotation, only two poses.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SLOT: float = GameRules.GOAL_LINE_Z - GameRules.ICING_FACEOFF_DOT_Z
const MPH: float = 78.0 * 0.44704
const PART := ["STICK", "PAD", "BLOCK", "CHEST", "GLOVE"]

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_h = Harness.new()
	_h.setup(_goalie, _puck, _ctrl, _shooter)


func test_drop_state_across_the_glove_window() -> void:
	var spot := Vector3(0.0, 0.0, GOAL_Z + SLOT)
	gut.p("HELD 0.25s, FLAT, 78 mph. drop_progress: 0 = standing, 1 = sealed.")
	gut.p(" aim_x  side     state@rel  drop@rel  drop@end  outcome  part")
	for a: float in [-0.50, -0.42, -0.38, -0.34, -0.30, -0.26, -0.20, -0.10,
			0.10, 0.20, 0.26, 0.30, 0.34, 0.38, 0.42, 0.50]:
		var aim := Vector3(a, 0.0, GOAL_Z)
		_ctrl.reset_to_crease()
		_h.settle(spot, 90)
		_h.hold_windup_at(spot, aim, ShotMechanics.ELEVATION_FLAT, MPH, 30)
		var st_rel: int = _ctrl._sm.current
		var dp_rel: float = _ctrl._slide.drop_progress
		var o: int = _h.fire_release_at(spot, aim, ShotMechanics.ELEVATION_FLAT, MPH, 0.0)
		var side: String = "BLOCKER" if a < 0.0 else "GLOVE  "
		gut.p("%+5.2f %s  %-9s  %6.2f    %6.2f    %-6s  %s"
				% [a, side, GoalieStateMachine.State.keys()[st_rel], dp_rel,
				_ctrl._slide.drop_progress,
				"GOAL" if o == Harness.GOAL else "save",
				PART[_h.last_part] if _h.last_part >= 0 else "-"])
	assert_true(true)
