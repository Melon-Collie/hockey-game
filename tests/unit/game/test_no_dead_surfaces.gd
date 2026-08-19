extends GutTest

# Fails when a public surface in Scripts/ stops having any reader: a function
# nobody calls, a signal nobody connects, an @export nobody reads.
#
# Godot makes this easy to get wrong, and every false-positive class below cost a
# wrong answer before it was handled:
#
#   · Callables. `host_ready.connect(on_host_started)` names the method without
#     calling it. A "does `.name(` appear" scan called 26 live functions dead.
#   · Virtual overrides. A base class calling `is_ai_controlled()` bare against a
#     subclass override never mentions the subclass.
#   · @rpc, dispatched by name over the wire.
#   · Engine virtuals — including `_static_init`, which Godot calls for static
#     initialisation and which no code ever references.
#   · .tscn signal connections and node references.
#   · Prose. A comment naming a function is not a caller, so comments are
#     stripped before counting — otherwise a well-documented orphan hides.
#
# So the rule is deliberately conservative: any occurrence of the identifier in
# stripped code, anywhere, counts as a use. It cannot report a live symbol dead;
# it can miss a dead one, which is the safe direction for something that gates
# commits.
#
# ACCEPTED holds what survives on purpose. Each entry needs a reason, and that is
# the point — an accepted orphan is a decision someone made and can be argued
# with, where a silent one is just rot.

const _ACCEPTED: Dictionary = {
	# Half-finished extraction (issue #519): the controller re-implements each of
	# these inline against the collaborator's fields. Whether to finish the
	# extraction or abandon it is that work's call, not a sweep's.
	"tick_cover_cooldown": "GoalieCreaseClear — unfinished extraction",
	"cover_ready": "GoalieCreaseClear — unfinished extraction",
	"accumulate_dwell": "GoalieCreaseClear — unfinished extraction",
	"consume_clear_cooldown": "GoalieCreaseClear — unfinished extraction",
	"begin_windup": "GoalieCreaseClear — unfinished extraction",
	"tick_windup": "GoalieCreaseClear — unfinished extraction",
	"tick_anim": "GoalieCreaseClear — unfinished extraction",
	"begin_follow_through": "GoalieCreaseClear — unfinished extraction",
	"start_clear_cooldown": "GoalieCreaseClear — unfinished extraction",
	"windup_in_flight": "GoalieCreaseClear — unfinished extraction",
	"cancel_windup": "GoalieCreaseClear — unfinished extraction",
	"begin_cover": "GoalieCreaseClear — unfinished extraction",
	"tick_cover_reach": "GoalieCreaseClear — unfinished extraction",
	"tick_cover_hold": "GoalieCreaseClear — unfinished extraction",
	"end_cover": "GoalieCreaseClear — unfinished extraction",
	"begin_catch": "GoalieCreaseClear — unfinished extraction",
	"tick_catch_hold": "GoalieCreaseClear — unfinished extraction",

	# Reachable by a human, not by code.
	"reset_all_achievements": "debug-gated dev tool, called from a debugger",

	# Documented as API in an area doc; the other half of the pair is live.
	"is_spectator_peer": "Scripts/networking/CLAUDE.md names it; spectator_peer_count is used",

	# Built for a future that has not arrived. CLAUDE.md says deferred work
	# belongs in an issue rather than the tree — these are the open question.
	"set_broadcast_rate": "self-described hook for future congestion response",
	"open_invite_overlay": "Steam invite overlay, no UI wired to it yet",
	"turnover_cost_local": "AI evaluator, not yet wired into a compete",
	"path_clearance": "AI evaluator, not yet wired into a compete",
}

const _ENGINE_VIRTUALS: PackedStringArray = [
	"_ready", "_process", "_physics_process", "_init", "_notification", "_input",
	"_unhandled_input", "_unhandled_key_input", "_exit_tree", "_enter_tree",
	"_draw", "_to_string", "_get_configuration_warnings", "_gui_input",
	"_integrate_forces", "_shortcut_input", "_static_init",
]

var _freq: Dictionary = {}
var _emits: Dictionary = {}


