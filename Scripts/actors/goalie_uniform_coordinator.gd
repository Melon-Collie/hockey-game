class_name GoalieUniformCoordinator
extends RefCounted

# Paints the goalie jersey using the same SubViewport + JerseyDecal pipeline as
# SkaterUniformCoordinator. The goalie body BoxMesh is replaced with a CylinderMesh
# so the jersey texture maps cleanly with uv1_offset.x = 0.25 (same UV convention
# as the skater torso: back-center of the cylinder lands at +Z).
#
# Entry points match the skater coordinator interface:
#   apply_uniform(colors)           — full v2 colors dict → jersey + solid pads/helmet
#   apply_jersey_info(name, number) — repaint jersey decal only (cached colors reused)

const _ROUGH_CLOTH: float = 0.9
const _ROUGH_HELMET: float = 0.28
const _ROUGH_PADS: float = 0.75
const _BODY_RADIUS: float = 0.22
const _BODY_HEIGHT: float = 0.6
const _BODY_SEGMENTS: int = 20

var _goalie: Goalie
var _body_mesh: MeshInstance3D
var _head_mesh: MeshInstance3D
var _left_pad_mesh: MeshInstance3D
var _right_pad_mesh: MeshInstance3D
var _glove_mesh: MeshInstance3D
var _blocker_mesh: MeshInstance3D

var _jersey_viewport: SubViewport
var _jersey_decal: JerseyDecal

# Cached so apply_jersey_info can repaint without re-supplying uniform data.
var _jersey_base_color: Color = Color.WHITE
var _jersey_yoke_color: Variant = null
var _jersey_stripes: Array[Dictionary] = []
var _player_name: String = ""
var _jersey_number: int = 0
var _text_color: Color = Color.BLACK
var _text_outline_color: Color = Color.BLACK


func setup(goalie: Goalie, body_mesh: MeshInstance3D, head_mesh: MeshInstance3D,
		left_pad_mesh: MeshInstance3D, right_pad_mesh: MeshInstance3D,
		glove_mesh: MeshInstance3D, blocker_mesh: MeshInstance3D) -> void:
	_goalie = goalie
	_body_mesh = body_mesh
	_head_mesh = head_mesh
	_left_pad_mesh = left_pad_mesh
	_right_pad_mesh = right_pad_mesh
	_glove_mesh = glove_mesh
	_blocker_mesh = blocker_mesh
	_init_body_mesh()
	_create_jersey_viewport()


func apply_uniform(colors: Dictionary) -> void:
	var uniform: Dictionary = colors.uniform
	_text_color = colors.text
	_text_outline_color = colors.text_outline
	_jersey_base_color = uniform.jersey.base
	_jersey_yoke_color = uniform.jersey.yoke
	_jersey_stripes = uniform.jersey.stripes
	_rebuild_jersey_texture()
	_head_mesh.material_override = _make_solid_mat(uniform.helmet, _ROUGH_HELMET)
	var pads_mat: StandardMaterial3D = _make_solid_mat(colors.goalie_pads, _ROUGH_PADS)
	_left_pad_mesh.material_override = pads_mat
	_right_pad_mesh.material_override = pads_mat.duplicate()
	_glove_mesh.material_override = pads_mat.duplicate()
	_blocker_mesh.material_override = pads_mat.duplicate()


func apply_jersey_info(p_name: String, number: int) -> void:
	_player_name = p_name
	_jersey_number = number
	_rebuild_jersey_texture()


func _init_body_mesh() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = _BODY_RADIUS
	cyl.bottom_radius = _BODY_RADIUS
	cyl.height = _BODY_HEIGHT
	cyl.radial_segments = _BODY_SEGMENTS
	_body_mesh.mesh = cyl


# Spawns the SubViewport + JerseyDecal and points the body material at the
# viewport texture. Same pattern as SkaterUniformCoordinator._create_jersey_viewport.
func _create_jersey_viewport() -> void:
	_jersey_viewport = SubViewport.new()
	_jersey_viewport.name = "GoalieJerseyViewport"
	_jersey_viewport.size = Vector2i(JerseyDecal.IMG_W, JerseyDecal.IMG_H)
	_jersey_viewport.transparent_bg = false
	_jersey_viewport.disable_3d = true
	_jersey_viewport.handle_input_locally = false
	_jersey_viewport.gui_disable_input = true
	_jersey_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_goalie.add_child(_jersey_viewport)

	_jersey_decal = JerseyDecal.new()
	_jersey_decal.name = "GoalieJerseyDecal"
	_jersey_viewport.add_child(_jersey_decal)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _jersey_viewport.get_texture()
	mat.roughness = _ROUGH_CLOTH
	mat.uv1_offset = Vector3(0.25, 0.0, 0.0)
	_body_mesh.material_override = mat


func _rebuild_jersey_texture() -> void:
	if _jersey_decal == null:
		return
	_jersey_decal.update_jersey(
			_jersey_base_color, _jersey_yoke_color, _jersey_stripes,
			_player_name, _jersey_number, _text_color, _text_outline_color)
	_jersey_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _make_solid_mat(color: Color, roughness: float = _ROUGH_CLOTH) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat
