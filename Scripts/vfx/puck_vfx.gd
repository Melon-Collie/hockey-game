class_name PuckVFX
extends Node3D

const ICE_Y: float = 0.005               # world Y for grounded trail dots (just above ice to avoid z-fighting)

# Trail uses two GPUParticles3D nodes:
#   _trail_emitter  — runs the gap-filling particles shader (amount=1, lives forever).
#                     Each frame it measures how far the puck moved and emits one sub-particle
#                     every TRAIL_SPACING meters along that path, so there are never gaps
#                     regardless of puck speed.
#   _trail_particles — the sub-emitter that actually renders each trail dot. Receives
#                      world-space positions from the parent shader and fades them out
#                      over TRAIL_LIFETIME seconds.
const TRAIL_SPACING: float = 0.045  # meters between trail dots (~puck diameter); trail appears above ~4 m/s
const TRAIL_LIFETIME: float = 0.25  # seconds each dot lingers
const TRAIL_AMOUNT: int = 150       # max concurrent trail dots (covers ~25 m/s at 60 fps with 0.25 s lifetime)

# Speed-reactive color: cream at slow, hot orange at fast.
const TRAIL_COLOR_SLOW: Color = Color(0.95, 0.93, 0.88, 1.0)
const TRAIL_COLOR_FAST: Color = Color(1.0, 0.45, 0.05, 1.0)
const TRAIL_SPEED_MIN: float = 3.0   # m/s — at or below this, full slow color
const TRAIL_SPEED_MAX: float = 18.0  # m/s — at or above this, full fast color

var _puck: Puck = null
var _trail_emitter: GPUParticles3D = null
var _trail_particles: GPUParticles3D = null
var _trail_mat: ParticleProcessMaterial = null
var _stick_lift_burst: CPUParticles3D = null
var _prev_pos: Vector3 = Vector3.ZERO

func _ready() -> void:
	_puck = get_parent() as Puck
	# Sub-emitter must be added first so the parent can reference it by path.
	_trail_particles = _make_trail_sub_emitter()
	add_child(_trail_particles)

	_trail_emitter = _make_trail_emitter()
	add_child(_trail_emitter)
	# NodePath from TrailEmitter to its sibling TrailParticles.
	_trail_emitter.sub_emitter = NodePath("../TrailParticles")

	_stick_lift_burst = _make_stick_lift_emitter()
	add_child(_stick_lift_burst)

	_prev_pos = global_position


# One-shot spark pop when a stick lift strips the puck. Anchored to the puck via
# this node's transform, so it fires wherever the dislodge happened. local_coords
# off keeps the sparks in world space as the freed puck starts moving.
func fire_stick_lift_burst() -> void:
	if _stick_lift_burst != null:
		_stick_lift_burst.restart()

func _process(delta: float) -> void:
	var curr_pos: Vector3 = global_position
	var vel: Vector3 = (curr_pos - _prev_pos) / delta if delta > 0.0 else Vector3.ZERO
	_prev_pos = curr_pos

	# When grounded, pin the emitter to ice level so trail dots scrape the ice surface.
	# When airborne, follow the puck's actual Y so the trail goes with it.
	var target_y: float = curr_pos.y if _puck.is_airborne() else ICE_Y
	_trail_emitter.position.y = target_y - curr_pos.y  # local offset relative to PuckVFX parent

	# Speed-reactive color: lerp from cream (slow) to hot orange (fast).
	var flat_speed: float = Vector3(vel.x, 0.0, vel.z).length()
	var t: float = clampf((flat_speed - TRAIL_SPEED_MIN) / (TRAIL_SPEED_MAX - TRAIL_SPEED_MIN), 0.0, 1.0)
	_trail_mat.color = TRAIL_COLOR_SLOW.lerp(TRAIL_COLOR_FAST, t)

