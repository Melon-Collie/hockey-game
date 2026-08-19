extends GutTest

# Fails when a `.tscn` sets a property the attached script declares.
#
# The project's position, now stated in CLAUDE.md: a tunable is a plain
# class-level `var` with its value in code, and `@export` is for the handful a
# scene genuinely overrides. Measured across the two controllers and `Skater`,
# that handful was ZERO out of 573 — so the inspector rows were pure cost and
# the exports came off.
#
# A scene override is worse than an inspector row, though, which is why this is
# a test and not a style note. The value a reader sees in the source is not the
# value the game runs: the `.tscn` silently wins, the code default rots
# unnoticed, and nothing anywhere reports the disagreement. `hockey_rink.gd`
# shipped `ice_color = Color(0.84, 0.91, 1.0)` while every frame drew
# `Color(0.929, 0.949, 0.973)` from `RinkArena.tscn`.
#
# Engine properties (`transform`, `fov`, `layout_mode`, `anchors_preset`, …) are
# not script state and are not the target — the check only fires on names the
# script itself declares.
#
# `.tscn` files are edited by the user in the Godot editor, not from here, so
# `_ACCEPTED` carries what is still outstanding. Each entry is a decision
# someone can argue with; an unlisted one is rot.

# "scene.tscn/node/property" -> why it is still there.
const _ACCEPTED: Dictionary = {
	# Load-bearing and not yet replaceable. Both goal nodes sit at the scene
	# origin and build their geometry procedurally from `facing`, so this is the
	# ONLY thing distinguishing the two nets — there is no transform to derive it
	# from and nothing in Scripts/ resolves either node by name. Removing it
	# needs a mechanism first (the arena assigning it, or the goal reading its
	# end from the rink), which is a design call, not a cleanup.
	"RinkArena.tscn/GoalTop/facing": "the only thing telling the two nets apart",

	# Inert cruft: 37 of puck.gd's exports serialised with a null value, which
	# Godot writes when a scene holds a slot for a property but no value. They
	# set nothing. Delete them in the editor and drop this entry.
	"Puck.tscn/Puck/*": "37 null-valued exports, inert, pending an editor pass",

	# Redundant as of this commit: hockey_rink.gd's code defaults were changed to
	# the values the scene was already imposing, so deleting these three in the
	# editor changes nothing on screen. They are the reason this test exists —
	# the source said the ice was Color(0.84, 0.91, 1.0) while every frame drew
	# the scene's value instead. Delete them and drop these entries.
	"RinkArena.tscn/Rink/ice_color": "now equals the code default; delete in the editor",
	"RinkArena.tscn/Rink/ice_fog_color": "now equals the code default; delete in the editor",
	"RinkArena.tscn/Rink/ice_roughness_head_on": "now equals the code default; delete in the editor",
}


func _script_fields(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(path):
		return out
	var re := RegEx.create_from_string(
			"(?m)^(?:@export(?:_[a-z_]+)?(?:\\([^)]*\\))? )?var ([a-z_][a-z_0-9]*)")
	for m: RegExMatch in re.search_all(FileAccess.get_file_as_string(path)):
		out.append(m.get_string(1))
	return out


func _all_scenes(root: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir: DirAccess = DirAccess.open(root)
	if dir == null:
		return out
	for d: String in dir.get_directories():
		if d == "addons":
			continue
		out.append_array(_all_scenes("%s/%s" % [root, d]))
	for f: String in dir.get_files():
		if f.ends_with(".tscn"):
			out.append("%s/%s" % [root, f])
	return out


# Overrides as "scene/node/property", read from the scene TEXT rather than
# SceneState: SceneState reports engine properties too, and the point here is
# specifically the ones a script declares.
func _overrides() -> Dictionary:
	var out: Dictionary = {}
	var ext := RegEx.create_from_string(
			'\\[ext_resource type="Script"[^\\]]*path="(res://[^"]+)"[^\\]]*id="([^"]+)"')
	var scr := RegEx.create_from_string('script = ExtResource\\("([^"]+)"\\)')
	var nam := RegEx.create_from_string('^name="([^"]+)"')
	var prop := RegEx.create_from_string("(?m)^([a-z_][a-z_0-9]*) = (.+)$")
	for path: String in _all_scenes("res://"):
		var txt: String = FileAccess.get_file_as_string(path)
		var ids: Dictionary = {}
		for m: RegExMatch in ext.search_all(txt):
			ids[m.get_string(2)] = m.get_string(1)
		for block: String in txt.split("\n[node "):
			var sm: RegExMatch = scr.search(block)
			if sm == null:
				continue
			var fields: PackedStringArray = _script_fields(ids.get(sm.get_string(1), ""))
			if fields.is_empty():
				continue
			var nm: RegExMatch = nam.search(block)
			var node: String = nm.get_string(1) if nm != null else "?"
			for pm: RegExMatch in prop.search_all(block):
				if fields.has(pm.get_string(1)):
					var key: String = "%s/%s/%s" % [path.get_file(), node, pm.get_string(1)]
					out[key] = pm.get_string(2).strip_edges()
	return out


func test_no_scene_sets_a_script_property() -> void:
	var found: Dictionary = _overrides()
	var unlisted: int = 0
	for key: String in found:
		var wildcard: String = "%s/*" % key.substr(0, key.rfind("/"))
		if _ACCEPTED.has(key) or _ACCEPTED.has(wildcard):
			continue
		unlisted += 1
		fail_test(("`%s` is set in a scene to `%s`. The value in the source is then " +
				"not the value the game runs, and nothing reports the disagreement — " +
				"put it in the code default and delete the override, or list it in " +
				"_ACCEPTED with why the scene has to own it.")
				% [key, found[key]])
	assert_eq(unlisted, 0, "every scene override is either gone or accounted for")


# Guards the guard: the parser is the only moving part, and a broken one would
# report a clean project.
func test_the_scene_scan_found_the_project() -> void:
	assert_gt(_all_scenes("res://").size(), 8, "expected the project's scenes")
	assert_gt(_overrides().size(), 0,
			"expected to still find the accepted overrides — finding none means the " +
			"parser stopped resolving scripts, not that the project is clean")
