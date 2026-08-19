extends GutTest

# Every uniform IceRingField writes must be one ice.gdshader declares.
#
# This replaces a "MIRRORED in Shaders/ice.gdshader — keep the two in sync"
# comment that turned out to describe a relationship that did not exist: the four
# arrow-geometry constants it governed were unreferenced leftovers (the shader owns
# that geometry outright), and the values that DO cross the boundary —
# reticle_half_len, chevron_stack_gap, the stamina radii — are pushed by
# IceRingField rather than duplicated, so they cannot drift.
#
# What can go wrong is the other thing, and it is worse because it is silent:
# `set_shader_parameter` on a name the shader does not declare is a no-op. No
# error, no warning, no visible failure at load — the HUD element simply draws
# with the shader's own default forever. Renaming a uniform in the shader, or
# fat-fingering one on the GDScript side, produces exactly that.
#
# IceRingField is the whole GDScript surface of this material (setup() takes the
# one ShaderMaterial and every write in the file targets it), so the two files
# here are the entire contract.

const _SHADER_PATH: String = "res://Shaders/ice.gdshader"
const _PUSHER_PATH: String = "res://Scripts/vfx/ice_ring_field.gd"


func _declared_uniforms() -> PackedStringArray:
	var src: String = FileAccess.get_file_as_string(_SHADER_PATH)
	assert_false(src.is_empty(), "could not read %s" % _SHADER_PATH)
	var names := PackedStringArray()
	for line: String in src.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with("uniform "):
			continue
		# `uniform vec4 ring_pos[12];` / `uniform float x : hint_range(..) = 1.0;`
		var decl: String = trimmed.trim_prefix("uniform ")
		for cut: String in [":", "=", ";", "["]:
			decl = decl.get_slice(cut, 0)
		var parts: PackedStringArray = decl.strip_edges().split(" ", false)
		if parts.size() >= 2:
			names.append(parts[parts.size() - 1])
	return names


func _pushed_uniforms() -> PackedStringArray:
	var src: String = FileAccess.get_file_as_string(_PUSHER_PATH)
	assert_false(src.is_empty(), "could not read %s" % _PUSHER_PATH)
	var names := PackedStringArray()
	var re := RegEx.create_from_string('set_shader_parameter\\(&"([a-zA-Z_0-9]+)"')
	for m: RegExMatch in re.search_all(src):
		var name: String = m.get_string(1)
		if not names.has(name):
			names.append(name)
	return names


func test_shader_declares_every_uniform_the_ring_field_writes() -> void:
	var declared: PackedStringArray = _declared_uniforms()
	var pushed: PackedStringArray = _pushed_uniforms()
	assert_gt(pushed.size(), 0, "found no set_shader_parameter calls — did the parser break?")
	for name: String in pushed:
		assert_true(declared.has(name),
				"IceRingField writes `%s`, which ice.gdshader does not declare. " % name +
				"set_shader_parameter is silent on an unknown name, so this draws " +
				"with the shader default and nothing reports it.")


# The parser is the test's only moving part, so it gets its own floor: if either
# file is restructured such that nothing matches, the assertion above would pass
# vacuously over an empty list.
func test_parsers_still_see_both_sides() -> void:
	assert_gt(_declared_uniforms().size(), 20,
			"expected ice.gdshader to declare many uniforms — parser may have broken")
	assert_true(_declared_uniforms().has("ring_pos"),
			"uniform parser must find `ring_pos`, an array-typed declaration")
	assert_true(_pushed_uniforms().has("stamina_inner_r"),
			"push parser must find `stamina_inner_r`")
