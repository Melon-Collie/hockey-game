class_name GoalieUniformCoordinator
extends RefCounted

# Paints the goalie uniform using a custom spatial shader on the body BoxMesh
# (goalie_jersey.gdshader) rather than the CylinderMesh + JerseyDecal viewport
# approach used for skaters. The body stays a BoxMesh so the visual silhouette
# matches the square hitbox of a heavily-padded goalie.
#
# Jersey stripes are placed in object-space Y by the shader — no UV layout
# knowledge required. Name/number are rendered into a face-proportioned
# SubViewport (GoalieTextDecal) and projected onto the ±Z faces by the shader.
#
# Entry points match the skater coordinator interface:
#   apply_uniform(colors)           — full v2 colors dict → body shader params + solid pads
#   apply_jersey_info(name, number) — repaint text decal only (cached colors reused)

const _ROUGH_HELMET: float = 0.28
const _ROUGH_PADS: float = 0.75
const _MAX_STRIPES: int = 5

const _JERSEY_SHADER: Shader = preload("res://Assets/Shaders/goalie_jersey.gdshader")

var _goalie: Goalie
var _body_mesh: MeshInstance3D
var _head_mesh: MeshInstance3D
var _left_pad_mesh: MeshInstance3D
var _right_pad_mesh: MeshInstance3D
var _glove_mesh: MeshInstance3D
var _blocker_mesh: MeshInstance3D

var _jersey_mat: ShaderMaterial
var _text_viewport: SubViewport
var _text_decal: GoalieTextDecal

var _glove_upper_arm: Node3D
var _glove_forearm: Node3D
var _blocker_upper_arm: Node3D
var _blocker_forearm: Node3D

# Cached for apply_jersey_info refresh.
var _text_color: Color = Color.WHITE
var _text_outline_color: Color = Color.BLACK
var _player_name: String = ""
var _jersey_number: int = 0


func setup(goalie: Goalie, body_mesh: MeshInstance3D, head_mesh: MeshInstance3D,
		left_pad_mesh: MeshInstance3D, right_pad_mesh: MeshInstance3D,
		glove_mesh: MeshInstance3D, blocker_mesh: MeshInstance3D,
		glove_upper_arm: Node3D, glove_forearm: Node3D,
		blocker_upper_arm: Node3D, blocker_forearm: Node3D) -> void:
	_goalie = goalie
	_body_mesh = body_mesh
	_head_mesh = head_mesh
	_left_pad_mesh = left_pad_mesh
	_right_pad_mesh = right_pad_mesh
	_glove_mesh = glove_mesh
	_blocker_mesh = blocker_mesh
	_glove_upper_arm = glove_upper_arm
	_glove_forearm = glove_forearm
	_blocker_upper_arm = blocker_upper_arm
	_blocker_forearm = blocker_forearm
	_create_jersey_material()


func apply_uniform(colors: Dictionary) -> void:
	var uniform: Dictionary = colors.uniform
	_text_color = colors.text
	_text_outline_color = colors.text_outline

	var jersey: Dictionary = uniform.jersey
	_jersey_mat.set_shader_parameter("base_color", jersey.base)
	_set_stripe_params(jersey.stripes)

	_head_mesh.material_override = _make_solid_mat(uniform.helmet, _ROUGH_HELMET)
	var pads_mat: StandardMaterial3D = _make_solid_mat(colors.goalie_pads, _ROUGH_PADS)
	_left_pad_mesh.material_override = pads_mat
	_right_pad_mesh.material_override = pads_mat.duplicate()
	_glove_mesh.material_override = pads_mat.duplicate()
	_blocker_mesh.material_override = pads_mat.duplicate()

	var arms: Dictionary = uniform.arms
	_paint_cylinder_h(_glove_upper_arm, arms.upper)
	_paint_cylinder_h(_blocker_upper_arm, arms.upper)
	_paint_cylinder_h(_glove_forearm, arms.lower)
	_paint_cylinder_h(_blocker_forearm, arms.lower)

	# Repaint text with new team text colors (number/name unchanged).
	_rebuild_text_decal()


func apply_jersey_info(p_name: String, number: int) -> void:
	_player_name = p_name
	_jersey_number = number
	_rebuild_text_decal()


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
	_body_mesh.material_override = _jersey_mat


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


func _paint_cylinder_h(bone: Node3D, segment: Dictionary) -> void:
	var visual: MeshInstance3D = _bone_visual(bone)
	if visual == null:
		return
	var stripes: Array = segment.get("stripes", []) as Array
	if stripes.is_empty():
		visual.material_override = _make_solid_mat(segment.base)
		return
	var tex: ImageTexture = _make_h_stripes_texture(segment.base, stripes)
	visual.material_override = _make_texture_material(tex)


func _bone_visual(bone: Node3D) -> MeshInstance3D:
	if bone == null:
		return null
	return bone.get_node_or_null("Cylinder") as MeshInstance3D


const _CYLINDER_SIDE_V_FRACTION: float = 0.5
const _STRIPE_TEX_HEIGHT_PX: int = 128
const _STRIPE_TEX_WIDTH_PX: int = 4

func _make_h_stripes_texture(base: Color, stripes: Array) -> ImageTexture:
	var img := Image.create(_STRIPE_TEX_WIDTH_PX, _STRIPE_TEX_HEIGHT_PX, false, Image.FORMAT_RGBA8)
	img.fill(base)
	var side_px: int = int(round(_CYLINDER_SIDE_V_FRACTION * float(_STRIPE_TEX_HEIGHT_PX)))
	for s: Dictionary in stripes:
		var center_px: float = float(s.pos) * float(side_px)
		var half_px: float = float(s.width) * float(side_px) * 0.5
		var y0: int = clampi(int(round(center_px - half_px)), 0, side_px)
		var y1: int = clampi(int(round(center_px + half_px)), 0, side_px)
		if y1 > y0:
			img.fill_rect(Rect2i(0, y0, _STRIPE_TEX_WIDTH_PX, y1 - y0), s.color)
	return ImageTexture.create_from_image(img)


const _ROUGH_CLOTH: float = 0.9

func _make_texture_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = _ROUGH_CLOTH
	return mat


func _make_solid_mat(color: Color, roughness: float = _ROUGH_CLOTH) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat
