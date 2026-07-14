extends GutTest

# Compile guard for the offline drill scripts (penalty shots, shot accuracy,
# passing).
# The drill managers have no class_name and are only loaded by game_scene at
# runtime, so a parse error there (a bad type, a renamed method) would never
# surface in tests. Preloading forces GDScript to compile each one in project
# context, where autoloads and class_name globals resolve. (Same pattern as
# test_tutorial_scripts_compile.)


func test_drill_hud_base_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/drill_hud.gd")
	assert_not_null(script, "drill_hud.gd failed to compile")


func test_penalty_drill_manager_compiles() -> void:
	var script: GDScript = load("res://Scripts/game/penalty_drill_manager.gd")
	assert_not_null(script, "penalty_drill_manager.gd failed to compile")


func test_penalty_drill_hud_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/penalty_drill_hud.gd")
	assert_not_null(script, "penalty_drill_hud.gd failed to compile")


func test_shot_accuracy_manager_compiles() -> void:
	var script: GDScript = load("res://Scripts/game/shot_accuracy_manager.gd")
	assert_not_null(script, "shot_accuracy_manager.gd failed to compile")


func test_shot_accuracy_hud_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/shot_accuracy_hud.gd")
	assert_not_null(script, "shot_accuracy_hud.gd failed to compile")


func test_passing_drill_manager_compiles() -> void:
	var script: GDScript = load("res://Scripts/game/passing_drill_manager.gd")
	assert_not_null(script, "passing_drill_manager.gd failed to compile")


func test_passing_drill_hud_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/passing_drill_hud.gd")
	assert_not_null(script, "passing_drill_hud.gd failed to compile")
