extends GutTest

# Compile guard for the post-game analytics screen. It's built entirely in code
# (nested RinkMap / XGFlow / LegendDot Controls with _draw overrides) and is only
# instantiated by HUD at runtime, so a parse error — a bad type, an inner class
# reaching for an outer-scope constant, a renamed accessor — would never surface
# in tests. Preloading forces GDScript to compile it in project context, where
# autoloads and class_name globals resolve. (Same pattern as
# test_drill_scripts_compile / test_tutorial_scripts_compile.)


func test_post_game_analytics_compiles() -> void:
	var gd: GDScript = load("res://Scripts/ui/post_game_analytics.gd")
	assert_not_null(gd, "post_game_analytics.gd failed to compile")


func test_game_over_popup_compiles() -> void:
	# Carries the Analytics button that opens the screen above.
	var gd: GDScript = load("res://Scripts/ui/game_over_popup.gd")
	assert_not_null(gd, "game_over_popup.gd failed to compile")


func test_career_stats_screen_compiles() -> void:
	# Same shape: nested CareerHeatMap / HeatRamp / GoalDot Controls with _draw
	# overrides, and the legend swatches reach across into the map's ramp
	# constants — all runtime-only failures otherwise.
	var gd: GDScript = load("res://Scripts/ui/career_stats_screen.gd")
	assert_not_null(gd, "career_stats_screen.gd failed to compile")
