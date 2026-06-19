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
const STEP_SKATE:      int = 0
const STEP_BRAKE:      int = 1
const STEP_QUICK_SHOT: int = 2
const STEP_WRIST_SHOT: int = 3
const STEP_SLAPSHOT:   int = 4
const STEP_ONE_TIMER:  int = 5
const STEP_SHOT_BLOCK: int = 6
const STEP_STICKCHECK: int = 7
const STEP_BODY_CHECK: int = 8
const STEP_ELEVATION:  int = 9
const STEP_OFFSIDES:   int = 10
const STEP_SPRINT:     int = 11
const STEP_BLADE_LIFT: int = 12
const STEP_STICK_LIFT: int = 13

# ── Tutorial identifiers ──────────────────────────────────────────────────────
const BASICS_ID: String = "basics"
const ADVANCED_ID: String = "advanced"

# Display order — also drives the SideMenu submenu row order.
const ALL_IDS: Array[String] = [BASICS_ID, ADVANCED_ID]


static func get_step_ids(tutorial_id: String) -> Array[int]:
	match tutorial_id:
		BASICS_ID:
			return [STEP_SKATE, STEP_SPRINT, STEP_BRAKE, STEP_BLADE_LIFT,
					STEP_QUICK_SHOT, STEP_WRIST_SHOT, STEP_SLAPSHOT]
		ADVANCED_ID:
			return [STEP_ONE_TIMER, STEP_ELEVATION, STEP_SHOT_BLOCK, STEP_STICK_LIFT,
					STEP_STICKCHECK, STEP_BODY_CHECK, STEP_OFFSIDES]
	return []


static func get_display_name(tutorial_id: String) -> String:
	match tutorial_id:
		BASICS_ID: return "Basics"
		ADVANCED_ID: return "Advanced"
	return tutorial_id


# "Part N of M" framing so the two tutorials read as one course the player is
# partway through, not two optional extras. N is the 1-based position in
# ALL_IDS; returns "" for an unrecognised id.
static func get_sequence_label(tutorial_id: String) -> String:
	var i: int = ALL_IDS.find(tutorial_id)
	if i < 0:
		return ""
	return "Part %d of %d" % [i + 1, ALL_IDS.size()]


# Whether the tutorial should have goalies spawned in the nets. Basics
# teaches shot mechanics on an empty net (with a shot-on-net pass
# criterion) so the player learns to put the puck where it needs to go
# before adding a defender; Advanced introduces goalies as the
# difficulty step up.
static func wants_goalies(tutorial_id: String) -> bool:
	return tutorial_id != BASICS_ID


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
