class_name SkaterVFX
extends Node3D

const TRAIL_MIN_SPEED: float = 0.5    # minimum speed for trail emission
const SPEED_LINE_MIN_SPEED: float = 5.5  # minimum speed for speed line effect
const TELEPORT_THRESHOLD: float = 1.0 # skip frame if skater moved this far (reconcile/faceoff guard)

# Hockey stop VFX — two-layer effect (surface marks + airborne spray) per blade side.
const STOP_MIN_SPEED: float = 2.5        # minimum speed at trigger time

# Body-check feedback scales with hit strength (the impact_force = weight x
# closing-speed the signal carries), normalized 0..1 between a light bump and a
# big hit. Burst size/velocity read this so a freight-train check throws bigger,
# faster debris than a glancing bump.
const _CHECK_FORCE_MIN: float = 3.0   # impact_force of a glancing bump (matches HitRules.MIN_HIT_IMPULSE)
const _CHECK_FORCE_REF: float = 14.0  # impact_force treated as a full-strength check
# Burst particle budget at the low/high end of the intensity range.
const _CHECK_BURST_AMOUNT_MIN: int = 10
const _CHECK_BURST_AMOUNT_MAX: int = 30
const _CHECK_BURST_VEL_MIN: float = 2.5   # initial_velocity_max at a light hit
const _CHECK_BURST_VEL_MAX: float = 9.0   # initial_velocity_max at a full hit

# --- Body-check SOUND: reserved for hits with real weight behind them ---------
# The impact BURST fires for every credited check (it scales with force via
# check_intensity above), but the THUD is gated harder and rides its OWN curve:
# an incidental bump or a board rub — two committed bodies grinding without a
# real collision behind them — should make NO sound, or the hit audio
# machine-guns through every scrum.
#
# The gate is in impact_force (weight x closing-speed) units, the same signal the
# stagger keys off (BodyCheckRules reconstructs the victim impulse from it):
#   ~3.0  MIN_HIT_IMPULSE — the bar to register a hit at all (~half a stagger)
#   ~4.0  a full-strength check (victim ref_impulse 1.35 — "skate in at pace")
#   ~5.5  a knockdown        (victim knockdown_impulse 1.8 — a committed solid hit)
# Sound starts at the full-check floor (below it is a bump/rub: silent) and
# reaches full volume by ~the knockdown point, so "loud thud" == "wobble or
# knockdown" and softer contact is silent. These are FEEL tunables (how hard a
# hit must land before you hear it), not evaluator constants.
const _CHECK_SOUND_MIN_FORCE: float = 4.0    # below this the hit is silent (bump/rub)
const _CHECK_SOUND_FULL_FORCE: float = 6.5   # at/above this the thud is at full volume
# Sound: louder + lower-pitched across the audible (full-check .. knockdown) band.
const _CHECK_VOL_MIN_DB: float = -9.0    # a just-audible full-strength check
const _CHECK_VOL_MAX_DB: float = 3.0     # a knockdown-class hit
const _CHECK_PITCH_LIGHT: float = 1.10   # full check — higher, snappier
const _CHECK_PITCH_HEAVY: float = 0.90   # knockdown — lower, heavier thud

# Blade trail — same zero-gap GPU approach as puck trail, one system per skate.
# Two dots per trail (left/right blade) pinned to ICE_Y so marks scrape the ice surface.
const BLADE_TRAIL_SPACING: float = 0.05   # meters between skate mark dots
const BLADE_TRAIL_LIFETIME: float = 1.5   # seconds each mark lingers
const BLADE_TRAIL_AMOUNT: int = 300       # max concurrent marks per blade
const BLADE_TRAIL_RADIUS: float = 0.025   # dot radius (smaller than puck's 0.055)
const BLADE_TRAIL_COLOR: Color = Color(0.95, 0.93, 0.88, 0.5)
const BLADE_X_OFFSET: float = 0.12       # left/right blade separation from center
const ICE_Y: float = 0.005              # world Y for trail dots (just above ice)
# Same GPUParticles3D frustum-culling hazard as the puck trail (see PuckVFX): the
# marks emit in world space but the visibility AABB is measured local to the node,
# i.e. centred on the skater, and defaults to ~±4 m. A blade trail lingers 1.5 s and
# streaks BLADE_TRAIL_LIFETIME × skate_speed (~18 m at a hard stride) behind the
# skater — so when the skater rides the frame edge the whole trail is culled by its
# skater-centred box, and a culled GPUParticles3D pauses processing, making the
# gap-fill emitter emit a backward streak on re-entry. A generous skater-centred AABB
# keeps it live whenever any mark could be on-screen. Half-extents (m) cover ~16 m/s.
const BLADE_TRAIL_AABB_HALF_XZ: float = 24.0
const BLADE_TRAIL_AABB_HALF_Y: float = 6.0

