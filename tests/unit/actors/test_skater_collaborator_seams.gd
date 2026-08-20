extends GutTest

# Structural guards on Skater's collaborator seam, plus the one behavioural
# check the split's riskiest piece needs.
#
# Skater keeps every @export tuning var and every marker — the gameplay geometry
# the claim resolvers clamp against — and hands them to seven RefCounted
# collaborators that own the cosmetic rigs, the paint, the world HUD and the
# faceoff clock. What makes that seam hold is that the traffic runs ONE way:
# a collaborator reads the node's tuning and writes only its own state, and the
# node calls methods and never writes a collaborator's field. The moment a field
# has two writers, whoever wrote it second has re-derived WHEN it changes, and
# the other side's own updater is dead code waiting to happen — the failure
# measured across the goalie's six collaborators
# (tests/unit/controllers/test_no_contested_collaborator_state.gd).

const _SKATER: String = "res://Scripts/actors/skater.gd"

# holder → source file. Each is constructed and owned by Skater.
const _COLLABORATORS: Dictionary = {
	"_legs": "res://Scripts/actors/skater_leg_rig.gd",
	"_arms": "res://Scripts/actors/skater_arm_rig.gd",
	"_stick": "res://Scripts/actors/skater_stick_rig.gd",
	"_draw": "res://Scripts/actors/skater_draw_tracker.gd",
	"_uniform": "res://Scripts/actors/skater_uniform_coordinator.gd",
	"_hud": "res://Scripts/actors/skater_hud_coordinator.gd",
	"_appearance": "res://Scripts/actors/skater_appearance_coordinator.gd",
}


func _strip(src: String) -> String:
	var out := PackedStringArray()
	for line: String in src.split("\n"):
		var h: int = line.find("#")
		out.append(line if h < 0 else line.substr(0, h))
	return "\n".join(out)


func _skater_src() -> String:
	return _strip(FileAccess.get_file_as_string(_SKATER))


# Fields the class assigns to itself outside reset()/clear(). `(?!=)` after the
# `=` keeps `x == y` from reading as an assignment.
func _self_written(src: String) -> PackedStringArray:
	var out := PackedStringArray()
	var in_reset: bool = false
	var assign := RegEx.create_from_string(
			"^\\t+([a-z_][a-z_0-9]*)\\s*(?:=(?!=)|\\+=|-=|\\*=)\\s")
	for line: String in _strip(src).split("\n"):
		if line.begins_with("func ") or line.begins_with("static func "):
			in_reset = line.begins_with("func reset") or line.begins_with("func clear")
		if in_reset:
			continue
		var m: RegExMatch = assign.search(line)
		if m != null and not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	return out


func test_skater_never_writes_a_collaborator_field() -> void:
	var src: String = _skater_src()
	for holder: String in _COLLABORATORS:
		var collab: String = FileAccess.get_file_as_string(_COLLABORATORS[holder])
		assert_false(collab.is_empty(), "could not read %s" % _COLLABORATORS[holder])
		var theirs: PackedStringArray = _self_written(collab)
		var re := RegEx.create_from_string(
				"%s\\.([a-z_][a-z_0-9]*)\\s*(?:=(?!=)|\\+=|-=)\\s" % holder)
		for m: RegExMatch in re.search_all(src):
			var field: String = m.get_string(1)
			if not theirs.has(field):
				continue
			fail_test(("Skater writes %s.%s, which %s also writes. Whoever writes a " +
					"field decides when it changes — so Skater now owns that " +
					"lifecycle and the collaborator's own updater is dead code " +
					"waiting to happen.") % [holder, field, _COLLABORATORS[holder]])


func test_no_rig_writes_the_skaters_own_state() -> void:
	# The mirror. A rig may write NODES it was handed (that is what a rig does —
	# bone poses, mesh transforms) but never a field of the Skater script: those
	# are the replicated gameplay state and the tuning the controller applies,
	# and a second writer for either is a netcode bug with a cosmetic disguise.
	var skater_fields: PackedStringArray = _self_written(
			FileAccess.get_file_as_string(_SKATER))
	var assign := RegEx.create_from_string(
			"_skater\\.([a-z_][a-z_0-9]*)\\s*(?:=(?!=)|\\+=|-=|\\*=)\\s")
	for holder: String in ["_legs", "_arms", "_stick", "_draw"]:
		var path: String = _COLLABORATORS[holder]
		for m: RegExMatch in assign.search_all(
				_strip(FileAccess.get_file_as_string(path))):
			assert_false(skater_fields.has(m.get_string(1)),
					"%s writes _skater.%s, a field Skater writes too"
							% [path, m.get_string(1)])


