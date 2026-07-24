extends GutTest

# Compile guard for the post-game analytics screen. It's built entirely in code
# (nested RinkMap / XGFlow / LegendDot Controls with _draw overrides) and is only
# instantiated by HUD at runtime, so a parse error — a bad type, an inner class
# reaching for an outer-scope constant, a renamed accessor — would never surface
# in tests. Preloading forces GDScript to compile it in project context, where
# autoloads and class_name globals resolve. (Same pattern as
# test_drill_scripts_compile / test_tutorial_scripts_compile.)


func test_post_game_analytics_compiles() -> void:
	var script: GDScript = load("res://Scripts/ui/post_game_analytics.gd")
	assert_not_null(script, "post_game_analytics.gd failed to compile")


func test_game_over_popup_compiles() -> void:
	# Carries the Analytics button that opens the screen above.
	var script: GDScript = load("res://Scripts/ui/game_over_popup.gd")
	assert_not_null(script, "game_over_popup.gd failed to compile")