# Two GPU trail systems: index 0 = left blade, 1 = right blade
var _blade_trail_emitters: Array[GPUParticles3D] = []
var _blade_trail_particles: Array[GPUParticles3D] = []
var _stop_spray_emitter: CPUParticles3D = null  # forward fan spray on brake
var _speed_lines: CPUParticles3D = null
var _body_check_burst: CPUParticles3D = null
var _prev_pos: Vector3 = Vector3.ZERO
var _prev_vel: Vector3 = Vector3.ZERO

func _ready() -> void:
	# Build left/right blade trail systems (same zero-gap GPU approach as puck).
	# Sub-emitters are added before their parents so the NodePath can reference siblings.
	for i: int in 2:
		var side_x: float = [-BLADE_X_OFFSET, BLADE_X_OFFSET][i]
		var sub_name: String = "BladeTrailParticles%d" % i
		var sub: GPUParticles3D = _make_blade_trail_sub_emitter(sub_name)
		add_child(sub)
		_blade_trail_particles.append(sub)

		var emitter: GPUParticles3D = _make_blade_trail_emitter(i)
		emitter.position = Vector3(side_x, 0.0, 0.0)  # Y updated each frame to ICE_Y
		emitter.sub_emitter = NodePath("../%s" % sub_name)
		add_child(emitter)
		_blade_trail_emitters.append(emitter)

	_stop_spray_emitter = _make_stop_spray_emitter()
	add_child(_stop_spray_emitter)

	_speed_lines = _make_speed_lines_emitter()
	_speed_lines.position = Vector3(0.0, 0.3, 0.0)
	add_child(_speed_lines)

	_body_check_burst = _make_body_check_emitter()
	add_child(_body_check_burst)

	# Body-check burst + sound are driven by the host-authoritative broadcast
	# (GameManager._on_body_check_landed → fire_body_check_burst), not by the local
	# body_checked_player signal — so the impact reads identically on every client
	# instead of firing off each machine's non-authoritative local collision.

	_prev_pos = global_position

func _process(_delta: float) -> void:
	var skater: Skater = get_parent() as Skater
	if skater == null:
		return

	var curr_pos: Vector3 = skater.global_position
	var curr_vel: Vector3 = skater.velocity

	# Reconcile / faceoff teleport guard: skip emission on large position jumps
	# so reconcile snaps don't trigger false trail marks or stop bursts.
	if (curr_pos - _prev_pos).length() > TELEPORT_THRESHOLD:
		_prev_pos = curr_pos
		_prev_vel = curr_vel
		_set_blade_trails_emitting(false)
		_speed_lines.emitting = false
		return

	_prev_pos = curr_pos

	var flat_vel: Vector3 = Vector3(curr_vel.x, 0.0, curr_vel.z)
	var speed: float = flat_vel.length()
	_prev_vel = curr_vel

	# Suppress all VFX when ghosted (offsides / icing)
	if skater.is_ghost:
		_set_blade_trails_emitting(false)
		_speed_lines.emitting = false
		return

	# Pin blade trail emitters to ice level (skater origin is ~1m above ice).
	var ice_local_y: float = ICE_Y - curr_pos.y
	for i: int in _blade_trail_emitters.size():
		_blade_trail_emitters[i].position.y = ice_local_y

	# Skate trails: continuous marks on ice while moving
	_set_blade_trails_emitting(speed > TRAIL_MIN_SPEED)

	# Hockey stop: emit continuously while pure braking, stop when not.
	if skater.is_braking and speed > STOP_MIN_SPEED:
		_emit_hockey_stop(skater, flat_vel)
	else:
		_stop_spray_emitter.emitting = false

	# Speed lines: small streaks behind the skater at high speed.
	# direction is in local space — convert world-space backward vector via basis inverse
	# so particles go backward along velocity regardless of the skater's facing.
	if speed > SPEED_LINE_MIN_SPEED and flat_vel.length() > 0.1:
		_speed_lines.emitting = true
		_speed_lines.direction = skater.global_transform.basis.inverse() * (-flat_vel.normalized())
	else:
		_speed_lines.emitting = false



