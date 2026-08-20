extends GutTest

# Two ratchets on the shape of Scripts/: how long a file may be, and how wide
# its public surface may be. Both only ever tighten.
#
# The audit that produced them found five root causes, and this is the guard for
# the one no cleanup can fix by itself: nothing stopped a file from growing.
# Every god class here got that way one reasonable commit at a time, and each of
# those commits was correct in isolation. A ratchet is the only thing that makes
# the aggregate visible at the moment it moves.
#
# HOW IT WORKS. A file not named in the table must stay under the limit — that
# is the real guard, covering ~310 of the 341 files. The tables are the
# grandfather list: every file already over the limit when the ratchet went in,
# pinned at the size it was. They are the backlog, made un-growable rather than
# hidden.
#
# WHEN IT FIRES, there are three things it can be saying:
#
#   · "grew past its allowance" — you added lines to a file that is already too
#     big. Splitting is the intended answer. Bumping the number is ALLOWED and
#     is not cheating: the ratchet's job is to make growth deliberate and
#     visible in the diff, not impossible. Say why in the commit message.
#   · "shrank well below its allowance" — you won something; bank it. Tighten
#     the entry to the new number so the space cannot be re-spent quietly. This
#     is the click that makes it a ratchet instead of a cap.
#   · "is now under the limit" — the file graduated. Delete its entry.
#
# WHAT THE NUMBERS MEAN. 800 lines is roughly the point past which an agent
# reads a file partially and edits it blind, which is the failure this codebase
# actually suffers. 25 public functions is the point past which "what does this
# class do" stops having a one-sentence answer. Neither is a law of nature;
# both are the line where the cost showed up here.
#
# Two entries in the API table are deliberate and will never come down, and it
# is worth knowing which before trying:
#   · network_manager.gd (200) — 111 are receive_*/send_*/notify_*. Godot
#     dispatches @rpc by name on the node, so that IS the wire protocol.
#   · player_attributes.gd (53) — one accessor per body dial, by design.
#
# Scope is Scripts/ only. A long test is not the same cost as a long subsystem,
# and addons/ is vendored.

const _SIZE_LIMIT: int = 800
# Slack before an un-banked win is reported, so ordinary edits inside a listed
# file don't demand a table update on every commit.
const _SIZE_SLACK: int = 40

const _SIZE_ALLOWANCE: Dictionary[String, int] = {
	"res://Scripts/ai/skater_agent_state_machine.gd": 6166,
	"res://Scripts/game/game_manager.gd": 5654,
	"res://Scripts/domain/ai/action_scoring.gd": 4476,
	"res://Scripts/controllers/goalie_controller.gd": 4476,
	"res://Scripts/domain/ai/role_behaviors/carrier.gd": 3755,
	"res://Scripts/controllers/skater_controller.gd": 3350,
	"res://Scripts/actors/skater.gd": 2486,
	"res://Scripts/networking/network_manager.gd": 2824,
	"res://Scripts/game/tutorial_manager.gd": 2101,
	"res://Scripts/controllers/skater_skating_coordinator.gd": 1577,
	"res://Scripts/controllers/skater_ik_coordinator.gd": 820,
	"res://Scripts/controllers/puck_controller.gd": 1517,
	"res://Scripts/actors/hockey_rink.gd": 1472,
	"res://Scripts/domain/ai/role_behaviors/role_helpers.gd": 1436,
	"res://Scripts/game/player_prefs.gd": 1370,
	"res://Scripts/actors/skater_mesh_builder.gd": 1366,
	"res://Scripts/domain/rules/goalie_behavior_rules.gd": 1324,
	"res://Scripts/ui/career_stats_screen.gd": 1271,
	"res://Scripts/domain/ai/carry_space.gd": 1255,
	"res://Scripts/ui/lobby_manager.gd": 1247,
	"res://Scripts/actors/puck.gd": 1017,
	"res://Scripts/ui/side_menu.gd": 995,
	"res://Scripts/controllers/goalie_body_config_builder.gd": 974,
	"res://Scripts/ui/network_debug_overlay.gd": 956,
	"res://Scripts/networking/network_telemetry.gd": 957,
	"res://Scripts/controllers/local_controller.gd": 924,
	"res://Scripts/ui/player_settings_popup.gd": 863,
	"res://Scripts/ui/slot_grid_panel.gd": 839,
	"res://Scripts/domain/state/game_state_machine.gd": 838,
	"res://Scripts/ui/locker_popup.gd": 822,
	"res://Scripts/ui/hud.gd": 811,
}