# The gap-filling parent emitter. One particle lives for the whole game session and
# tracks the puck's world position in CUSTOM.xyz each frame. When the puck moves more
# than TRAIL_SPACING meters since the last recorded position, it emits a sub-particle
# at each spacing interval along that path — filling the gap that would otherwise
# appear at high speeds.
func _make_trail_emitter() -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.name = "TrailEmitter"
	e.amount = 1
	e.lifetime = 3600.0  # effectively permanent; one particle tracks position all game
	e.one_shot = false
	e.explosiveness = 0.0
	e.fixed_fps = 0
	e.local_coords = false
	e.emitting = true

	var shader := Shader.new()
	shader.code = """shader_type particles;

void start() {
	CUSTOM.xyz = EMISSION_TRANSFORM[3].xyz;
}

void process() {
	float spacing = %f;
	for (int i = 0; i < int(distance(EMISSION_TRANSFORM[3].xyz, CUSTOM.xyz) / spacing); i++) {
		CUSTOM.xyz += normalize(EMISSION_TRANSFORM[3].xyz - CUSTOM.xyz) * spacing;
		mat4 custom_transform = mat4(1.0);
		custom_transform[3].xyz = CUSTOM.xyz;
		emit_subparticle(custom_transform, vec3(0.0), vec4(0.0), vec4(0.0), FLAG_EMIT_POSITION);
	}
}
""" % TRAIL_SPACING

	var mat := ShaderMaterial.new()
	mat.shader = shader
	e.process_material = mat

	return e

# The sub-emitter that renders each trail dot placed by the gap-filling shader.
# Receives world-space positions only (no velocity). Color is driven each frame
# by speed via _trail_mat.color; the ramp handles the age-based alpha fade.
func _make_trail_sub_emitter() -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.name = "TrailParticles"
	e.amount = TRAIL_AMOUNT
	e.lifetime = TRAIL_LIFETIME
	e.one_shot = false
	e.explosiveness = 0.0
	e.fixed_fps = 0
	e.local_coords = false
	e.emitting = false  # driven exclusively by the parent shader via emit_subparticle

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3.ZERO
	mat.spread = 0.0
	mat.initial_velocity_min = 0.0
	mat.initial_velocity_max = 0.0
	mat.gravity = Vector3.ZERO
	mat.color = TRAIL_COLOR_SLOW
	# color_ramp is white → transparent: pure alpha fade that lets mat.color drive the hue.
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 0.85))
	grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad
	mat.color_ramp = grad_tex
	e.process_material = mat
	_trail_mat = mat

	# Flat disk lying on the ice. CylinderMesh with negligible height gives a
	# circular scrape mark; cull_mode disabled so it's visible from above.
	var disk := CylinderMesh.new()
	disk.top_radius = 0.04
	disk.bottom_radius = 0.04
	disk.height = 0.003
	disk.radial_segments = 10
	disk.rings = 1
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_mat.albedo_color = Color.WHITE
	mesh_mat.vertex_color_use_as_albedo = true  # color_ramp * mat.color drives the final color
	mesh_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	disk.material = mesh_mat
	e.draw_pass_1 = disk

	return e

# Small upward spark fan — the "pop" of the stick getting lifted. Brief, explosive,
# light gravity so the sparks arc back down. Distinct from the puck-strip trail.
func _make_stick_lift_emitter() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.name = "StickLiftBurst"
	e.emitting = false
	e.amount = 14
	e.lifetime = 0.3
	e.one_shot = true
	e.explosiveness = 0.95
	e.randomness = 0.4
	e.local_coords = false
	e.direction = Vector3(0.0, 1.0, 0.0)
	e.spread = 55.0
	e.initial_velocity_min = 2.0
	e.initial_velocity_max = 5.0
	e.gravity = Vector3(0.0, -18.0, 0.0)
	e.scale_amount_min = 0.02
	e.scale_amount_max = 0.045
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 4
	sphere.rings = 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.97, 0.85, 0.9)
	sphere.material = mat
	e.mesh = sphere
	return e