# 0..1 hit hardness from the impact_force the body_checked_player signal carries.
# Static so the burst, the sound, and the replay path all map strength the same way.
static func check_intensity(force: float) -> float:
	if _CHECK_FORCE_REF <= _CHECK_FORCE_MIN:
		return 0.0
	return clampf((force - _CHECK_FORCE_MIN) / (_CHECK_FORCE_REF - _CHECK_FORCE_MIN), 0.0, 1.0)


# True when a check is hard enough to earn a thud — a full-strength (stagger)
# check or harder. Softer contact (incidental bumps, committed board rubs) stays
# SILENT. Both the live and replay sound paths gate on this so no near-silent
# BODY_CHECK player is ever spawned for a bump.
static func check_sound_audible(force: float) -> bool:
	return force >= _CHECK_SOUND_MIN_FORCE


# 0..1 sound hardness — a SEPARATE, harder-gated curve than the burst's
# check_intensity: 0 at the full-check floor, 1 by the knockdown point. Only
# meaningful once check_sound_audible() has passed.
static func check_sound_intensity(force: float) -> float:
	if _CHECK_SOUND_FULL_FORCE <= _CHECK_SOUND_MIN_FORCE:
		return 0.0
	return clampf((force - _CHECK_SOUND_MIN_FORCE) / (_CHECK_SOUND_FULL_FORCE - _CHECK_SOUND_MIN_FORCE), 0.0, 1.0)


static func check_sound_volume_db(force: float) -> float:
	return lerpf(_CHECK_VOL_MIN_DB, _CHECK_VOL_MAX_DB, check_sound_intensity(force))


static func check_sound_pitch_scale(force: float) -> float:
	return lerpf(_CHECK_PITCH_LIGHT, _CHECK_PITCH_HEAVY, check_sound_intensity(force))


# Public so ReplayEventReplayer can fire the burst during replay without
# routing through body_checked_player — re-emitting the signal would also
# re-trigger GameManager's hit-landed / replay-record closures, which is wrong
# during playback (and recursive for the recorder). Burst size + velocity scale
# with hit strength (the impact_force) so a big check throws more, faster debris.
func fire_body_check_burst(victim: Skater, force: float, hit_dir: Vector3) -> void:
	if victim == null:
		return
	var t: float = check_intensity(force)
	_body_check_burst.amount = int(lerpf(float(_CHECK_BURST_AMOUNT_MIN), float(_CHECK_BURST_AMOUNT_MAX), t))
	var vel_max: float = lerpf(_CHECK_BURST_VEL_MIN, _CHECK_BURST_VEL_MAX, t)
	_body_check_burst.initial_velocity_min = vel_max * 0.4
	_body_check_burst.initial_velocity_max = vel_max
	# Burst at the victim's position, emitting outward along the hit direction.
	# direction must be in the emitter's local space — convert the world-space
	# hit vector using the emitter's inverse basis (inherited from the skater's facing).
	_body_check_burst.global_position = victim.global_position + Vector3(0.0, 0.5, 0.0)
	var flat_hit: Vector3 = Vector3(hit_dir.x, 0.0, hit_dir.z)
	var world_dir: Vector3 = (flat_hit + Vector3(0.0, 0.4, 0.0)).normalized()
	_body_check_burst.direction = _body_check_burst.global_transform.basis.inverse() * world_dir
	_body_check_burst.restart()

func _set_blade_trails_emitting(active: bool) -> void:
	for emitter: GPUParticles3D in _blade_trail_emitters:
		emitter.emitting = active

# Skater-centred visibility box, generous enough that it always overlaps the frustum
# whenever a live blade mark could be on-screen — so the world-space trail is never
# culled (nor its processing paused) as the skater rides the frame edge. See the
# BLADE_TRAIL_AABB_HALF_* doc-block for why the default AABB is too small.
func _blade_trail_visibility_aabb() -> AABB:
	return AABB(
			Vector3(-BLADE_TRAIL_AABB_HALF_XZ, -BLADE_TRAIL_AABB_HALF_Y, -BLADE_TRAIL_AABB_HALF_XZ),
			Vector3(BLADE_TRAIL_AABB_HALF_XZ * 2.0, BLADE_TRAIL_AABB_HALF_Y * 2.0, BLADE_TRAIL_AABB_HALF_XZ * 2.0))

