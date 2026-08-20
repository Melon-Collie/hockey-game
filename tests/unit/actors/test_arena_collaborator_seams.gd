extends GutTest

# Structural guards on the ArenaStands → Scripts/actors/arena/ seam. None of
# these asserts anything about how the bowl looks; they hold the shape of the
# split, which is the thing that rots silently once the renders stop being
# diffed.
#
# Three failure modes, in the order they cost the most:
#
#   · A collaborator writing the spec. `ArenaBowlSpec` is the ONE snapshot of the
#     @export knobs, and `ArenaStands` fills it. The moment a collaborator writes
#     a field back, that export has two owners and the node's setter — the thing
#     that decides a rebuild is needed — stops being the whole story.
#   · A collaborator reaching sideways or upward. A const read across a GDScript
#     `class_name` cycle fails at PARSE time and takes the whole class down with
#     it, so a cycle is not a slow-burn design smell here; it is a crash.
#   · A signal connected straight to a re-signatured method. Godot validates
#     arity at emit, not at connect, so that one first fails in a live match.

const _STANDS: String = "res://Scripts/actors/arena_stands.gd"
const _ARENA_DIR: String = "res://Scripts/actors/arena"
const _GAME_MANAGER: String = "res://Scripts/game/game_manager.gd"

# The collaborators ArenaStands holds, in the order it constructs them.
const _HOLDERS: Array[String] = ["_path", "_rake", "_deck", "_crowd",
		"_seating", "_rinkside", "_signage"]

# The layering, lowest first. A file may name a class from a STRICTLY lower tier
# and nothing else in this directory — so two collaborators on the same tier can
# never reach for each other. `ArenaStands` sits above all of them and is named
# by none.
const _TIERS: Array[Array] = [
	["ArenaMeshEmit", "ArenaRinksideLayout", "ArenaBowlSpec"],
	["ArenaFigureMesh", "ArenaBowlPath"],
	["ArenaBowlRake"],
	["ArenaDeckMesh", "ArenaCrowd", "ArenaSeating", "ArenaRinkside", "ArenaSignage"],
]

var _sources: Dictionary = {}


func before_all() -> void:
	var dir: DirAccess = DirAccess.open(_ARENA_DIR)
	assert_not_null(dir, "could not open %s" % _ARENA_DIR)
	if dir == null:
		return
	for f: String in dir.get_files():
		if f.ends_with(".gd"):
			_sources[f] = _strip(FileAccess.get_file_as_string("%s/%s" % [_ARENA_DIR, f]))
	assert_gt(_sources.size(), 6, "expected the arena collaborators to be found")


func _strip(src: String) -> String:
	var out := PackedStringArray()
	for line: String in src.split("\n"):
		var h: int = line.find("#")
		out.append(line if h < 0 else line.substr(0, h))
	return "\n".join(out)


func _class_name_of(src: String) -> String:
	var m: RegExMatch = RegEx.create_from_string("(?m)^class_name ([A-Za-z0-9]+)") \
			.search(src)
	return "" if m == null else m.get_string(1)


func _tier_of(cls: String) -> int:
	for i: int in _TIERS.size():
		if _TIERS[i].has(cls):
			return i
	return -1


# ── Ownership ────────────────────────────────────────────────────────────────

func test_no_collaborator_writes_the_spec() -> void:
	# `_spec.field = ...` anywhere below ArenaStands. Assigning a field is
	# deciding when it changes, and when a bowl param changes is exactly what the
	# node's export setters own — they are what schedules the rebuild.
	var assign := RegEx.create_from_string(
			"_spec\\.([a-z_0-9]+)\\s*(?:=(?!=)|\\+=|-=|\\*=)\\s")
	for file: String in _sources:
		for m: RegExMatch in assign.search_all(_sources[file]):
			fail_test(("%s writes _spec.%s. The spec is ArenaStands' snapshot of its " +
					"@export knobs — a collaborator that writes one has taken over " +
					"deciding when that knob changes, and the export setter that " +
					"triggers the rebuild no longer knows about it.")
					% [file, m.get_string(1)])