const _API_LIMIT: int = 25
const _API_SLACK: int = 3

const _API_ALLOWANCE: Dictionary[String, int] = {
	"res://Scripts/networking/network_manager.gd": 200,
	"res://Scripts/actors/skater.gd": 134,
	"res://Scripts/domain/ai/action_scoring.gd": 68,
	"res://Scripts/game/game_manager.gd": 61,
	"res://Scripts/domain/state/player_attributes.gd": 53,
	"res://Scripts/networking/network_telemetry.gd": 53,
	"res://Scripts/domain/ai/role_behaviors/role_helpers.gd": 48,
	"res://Scripts/controllers/skater_controller.gd": 39,
	"res://Scripts/actors/puck.gd": 39,
	"res://Scripts/domain/state/game_state_machine.gd": 38,
	"res://Scripts/domain/rules/goalie_behavior_rules.gd": 36,
	"res://Scripts/actors/skater_hud_coordinator.gd": 30,
	"res://Scripts/actors/skater_mesh_builder.gd": 29,
	"res://Scripts/controllers/puck_controller.gd": 27,
	"res://Scripts/game/shot_on_goal_tracker.gd": 26,
}


func _all_files(root: String, suffix: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir: DirAccess = DirAccess.open(root)
	if dir == null:
		return out
	for d: String in dir.get_directories():
		out.append_array(_all_files("%s/%s" % [root, d], suffix))
	for f: String in dir.get_files():
		if f.ends_with(suffix):
			out.append("%s/%s" % [root, f])
	return out


# Lines as an editor shows them: a trailing newline does not open a new one.
func _line_count(path: String) -> int:
	var src: String = FileAccess.get_file_as_string(path)
	if src.ends_with("\n"):
		src = src.substr(0, src.length() - 1)
	return src.split("\n").size()


# Functions the file offers to other files: declared at column 0 (an inner
# class's methods are that class's surface, not this one's) and not `_`-prefixed.
func _public_func_count(path: String) -> int:
	var re := RegEx.create_from_string("^(static )?func [a-z][a-zA-Z0-9_]*\\(")
	var n: int = 0
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		if re.search(line) != null:
			n += 1
	return n


# The shared ratchet. `measure` maps a path to its number; everything else is
# the same four rules for both axes.
func _assert_ratchet(allowance: Dictionary[String, int], limit: int, slack: int,
		unit: String, measure: Callable, remedy: String) -> void:
	var seen: Dictionary[String, bool] = {}
	for path: String in _all_files("res://Scripts", ".gd"):
		var measured: int = measure.call(path)
		seen[path] = true
		if not allowance.has(path):
			if measured > limit:
				fail_test(("%s is %d %s, over the %d limit. %s — or add it to the " +
						"table in test_no_god_class_growth.gd if it genuinely has to " +
						"be this big, and say why in the commit.")
						% [path, measured, unit, limit, remedy])
			continue
		var allowed: int = allowance[path]
		if measured <= limit:
			fail_test(("%s is down to %d %s, under the %d limit — it graduated. " +
					"Delete its entry from the table.") % [path, measured, unit, limit])
		elif measured > allowed:
			fail_test(("%s grew to %d %s, past its allowance of %d. %s. Bumping the " +
					"entry is allowed and visible in the diff — but it is a decision, " +
					"so say why in the commit message.")
					% [path, measured, unit, allowed, remedy])
		elif measured < allowed - slack:
			fail_test(("%s is down to %d %s from an allowance of %d. Bank it: tighten " +
					"the entry to %d so the space cannot be re-spent quietly.")
					% [path, measured, unit, allowed, measured])
	for path: String in allowance:
		if not seen.has(path):
			fail_test("%s no longer exists; drop its stale entry from the table." % path)
	# A ratchet that scanned nothing passes silently, which is the one way this
	# can rot into decoration. Scripts/ has ~340 .gd files.
	assert_gt(seen.size(), 250, "the %s scan must actually reach Scripts/" % unit)


func test_no_file_grows_past_its_allowance() -> void:
	_assert_ratchet(_SIZE_ALLOWANCE, _SIZE_LIMIT, _SIZE_SLACK, "lines",
			_line_count, "Split it, or move the prose to its area CLAUDE.md")


func test_no_class_widens_past_its_allowance() -> void:
	_assert_ratchet(_API_ALLOWANCE, _API_LIMIT, _API_SLACK, "public functions",
			_public_func_count,
			"Split it, or make the callers go through fewer entry points")
