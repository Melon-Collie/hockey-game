class_name DrillRegistry

# Central catalogue of the offline practice drills (mirrors TutorialRegistry,
# which owns the tutorial course). A drill is a single-local-player offline
# session whose whole flow — staging, scoring, HUD — is owned by one dedicated
# manager node. Adding a new drill means appending here plus writing that
# manager (and usually a DrillHUD subclass for its strings): no NetworkManager
# flag, no game_scene branch, no SideMenu wiring change — the Practice menu
# builds its drill rows from ALL_IDS, and game_scene instantiates the
# registered manager for NetworkManager.drill_id.

const PENALTY_SHOTS_ID: String = "penalty_shots"
const SHOT_ACCURACY_ID: String = "shot_accuracy"
const PASSING_ID: String = "passing"

# Display order — also drives the Practice submenu's drill row order.
const ALL_IDS: Array[String] = [PENALTY_SHOTS_ID, SHOT_ACCURACY_ID, PASSING_ID]


static func get_display_name(drill_id: String) -> String:
	match drill_id:
		PENALTY_SHOTS_ID: return "Penalty Shots"
		SHOT_ACCURACY_ID: return "Shot Accuracy"
		PASSING_ID: return "Passing"
	return drill_id


# Script path of the manager node game_scene.gd instantiates for the drill.
# Empty for an unrecognised id (the caller skips spawning).
static func get_manager_path(drill_id: String) -> String:
	match drill_id:
		PENALTY_SHOTS_ID: return "res://Scripts/game/penalty_drill_manager.gd"
		SHOT_ACCURACY_ID: return "res://Scripts/game/shot_accuracy_manager.gd"
		PASSING_ID: return "res://Scripts/game/passing_drill_manager.gd"
	return ""


# Whether the drill should have the normal AI goalie PAIR auto-spawned by
# GameManager (same contract as TutorialRegistry.wants_goalies). None of the
# current drills want it — penalty spawns a lone reactive goalie, accuracy a
# lone frozen one, and passing plays on open ice — so a future drill played
# against live nets can opt in here.
static func wants_goalie_pair(_drill_id: String) -> bool:
	return false


static func has(drill_id: String) -> bool:
	return ALL_IDS.has(drill_id)
