extends GutTest

# The net's response to being struck: HockeyGoal's impact ring buffer, and the
# contract between it and goal_net.gdshader.
#
# The contract matters more than it looks. `set_shader_parameter` on a name the
# shader does not declare is a silent no-op — no error, no warning — so a
# renamed uniform does not break the net, it just stops it moving forever, which
# is exactly the kind of thing nobody notices until a playtest.
#
# Everything here is read back through the PANELS rather than through the goal's
# own material reference, so each assertion also proves the material actually
# reached the mesh the player sees.

const _SHADER_PATH: String = "res://Shaders/goal_net.gdshader"
const _GOAL_PATH: String = "res://Scripts/actors/hockey_goal.gd"


func _make_goal() -> HockeyGoal:
	var goal := HockeyGoal.new()
	add_child_autofree(goal)
	return goal


# The live net panels. Skips anything already queue_freed: setting `facing`
# rebuilds the cage, and the previous generation's nodes are still children until
# the frame ends — reading one of those would report the material of a net that
# no longer exists.
func _panels(goal: HockeyGoal) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child: Node in goal.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.is_queued_for_deletion():
			continue
		if (mi.material_override as ShaderMaterial) != null:
			out.append(mi)
	return out


# The material as the panels actually carry it.
func _panel_material(goal: HockeyGoal) -> ShaderMaterial:
	var panels: Array[MeshInstance3D] = _panels(goal)
	return null if panels.is_empty() else panels[0].material_override as ShaderMaterial


func _impacts(goal: HockeyGoal) -> PackedVector4Array:
	return _panel_material(goal).get_shader_parameter(&"impact_origin_amp")


func _meta(goal: HockeyGoal) -> PackedVector4Array:
	return _panel_material(goal).get_shader_parameter(&"impact_start_radius")


func _dirs(goal: HockeyGoal) -> PackedVector4Array:
	return _panel_material(goal).get_shader_parameter(&"impact_dir")


# A point well inside the cage, and one behind the back twine.
func _inside(goal: HockeyGoal) -> Vector3:
	return Vector3(0.0, 0.5, goal.goal_line_z() + goal.facing * 0.6)


func _outside(goal: HockeyGoal) -> Vector3:
	return Vector3(0.0, 0.5, goal.goal_line_z() + goal.facing * (GameRules.NET_DEPTH + 0.4))


func test_panels_share_one_shader_material() -> void:
	var goal: HockeyGoal = _make_goal()
	var mats := {}
	var panels: Array[MeshInstance3D] = _panels(goal)
	for mi: MeshInstance3D in panels:
		mats[(mi.material_override as ShaderMaterial).get_instance_id()] = true
	assert_eq(panels.size(), 8,
			"the cage is eight twine panels: roof, back, two sides, two crown " +
			"gussets, two back-corner gussets")
	assert_eq(mats.size(), 1,
			"every panel must share ONE ShaderMaterial — an impact anywhere on the " +
			"cage is meant to be a single uniform write, not one per panel")


func test_shader_declares_every_uniform_the_goal_writes() -> void:
	var src: String = FileAccess.get_file_as_string(_SHADER_PATH)
	assert_false(src.is_empty(), "could not read %s" % _SHADER_PATH)
	var declared := PackedStringArray()
	for line: String in src.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with("uniform "):
			continue
		var decl: String = trimmed.trim_prefix("uniform ")
		for cut: String in [":", "=", ";", "["]:
			decl = decl.get_slice(cut, 0)
		var parts: PackedStringArray = decl.strip_edges().split(" ", false)
		if parts.size() >= 2:
			declared.append(parts[parts.size() - 1])

	var goal_src: String = FileAccess.get_file_as_string(_GOAL_PATH)
	assert_false(goal_src.is_empty(), "could not read %s" % _GOAL_PATH)
	var re := RegEx.create_from_string('set_shader_parameter\\(&"([a-zA-Z_0-9]+)"')
	var pushed := PackedStringArray()
	for m: RegExMatch in re.search_all(goal_src):
		if not pushed.has(m.get_string(1)):
			pushed.append(m.get_string(1))
	assert_gt(pushed.size(), 0, "found no set_shader_parameter calls — did the parser break?")
	for name: String in pushed:
		assert_true(declared.has(name),
				"HockeyGoal writes uniform '%s', which goal_net.gdshader does not declare — " % name +
				"that write is a silent no-op and the net would simply stop moving")


# HockeyGoal.IMPACT_LIFETIME is when it stops advancing the clock and zeroes the
# buffer; the shader's DECAY_TAU is how fast the bulge actually decays. A lifetime
# shorter than the decay snaps a still-visible bulge to flat.
func test_impact_lifetime_outlives_the_shader_decay() -> void:
	var src: String = FileAccess.get_file_as_string(_SHADER_PATH)
	var re := RegEx.create_from_string('const float DECAY_TAU = ([0-9.]+)')
	var m: RegExMatch = re.search(src)
	assert_not_null(m, "goal_net.gdshader must declare `const float DECAY_TAU = ...`")
	var tau: float = float(m.get_string(1))
	assert_gte(HockeyGoal.IMPACT_LIFETIME, tau * 4.0,
			"IMPACT_LIFETIME (%f) must cover at least 4 shader DECAY_TAUs (%f) or the buffer " %
			[HockeyGoal.IMPACT_LIFETIME, tau] +
			"is cleared while the panel is still visibly bulged, snapping it flat")


