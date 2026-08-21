extends GutTest

# ── DOES A SMOTHERED PUCK STILL FIND HIS OWN STICK? ──────────────────────────
# A chest save is a two-beat sequence: he kills the shot against his body, the
# puck goes down in front of him, and the crease sweep clears it. The first beat
# used to break the second. Ejecting the trapped puck flush off the chest
# dropped it from chest height through his own equipment, and it landed on the
# paddle — the stiffest surface on him — which threw it back out at pace and,
# often enough to notice, into his own net. The fix was to stop simulating the
# fall at all: a goalie holding a puck against his body PLACES it on the ice, so
# the trapped branch sets the position as well as the velocity
# (GoalieSaveRules.ContactResult.trapped, honoured in Puck._drive_analytic).
#
# THIS IS A TEST BECAUSE THE FIX IS NOT SELF-EVIDENTLY SAFE, and it got less so.
# Placing the puck on the ice at the chest's own XZ puts it exactly where the
# blade now lives: the blade used to float 12 cm up and sit 0.40 m past the pads,
# and it is now ON the ice and 0.35 m out, sweeping through the space a trapped
# puck is placed into and then drifts across at CHEST_TRAP_DROP_M_S. So the
# geometry that made the old bug is back, on a different surface, and only a
# live run can say whether it bites.
#
# WHAT IT MEASURES: of 40 smothers across the spread, 16 DO go on to touch the
# stick and 15 the pad — so the answer to "does it still find his own equipment"
# is yes, about four times in ten. None of them went in, and all 40 were swept
# away. That is the distinction the assertions draw, because it is the one that
# matters: a trapped puck is PLACED at CHEST_TRAP_DROP_M_S rather than arriving
# under gravity with the 2 m/s it used to pick up, and a blade meeting a puck at
# a walking pace is a keeper's stick doing its job. The old bug was never the
# contact, it was the speed the fall gave it.
#
# The tracked window runs from the smother until the puck leaves the crease area
# or 2.5 s, and the harness returns GOAL the instant it crosses the line, so an
# own goal anywhere in the two-beat sequence is caught. What happens to a puck
# after it has been swept clear is out of scope and is not this bug.
const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const MPH_TO_MS: float = 0.44704
const SETTLE_TICKS: int = 90
# Chest saves come from shots ARRIVING at his torso, so the sweep is over lofts
# and speeds rather than aim: a flat puck goes to the pads whatever you do.
# Spots, not aims, are what feed this: a chest save needs a shot ARRIVING at his
# torso, which is set by range and angle. Widening the aim fractions added pad
# and stick saves and no chest ones at all.
const SPOTS: Array[Vector3] = [
	Vector3(0.0, 0.0, 3.0),
	Vector3(0.0, 0.0, 4.5),
	Vector3(0.0, 0.0, 6.4),
	Vector3(0.0, 0.0, 10.0),
	Vector3(3.0, 0.0, 7.0),
	Vector3(-3.0, 0.0, 7.0),
	Vector3(5.5, 0.0, 8.0),
	Vector3(-5.5, 0.0, 8.0),
]
const MPH: Array[float] = [65.0, 75.0, 85.0]
const AIM_FRACTIONS: Array[float] = [-1.0, -0.5, 0.0, 0.5, 1.0]

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null
static var _part_names: Array = GoalieSaveRules.SavePart.keys()


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
	_shooter.set_physics_process(false)


func test_a_smothered_puck_never_comes_back_off_his_own_equipment() -> void:
	var max_aim: float = GameRules.NET_HALF_WIDTH \
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_MID,
		ShotMechanics.ELEVATION_HIGH,
	]
	var chest_saves: int = 0
	var then_stick: int = 0
	var then_pad: int = 0
	var own_goals: int = 0
	var swept: int = 0
	var by_first: Dictionary = {}
	for spot: Vector3 in SPOTS:
		var from := Vector3(spot.x, 0.0, GOAL_Z + spot.z)
		for loft: int in lofts:
			for frac: float in AIM_FRACTIONS:
				for mph: float in MPH:
					_ctrl.reset_to_crease()
					_h.settle(from, SETTLE_TICKS)
					var o: int = _h.fire_tracking_rebound(
							from, Vector3(frac * max_aim, 0.0, GOAL_Z), loft,
							mph * MPH_TO_MS, 0.0)
					if o != Harness.SAVE:
						continue
					var fk: String = _part_names[_h.last_part] if _h.last_part >= 0 else "?"
					by_first[fk] = int(by_first.get(fk, 0)) + 1
					if _h.last_part != GoalieSaveRules.SavePart.CHEST:
						continue
					if not _h.last_trapped:
						continue
					chest_saves += 1
					if _h.rebound_swept:
						swept += 1
					if _h.rebound_goal:
						own_goals += 1
					# Skip index 0 — that IS the chest contact that trapped it.
					var later: Array[int] = []
					for i: int in range(1, _h.contact_parts.size()):
						later.append(_h.contact_parts[i])
					if later.has(GoalieSaveRules.SavePart.STICK):
						then_stick += 1
					if later.has(GoalieSaveRules.SavePart.PAD):
						then_pad += 1
	gut.p("%d spots x %d lofts x %d aims x %d speeds" % [
		SPOTS.size(), lofts.size(), AIM_FRACTIONS.size(), MPH.size()])
	gut.p("  first surface struck: %s" % [by_first])
	gut.p("  chest smothers %d | swept away %d | then touched STICK %d | then PAD %d"
			% [chest_saves, swept, then_stick, then_pad])
	gut.p("  OWN GOALS off a smothered puck: %d" % own_goals)
	assert_gt(chest_saves, 25,
			"too few chest smothers in the sample to conclude anything")
	assert_eq(own_goals, 0,
			"a smothered puck went into his own net — the placement is not " +
			"clearing his equipment any more")
	# The second beat, which is the point of a smother in a ruleset that does not
	# want the whistle: he has to actually clear it. Touching the blade on the way
	# out is fine; being left in the paint is the failure.
	assert_gt(float(swept) / float(maxi(chest_saves, 1)), 0.9,
			"only %d of %d smothers got swept away — the dead play is not being " % [
			swept, chest_saves] + "finished")
