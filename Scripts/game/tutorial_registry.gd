class_name TutorialRegistry

# Central catalogue of tutorials and step identifiers. Each tutorial is an
# ordered list of step constants. Adding a new tutorial (drills, etc.) means
# appending here — no PlayerPrefs schema change, no SideMenu wiring change.
# PlayerPrefs.tutorial_completion is keyed by the tutorial ids below.
#
# Step IDs live here (not in TutorialManager) to avoid a circular preload —
# TutorialManager references this registry to build its step list, and the
# registry would otherwise need to preload TutorialManager to read the IDs.

# ── Step identifiers ──────────────────────────────────────────────────────────
# Movement
const STEP_SKATE:       int = 0
const STEP_SPRINT:      int = 1
const STEP_STAMINA:     int = 2
const STEP_BRAKE:       int = 3
# Stick Basics — the cursor-driven blade, the Q gestures (deflect intents at
# the three loft levels), and the Q-tap drop. Taught before Shooting so loft
# is already a familiar mode, and before Defense's stick lift (same button).
const STEP_STICKHANDLE: int = 4
const STEP_DEFLECT:     int = 5   # LOW-loft tip on a grounded feed
const STEP_BLADE_LIFT:  int = 6   # HIGH-loft raise — bat an airborne lob down
const STEP_DROP_PUCK:   int = 7   # Q-tap nudge off the blade (the nutmeg)
# Shooting — drill-based: target waves, the stationary goalie, the live finish.
const STEP_SHOOT_WRIST:   int = 8
const STEP_SHOOT_TARGETS: int = 9    # pick-your-spot: flat, saucer-over-board, high, toggle off
const STEP_SHOOT_SLAP:    int = 10
const STEP_ONE_TIMER:     int = 11
const STEP_SHOOT_FINISH:  int = 12   # free finish on a live Easy goalie
# Passing — the quick pass, weighted wrister passes, the saucer, and reception.
const STEP_QUICK_PASS:  int = 13
const STEP_TOUCH_PASS:  int = 14
const STEP_SAUCER_PASS: int = 15
const STEP_RECEIVE:     int = 16
# Defense
const STEP_STICKCHECK:  int = 17
const STEP_BODY_CHECK:  int = 18
const STEP_STICK_LIFT:  int = 19
const STEP_SHOT_BLOCK:  int = 20
# Rules
const STEP_OFFSIDES:    int = 21

# ── Tutorial identifiers ──────────────────────────────────────────────────────
const MOVEMENT_ID: String = "movement"
const STICK_ID:    String = "stick_basics"
const SHOOTING_ID: String = "shooting"
const PASSING_ID:  String = "passing"
const DEFENSE_ID:  String = "defense"
const RULES_ID:    String = "rules"

# Display order — also drives the SideMenu submenu row order and the
# "Part N of M" course framing.
const ALL_IDS: Array[String] = [
	MOVEMENT_ID, STICK_ID, SHOOTING_ID, PASSING_ID, DEFENSE_ID, RULES_ID]


static func get_step_ids(tutorial_id: String) -> Array[int]:
	match tutorial_id:
		MOVEMENT_ID:
			return [STEP_SKATE, STEP_SPRINT, STEP_STAMINA, STEP_BRAKE]
		STICK_ID:
			return [STEP_STICKHANDLE, STEP_DEFLECT, STEP_BLADE_LIFT, STEP_DROP_PUCK]
		SHOOTING_ID:
			return [STEP_SHOOT_WRIST, STEP_SHOOT_TARGETS, STEP_SHOOT_SLAP,
					STEP_ONE_TIMER, STEP_SHOOT_FINISH]
		PASSING_ID:
			return [STEP_QUICK_PASS, STEP_TOUCH_PASS, STEP_SAUCER_PASS, STEP_RECEIVE]
		DEFENSE_ID:
			return [STEP_STICKCHECK, STEP_BODY_CHECK, STEP_STICK_LIFT, STEP_SHOT_BLOCK]
		RULES_ID:
			return [STEP_OFFSIDES]
	return []


static func get_display_name(tutorial_id: String) -> String:
	match tutorial_id:
		MOVEMENT_ID: return "Movement"
		STICK_ID: return "Stick Basics"
		SHOOTING_ID: return "Shooting"
		PASSING_ID: return "Passing"
		DEFENSE_ID: return "Defense"
		RULES_ID: return "Rules"
	return tutorial_id


# "Part N of M" framing so the tutorials read as one course the player is
# partway through, not optional extras. N is the 1-based position in
# ALL_IDS; returns "" for an unrecognised id.
static func get_sequence_label(tutorial_id: String) -> String:
	var i: int = ALL_IDS.find(tutorial_id)
	if i < 0:
		return ""
	return "Part %d of %d" % [i + 1, ALL_IDS.size()]


# Whether the tutorial should have the normal AI goalie PAIR auto-spawned by
# GameManager. Movement/Stick/Passing teach on open ice; Shooting spawns its
# own single goalie on demand (stationary for the target drill, live Easy for
# the finish), so only Defense and Rules want the live pair as rink dressing.
static func wants_goalies(tutorial_id: String) -> bool:
	return tutorial_id == DEFENSE_ID or tutorial_id == RULES_ID


static func has(tutorial_id: String) -> bool:
	return ALL_IDS.has(tutorial_id)


# Returns the next tutorial id in ALL_IDS order, or "" if `tutorial_id` is
# the last one (or unrecognised). Used by the completion modal to offer
# "Next: <name>" as a one-click continuation when the player just finished
# a tutorial that has a successor.
static func get_next_id(tutorial_id: String) -> String:
	var i: int = ALL_IDS.find(tutorial_id)
	if i < 0 or i + 1 >= ALL_IDS.size():
		return ""
	return ALL_IDS[i + 1]
