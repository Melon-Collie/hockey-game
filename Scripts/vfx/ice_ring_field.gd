class_name IceRingField
extends Node

# Feeds the ice shader's analytic player rings (see Shaders/ice.gdshader).
#
# Each ring used to be a MeshInstance3D per skater: a 48-segment alpha-blended
# disc, parented to the skater, sitting a few millimetres above the ice. Ten of
# those at 5v5 meant ten nodes, ten transparent draw calls in the depth-sorted
# pass, and ten transforms to propagate every frame — to draw something that is
# not an object at all. A ring under a player is just ice that is coloured
# differently near a position, so the ice shader computes it directly and this
# node's whole job is to hand it the positions.
#
# The per-frame cost that replaces all of it is three set_shader_parameter calls,
# regardless of roster size. What it buys beyond the node count:
#   • No transparency pass. Ten coplanar alpha quads used to be depth-sorted
#     against each other and everything else; the ring is now part of an opaque
#     surface.
#   • No z-fighting. The ring IS the ice, not a plane hovering above it.
#   • Analytic antialiasing (see the fwidth feather in the shader), so it holds
#     up at any camera height instead of faceting up close.
#
# Sibling of IceScratchMap: same place in the tree, same owner (HockeyRink), same
# job of turning live skater state into something the ice shader samples.

# Shader arrays are fixed-size, so this is the ceiling on simultaneous rings —
# sized past 5v5's ten so a roster change does not silently drop one. Kept in
# lockstep with the array length declared in ice.gdshader.
const MAX_RINGS: int = 12

var _material: ShaderMaterial = null
# Reused across frames — this runs every frame, and a fresh array per frame is
# exactly the per-tick heap churn the hot-path rules warn about. Always sent
# full-length (the shader reads only the first ring_count entries).
var _positions: PackedVector4Array = PackedVector4Array()
var _colors: PackedVector4Array = PackedVector4Array()
# Elevation chevrons ride along: xy = first apex, z = how many are stacked. The
# shader stacks the rest itself, so a skater at HIGH loft is still one entry.
var _chevrons: PackedVector4Array = PackedVector4Array()


func _init() -> void:
	_positions.resize(MAX_RINGS)
	_colors.resize(MAX_RINGS)
	_chevrons.resize(MAX_RINGS)


func setup(material: ShaderMaterial) -> void:
	_material = material
	# Every chevron shares the neutral HUD stroke, so it is a uniform written
	# once rather than a per-frame array like the rings.
	_material.set_shader_parameter(&"chevron_col", _linear_rgba(MenuStyle.HUD_ICE))


# The shader's colour uniforms are LINEAR — see the note on ring_col in
# ice.gdshader. A `source_color` hint would normally handle this, but the
# conversion is not applied elementwise when the value arrives as a packed
# array, and doing it here keeps the two colour paths (per-ring array, single
# chevron uniform) converting identically. Alpha is not a colour and is left as
# authored.
static func _linear_rgba(c: Color) -> Vector4:
	var lin: Color = c.srgb_to_linear()
	return Vector4(lin.r, lin.g, lin.b, MenuStyle.HUD_OPACITY)


func _process(_delta: float) -> void:
	if _material == null:
		return
	var count: int = 0
	var chevron_count: int = 0
	# Screen-down is a property of the CAMERA, not of any skater — every skater's
	# copy is the same value. Taken from whichever is seen first rather than
	# recomputed here, so the camera-change check that maintains it stays in one
	# place (SkaterHUDCoordinator) instead of being duplicated.
	var screen_down: Vector2 = Vector2(0.0, 1.0)
	for node: Node in get_tree().get_nodes_in_group("skaters"):
		if count >= MAX_RINGS:
			break
		var skater: Skater = node as Skater
		if skater == null or not skater.ring_field_visible():
			continue
		screen_down = skater.hud_screen_down()
		var stack: int = skater.chevron_field_stack()
		if stack > 0 and chevron_count < MAX_RINGS:
			var apex: Vector2 = skater.chevron_field_apex()
			_chevrons[chevron_count] = Vector4(apex.x, apex.y, float(stack), 0.0)
			chevron_count += 1
		# Interpolation-correct read, so the ring tracks the RENDERED skater
		# rather than the post-tick physics pose — the same reason IceScratchMap
		# uses it. As a child node the ring inherited this for free; driving it
		# from a uniform makes the choice explicit.
		var pos: Vector3 = skater.get_global_transform_interpolated().origin
		_positions[count] = Vector4(pos.x, pos.z,
				SkaterHUDCoordinator.RING_OUTER_R, SkaterHUDCoordinator.RING_INNER_R)
		_colors[count] = _linear_rgba(skater.ring_field_color())
		count += 1
	# Unused tail entries are left stale on purpose: the shader never reads past
	# ring_count, and zeroing them would be work to hide data nothing looks at.
	_material.set_shader_parameter(&"ring_pos", _positions)
	_material.set_shader_parameter(&"ring_col", _colors)
	_material.set_shader_parameter(&"ring_count", count)
	_material.set_shader_parameter(&"chevron_pos", _chevrons)
	_material.set_shader_parameter(&"chevron_count", chevron_count)
	_material.set_shader_parameter(&"hud_screen_down", screen_down)
