extends GutTest

# Compile guard for the Shooting-module scripts that aren't otherwise exercised
# by the unit suite. TutorialManager has no class_name and is only loaded by
# game_scene at runtime, so a parse error there (a bad type, a renamed method)
# would never surface in tests. Preloading forces GDScript to compile each one
# in project context, where autoloads and class_name globals resolve.


func test_tutorial_manager_compiles() -> void:
	var script: GDScript = load("res://Scripts/game/tutorial_manager.gd")
	assert_not_null(script, "tutorial_manager.gd failed to compile")


func test_tutorial_hud_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/tutorial_hud.gd")
	assert_not_null(script, "tutorial_hud.gd failed to compile")


func test_tutorial_targets_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/tutorial_targets.gd")
	assert_not_null(script, "tutorial_targets.gd failed to compile")

func test_tutorial_wall_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/tutorial_wall.gd")
	assert_not_null(script, "tutorial_wall.gd failed to compile")
