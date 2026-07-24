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
const TRAIL_SPACING: float = 0.07   # meters between trail dots (~puck diameter); trail appears above ~4 m/s
const TRAIL_LIFETIME: float = 0.25  # seconds each dot lingers
const TRAIL_AMOUNT: int = 150       # max concurrent trail dots (covers ~25 m/s at 60 fps with 0.25 s lifetime)

# Speed-reactive color: cream at slow, hot orange at fast.
const TRAIL_COLOR_SLOW: Color = Color(0.95, 0.93, 0.88, 1.0)
const TRAIL_COLOR_FAST: Color = Color(1.0, 0.45, 0.05, 1.0)
const TRAIL_SPEED_MIN: float = 3.0   # m/s — at or below this, full slow color
const TRAIL_SPEED_MAX: float = 18.0  # m/s — at or above this, full fast color

# GPU-emitted particles are displayed ~one render frame after the emitter reached
# their spot, and the lag scales with speed — so the puck (the fastest thing on the
# ice) sheds a trail whose head detaches from the mesh, each new segment popping in
# behind it (reads as the trail "jumping backwards"). We cancel it by leading the
# emission origin one frame of travel ahead (vel * delta), so the newest dot lands
# where the puck renders THIS frame. Clamped so a faceoff/goal teleport (a one-frame
# velocity spike) can't fling the emit origin across the rink.
const TRAIL_LEAD_MAX_M: float = 0.5  # cap on the one-frame lead offset (m)

# Board impact puff: ice chips kicked up where the puck slams the boards.
# Amount/velocity scale with impact speed; soft touches get nothing. The
# cooldown coalesces the per-contact re-fires of a puck grinding along the
# boards into one puff (the sound path throttles the same way).
const BOARD_PUFF_MIN_SPEED: float = 4.0
const BOARD_PUFF_MAX_SPEED: float = 22.0
const BOARD_PUFF_COOLDOWN_MS: int = 150
# Post ping: bright spark snap off the iron. Only a genuinely hard shot rings.
const POST_PING_MIN_SPEED: float = 8.0

var _puck: Puck = null
var _trail_emitter: GPUParticles3D = null
var _trail_particles: GPUParticles3D = null
var _trail_mat: ParticleProcessMaterial = null
var _stick_lift_burst: CPUParticles3D = null
var _board_puff: CPUParticles3D = null
var _post_ping: CPUParticles3D = null
var _last_board_puff_ms: int = 0
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

	_board_puff = _make_board_puff_emitter()
	add_child(_board_puff)

	_post_ping = _make_post_ping_emitter()
	add_child(_post_ping)

	_prev_pos = global_position


# One-shot spark pop when a stick lift strips the puck. Anchored to the puck via
# this node's transform, so it fires wherever the dislodge happened. local_coords
# off keeps the sparks in world space as the freed puck starts moving.
func fire_stick_lift_burst() -> void:
	if _stick_lift_burst != null:
		_stick_lift_burst.restart()


# One-shot ice-chip puff for a board hit, scaled by impact speed (the puck's
# post-bounce speed, same value the sound volume uses). Anchored to the puck,
# which sits at the contact point when the signal fires.
func fire_board_impact_burst(speed: float) -> void:
	if _board_puff == null or speed < BOARD_PUFF_MIN_SPEED:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_board_puff_ms < BOARD_PUFF_COOLDOWN_MS:
		return
	_last_board_puff_ms = now
	var t: float = clampf(
			(speed - BOARD_PUFF_MIN_SPEED) / (BOARD_PUFF_MAX_SPEED - BOARD_PUFF_MIN_SPEED),
			0.0, 1.0)
	_board_puff.amount = int(lerpf(8.0, 26.0, t))
	_board_puff.initial_velocity_max = lerpf(2.5, 6.5, t)
	_board_puff.restart()


# One-shot spark snap when a hard shot rings iron. Soft post touches skip it.
func fire_post_ping_burst(speed: float) -> void:
	if _post_ping == null or speed < POST_PING_MIN_SPEED:
		return
	_post_ping.restart()

func _process(delta: float) -> void:
	var curr_pos: Vector3 = global_position
	var vel: Vector3 = (curr_pos - _prev_pos) / delta if delta > 0.0 else Vector3.ZERO
	_prev_pos = curr_pos

	# When grounded, pin the emitter to ice level so trail dots scrape the ice surface.
	# When airborne, follow the puck's actual Y so the trail goes with it.
	var target_y: float = curr_pos.y if _puck.is_airborne() else ICE_Y

	# Lead the emission origin one render frame ahead (see TRAIL_LEAD_MAX_M) to cancel
	# the GPU particle display latency. Horizontal only — the Y stays pinned to the ice
	# (or the puck's height when airborne); leading is a chase-plane correction. The
	# puck node keeps an identity basis, so this local offset is also the world offset.
	var lead: Vector3 = vel * delta
	var lead_flat := Vector3(lead.x, 0.0, lead.z)
	if lead_flat.length() > TRAIL_LEAD_MAX_M:
		lead_flat = lead_flat.normalized() * TRAIL_LEAD_MAX_M
	_trail_emitter.position = Vector3(lead_flat.x, target_y - curr_pos.y, lead_flat.z)

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
	disk.top_radius = 0.055
	disk.bottom_radius = 0.055
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

# Ice chips off the boards: white flecks kicked up and back down under heavy
# gravity, like the snow a real board slam shakes loose. Amount and velocity
# are overwritten per fire in fire_board_impact_burst.
func _make_board_puff_emitter() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.name = "BoardPuff"
	e.emitting = false
	e.amount = 16
	e.lifetime = 0.35
	e.one_shot = true
	e.explosiveness = 0.95
	e.randomness = 0.5
	e.local_coords = false
	e.direction = Vector3(0.0, 1.0, 0.0)
	e.spread = 65.0
	e.initial_velocity_min = 1.5
	e.initial_velocity_max = 5.0
	e.gravity = Vector3(0.0, -14.0, 0.0)
	e.scale_amount_min = 0.02
	e.scale_amount_max = 0.05
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 4
	sphere.rings = 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.97, 0.98, 1.0, 0.85)
	sphere.material = mat
	e.mesh = sphere
	return e


# Hot spark snap for a shot off the post: fewer, faster, brighter than the
# stick-lift pop, thrown omni-directionally the way a ricochet reads.
func _make_post_ping_emitter() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.name = "PostPing"
	e.emitting = false
	e.amount = 12
	e.lifetime = 0.22
	e.one_shot = true
	e.explosiveness = 1.0
	e.randomness = 0.3
	e.local_coords = false
	e.direction = Vector3(0.0, 1.0, 0.0)
	e.spread = 180.0
	e.initial_velocity_min = 4.0
	e.initial_velocity_max = 8.0
	e.gravity = Vector3(0.0, -10.0, 0.0)
	e.scale_amount_min = 0.015
	e.scale_amount_max = 0.03
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 4
	sphere.rings = 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.95, 0.75, 0.95)
	sphere.material = mat
	e.mesh = sphere
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
