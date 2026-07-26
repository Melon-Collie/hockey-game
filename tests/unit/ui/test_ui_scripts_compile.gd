extends GutTest

# Smoke test: load() the controller/UI scripts so their bodies actually COMPILE.
# GDScript defers full body analysis of a class_name script until it's loaded, so a
# body-level error (an undeclared identifier from a bad edit) hides from the rest of
# the suite unless something instantiates the class. Running under GUT means the
# project's autoloads are present, so an autoload reference is NOT a false failure
# here (unlike a bare `godot -s` load) — only genuine errors make load() return null.

const _SCRIPTS: Array[String] = [
	"res://Scripts/ui/side_menu.gd",
	"res://Scripts/ui/hud.gd",
	"res://Scripts/ui/boot.gd",
	"res://Scripts/ui/menu_style.gd",
	"res://Scripts/ui/controller_nav.gd",
	"res://Scripts/ui/controller_glyphs.gd",
	"res://Scripts/ui/controller_keyboard.gd",
	"res://Scripts/ui/free_camera.gd",
	"res://Scripts/ui/palette_dropdown.gd",
	"res://Scripts/ui/slot_grid_panel.gd",
	"res://Scripts/ui/options_panel.gd",
	"res://Scripts/ui/options/controls_tab.gd",
	"res://Scripts/ui/lobby_manager.gd",
	"res://Scripts/ui/lobby_build_popup.gd",
	"res://Scripts/ui/attribute_picker_panel.gd",
	"res://Scripts/ui/pause_menu.gd",
	"res://Scripts/ui/confirm_dialog.gd",
	"res://Scripts/ui/display_revert_dialog.gd",
	"res://Scripts/ui/loading_screen.gd",
	"res://Scripts/ui/post_game_analytics.gd",
	"res://Scripts/ui/game_over_popup.gd",
	"res://Scripts/ui/career_stats_screen.gd",
	"res://Scripts/ui/tutorial_hud.gd",
	"res://Scripts/ui/drill_hud.gd",
	"res://Scripts/ui/replay_viewer_hud.gd",
	"res://Scripts/ui/player_settings_popup.gd",
	"res://Scripts/ui/play_popup.gd",
	"res://Scripts/ui/bug_report_dialog.gd",
	"res://Scripts/ui/controller_keyboard.gd",
]


func test_ui_scripts_compile() -> void:
	for path: String in _SCRIPTS:
		assert_not_null(load(path), "%s compiles" % path)
