class_name GoalieUniformCoordinator
extends RefCounted

# Paints the goalie uniform using a custom spatial shader on the body BoxMesh
# (goalie_jersey.gdshader) rather than the CylinderMesh + JerseyDecal viewport
# approach used for skaters. The body stays a BoxMesh so the visual silhouette
# matches the square hitbox of a heavily-padded goalie.
#
# Follows the SkaterUniformCoordinator pattern: takes a Goalie reference and
# reads all mesh refs from its public fields, so adding new visual nodes to
# Goalie doesn't require updating the setup() signature.
#
# Entry points match the skater coordinator interface:
#   apply_uniform(colors)           — full v2 colors dict → body shader + all meshes
#   apply_jersey_info(name, number) — repaint text decal only (cached colors reused)

const _ROUGH_PADS: float = 0.75  # leather-and-nylon pad face, between cloth and helmet
const _MAX_STRIPES: int = 5

const _JERSEY_SHADER: Shader = preload("res://Assets/Shaders/goalie_jersey.gdshader")

# Where the jersey ends and the pants band begins on the body solid, in the
# shader's normalized height (0 = collar, 1 = bottom). 0.72 lands just above
# the mesh's hip-crest station (body-local y −0.16) so the color split rides
# the silhouette split.
const _PANTS_START_NORM_Y: float = 0.72


var _goalie: Goalie
var _jersey_mat: ShaderMaterial
var _text_viewport: SubViewport
var _text_decal: GoalieTextDecal
var _shoulder_viewport: SubViewport
var _shoulder_decal: ShoulderDecal

# Cached for apply_jersey_info refresh.
var _text_color: Color = Color.WHITE
var _text_outline_color: Color = Color.BLACK
var _shoulder_color: Color = Color.WHITE
var _shoulder_text_color: Color = Color.BLACK
var _shoulder_outline_color: Color = Color.BLACK
var _player_name: String = ""
var _jersey_number: int = 0


func setup(goalie: Goalie) -> void:
	_goalie = goalie
	_create_jersey_material()
	_create_shoulder_viewport()


func apply_uniform(colors: Dictionary) -> void:
	var uniform: Dictionary = colors.uniform
	_text_color = colors.text
	_text_outline_color = colors.text_outline

	var jersey: Dictionary = uniform.jersey
	_jersey_mat.set_shader_parameter("base_color", jersey.base)
	_set_stripe_params(jersey.stripes)
	var yoke: Variant = jersey.yoke
	_jersey_mat.set_shader_parameter("yoke_enabled", yoke is Color)
	if yoke is Color:
		_jersey_mat.set_shader_parameter("yoke_color", yoke as Color)

	# The mask mesh bakes its cage as a dark per-facet vertex tint
	# (GoalieMeshBuilder._bake_cage_tint) — multiply it under the kit paint.
	var mask_mat: StandardMaterial3D = UniformPaint.solid(uniform.helmet, UniformPaint.ROUGH_HELMET)
	mask_mat.vertex_color_use_as_albedo = true
	_goalie.head_mesh.material_override = mask_mat

	var pads_mat: StandardMaterial3D = UniformPaint.solid(colors.goalie_pads, _ROUGH_PADS)
	_goalie.left_pad_mesh.material_override = pads_mat
	_goalie.right_pad_mesh.material_override = pads_mat.duplicate()
	# The glove (rim + pocket + cuff) and the blocker (board + hand) are each one
	# merged mesh wearing one material, so each is a single paint target.
	_goalie.glove_main_mesh.material_override = pads_mat.duplicate()
	_goalie.blocker_mesh.material_override = pads_mat.duplicate()

	var arms: Dictionary = uniform.arms
	_paint_cylinder_h(_goalie.glove_upper_arm, arms.upper)
	_paint_cylinder_h(_goalie.blocker_upper_arm, arms.upper)
	_paint_cylinder_h(_goalie.glove_forearm, arms.lower)
	_paint_cylinder_h(_goalie.blocker_forearm, arms.lower)

	_shoulder_color = uniform.shoulders.color
	_shoulder_text_color = uniform.shoulders.text
	_shoulder_outline_color = uniform.shoulders.outline
	_rebuild_shoulder_texture()

	var elbow_mat: StandardMaterial3D = UniformPaint.solid(arms.lower.base)
	_goalie.glove_elbow_sphere.material_override = elbow_mat
	_goalie.blocker_elbow_sphere.material_override = elbow_mat.duplicate()

	# Hip connectors — painted like pants (same horizontal stripe pipeline as
	# the skater's thigh cylinders, minus the per-side uv1_offset since these
	# connectors are too thin for side-stripe positioning to matter).
	_paint_mesh_h(_goalie.left_hip_connector, uniform.pants)
	_paint_mesh_h(_goalie.right_hip_connector, uniform.pants)

	# The body solid is torso THROUGH hips — its lower band paints as the
	# kit's pants (the mesh's hip flare marks the same line in silhouette;
	# see GoalieMeshBuilder._BODY_STATIONS).
	_jersey_mat.set_shader_parameter("pants_color", uniform.pants.base)
	_jersey_mat.set_shader_parameter("pants_start", _PANTS_START_NORM_Y)

	# Stick — the house design's goalie colorway (#586): all-white composite,
	# shaft through blade, the real-world goalie norm. The white tape knob is
	# geometry-side (Goalie._init_stick_knob) and never repaints.
	var stick_mat: StandardMaterial3D = StickStyle.make_goalie_stick_material()
	# Shaft, paddle and blade are one merged mesh (see GoalieMeshBuilder).
	_goalie.stick_shaft_mesh.material_override = stick_mat

	_rebuild_text_decal()


