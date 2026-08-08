class_name GoalVFX
extends Node3D

# Goal lamp strobe: energy of the red wash light, emission of the dome
# fixture, flash count/timing. The lamp reads as the classic behind-the-glass
# red light — no shadows on the light, so the wash reaches the end-zone ice
# through the boards.
const LAMP_COLOR := Color(1.0, 0.07, 0.07)
const LAMP_MAX_ENERGY: float = 5.0
const DOME_MAX_EMISSION: float = 4.5
const LAMP_FLASHES: int = 6
const LAMP_RISE_TIME: float = 0.10
const LAMP_FALL_TIME: float = 0.24
const LAMP_FADE_TIME: float = 0.6
const NET_RIPPLE_PEAK: float = 0.22
# Clamp bracket under the base, wrapping the glass top edge (glass is 0.05
# thick, centered on the fixture) so the lamp reads as mounted, not floating.
const BRACKET_SIZE := Vector3(0.14, 0.12, 0.10)
const FIXTURE_COLOR := Color(0.15, 0.15, 0.17)

var _particles: GPUParticles3D = null
var _light: OmniLight3D = null
var _lamp_light: OmniLight3D = null
var _dome_mat: StandardMaterial3D = null
var _net_material: ShaderMaterial = null
var _lamp_tween: Tween = null

func _ready() -> void:
	_particles = GPUParticles3D.new()
	_particles.amount = 60
	_particles.lifetime = 1.5
	_particles.one_shot = true
	_particles.explosiveness = 0.9
	_particles.fixed_fps = 60
	_particles.local_coords = false
	_particles.emitting = false

	var process_mat := ParticleProcessMaterial.new()
	process_mat.direction = Vector3(0.0, 1.0, 0.0)
	process_mat.spread = 70.0
	process_mat.initial_velocity_min = 3.0
	process_mat.initial_velocity_max = 9.0
	process_mat.gravity = Vector3(0.0, -5.0, 0.0)
	process_mat.scale_min = 0.06
	process_mat.scale_max = 0.14
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.9, 0.3, 1.0))
	grad.set_color(1, Color(1.0, 0.9, 0.3, 0.0))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad
	process_mat.color_ramp = grad_tex
	_particles.process_material = process_mat

	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 4
	sphere.rings = 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	sphere.material = mat
	_particles.draw_pass_1 = sphere
	add_child(_particles)

	_light = OmniLight3D.new()
	_light.omni_range = 7.0
	_light.light_energy = 0.0
	_light.light_color = Color(1.0, 0.85, 0.3)
	add_child(_light)


# Called by HockeyGoal after this node is in the tree (game runtime only, not
# in the editor). net_material is the shared ShaderMaterial on the net panels
# (for the goal ripple); lamp_local_pos places the lamp fixture atop the
# glass behind this net, expressed relative to this node.
func setup(net_material: ShaderMaterial, lamp_local_pos: Vector3) -> void:
	_net_material = net_material
	_build_lamp(lamp_local_pos)


func celebrate() -> void:
	_particles.restart()
	_light.light_energy = 2.5
	var tween := create_tween()
	tween.tween_property(_light, "light_energy", 0.0, 1.8)
	_strobe_lamp()
	_ripple_net()


func _build_lamp(lamp_local_pos: Vector3) -> void:
	_lamp_light = OmniLight3D.new()
	_lamp_light.omni_range = 13.0
	_lamp_light.light_energy = 0.0
	_lamp_light.light_color = LAMP_COLOR
	_lamp_light.position = lamp_local_pos
	add_child(_lamp_light)

	var fixture_mat := StandardMaterial3D.new()
	fixture_mat.albedo_color = FIXTURE_COLOR

	var base_mesh := CylinderMesh.new()
	base_mesh.height = 0.10
	base_mesh.top_radius = 0.11
	base_mesh.bottom_radius = 0.11
	base_mesh.material = fixture_mat
	var base_inst := MeshInstance3D.new()
	base_inst.mesh = base_mesh
	base_inst.position = lamp_local_pos
	add_child(base_inst)

	var bracket_mesh := BoxMesh.new()
	bracket_mesh.size = BRACKET_SIZE
	bracket_mesh.material = fixture_mat
	var bracket_inst := MeshInstance3D.new()
	bracket_inst.mesh = bracket_mesh
	bracket_inst.position = lamp_local_pos \
			+ Vector3(0.0, -(base_mesh.height + BRACKET_SIZE.y) / 2.0, 0.0)
	add_child(bracket_inst)

	var dome_mesh := SphereMesh.new()
	dome_mesh.radius = 0.10
	dome_mesh.height = 0.10
	dome_mesh.is_hemisphere = true
	_dome_mat = StandardMaterial3D.new()
	_dome_mat.albedo_color = Color(0.45, 0.03, 0.03)
	_dome_mat.emission_enabled = true
	_dome_mat.emission = LAMP_COLOR
	_dome_mat.emission_energy_multiplier = 0.0
	dome_mesh.material = _dome_mat
	var dome_inst := MeshInstance3D.new()
	dome_inst.mesh = dome_mesh
	dome_inst.position = lamp_local_pos + Vector3(0.0, 0.05, 0.0)
	add_child(dome_inst)


func _strobe_lamp() -> void:
	if _lamp_light == null:
		return
	if _lamp_tween != null and _lamp_tween.is_valid():
		_lamp_tween.kill()
	_lamp_tween = create_tween()
	for _i in range(LAMP_FLASHES):
		_lamp_tween.tween_method(_apply_lamp, 0.25, 1.0, LAMP_RISE_TIME)
		_lamp_tween.tween_method(_apply_lamp, 1.0, 0.25, LAMP_FALL_TIME)
	_lamp_tween.tween_method(_apply_lamp, 0.25, 0.0, LAMP_FADE_TIME)


func _apply_lamp(intensity: float) -> void:
	_lamp_light.light_energy = intensity * LAMP_MAX_ENERGY
	_dome_mat.emission_energy_multiplier = intensity * DOME_MAX_EMISSION


func _ripple_net() -> void:
	if _net_material == null:
		return
	_net_material.set_shader_parameter("ripple_amount", 0.0)
	var tween := create_tween()
	tween.tween_property(_net_material, "shader_parameter/ripple_amount", NET_RIPPLE_PEAK, 0.06)
	var settle := tween.tween_property(_net_material, "shader_parameter/ripple_amount", 0.0, 0.9)
	settle.set_trans(Tween.TRANS_CUBIC)
	settle.set_ease(Tween.EASE_OUT)