func _make_blade_trail_emitter(index: int) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.name = "BladeTrailEmitter%d" % index
	e.amount = 1
	e.lifetime = 3600.0
	e.one_shot = false
	e.explosiveness = 0.0
	e.fixed_fps = 0
	e.local_coords = false
	e.emitting = false
	# Never let culling pause this tracker (see BLADE_TRAIL_AABB_HALF_XZ).
	e.visibility_aabb = _blade_trail_visibility_aabb()

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
""" % BLADE_TRAIL_SPACING

	var mat := ShaderMaterial.new()
	mat.shader = shader
	e.process_material = mat
	return e

func _make_blade_trail_sub_emitter(sub_name: String) -> GPUParticles3D:
	var e := GPUParticles3D.new()
	e.name = sub_name
	e.amount = BLADE_TRAIL_AMOUNT
	e.lifetime = BLADE_TRAIL_LIFETIME
	e.one_shot = false
	e.explosiveness = 0.0
	e.fixed_fps = 0
	e.local_coords = false
	e.emitting = false
	# World-space marks stream well past the default AABB; keep the trail un-culled.
	e.visibility_aabb = _blade_trail_visibility_aabb()

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3.ZERO
	mat.spread = 0.0
	mat.initial_velocity_min = 0.0
	mat.initial_velocity_max = 0.0
	mat.gravity = Vector3.ZERO
	mat.color = BLADE_TRAIL_COLOR
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 0.5))
	grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad
	mat.color_ramp = grad_tex
	e.process_material = mat

	var disk := CylinderMesh.new()
	disk.top_radius = BLADE_TRAIL_RADIUS
	disk.bottom_radius = BLADE_TRAIL_RADIUS
	disk.height = 0.003
	disk.radial_segments = 8
	disk.rings = 1
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_mat.albedo_color = Color.WHITE
	mesh_mat.vertex_color_use_as_albedo = true
	mesh_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	disk.material = mesh_mat
	e.draw_pass_1 = disk
	return e

func _emit_hockey_stop(skater: Skater, flat_vel: Vector3) -> void:
	# Snow fans forward in the direction of travel — snowplow look.
	var forward: Vector3 = flat_vel.normalized()
	var world_dir: Vector3 = (forward + Vector3(0.0, 0.36, 0.0)).normalized()
	var local_dir: Vector3 = _stop_spray_emitter.global_transform.basis.inverse() * world_dir
	_stop_spray_emitter.global_position = skater.global_position + forward * 0.7 + Vector3(0.0, 0.005, 0.0)
	_stop_spray_emitter.direction = local_dir
	_stop_spray_emitter.emitting = true

func _make_stop_spray_emitter() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.emitting = false
	e.amount = 150
	e.lifetime = 0.35
	e.one_shot = false
	e.explosiveness = 0.0
	e.randomness = 0.3
	e.local_coords = false
	e.direction = Vector3(1.0, 0.0, 0.0)  # overwritten per burst
	e.spread = 65.0                        # wide forward fan
	e.initial_velocity_min = 3.0
	e.initial_velocity_max = 9.0
	e.gravity = Vector3(0.0, -25.0, 0.0)
	e.scale_amount_min = 0.03
	e.scale_amount_max = 0.06
	e.mesh = _make_sphere_mesh(Color(0.95, 0.93, 0.88, 0.85))
	return e

func _make_speed_lines_emitter() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.emitting = false
	e.amount = 8
	e.lifetime = 0.12
	e.one_shot = false
	e.explosiveness = 0.0
	e.randomness = 0.3
	e.local_coords = false
	e.direction = Vector3(0.0, 0.0, 1.0)  # updated each frame to face backward along velocity
	e.spread = 10.0
	e.initial_velocity_min = 5.0
	e.initial_velocity_max = 8.0
	e.gravity = Vector3.ZERO
	e.scale_amount_min = 0.015
	e.scale_amount_max = 0.03
	e.mesh = _make_sphere_mesh(Color(0.85, 0.92, 1.0, 0.5))
	return e

func _make_body_check_emitter() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.emitting = false
	e.amount = 20
	e.lifetime = 0.4
	e.one_shot = true
	e.explosiveness = 0.95
	e.randomness = 0.4
	e.local_coords = false
	e.direction = Vector3(0.0, 1.0, 0.0)  # overwritten per hit
	e.spread = 50.0
	e.initial_velocity_min = 3.0
	e.initial_velocity_max = 7.0
	e.gravity = Vector3(0.0, -25.0, 0.0)
	e.scale_amount_min = 0.04
	e.scale_amount_max = 0.08
	e.mesh = _make_sphere_mesh(Color(0.9, 0.95, 1.0, 0.9))
	return e

func _make_sphere_mesh(color: Color) -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 4
	sphere.rings = 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	sphere.material = mat
	return sphere