func apply_jersey_info(p_name: String, number: int) -> void:
	_player_name = p_name
	_jersey_number = number
	_rebuild_text_decal()
	_rebuild_shoulder_texture()


func _create_jersey_material() -> void:
	_jersey_mat = ShaderMaterial.new()
	_jersey_mat.shader = _JERSEY_SHADER

	_text_viewport = SubViewport.new()
	_text_viewport.name = "GoalieTextViewport"
	_text_viewport.size = Vector2i(GoalieTextDecal.IMG_W, GoalieTextDecal.IMG_H)
	_text_viewport.transparent_bg = true
	_text_viewport.disable_3d = true
	_text_viewport.handle_input_locally = false
	_text_viewport.gui_disable_input = true
	_text_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_goalie.add_child(_text_viewport)

	_text_decal = GoalieTextDecal.new()
	_text_decal.name = "GoalieTextDecal"
	_text_viewport.add_child(_text_decal)

	_jersey_mat.set_shader_parameter("text_decal", _text_viewport.get_texture())
	_goalie.body_mesh.material_override = _jersey_mat


# Shared SubViewport + ShoulderDecal for both shoulder spheres. Sphere U=0 is
# at +Z, so per-shoulder uv1_offset.x rotates the wrap a quarter turn each way
# to face the number outward: glove side (-X) gets -0.25, blocker side (+X) +0.25.
func _create_shoulder_viewport() -> void:
	_shoulder_viewport = SubViewport.new()
	_shoulder_viewport.name = "GoalieShoulderViewport"
	_shoulder_viewport.size = Vector2i(ShoulderDecal.IMG_W, ShoulderDecal.IMG_H)
	_shoulder_viewport.transparent_bg = false
	_shoulder_viewport.disable_3d = true
	_shoulder_viewport.handle_input_locally = false
	_shoulder_viewport.gui_disable_input = true
	_shoulder_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_goalie.add_child(_shoulder_viewport)

	_shoulder_decal = ShoulderDecal.new()
	_shoulder_decal.name = "GoalieShoulderDecal"
	_shoulder_viewport.add_child(_shoulder_decal)

	var tex: ViewportTexture = _shoulder_viewport.get_texture()
	var mat_glove := StandardMaterial3D.new()
	mat_glove.albedo_texture = tex
	mat_glove.roughness = UniformPaint.ROUGH_CLOTH
	mat_glove.uv1_offset = Vector3(-0.25, 0.0, 0.0)
	BodyRim.apply(mat_glove)
	_goalie.glove_shoulder_sphere.material_override = mat_glove
	var mat_blocker := StandardMaterial3D.new()
	mat_blocker.albedo_texture = tex
	mat_blocker.roughness = UniformPaint.ROUGH_CLOTH
	mat_blocker.uv1_offset = Vector3(0.25, 0.0, 0.0)
	BodyRim.apply(mat_blocker)
	_goalie.blocker_shoulder_sphere.material_override = mat_blocker


func _rebuild_shoulder_texture() -> void:
	if _shoulder_decal == null:
		return
	_shoulder_decal.update_shoulder(
			_shoulder_color, _jersey_number, _shoulder_text_color, _shoulder_outline_color)
	_shoulder_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# Packs up to _MAX_STRIPES stripe definitions from the v2 stripes array into
# the shader's fixed-size uniform arrays.
func _set_stripe_params(stripes: Array[Dictionary]) -> void:
	var count: int = mini(stripes.size(), _MAX_STRIPES)
	_jersey_mat.set_shader_parameter("stripe_count", count)

	var colors: Array[Color] = []
	var positions: PackedFloat32Array = PackedFloat32Array()
	var widths: PackedFloat32Array = PackedFloat32Array()
	for i: int in range(_MAX_STRIPES):
		if i < count:
			colors.append(stripes[i].color as Color)
			positions.append(float(stripes[i].pos))
			widths.append(float(stripes[i].width))
		else:
			colors.append(Color.WHITE)
			positions.append(0.0)
			widths.append(0.0)
	_jersey_mat.set_shader_parameter("stripe_colors", colors)
	_jersey_mat.set_shader_parameter("stripe_positions", positions)
	_jersey_mat.set_shader_parameter("stripe_widths", widths)


func _rebuild_text_decal() -> void:
	_text_decal.update_text(_player_name, _jersey_number, _text_color, _text_outline_color)
	_text_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# Paints an arm bone. The bone IS the MeshInstance3D (Goalie._make_arm_bone), not
# a wrapper around a child mesh.
func _paint_cylinder_h(bone: Node3D, segment: Dictionary) -> void:
	var visual: MeshInstance3D = bone as MeshInstance3D
	if visual == null:
		return
	_paint_mesh_h(visual, segment)


# Paints any MeshInstance3D directly with horizontal stripes (or solid).
func _paint_mesh_h(visual: MeshInstance3D, segment: Dictionary) -> void:
	if visual == null:
		return
	var stripes: Array = segment.get("stripes", []) as Array
	if stripes.is_empty():
		visual.material_override = UniformPaint.solid(segment.base)
		return
	var tex: ImageTexture = UniformPaint.h_stripes(segment.base, stripes)
	visual.material_override = UniformPaint.textured(tex)
