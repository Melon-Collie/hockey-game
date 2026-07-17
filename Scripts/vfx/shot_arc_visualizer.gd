class_name ShotArcVisualizer
extends Node3D

# Practice-only shot visualizer (spawned by game_scene.gd in free play /
# tutorial / drills, never in matches):
#
# - POST-SHOT TRACE (every practice mode): after a local shot/pass release the
#   puck's ACTUAL flight is sampled at render rate and drawn as a ribbon that
#   holds briefly, then fades — the "why did it go there" record of the release
#   the player just performed. Because wrister power is the cursor speed at
#   release, the gesture is over before any live readout could be read; the
#   after-the-fact trace is what teaches the speed→power mapping.
# - LIVE GHOST (Shooting tutorial only): while the local player charges a
#   wrister, the PREDICTED release arc — ShotArcRules integrating the same
#   per-tick release-now prediction the goalie reads
#   (Skater.predicted_shot_velocity) — draws from the carried puck, making
#   drag-to-aim, cursor-speed power, and the loft levels visible while
#   learning them. The velocity is briefly smoothed (and the ribbon fades in)
#   so the noisy first ticks of a drag don't flicker.
#
# Cosmetic-only and render-rate by design: everything runs in _process, reads
# published state (no gameplay writes), pre-allocates its point buffers, and
# skips all mesh work while hidden. Ribbons are flat XZ triangle strips — the
# ~75° camera reads them well at any arc height — following the on-ice HUD
# stroke conventions in MenuStyle. The release hook re-fetches the local
# controller per frame (the HUD's shot-toast pattern) so respawns and
# spectator swaps never leave it pointing at a freed controller.

# Whether the live pre-shot ghost draws at all. Set before add_child by
# game_scene.gd; the post-shot trace runs wherever this node exists.
var show_live_ghost: bool = false

# ── Ribbon styling ────────────────────────────────────────────────────────────
const _RIBBON_HALF_WIDTH: float = MenuStyle.HUD_LINE_THICK * 0.5
# Minimum draw height: keeps grounded segments above the ice plane (and its
# scratch overlay) — same lift the ping marker's ring uses.
const _DRAW_Y_MIN: float = 0.05
const _GHOST_COLOR: Color = MenuStyle.HUD_ICE
const _GHOST_TAIL_ALPHA: float = 0.25  # ghost tapers toward the landing tail
const _TRACE_COLOR := Color(1.0, 0.72, 0.25)  # warm amber — "what just happened"

# ── Ghost timing ──────────────────────────────────────────────────────────────
const _GHOST_ARC_CAPACITY: int = 128       # ~1 s flight + slide tail at 60 Hz
const _GHOST_VEL_SMOOTH_TAU: float = 0.06  # s; absorbs early-drag direction noise
const _GHOST_FADE_IN_S: float = 0.15
const _GHOST_FADE_OUT_S: float = 0.08

# ── Trace timing ──────────────────────────────────────────────────────────────
const _TRACE_MAX_POINTS: int = 240
const _TRACE_SAMPLE_SPACING_M: float = 0.12
const _TRACE_RECORD_S: float = 2.0
const _TRACE_HOLD_S: float = 1.0
const _TRACE_FADE_S: float = 0.7

var _ghost_mesh: MeshInstance3D
var _ghost_im: ImmediateMesh
var _trace_mesh: MeshInstance3D
var _trace_im: ImmediateMesh
var _trace_mat: StandardMaterial3D

# Ghost state. Origin/velocity persist through the short fade-out so the
# ribbon doesn't re-anchor to the already-flying puck after release.
var _arc_points: PackedVector3Array = PackedVector3Array()
var _smoothed_vel: Vector3 = Vector3.ZERO
var _ghost_origin: Vector3 = Vector3.ZERO
var _ghost_alpha: float = 0.0
var _was_charging: bool = false

# Trace state: a prefix (_trace_count) of a pre-sized sample buffer.
var _trace_points: PackedVector3Array = PackedVector3Array()
var _trace_count: int = 0
var _trace_recording: bool = false
var _trace_elapsed: float = 0.0  # while recording
var _trace_age: float = 0.0      # after recording stops (hold + fade)
var _trace_dirty: bool = false

