extends GutTest

# AICarrySpace was split out of AIActionScoring, and the split is only safe
# while the dependency runs ONE WAY: carry-space reads the scorer, never the
# reverse.
#
# This is not a style preference. AICarrySpace reads six reference speeds and
# the puck-protect handle as CONSTANTS off AIActionScoring, and a const read
# across a GDScript `class_name` cycle fails at PARSE time — which takes the
# whole class down, not one call. When that happened during the split, every
# static call on the scorer reported "Nonexistent function ... in base
# 'GDScript'" from 82 files at once, and 522 tests failed with nothing pointing
# at the actual cause.
#
# The split itself was chosen by dependency closure rather than by topic: the
# seven functions the rest of the scorer still calls — the shared arrival clock
# and the net-obstacle tests — stayed behind precisely so this direction holds.

const _SCORING: String = "res://Scripts/domain/ai/action_scoring.gd"
const _CARRY: String = "res://Scripts/domain/ai/carry_space.gd"


func test_the_scorer_never_reaches_into_carry_space() -> void:
	var src: String = FileAccess.get_file_as_string(_SCORING)
	assert_false(src.is_empty(), "could not read action_scoring.gd")
	var out := PackedStringArray()
	for line: String in src.split("\n"):
		var code: String = line.split("#")[0]
		if code.contains("AICarrySpace"):
			out.append(code.strip_edges())
	assert_eq(out.size(), 0,
			"action_scoring.gd references AICarrySpace: %s. That closes the loop — " % [out] +
			"carry-space reads consts off the scorer, and a const read across a " +
			"class_name cycle is a parse error that takes the whole class with it. " +
			"Move what the scorer needs back into it instead.")


# The other half of the same rule, stated positively: carry-space is allowed to
# read the scorer, and does. If this stops being true the borrow list in its
# header is stale.
func test_carry_space_reads_the_scorer() -> void:
	var src: String = FileAccess.get_file_as_string(_CARRY)
	assert_false(src.is_empty(), "could not read carry_space.gd")
	assert_true(src.contains("AIActionScoring."),
			"carry_space.gd no longer reads AIActionScoring — if the borrowed clock " +
			"and constants are genuinely gone, update its header, which names them")


# The scorer keeps the primitives the rest of it calls. Losing one to a future
# split is the exact failure this file exists for, and it is silent until the
# whole class stops parsing.
func test_the_shared_primitives_stayed_with_the_scorer() -> void:
	var src: String = FileAccess.get_file_as_string(_SCORING)
	for shared: String in ["time_to_arrive", "carry_path_blocked_by_net",
			"pass_lane_blocked_by_net"]:
		assert_true(src.contains("static func %s(" % shared),
				"`%s` is a primitive the rest of the scorer calls bare — it has to " % shared +
				"live here, not in a class the scorer is forbidden to reference")