func test_arena_stands_never_writes_a_collaborator_field() -> void:
	# The mirror of the rule above, from the owner's side: ArenaStands calls
	# methods on its collaborators and constructs them, and does nothing else to
	# them. `_crowd.something = x` here would put the crowd's lifecycle in two
	# places, which is what killed GoalieCreaseClear's extraction.
	var src: String = _strip(FileAccess.get_file_as_string(_STANDS))
	for holder: String in _HOLDERS:
		var re := RegEx.create_from_string(
				"%s\\.([a-z_][a-z_0-9]*)\\s*(?:=(?!=)|\\+=|-=)\\s" % holder)
		for m: RegExMatch in re.search_all(src):
			fail_test(("ArenaStands writes %s.%s. Call a method instead — whoever " +
					"writes a field owns when it changes.") % [holder, m.get_string(1)])


func test_the_collaborator_set_is_rebuilt_in_one_place() -> void:
	# Every holder rebound exactly once, all of them together. A second
	# construction site is how one collaborator ends up holding a spec the others
	# have moved past.
	var src: String = _strip(FileAccess.get_file_as_string(_STANDS))
	for holder: String in _HOLDERS:
		var bind := RegEx.create_from_string(
				"(?m)^\\t%s = Arena[A-Za-z]+\\.new\\(" % holder)
		assert_eq(bind.search_all(src).size(), 1,
				"%s should be constructed exactly once, in _build_collaborators"
						% holder)


# ── Direction ────────────────────────────────────────────────────────────────

func test_no_collaborator_names_arena_stands() -> void:
	# The cycle guard. ArenaStands depends on all of them; one of them naming it
	# back closes a `class_name` cycle, and a const read across such a cycle is a
	# parse error that takes down every file in it.
	var re := RegEx.create_from_string("\\bArenaStands\\b")
	for file: String in _sources:
		assert_null(re.search(_sources[file]),
				("%s names ArenaStands. Nothing under Scripts/actors/arena/ may — " +
						"the dependency runs one way.") % file)


func test_collaborators_only_depend_downward() -> void:
	for file: String in _sources:
		var src: String = _sources[file]
		var cls: String = _class_name_of(src)
		var tier: int = _tier_of(cls)
		assert_gt(tier, -1, ("%s declares %s, which is not in the layering table — "
				+ "add it to the tier it belongs in") % [file, cls])
		if tier < 0:
			continue
		for other_file: String in _sources:
			var other: String = _class_name_of(_sources[other_file])
			if other == cls or other.is_empty():
				continue
			if RegEx.create_from_string("\\b%s\\b" % other).search(src) == null:
				continue
			assert_lt(_tier_of(other), tier,
					("%s (tier %d) references %s (tier %d). Dependencies run " +
							"strictly downward, so two collaborators on one tier can " +
							"never reach for each other.")
							% [cls, tier, other, _tier_of(other)])


# ── Signal arity ─────────────────────────────────────────────────────────────

func test_every_wired_game_signal_matches_its_handler() -> void:
	# Godot checks a connection's arity when the signal FIRES, not when it is
	# connected, so a re-signatured handler here fails first in a live match —
	# during a goal celebration, on the one path nobody replays headless.
	var stands_src: String = _strip(FileAccess.get_file_as_string(_STANDS))
	var gm_src: String = FileAccess.get_file_as_string(_GAME_MANAGER)
	var wired := RegEx.create_from_string(
			"gm\\.([a-z_]+)\\.connect\\(([a-z_][a-z_0-9]*)\\)")
	var matches: Array[RegExMatch] = wired.search_all(stands_src)
	assert_gt(matches.size(), 4, "expected several GameManager signals to be wired")
	for m: RegExMatch in matches:
		var signal_name: String = m.get_string(1)
		var handler: String = m.get_string(2)
		assert_eq(_signal_arity(gm_src, signal_name), _method_arity(stands_src, handler),
				"%s(...) is connected to %s(...) with a different argument count"
						% [signal_name, handler])


# Args declared by `signal name(...)`.
func _signal_arity(src: String, signal_name: String) -> int:
	var m: RegExMatch = RegEx.create_from_string(
			"(?m)^signal %s(\\(([^)]*)\\))?\\s*$" % signal_name).search(src)
	assert_not_null(m, "GameManager declares no signal %s" % signal_name)
	return 0 if m == null else _arg_count(m.get_string(2))


func _method_arity(src: String, method: String) -> int:
	var m: RegExMatch = RegEx.create_from_string(
			"(?m)^func %s\\(([^)]*)\\)" % method).search(src)
	assert_not_null(m, "ArenaStands declares no method %s" % method)
	return 0 if m == null else _arg_count(m.get_string(1))


func _arg_count(args: String) -> int:
	return 0 if args.strip_edges().is_empty() else args.split(",").size()