# HUD shot-toast pattern: the local controller changes across respawns and
# spectator swaps, so the release-signal hook is re-resolved per frame.
var _hooked_controller: SkaterController = null


func _ready() -> void:
	_arc_points.resize(_GHOST_ARC_CAPACITY)
	_trace_points.resize(_TRACE_MAX_POINTS)
	_ghost_im = ImmediateMesh.new()
	_ghost_mesh = _make_ribbon_mesh(_ghost_im, _make_ribbon_material())
	_trace_im = ImmediateMesh.new()
	_trace_mat = _make_ribbon_material()
	_trace_mesh = _make_ribbon_mesh(_trace_im, _trace_mat)


func _exit_tree() -> void:
	_unhook_controller()


func _process(delta: float) -> void:
	if NetworkManager.is_replay_mode():
		_ghost_mesh.visible = false
		_trace_mesh.visible = false
		return
	_update_release_hook()
	_update_ghost(delta)
	_update_trace(delta)


# ── Live ghost ────────────────────────────────────────────────────────────────

func _update_ghost(delta: float) -> void:
	if not show_live_ghost:
		return
	var record: PlayerRecord = GameManager.get_local_player()
	var skater: Skater = record.skater if record != null else null
	var puck: Puck = GameManager.get_puck()
	var charging: bool = skater != null and puck != null \
			and skater.current_shot_state == SkaterStateMachine.State.WRISTER_AIM \
			and puck.get_carrier() == skater \
			and skater.predicted_shot_velocity.length_squared() > 1.0
	if charging:
		var target: Vector3 = skater.predicted_shot_velocity
		if _was_charging:
			_smoothed_vel = _smoothed_vel.lerp(
					target, 1.0 - exp(-delta / _GHOST_VEL_SMOOTH_TAU))
		else:
			_smoothed_vel = target  # fresh charge: snap, never lerp from stale
		# Anchor at the carried puck; a lofted release actually leaves the
		# blade lifted (Puck.release raises the origin for elevated shots).
		_ghost_origin = puck.global_position
		if _smoothed_vel.y > 0.0:
			_ghost_origin.y = puck.ice_height + 0.1
		_ghost_alpha = minf(_ghost_alpha + delta / _GHOST_FADE_IN_S, 1.0)
	else:
		_ghost_alpha = maxf(_ghost_alpha - delta / _GHOST_FADE_OUT_S, 0.0)
	_was_charging = charging
	if _ghost_alpha <= 0.0 or puck == null:
		_ghost_mesh.visible = false
		return
	_ghost_mesh.visible = true
	var count: int = ShotArcRules.fill_arc(
			_ghost_origin, _smoothed_vel, _arc_points, puck.ice_height)
	var color: Color = _GHOST_COLOR
	color.a = MenuStyle.HUD_OPACITY * _ghost_alpha
	_rebuild_ribbon(_ghost_im, _arc_points, count, color, _GHOST_TAIL_ALPHA)


# ── Post-shot trace ───────────────────────────────────────────────────────────

func _update_release_hook() -> void:
	var record: PlayerRecord = GameManager.get_local_player()
	var controller: SkaterController = record.controller if record != null else null
	if controller == _hooked_controller:
		return
	_unhook_controller()
	_hooked_controller = controller
	if controller != null:
		controller.puck_release_requested.connect(_on_local_shot_released)
		controller.one_timer_release_requested.connect(_on_local_one_timer_released)


func _unhook_controller() -> void:
	if _hooked_controller != null and is_instance_valid(_hooked_controller):
		_hooked_controller.puck_release_requested.disconnect(_on_local_shot_released)
		_hooked_controller.one_timer_release_requested.disconnect(
				_on_local_one_timer_released)
	_hooked_controller = null


# The leniency one-timer releases through its own signal; same trace.
func _on_local_one_timer_released(direction: Vector3, power: float) -> void:
	_on_local_shot_released(direction, power, true)