# One pass over every source the project can reach a symbol from, comments
# stripped. Built once per run rather than per assertion.
func before_all() -> void:
	# Accumulated into an array and joined once. Appending to a String in the
	# loop is quadratic — the first draft of this took 147 s on ~7 MB, which is
	# most of the suite's whole runtime.
	var chunks := PackedStringArray()
	for root: String in ["res://Scripts", "res://tests", "res://benchmarks", "res://tools"]:
		for path: String in _all_files(root, ".gd"):
			chunks.append(_strip_comments(FileAccess.get_file_as_string(path)))
	# Scenes reference methods by name in signal connections, and tools/ is a
	# real consumer of the builders — omitting either reports live code dead.
	for path: String in _all_files("res://Scenes", ".tscn") + _all_files("res://", ".tscn"):
		chunks.append(FileAccess.get_file_as_string(path))
	var corpus: String = "\n".join(chunks)
	var re := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
	for m: RegExMatch in re.search_all(corpus):
		var w: String = m.get_string()
		_freq[w] = int(_freq.get(w, 0)) + 1
	# A signal's own emit is not a listener. Counted separately so the signal
	# check can subtract it — without this every emitted signal escapes, because
	# its declaration plus its emit already outnumber the declaration alone.
	# (The first version of this test had exactly that hole, and the injected-
	# dead-signal check is what found it.)
	var emit_re := RegEx.create_from_string("([A-Za-z_][A-Za-z0-9_]*)\\.emit\\(")
	for m: RegExMatch in emit_re.search_all(corpus):
		var w: String = m.get_string(1)
		_emits[w] = int(_emits.get(w, 0)) + 1


func _strip_comments(src: String) -> String:
	var out := PackedStringArray()
	for line: String in src.split("\n"):
		var hash_at: int = line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)


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


# A symbol is dead when it appears no more often than it is declared.
func _orphans(pattern: String, skip: PackedStringArray, discount_emits: bool = false) -> Dictionary:
	var decls: Dictionary = {}
	var homes: Dictionary = {}
	var re := RegEx.create_from_string(pattern)
	for path: String in _all_files("res://Scripts", ".gd"):
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in lines.size():
			var m: RegExMatch = re.search(lines[i])
			if m == null:
				continue
			var name: String = m.get_string(1)
			if skip.has(name) or (i > 0 and lines[i - 1].strip_edges().begins_with("@rpc")):
				continue
			decls[name] = int(decls.get(name, 0)) + 1
			homes[name] = "%s:%d" % [path, i + 1]
	var out: Dictionary = {}
	for name: String in decls:
		var uses: int = int(_freq.get(name, 0))
		if discount_emits:
			uses -= int(_emits.get(name, 0))
		if uses <= int(decls[name]) and not _ACCEPTED.has(name):
			out[name] = homes[name]
	return out


func test_no_unreachable_public_functions() -> void:
	var dead: Dictionary = _orphans("^(?:static )?func ([a-z][a-z_0-9]*)", _ENGINE_VIRTUALS)
	for name: String in dead:
		fail_test("`%s()` at %s has no caller anywhere — delete it, or add it to " % [name, dead[name]] +
				"_ACCEPTED with the reason it stays")
	assert_eq(dead.size(), 0, "no unreachable public functions")


func test_no_signals_without_listeners() -> void:
	var dead: Dictionary = _orphans("^signal ([a-z][a-z_0-9]*)", PackedStringArray(), true)
	for name: String in dead:
		fail_test("signal `%s` at %s is emitted but never connected — " % [name, dead[name]] +
				"a broadcast with no listener is not a seam, it is a comment that compiles")
	assert_eq(dead.size(), 0, "no signals without listeners")


func test_no_exports_nothing_reads() -> void:
	var dead: Dictionary = _orphans(
			"^@export(?:_[a-z_]+)?(?:\\([^)]*\\))? var ([a-z][a-z_0-9]*)", PackedStringArray())
	for name: String in dead:
		fail_test("@export `%s` at %s is never read — it is a tunable that tunes " % [name, dead[name]] +
				"nothing, and the inspector still offers it")
	assert_eq(dead.size(), 0, "no exports nothing reads")


# Guards the guard: if the corpus scan ever comes back thin, every assertion
# above passes over an empty frequency map and reports a clean tree.
func test_the_corpus_scan_actually_saw_the_project() -> void:
	assert_gt(_freq.size(), 5000, "expected thousands of distinct identifiers")
	assert_gt(int(_freq.get("GameManager", 0)), 50, "GameManager should appear widely")
	assert_gt(_all_files("res://Scripts", ".gd").size(), 250, "expected 250+ scripts")
