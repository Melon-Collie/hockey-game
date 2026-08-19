extends GutTest

# Fails when a controller starts writing a field its collaborator also writes.
#
# That single condition is what killed GoalieCreaseClear's extraction. It shipped
# with a full lifecycle API — begin_cover, tick_cover_reach, end_cover and
# fourteen more — that the controller never called, because the controller was
# already writing the same timers inline. Once you write a field, you have
# re-derived WHEN to write it, which is the lifecycle; the collaborator's own tick
# method is redundant from that moment and rots without failing anything.
#
# The correlation across the goalie's six collaborators, measured before the
# cleanup:
#
#     contested fields   0    2    2    12
#     methods that died  0    0    0    17
#
# GoaliePuckPlay takes twenty caller-written fields and lost nothing, so the
# volume crossing the seam is not the problem — shared ownership of one field is.
# The rule is in Scripts/controllers/CLAUDE.md.
#
# Two writes are deliberately NOT contested:
#   · Anything inside the collaborator's own reset()/clear() — restoring state you
#     own to defaults is not advancing it, and the controller calling reset() at a
#     faceoff is the seam working.
#   · The caller zeroing a timer on an abort path. Cancelling is a decision the
#     controller owns; arming and advancing are the collaborator's.
# The second cannot be told from the first mechanically, so the four that exist
# are listed below with what they do.

const _CONTROLLER: String = "res://Scripts/controllers/goalie_controller.gd"

# "holder.field" -> why the shared write is tolerated. Anything not listed fails.
# Keyed by holder as well as field so exempting one collaborator's `current`
# does not silently exempt every other collaborator's.
const _ACCEPTED: Dictionary = {
	"_slide.drop_progress": "zeroed on the abort path, never advanced",
	"_slide.velocity_x": "zeroed on the abort path, never advanced",
	"_reaction.arm_timer": "zeroed when the read is cancelled",
	"_reaction.shot_timer": "zeroed when the read is cancelled",
	# Netcode-mandated bypass. transition_to() emits `transitioned`, which drives
	# host-side side effects; _apply_interpolated and apply_replay_state are
	# client/replay paths applying an authoritative pose, where firing those would
	# be exactly the client-side goalie AI Scripts/networking/CLAUDE.md forbids.
	"_sm.current": "client/replay pose apply must not fire the transition signal",
}


func _strip(src: String) -> String:
	var out := PackedStringArray()
	for line: String in src.split("\n"):
		var h: int = line.find("#")
		out.append(line if h < 0 else line.substr(0, h))
	return "\n".join(out)


# `var _clear: GoalieCreaseClear = GoalieCreaseClear.new()` → {"_clear": "GoalieCreaseClear"}
func _collaborators(ctrl_src: String) -> Dictionary:
	var out: Dictionary = {}
	var re := RegEx.create_from_string(
			"(?m)^var (_[a-z_0-9]+)\\s*:\\s*([A-Z][A-Za-z0-9]*)\\s*=\\s*[A-Z][A-Za-z0-9]*\\.new\\(\\)")
	for m: RegExMatch in re.search_all(ctrl_src):
		out[m.get_string(1)] = m.get_string(2)
	return out


# Fields the class assigns to itself outside reset()/clear(). `(?!=)` after the
# `=` keeps `x == y` from reading as an assignment — without it every comparison
# against a collaborator field looks like a contested write.
func _self_written(src: String) -> PackedStringArray:
	var out := PackedStringArray()
	var in_reset: bool = false
	var assign := RegEx.create_from_string("^\\t+([a-z_][a-z_0-9]*)\\s*(?:=(?!=)|\\+=|-=|\\*=)\\s")
	for line: String in _strip(src).split("\n"):
		if line.begins_with("func ") or line.begins_with("static func "):
			in_reset = line.begins_with("func reset") or line.begins_with("func clear")
		if in_reset:
			continue
		var m: RegExMatch = assign.search(line)
		if m != null and not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	return out


func _caller_written(ctrl_src: String, holder: String) -> PackedStringArray:
	var out := PackedStringArray()
	var re := RegEx.create_from_string(
			"%s\\.([a-z_][a-z_0-9]*)\\s*(?:=(?!=)|\\+=|-=)\\s" % holder)
	for m: RegExMatch in re.search_all(ctrl_src):
		if not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	return out


func _source_for(cls: String) -> String:
	# GoalieCreaseClear -> goalie_crease_clear.gd, beside the controller.
	var snake: String = ""
	for i: int in cls.length():
		var c: String = cls[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower():
			snake += "_"
		snake += c.to_lower()
	var path: String = "res://Scripts/controllers/%s.gd" % snake
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func test_no_collaborator_state_is_written_from_both_sides() -> void:
	var ctrl: String = _strip(FileAccess.get_file_as_string(_CONTROLLER))
	assert_false(ctrl.is_empty(), "could not read %s" % _CONTROLLER)
	var found: Dictionary = _collaborators(ctrl)
	assert_gt(found.size(), 4, "expected the controller to hold several collaborators")

	for holder: String in found:
		var src: String = _source_for(found[holder])
		if src.is_empty():
			continue  # lives outside controllers/ (the domain rule classes)
		var mine: PackedStringArray = _self_written(src)
		for field: String in _caller_written(ctrl, holder):
			if not mine.has(field) or _ACCEPTED.has("%s.%s" % [holder, field]):
				continue
			fail_test(("GoalieController writes `%s.%s`, which %s also writes outside " +
					"its reset(). Whoever writes a field decides when — so the controller " +
					"now owns that lifecycle and %s's own method for it is dead code " +
					"waiting to happen. Give the field one owner, or list it in " +
					"_ACCEPTED with what the shared write does.")
					% [holder, field, found[holder], found[holder]])


# GoalieCreaseClear is the worked example: twelve contested fields before the
# lifecycle half was deleted, zero after. Pinned so a regression there is named
# rather than just counted.
func test_the_crease_clear_seam_stays_clean() -> void:
	var ctrl: String = _strip(FileAccess.get_file_as_string(_CONTROLLER))
	var mine: PackedStringArray = _self_written(_source_for("GoalieCreaseClear"))
	var contested := PackedStringArray()
	for field: String in _caller_written(ctrl, "_clear"):
		if mine.has(field):
			contested.append(field)
	assert_eq(contested.size(), 0,
			"GoalieCreaseClear must own every field it writes: %s" % [contested])