func _on_local_shot_released(
		_direction: Vector3, _power: float, _is_slapper: bool) -> void:
	var puck: Puck = GameManager.get_puck()
	if puck == null:
		return
	_trace_count = 0
	_trace_recording = true
	_trace_elapsed = 0.0
	_trace_age = 0.0
	_append_trace_point(puck.global_position)


func _append_trace_point(pos: Vector3) -> void:
	if _trace_count >= _TRACE_MAX_POINTS:
		return
	_trace_points[_trace_count] = pos
	_trace_count += 1
	_trace_dirty = true


func _update_trace(delta: float) -> void:
	if _trace_recording:
		_trace_elapsed += delta
		var puck: Puck = GameManager.get_puck()
		# A corralled puck ends the flight (the trace is the shot/pass path,
		# not a possession tail) — but only after it has actually left the
		# blade (>1 sample), so the release frame itself never ends it.
		if puck == null or _trace_elapsed > _TRACE_RECORD_S \
				or _trace_count >= _TRACE_MAX_POINTS \
				or (puck.get_carrier() != null and _trace_count > 1):
			_trace_recording = false
		else:
			var pos: Vector3 = puck.global_position
			var last: Vector3 = _trace_points[_trace_count - 1]
			if pos.distance_squared_to(last) \
					>= _TRACE_SAMPLE_SPACING_M * _TRACE_SAMPLE_SPACING_M:
				_append_trace_point(pos)
	elif _trace_count > 0:
		_trace_age += delta
		if _trace_age >= _TRACE_HOLD_S + _TRACE_FADE_S:
			_trace_count = 0
			_trace_dirty = false
			_trace_mesh.visible = false
	if _trace_count < 2:
		_trace_mesh.visible = false
		return
	_trace_mesh.visible = true
	# Fade via the material's albedo (it modulates the vertex colors), so the
	# mesh itself only rebuilds when a new sample lands.
	var fade_t: float = clampf((_trace_age - _TRACE_HOLD_S) / _TRACE_FADE_S, 0.0, 1.0)
	_trace_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0 - fade_t)
	if _trace_dirty:
		_trace_dirty = false
		var color: Color = _TRACE_COLOR
		color.a = MenuStyle.HUD_OPACITY
		_rebuild_ribbon(_trace_im, _trace_points, _trace_count, color, 1.0)


# ── Ribbon building ───────────────────────────────────────────────────────────

func _make_ribbon_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	return mat


func _make_ribbon_mesh(im: ImmediateMesh, mat: StandardMaterial3D) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = im
	mesh_instance.material_override = mat
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.visible = false
	# Vertices are written in world space; keep the instance out of any parent
	# transform so they land where they were sampled.
	mesh_instance.top_level = true
	add_child(mesh_instance)
	return mesh_instance


# Rebuilds `im` as a flat, XZ-plane triangle-strip ribbon through the first
# `count` entries of `points`, vertex alpha tapering from color.a at the start
# to color.a · tail_alpha at the end.
func _rebuild_ribbon(
		im: ImmediateMesh,
		points: PackedVector3Array,
		count: int,
		color: Color,
		tail_alpha: float) -> void:
	im.clear_surfaces()
	if count < 2:
		return
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var side := Vector3(_RIBBON_HALF_WIDTH, 0.0, 0.0)
	var inv_last: float = 1.0 / float(count - 1)
	for i: int in range(count):
		var ahead: Vector3 = points[mini(i + 1, count - 1)]
		var behind: Vector3 = points[maxi(i - 1, 0)]
		var dir := Vector3(ahead.x - behind.x, 0.0, ahead.z - behind.z)
		if dir.length_squared() > 0.000001:
			side = Vector3(-dir.z, 0.0, dir.x).normalized() * _RIBBON_HALF_WIDTH
		var vertex_color: Color = color
		vertex_color.a = color.a * lerpf(1.0, tail_alpha, float(i) * inv_last)
		var p: Vector3 = points[i]
		p.y = maxf(p.y, _DRAW_Y_MIN)
		im.surface_set_color(vertex_color)
		im.surface_add_vertex(p - side)
		im.surface_set_color(vertex_color)
		im.surface_add_vertex(p + side)
	im.surface_end()
