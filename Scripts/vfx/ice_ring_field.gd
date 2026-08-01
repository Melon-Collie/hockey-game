class_name IceRingField
extends Node

# Feeds the ice shader's analytic on-ice HUD — player rings, elevation chevrons,
# the slapper one-timer indicator and the stamina gauge (see
# Shaders/ice.gdshader).
#
# Each ring used to be a MeshInstance3D per skater: a 48-segment alpha-blended
# disc, parented to the skater, sitting a few millimetres above the ice. Ten of
# those at 5v5 meant ten nodes, ten transparent draw calls in the depth-sorted
# pass, and ten transforms to propagate every frame — to draw something that is
# not an object at all. A ring under a player is just ice that is coloured
# differently near a position, so the ice shader computes it directly and this
# node's whole job is to hand it the positions.
#
# The chevrons, the slapper indicator and the stamina gauge followed for the same
# reason. The slapper indicator is the starkest case: five nodes on EVERY skater — a
# reticle, an arrow root, an arrow and a gapped convergence ring — plus an
# ArrayMesh rebuilt on convergence ticks, all so that at most ONE skater could
# show them. Being self-only, it needs no array here at all — nor does the
# stamina gauge.
#
# The per-frame cost that replaces all of it is a handful of
# set_shader_parameter calls, regardless of roster size. What it buys beyond the
# node count:
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
# shader stacks the rest itself, so a skater at HIGH loft — three marks, one per
# rung above flat — is still one entry.
var _chevrons: PackedVector4Array = PackedVector4Array()


func _init() -> void:
	_positions.resize(MAX_RINGS)
	_colors.resize(MAX_RINGS)
	_chevrons.resize(MAX_RINGS)


func setup(material: ShaderMaterial) -> void:
	_material = material
	# The neutral HUD stroke and the fixed stroke sizes never change, so they are
	# written once rather than per frame like the rings.
	_material.set_shader_parameter(&"hud_stroke_col", _linear_rgba(MenuStyle.HUD_ICE))
	# World-metre stroke sizes the shader cannot read from GDScript.
	_material.set_shader_parameter(&"hud_line_thin", MenuStyle.HUD_LINE_THIN)
	_material.set_shader_parameter(&"reticle_half_len",
			SkaterHUDCoordinator.RETICLE_HALF_LENGTH)
	_material.set_shader_parameter(&"chevron_stack_gap",
			SkaterHUDCoordinator.CHEVRON_STACK_GAP)
	_material.set_shader_parameter(&"stamina_inner_r",
			SkaterHUDCoordinator.STAMINA_RING_INNER_R)
	_material.set_shader_parameter(&"stamina_outer_r",
			SkaterHUDCoordinator.STAMINA_RING_OUTER_R)
	_material.set_shader_parameter(&"stamina_track_col",
			_linear_hud_rgba(SkaterHUDCoordinator.STAMINA_TRACK_COLOR))


# The shader's colour uniforms are LINEAR — see the note on ring_col in
# ice.gdshader. A `source_color` hint would normally handle this, but the
# conversion is not applied elementwise when the value arrives as a packed
# array, and doing it here keeps the two colour paths (per-ring array, single
# chevron uniform) converting identically. Alpha is not a colour and is left as
# authored.
static func _linear_rgba(c: Color) -> Vector4:
	var lin: Color = c.srgb_to_linear()
	return Vector4(lin.r, lin.g, lin.b, MenuStyle.HUD_OPACITY)


# As above, but KEEPING the colour's own alpha (scaled by the HUD opacity) rather
# than replacing it. The stamina gauge's track is deliberately fainter than its
# fill, so the two cannot share one opacity the way the rings do.
static func _linear_hud_rgba(c: Color) -> Vector4:
	var lin: Color = c.srgb_to_linear()
	return Vector4(lin.r, lin.g, lin.b, c.a * MenuStyle.HUD_OPACITY)


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
	# The slapper indicator is SELF-ONLY: at most one skater ever shows it, so it
	# is a handful of scalar uniforms rather than an array, and the first skater
	# reporting it wins. Checked BEFORE the ring gate below — the two are
	# independent pieces of chrome and one must not suppress the other.
	var slapper_seen: bool = false
	# Self-only for the same reason as the slapper indicator.
	var stamina_seen: bool = false
	for node: Node in get_tree().get_nodes_in_group("skaters"):
		var skater: Skater = node as Skater
		if skater == null:
			continue
		if not slapper_seen and skater.slapper_field_visible():
			slapper_seen = true
			var centre: Vector2 = skater.slapper_field_center()
			_material.set_shader_parameter(&"slapper_zone", Vector4(centre.x, centre.y,
					skater.slapper_field_radius(), skater.slapper_field_ring_scale()))
			_material.set_shader_parameter(&"slapper_dir", skater.slapper_field_arrow_dir())
			_material.set_shader_parameter(&"slapper_arrow",
					skater.slapper_field_arrow_visible())
		if not stamina_seen and skater.stamina_field_visible():
			stamina_seen = true
			var body: Vector3 = skater.global_position
			_material.set_shader_parameter(&"stamina_zone", Vector4(
					body.x, body.z, skater.stamina_field_fill(), 0.0))
			_material.set_shader_parameter(&"stamina_up", skater.stamina_field_up())
			_material.set_shader_parameter(&"stamina_fill_col",
					_linear_hud_rgba(skater.stamina_field_color()))
		if count >= MAX_RINGS or not skater.ring_field_visible():
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
	# Cleared explicitly: a stale `true` would leave the last charge's reticle
	# painted on the ice for the rest of the period.
	_material.set_shader_parameter(&"slapper_active", slapper_seen)
	_material.set_shader_parameter(&"stamina_active", stamina_seen)