func test_the_rigs_never_reach_for_each_other() -> void:
	# A rig naming a sibling is a lateral edge, and a const read across a GDScript
	# `class_name` cycle fails at PARSE time — taking every file in the cycle down
	# with it. The one allowed edge is the stick knob reading the arm rig's
	# look-at helper, which its cuff pose is copied from; it is one-way.
	const ALLOWED: Dictionary = {"skater_stick_rig.gd": "SkaterArmRig"}
	var names: Array[String] = ["SkaterLegRig", "SkaterArmRig", "SkaterStickRig",
			"SkaterDrawTracker"]
	for holder: String in ["_legs", "_arms", "_stick", "_draw"]:
		var path: String = _COLLABORATORS[holder]
		var src: String = _strip(FileAccess.get_file_as_string(path))
		var own: String = path.get_file()
		for other: String in names:
			if src.contains("class_name %s" % other):
				continue
			if ALLOWED.get(own, "") == other:
				continue
			assert_false(RegEx.create_from_string("\\b%s\\b" % other).search(src) != null,
					"%s names %s. Rigs are siblings; go through Skater." % [own, other])


func test_every_rig_is_built_before_the_passes_that_size_and_paint_it() -> void:
	# Build order inside _ready is load-bearing: the uniform pass installs the
	# shaft's flex ShaderMaterial and the appearance pass sizes bones through the
	# rigs' seams, so both need the rigs standing. A reorder puts the paint on a
	# mesh that does not exist yet and fails only in a live match.
	var ready_src: String = _skater_src().split("func _ready()")[1].split("\nfunc ")[0]
	var order: Array[String] = []
	for token: String in ["_legs.build()", "_arms.build()", "_stick.setup(self)",
			"_uniform = SkaterUniformCoordinator.new()",
			"_appearance = SkaterAppearanceCoordinator.new()"]:
		var at: int = ready_src.find(token)
		assert_gt(at, -1, "_ready no longer contains %s" % token)
		order.append("%08d %s" % [at, token])
	var sorted_order: Array[String] = order.duplicate()
	sorted_order.sort()
	assert_eq(order, sorted_order,
			"_ready must build the rigs before the uniform and appearance passes")


func test_a_seated_draw_tracker_is_free_until_it_is_armed() -> void:
	# The one behavioural guard: the tracker is per-skater and runs on every host
	# tick, so "zero cost unless armed" is a real claim. is_tracking() gating the
	# update is what makes it true, and an accidental default of true would put
	# the whole crest solve on every skater for the whole game.
	var tracker := SkaterDrawTracker.new()
	assert_false(tracker.is_tracking(), "a fresh tracker is idle")
	assert_eq(tracker.peak_velocity(), Vector3.ZERO)
	assert_eq(tracker.since_drop(), -1.0, "no drop marked yet reads as neutral")
	assert_true(_skater_src().contains("if _draw.is_tracking():"),
			"Skater must gate the per-tick update on is_tracking()")


func test_the_draw_crest_survives_a_decaying_swipe() -> void:
	# The whole point of the tracker: a well-aimed sweep that peaks a few ticks
	# BEFORE the drop still carries its crest into the contest, timed by the
	# shared host clock rather than by when the input landed.
	var tracker := SkaterDrawTracker.new()
	tracker.begin(6.0, 1.5)
	tracker.set_input_time(0.10)
	tracker.update(0.05, Vector3(9.0, 0.0, 0.0))       # the crest
	var crest: Vector3 = tracker.peak_velocity()
	assert_almost_eq(crest.length(), 9.0, 0.001, "the crest is the peak sweep")
	tracker.set_input_time(0.20)
	tracker.update(0.05, Vector3(1.0, 0.0, 0.0))       # swing has slowed
	assert_lt(tracker.peak_velocity().length(), 9.0, "the retained crest decays")
	assert_gt(tracker.peak_velocity().length(), 1.0, "but not to the live speed")
	assert_almost_eq(tracker.peak_velocity().normalized().dot(crest.normalized()),
			1.0, 0.0001, "and it holds the crest's heading while it sheds speed")
	tracker.mark_drop(0.15)
	assert_almost_eq(tracker.since_drop(), -0.05, 0.0001,
			"a crest that predates the drop reads as an early swing")


func test_the_draw_expires_on_its_own_after_the_drop() -> void:
	# A resolved draw must not leak a stale peak into later play, and nothing
	# guarantees end_draw_tracking is called on every path out of a faceoff.
	var tracker := SkaterDrawTracker.new()
	tracker.begin(6.0, 0.2)
	tracker.update(0.05, Vector3(9.0, 0.0, 0.0))
	tracker.mark_drop(0.0)
	for _i: int in 3:
		tracker.update(0.05, Vector3(9.0, 0.0, 0.0))
	assert_true(tracker.is_tracking(), "still inside the valid window")
	tracker.update(0.10, Vector3(9.0, 0.0, 0.0))
	assert_false(tracker.is_tracking(), "past the window it ends itself")