# Sign lives in the push DIRECTION, not the amplitude — the two ends of the rink
# have opposite outward normals, so there is no global "positive is outward".
func test_a_strike_from_inside_pushes_the_twine_out_of_the_cage() -> void:
	for facing: int in [1, -1]:
		var goal: HockeyGoal = _make_goal()
		goal.facing = facing
		var pos: Vector3 = _inside(goal)
		goal.net_impact(pos, 20.0)
		var dir: Vector4 = _dirs(goal)[0]
		assert_gt(dir.z * signf(goal.goal_line_z()), 0.0,
				"a puck arriving through the mouth at the %+d end pushes the back " % facing +
				"twine further from centre ice, not toward it")


func test_a_strike_from_outside_pushes_the_twine_in() -> void:
	for facing: int in [1, -1]:
		var goal: HockeyGoal = _make_goal()
		goal.facing = facing
		goal.net_impact(_outside(goal), 20.0)
		var dir: Vector4 = _dirs(goal)[0]
		assert_lt(dir.z * signf(goal.goal_line_z()), 0.0,
				"a puck pressing on the back mesh from behind pushes it INTO the cage")


# The seam property, and the reason the direction is a function of position
# rather than of the panel a vertex sits on: two panels meeting at a right angle
# must be pushed the SAME way, or a bulge opens a hole between them.
func test_one_impact_pushes_every_panel_the_same_way() -> void:
	var goal: HockeyGoal = _make_goal()
	goal.net_impact(_inside(goal), 20.0)
	var dir: Vector4 = _dirs(goal)[0]
	assert_almost_eq(Vector3(dir.x, dir.y, dir.z).length(), 1.0, 1e-5,
			"a strike carries ONE unit push direction for the whole cage — per-panel " +
			"face normals would move the two sides of a seam apart and tear the twine")
	assert_lt(dir.w, 0.5, "a puck strike is directional, not the radial celebration mode")


func test_bulge_scales_with_speed_and_saturates() -> void:
	var goal: HockeyGoal = _make_goal()
	goal.net_impact(_inside(goal), 5.0)
	var soft: float = _impacts(goal)[0].w
	goal.net_impact(_inside(goal), 15.0)
	var hard: float = _impacts(goal)[1].w
	assert_gt(hard, soft, "a harder shot must bury more twine")
	assert_almost_eq(soft, 5.0 * HockeyGoal.IMPACT_METRES_PER_MPS, 1e-6,
			"bulge is speed x IMPACT_METRES_PER_MPS below the cap")
	goal.net_impact(_inside(goal), 500.0)
	assert_almost_eq(_impacts(goal)[2].w, HockeyGoal.IMPACT_MAX_BULGE, 1e-6,
			"an absurd speed saturates at IMPACT_MAX_BULGE rather than turning the " +
			"mesh inside out")


func test_a_dead_puck_registers_nothing() -> void:
	var goal: HockeyGoal = _make_goal()
	goal.net_impact(_inside(goal), 0.0)
	assert_almost_eq(_impacts(goal)[0].w, 0.0, 1e-9,
			"a puck with no pace leaves the twine alone")


func test_the_ring_buffer_evicts_the_oldest_impact() -> void:
	var goal: HockeyGoal = _make_goal()
	var pos: Vector3 = _inside(goal)
	for i in HockeyGoal.MAX_IMPACTS:
		# Distinct speeds so slots are distinguishable.
		goal.net_impact(pos, float(i + 1))
	var first: float = _impacts(goal)[0].w
	goal.net_impact(pos, 30.0)
	assert_ne(_impacts(goal)[0].w, first,
			"a %dth impact must overwrite the oldest slot" % (HockeyGoal.MAX_IMPACTS + 1))
	assert_almost_eq(_impacts(goal)[0].w, 30.0 * HockeyGoal.IMPACT_METRES_PER_MPS, 1e-6,
			"and the newest impact is the one that lands there")


func test_the_celebration_is_one_wide_impact_on_the_same_path() -> void:
	var goal: HockeyGoal = _make_goal()
	goal.shake_for_goal()
	var impact: Vector4 = _impacts(goal)[0]
	var meta: Vector4 = _meta(goal)[0]
	assert_almost_eq(impact.w, HockeyGoal.CELEBRATION_BULGE, 1e-6,
			"the goal shake rides the impact buffer, not a displacement path of its own")
	assert_gt(meta.y, HockeyGoal.IMPACT_RADIUS,
			"and it is wider than a puck strike — the whole cage shakes at once")
	assert_gte(_dirs(goal)[0].w, 0.5,
			"and it billows radially: one fixed direction would shove the cage sideways " +
			"rather than swell it")


# An idle net must cost nothing per frame. The clock only runs while the twine
# is still moving.
func test_the_net_only_processes_while_an_impact_is_live() -> void:
	var goal: HockeyGoal = _make_goal()
	assert_false(goal.is_processing(), "a net at rest should not be ticking a clock")
	goal.net_impact(_inside(goal), 20.0)
	assert_true(goal.is_processing(), "a struck net advances its clock")
	# Past the lifetime in one step: the buffer clears and processing stops.
	goal._process(HockeyGoal.IMPACT_LIFETIME + 0.01)
	assert_false(goal.is_processing(), "once the twine settles the clock stops again")
	assert_almost_eq(_impacts(goal)[0].w, 0.0, 1e-9,
			"and the buffer is zeroed, so the shader's per-vertex loop skips every slot")
