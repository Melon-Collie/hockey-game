class_name SkaterHUDCoordinator
extends RefCounted

# ── HUD geometry constants ────────────────────────────────────────────────────
# Slot ring sits just inside RING_OUTER_R. The stamina ring is concentric,
# just inside the slot ring's inner edge with a small gap. Chevron and player
# name sit below the rings on the screen-down side.
const RING_LINE_SCALE: float     = 2.0   # line-thickness bump for readability; visual only, never a hitbox
const RING_OUTER_R: float        = 0.45

# Stamina ring — BOTW-style sprint gauge nested inside the player's own color
# ring (self-only). Hidden while the pool is full; while draining/refilling the
# arc empties clockwise over a faint track, goes amber when low, and flashes
# red while sprint is locked out by exhaustion. The mesh is top_level with its
# fill origin re-aligned to camera screen-up, so the gauge doesn't spin with
# the skater's facing. Slot ring occupies 0.39..0.45 (RING_OUTER_R minus the
# scaled line thickness); the stamina arc tucks inside that with a visible gap.
const STAMINA_RING_OUTER_R: float = 0.37
const STAMINA_RING_INNER_R: float = 0.31
const _STAMINA_SHOW_BELOW: float = 0.999  # hidden while (effectively) full
const _STAMINA_LOW_FRACTION: float = 0.3
const _STAMINA_LOCKED_FLASH_HZ: float = 2.5
const _STAMINA_LOW_COLOR := Color(0.95, 0.65, 0.20, 1.0)  # amber when running low
const _STAMINA_TRACK_COLOR := Color(0.06, 0.08, 0.11, 0.55)

# Player-name placement — billboarded Label3D just outside the slot ring.
const _NAME_RADIUS: float   = RING_OUTER_R + 0.10
const _CHEVRON_RADIUS: float = RING_OUTER_R + 0.10
const _CHEVRON_OFFSET_DEG: float = 60.0
# Screen-up gap between the stacked chevrons: one "^" = LOW loft, "^^" = HIGH.
const _CHEVRON_STACK_GAP: float = 0.11

# Overhead self-beacon. A billboarded downward-arrow that floats above ONLY the
# local player's own skater so "which one is me" is answered pre-attentively
# (shape + motion + high-contrast self color) rather than by color-matching a
# flat on-ice ring. Self-only: driven from the ring-relation resolver
# (RingRelation.SELF). Bobs vertically and pulses in scale to draw the eye;
# hidden in replay/spectator, while ghosted, and for every non-local skater.
# HOVER_OFFSET is metres above the skater root, which sits at body-centre
# height (~1.0 m), so the apex clears the head with room to spare.
const _BEACON_HOVER_OFFSET: float    = 1.30
const _BEACON_HALF_W: float          = 0.17
const _BEACON_HALF_H: float          = 0.15
const _BEACON_OUTLINE_SCALE: float   = 1.4
const _BEACON_OPACITY: float         = 0.95
const _BEACON_OUTLINE_COLOR: Color   = Color(0.05, 0.07, 0.10, 0.9)
const _BEACON_BOB_HZ: float          = 1.1
const _BEACON_BOB_AMPLITUDE: float   = 0.045
const _BEACON_PULSE_HZ: float        = 1.6
const _BEACON_PULSE_MIN_SCALE: float = 0.92
const _BEACON_PULSE_MAX_SCALE: float = 1.10

# Crowd-gated visibility. The beacon is clutter on open ice and only earns its
# place in a scrum, so it shows only when at least _BEACON_CROWD_COUNT other
# skaters are within _BEACON_CROWD_RADIUS of the local player (or while ghosted
# — see _update_beacon_visibility). A linger timer keeps it up briefly after the
# crowd disperses so skaters weaving past don't make it flicker. The proximity
# scan runs on a coarse interval, not every physics tick.
const _BEACON_CROWD_RADIUS: float         = 4.5
const _BEACON_CROWD_COUNT: int            = 2
const _BEACON_CROWD_LINGER: float         = 1.0
const _BEACON_CROWD_CHECK_INTERVAL: float = 0.2

# Slapper one-timer reticle. All geometry is built in unit (1 m) space;
# _slapper_indicator.scale = (radius, 1, radius) carries the zone radius.
const _SLAPPER_RING_MIN_SCALE: float   = 0.15
const _ARROW_TIP_DISTANCE_UNIT: float  = 1.8
const _ARROW_HEAD_LEN_UNIT: float      = 0.30
const _ARROW_HEAD_HALF_W_UNIT: float   = 0.20
const _ARROW_SHAFT_HALF_W_UNIT: float  = 0.06
const _RETICLE_HALF_LENGTH: float      = 0.06
const _RING_SEGMENTS: int              = 48
const _SLAPPER_HUD_Y: float            = 0.05

# Stamina ring shader: angle-mask radial gauge. Fill goes clockwise from
# 12 o'clock (UV.x of the procedural ring encodes 0..1 clockwise); the
# depleted remainder renders as a faint track so the fraction stays readable.
# Fill color is picked CPU-side (normal / low / lockout flash) — it changes
# rarely, so the shader stays a dumb two-color mask.
const _STAMINA_RING_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform float fill : hint_range(0.0, 1.0) = 1.0;
uniform vec4 fill_color;
uniform vec4 track_color;
uniform float opacity = 0.7;

void fragment() {
	if (UV.x <= fill) {
		ALBEDO = fill_color.rgb;
		ALPHA = opacity * fill_color.a;
	} else {
		ALBEDO = track_color.rgb;
		ALPHA = opacity * track_color.a;
	}
}
"""

# Slot-ring relationship to the LOCAL player, resolved live so a late-spawning
# local player and mid-game slot swaps self-correct. UNKNOWN keeps the neutral
# HUD_ICE tint (the pre-coloring default).
enum RingRelation { UNKNOWN = -1, SELF = 0, TEAMMATE = 1, ENEMY = 2 }

var _skater: Skater

var _ring_mesh: MeshInstance3D
var _stamina_ring_mesh: MeshInstance3D
var _stamina_ring_mat: ShaderMaterial
var _chevron_mesh: MeshInstance3D
# Second stacked chevron, visible only at HIGH loft (level 2).
var _chevron_mesh2: MeshInstance3D
var _name_label: Label3D

# Overhead self-beacon. `_self_beacon` is top_level (world transform rewritten
# each tick, like the name label) and parents an outline + fill MeshInstance.
# `_self_beacon_active` latches whether the resolver currently reports SELF;
# actual visibility also gates on ghost/replay/spectator state.
var _self_beacon: Node3D
var _self_beacon_fill_mat: StandardMaterial3D
var _self_beacon_active: bool = false
# Crowd-gate state. `_beacon_crowded` is the latched "enough skaters nearby"
# result; `_beacon_linger_timer` holds it on briefly after the crowd clears.
var _beacon_crowded: bool = false
var _beacon_crowd_accum: float = _BEACON_CROWD_CHECK_INTERVAL
var _beacon_linger_timer: float = 0.0

var _slapper_indicator: Node3D
var _slapper_indicator_mat: StandardMaterial3D
var _slapper_reticle_node: MeshInstance3D
var _slapper_arrow_root: Node3D
var _slapper_arrow_mesh: MeshInstance3D
var _slapper_ring_mesh: MeshInstance3D

var _slapper_zone_radius_cached: float = 0.5
var _slapper_current_ring_scale: float = 1.0
# Force-hide all per-skater HUD chrome regardless of replay-mode state. Used
# by the offline replay viewer and live spectator mode where the broadcast /
# chase / free cameras frame the rink from angles the flat ring decals weren't
# designed for. Latched once at setup; persists for the actor's lifetime.
var _force_world_hud_hidden: bool = false

# Reusable resources + buffers — _rebuild_slapper_geometry() can fire every
# physics tick during a slapper charge, so the ArrayMeshes it fills and the
# PackedArrays it uses are allocated once and refilled in place to keep GC
# pressure off the hot path. `_last_rebuild_*` short-circuits when nothing
# has changed since the previous rebuild.
var _arrow_mesh_resource: ArrayMesh = ArrayMesh.new()
var _ring_mesh_resource: ArrayMesh = ArrayMesh.new()
var _arrow_verts: PackedVector3Array = PackedVector3Array()
var _arrow_normals: PackedVector3Array = PackedVector3Array()
var _arrow_indices: PackedInt32Array = PackedInt32Array()
var _ring_verts: PackedVector3Array = PackedVector3Array()
var _ring_normals: PackedVector3Array = PackedVector3Array()
var _ring_indices: PackedInt32Array = PackedInt32Array()
var _last_rebuild_ring_scale: float = -1.0
var _last_rebuild_radius: float = -1.0
var _last_rebuild_ring_visible: bool = false

# Per-tick caches. `update()` runs every physics tick across every skater, so anything
# derived from infrequently-changing inputs (camera orientation, skater Y,
# shader-param values) is recomputed only on change.
var _last_skater_y: float = INF
var _cached_cam_basis_y: Vector3 = Vector3.ZERO
var _cached_screen_down: Vector2 = Vector2(0.0, 1.0)
var _cached_arc_base_angle: float = 0.0
var _cached_chevron_dir: Vector3 = Vector3(0.0, 0.0, 1.0)
var _last_stamina_fill: float = -1.0
var _last_stamina_color: Color = Color(0, 0, 0, 0)  # unreachable sentinel

# Slot-ring relationship tint. The resolver (installed by PlayerRegistry)
# returns a RingRelation each refresh; recolor is re-evaluated on a coarse
# interval rather than every physics tick since relationship changes rarely
# (local-player spawn, slot swap). RingRelation values are non-negative; -2 is
# an unreachable sentinel that forces the first refresh to apply.
const _RING_RECOLOR_INTERVAL: float = 0.25
var _ring_relation_resolver: Callable = Callable()
var _ring_relation_cached: int = -2
var _ring_color_cached: Color = Color(0, 0, 0, 0)  # unreachable sentinel; forces first refresh
var _ring_recolor_accum: float = _RING_RECOLOR_INTERVAL

# HUD geometry assumes the gameplay top-down camera (ring decals flat on ice,
# name/chevron placed via camera screen-down). Replays cut to broadcast cams
# at arbitrary angles, so we hide the per-skater HUD for the cinematic and
# restore the always-visible nodes on the first non-replay tick.
var _hidden_for_replay: bool = false


func setup(skater: Skater) -> void:
	_skater = skater

	_ring_mesh = MeshInstance3D.new()
	_ring_mesh.name = "RingIndicator"
	_ring_mesh.mesh = _create_ring_mesh(RING_OUTER_R - MenuStyle.HUD_LINE_THIN * RING_LINE_SCALE, RING_OUTER_R, 48)
	_ring_mesh.position = Vector3.ZERO
	_ring_mesh.material_override = _make_hud_ice_material()
	_skater.add_child(_ring_mesh)

	# Stamina ring: top_level so its world transform is rewritten each tick —
	# parented transform would spin the gauge's 12-o'clock fill origin with the
	# skater's facing. Hidden until the local player's pool dips below full
	# (see _update_stamina_ring).
	_stamina_ring_mesh = MeshInstance3D.new()
	_stamina_ring_mesh.name = "StaminaRing"
	_stamina_ring_mesh.top_level = true
	_stamina_ring_mesh.mesh = _create_ring_mesh_with_uv(STAMINA_RING_INNER_R, STAMINA_RING_OUTER_R, 64)
	_stamina_ring_mat = _make_stamina_ring_material()
	_stamina_ring_mesh.material_override = _stamina_ring_mat
	_stamina_ring_mesh.visible = false
	_skater.add_child(_stamina_ring_mesh)

	_chevron_mesh = MeshInstance3D.new()
	_chevron_mesh.name = "ElevatedChevron"
	_chevron_mesh.top_level = true
	_chevron_mesh.mesh = _create_chevron_mesh()
	_chevron_mesh.material_override = _make_hud_ice_material()
	_chevron_mesh.visible = false
	_skater.add_child(_chevron_mesh)

	_chevron_mesh2 = MeshInstance3D.new()
	_chevron_mesh2.name = "ElevatedChevronHigh"
	_chevron_mesh2.top_level = true
	_chevron_mesh2.mesh = _chevron_mesh.mesh
	_chevron_mesh2.material_override = _chevron_mesh.material_override
	_chevron_mesh2.visible = false
	_skater.add_child(_chevron_mesh2)

	# Player name. Single billboarded Label3D, top-level so its world
	# transform isn't tied to the skater's rotation. Position is rewritten
	# each tick from camera screen-down so it always sits below the ring.
	_name_label = Label3D.new()
	_name_label.name = "PlayerNameLabel"
	_name_label.top_level = true
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = false
	_name_label.fixed_size = false
	_name_label.font_size = 40
	_name_label.outline_size = 0
	_name_label.modulate = Color(MenuStyle.HUD_ICE.r, MenuStyle.HUD_ICE.g,
			MenuStyle.HUD_ICE.b, MenuStyle.HUD_OPACITY)
	_name_label.pixel_size = 0.005
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skater.add_child(_name_label)

	# Overhead self-beacon. Built once and hidden until the ring-relation
	# resolver reports SELF. top_level so its world transform is rewritten each
	# tick independent of the skater's body rotation (mirrors the name label).
	# Outline (larger, dark) draws behind the bright fill via render_priority;
	# both are no-depth-test so the marker stays readable through a scrum.
	_self_beacon = Node3D.new()
	_self_beacon.name = "SelfBeacon"
	_self_beacon.top_level = true
	_self_beacon.visible = false
	_skater.add_child(_self_beacon)

	var beacon_outline := MeshInstance3D.new()
	beacon_outline.name = "Outline"
	beacon_outline.mesh = _create_beacon_mesh(
			_BEACON_HALF_W * _BEACON_OUTLINE_SCALE, _BEACON_HALF_H * _BEACON_OUTLINE_SCALE)
	beacon_outline.material_override = _make_beacon_material(_BEACON_OUTLINE_COLOR, 0)
	_self_beacon.add_child(beacon_outline)

	# Fill shares the local player's self ring color (kept in sync live by
	# _apply_self_beacon_relation); seed it from the picked color here.
	var self_col: Color = PlayerPrefs.ring_color_self
	_self_beacon_fill_mat = _make_beacon_material(
			Color(self_col.r, self_col.g, self_col.b, _BEACON_OPACITY), 1)
	var beacon_fill := MeshInstance3D.new()
	beacon_fill.name = "Fill"
	beacon_fill.mesh = _create_beacon_mesh(_BEACON_HALF_W, _BEACON_HALF_H)
	beacon_fill.material_override = _self_beacon_fill_mat
	_self_beacon.add_child(beacon_fill)

	# Slapper one-timer reticle. The parent _slapper_indicator carries the
	# zone offset + radius scale. Arrow + ring share _slapper_arrow_root's
	# rotation so the ring gap stays glued to the arrow tail.
	_slapper_indicator = Node3D.new()
	_slapper_indicator.name = "SlapperIndicator"
	_slapper_indicator.visible = true
	_skater.add_child(_slapper_indicator)
	_slapper_indicator_mat = _make_hud_ice_material()

	_slapper_reticle_node = _create_reticle_mesh(_RETICLE_HALF_LENGTH)
	_slapper_reticle_node.material_override = _slapper_indicator_mat
	_slapper_reticle_node.visible = false
	_slapper_reticle_node.position = Vector3(0.0, _SLAPPER_HUD_Y, 0.0)
	_slapper_indicator.add_child(_slapper_reticle_node)

	_slapper_arrow_root = Node3D.new()
	_slapper_arrow_root.name = "SlapperArrow"
	_slapper_arrow_root.position = Vector3(0.0, _SLAPPER_HUD_Y, 0.0)
	_slapper_indicator.add_child(_slapper_arrow_root)

	_slapper_arrow_mesh = MeshInstance3D.new()
	_slapper_arrow_mesh.material_override = _slapper_indicator_mat
	_slapper_arrow_mesh.visible = false
	_slapper_arrow_mesh.mesh = _arrow_mesh_resource
	_slapper_arrow_root.add_child(_slapper_arrow_mesh)

	_slapper_ring_mesh = MeshInstance3D.new()
	_slapper_ring_mesh.material_override = _slapper_indicator_mat
	_slapper_ring_mesh.visible = false
	_slapper_ring_mesh.mesh = _ring_mesh_resource
	_slapper_arrow_root.add_child(_slapper_ring_mesh)

	update_slapper_indicator_convergence(1.0)


func update(delta: float) -> void:
	if _force_world_hud_hidden or NetworkManager.is_replay_mode() or GameManager.is_local_spectator():
		if not _hidden_for_replay:
			_hidden_for_replay = true
			if _ring_mesh != null: _ring_mesh.visible = false
			if _stamina_ring_mesh != null: _stamina_ring_mesh.visible = false
			if _chevron_mesh != null: _chevron_mesh.visible = false
			if _chevron_mesh2 != null: _chevron_mesh2.visible = false
			if _name_label != null: _name_label.visible = false
			if _slapper_indicator != null: _slapper_indicator.visible = false
			if _slapper_ring_mesh != null: _slapper_ring_mesh.visible = false
			if _self_beacon != null: _self_beacon.visible = false
		return
	if _hidden_for_replay:
		_hidden_for_replay = false
		# Restore the always-visible nodes. _stamina_ring_mesh, _chevron_mesh,
		# _slapper_indicator children, and _slapper_ring_mesh are gated by
		# their own show logic (driven from skater / stamina state) and will
		# re-enable themselves as needed.
		if _ring_mesh != null: _ring_mesh.visible = true
		if _name_label != null: _name_label.visible = true
		if _slapper_indicator != null: _slapper_indicator.visible = true
		_update_beacon_visibility()

	_refresh_height_anchors_if_skater_moved()
	_refresh_screen_down_cache_if_camera_changed()

	_ring_recolor_accum += delta
	if _ring_recolor_accum >= _RING_RECOLOR_INTERVAL:
		_ring_recolor_accum = 0.0
		_refresh_ring_color()

	if _name_label != null and _name_label.visible:
		_name_label.global_position = Vector3(
				_skater.global_position.x + _cached_screen_down.x * _NAME_RADIUS,
				0.05,
				_skater.global_position.z + _cached_screen_down.y * _NAME_RADIUS)

	# Overhead self-beacon: re-evaluate the crowd gate (self-only), then float
	# above the head with a gentle vertical bob and a scale pulse. Only the local
	# player's own skater is ever active, so this runs for a single skater.
	if _self_beacon != null and _self_beacon_active:
		_update_beacon_crowd_state(delta)
	if _self_beacon != null and _self_beacon.visible:
		var now: float = Time.get_ticks_msec() * 0.001
		var bob: float = sin(now * TAU * _BEACON_BOB_HZ) * _BEACON_BOB_AMPLITUDE
		_self_beacon.global_position = Vector3(
				_skater.global_position.x,
				_skater.global_position.y + _BEACON_HOVER_OFFSET + bob,
				_skater.global_position.z)
		var pulse_t: float = 0.5 + 0.5 * sin(now * TAU * _BEACON_PULSE_HZ)
		var s: float = lerpf(_BEACON_PULSE_MIN_SCALE, _BEACON_PULSE_MAX_SCALE, pulse_t)
		_self_beacon.scale = Vector3(s, s, s)

	if _chevron_mesh != null:
		var chevron_should_show: bool = _skater.elevation_level > 0 and not _skater.is_ghost
		var chevron2_should_show: bool = _skater.elevation_level >= 2 and not _skater.is_ghost
		if _chevron_mesh.visible != chevron_should_show:
			_chevron_mesh.visible = chevron_should_show
		if _chevron_mesh2.visible != chevron2_should_show:
			_chevron_mesh2.visible = chevron2_should_show
		if chevron_should_show:
			_chevron_mesh.global_position = Vector3(
					_skater.global_position.x + _cached_chevron_dir.x * _CHEVRON_RADIUS,
					0.05,
					_skater.global_position.z + _cached_chevron_dir.z * _CHEVRON_RADIUS)
		if chevron2_should_show:
			# Stack the second "^" screen-up from the first (the chevron points
			# screen-up, so -screen_down is "above" it on screen).
			_chevron_mesh2.global_position = Vector3(
					_chevron_mesh.global_position.x - _cached_screen_down.x * _CHEVRON_STACK_GAP,
					0.05,
					_chevron_mesh.global_position.z - _cached_screen_down.y * _CHEVRON_STACK_GAP)

	_update_stamina_ring()


# ── Stamina ring ──────────────────────────────────────────────────────────────
# BOTW-style self-only sprint gauge. Gates on the ring-relation resolver's
# SELF result, so only one skater in the scene ever runs the body of this.
# Stamina lives on the LOCAL controller (it is never mirrored onto the Skater
# node), so the controller is re-fetched per tick — the same lifecycle dodge
# the old bottom-edge HUD bar used: the local controller changes across
# respawns, session changes, and spectator swaps, and the fetch is a no-op
# except on the frame it actually changes. Stays visible while ghosted —
# sprinting back to tag up is exactly when the gauge matters.
func _update_stamina_ring() -> void:
	if _stamina_ring_mesh == null:
		return
	var controller: SkaterController = null
	if _ring_relation_cached == RingRelation.SELF:
		var record: PlayerRecord = GameManager.get_local_player()
		controller = record.controller if record != null else null
	if controller == null:
		if _stamina_ring_mesh.visible:
			_stamina_ring_mesh.visible = false
		return
	var s: float = clampf(controller.stamina, 0.0, 1.0)
	var locked: bool = controller.is_sprint_exhausted()
	# Hidden while full (the BOTW rule): the gauge only earns screen space
	# while the pool is actually in play.
	var show: bool = s < _STAMINA_SHOW_BELOW or locked
	if _stamina_ring_mesh.visible != show:
		_stamina_ring_mesh.visible = show
	if not show:
		return
	# Follow the skater; re-align the fill's 12-o'clock origin to camera
	# screen-up so the gauge reads the same regardless of body facing.
	_stamina_ring_mesh.global_position = Vector3(
			_skater.global_position.x, 0.05, _skater.global_position.z)
	_stamina_ring_mesh.rotation = Vector3(0.0, _cached_arc_base_angle, 0.0)
	if not is_equal_approx(s, _last_stamina_fill):
		_last_stamina_fill = s
		_stamina_ring_mat.set_shader_parameter("fill", s)
	# Fill color: normal tracks the player's own picked ring color (the gauge
	# reads as part of "you"); amber when low; flashing red while locked out.
	var col: Color
	if locked:
		var flash_t: float = 0.5 + 0.5 * sin(
				Time.get_ticks_msec() * 0.001 * TAU * _STAMINA_LOCKED_FLASH_HZ)
		col = MenuStyle.DANGER.lerp(_STAMINA_TRACK_COLOR, flash_t * 0.6)
	elif s < _STAMINA_LOW_FRACTION:
		col = _STAMINA_LOW_COLOR
	else:
		col = PlayerPrefs.ring_color_self
	if col != _last_stamina_color:
		_last_stamina_color = col
		_stamina_ring_mat.set_shader_parameter("fill_color", col)


# Y-anchor write only when skater's vertical position changes. Skater Y is
# effectively constant on the ice; the original per-tick global_position.y
# writes were defensive — change-detection preserves that defence at near-zero
# cost when nothing's moved.
func _refresh_height_anchors_if_skater_moved() -> void:
	var y: float = _skater.global_position.y
	if is_equal_approx(y, _last_skater_y):
		return
	_last_skater_y = y
	if _ring_mesh != null:
		_ring_mesh.global_position.y = 0.05
	if _slapper_indicator != null:
		_slapper_indicator.global_position.y = 0.0


# Screen-down + chevron direction depend only on the local camera's orientation.
# That's effectively constant during gameplay (top-down camera), so the trig is
# recomputed only when basis.y actually changes — usually never after first frame.
func _refresh_screen_down_cache_if_camera_changed() -> void:
	var vp: Viewport = _skater.get_viewport() if _skater != null else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return
	var basis_y: Vector3 = cam.global_transform.basis.y
	if basis_y == _cached_cam_basis_y:
		return
	_cached_cam_basis_y = basis_y
	var down := Vector2(-basis_y.x, -basis_y.z)
	if down.length_squared() < 0.0001:
		_cached_screen_down = Vector2(0.0, 1.0)
	else:
		_cached_screen_down = down.normalized()
	_cached_arc_base_angle = atan2(_cached_screen_down.x, _cached_screen_down.y)
	var side_sign: float = 1.0 if _skater.is_left_handed else -1.0
	var chevron_angle: float = _cached_arc_base_angle + side_sign * deg_to_rad(_CHEVRON_OFFSET_DEG)
	_cached_chevron_dir = Vector3(sin(chevron_angle), 0.0, cos(chevron_angle))
	if _chevron_mesh != null:
		_chevron_mesh.rotation = Vector3(0.0, _cached_arc_base_angle, 0.0)
		_chevron_mesh2.rotation = _chevron_mesh.rotation


func set_player_name(p_name: String) -> void:
	if _name_label != null:
		_name_label.text = p_name


# Installs the resolver that maps this skater to a RingRelation (self/teammate/
# enemy) relative to the local player, then applies the color immediately so
# the ring is correct on the spawn frame rather than after the first interval.
func set_ring_relation_resolver(resolver: Callable) -> void:
	_ring_relation_resolver = resolver
	_ring_recolor_accum = 0.0
	_refresh_ring_color()


# Re-resolves the relationship and rewrites the slot-ring tint only when it
# changes. Opacity is preserved from HUD_OPACITY; the ring material is a
# per-skater StandardMaterial3D (see _make_hud_ice_material) so mutating its
# albedo here never bleeds into other skaters' rings.
func _refresh_ring_color() -> void:
	if _ring_mesh == null or not _ring_relation_resolver.is_valid():
		return
	var relation: int = _ring_relation_resolver.call() as int
	var col: Color = _ring_color_for_relation(relation)
	# Recolor when the relationship changes OR the picked color changes — the
	# periodic update() recolor (every _RING_RECOLOR_INTERVAL) then picks up a
	# live ring-color change from the options panel within ~0.25s.
	if relation == _ring_relation_cached and col == _ring_color_cached:
		return
	_ring_relation_cached = relation
	_ring_color_cached = col
	var mat: StandardMaterial3D = _ring_mesh.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(col.r, col.g, col.b, MenuStyle.HUD_OPACITY)
	_apply_self_beacon_relation(relation)


# Show the overhead beacon only when this skater is the local player's own, and
# keep its fill in sync with the user-picked self ring color. Stays visible
# while ghosted — being ghosted (offside/icing) is exactly when steering back
# to tag the blue line makes the self cue most valuable — so only replay /
# spectator hiding gates it.
func _apply_self_beacon_relation(relation: int) -> void:
	_self_beacon_active = (relation == RingRelation.SELF)
	if _self_beacon_active and _self_beacon_fill_mat != null:
		var col: Color = _ring_color_for_relation(RingRelation.SELF)
		_self_beacon_fill_mat.albedo_color = Color(col.r, col.g, col.b, _BEACON_OPACITY)
	_update_beacon_visibility()


func _update_beacon_visibility() -> void:
	if _self_beacon == null:
		return
	# Gated by the Self Marker mode (PlayerPrefs, read live):
	#   ALWAYS   — shown whenever this is your skater.
	#   SMART    — shown when crowded OR ghosted: a scrum is where you lose
	#              yourself, and a lone ghosted player still needs the cue to
	#              steer back to the blue line.
	#   DISABLED — never shown.
	var ghosted: bool = _skater != null and _skater.is_ghost
	var gate: bool
	match PlayerPrefs.self_beacon_mode:
		PlayerPrefs.BEACON_MODE_ALWAYS: gate = true
		PlayerPrefs.BEACON_MODE_SMART:  gate = _beacon_crowded or ghosted
		_:                              gate = false
	_self_beacon.visible = (_self_beacon_active
			and gate
			and not _hidden_for_replay
			and not _force_world_hud_hidden)


# Coarse-interval proximity scan + linger timer that drives _beacon_crowded.
# Re-arms the linger every time a scan still finds a crowd, so the gate only
# falls _BEACON_CROWD_LINGER seconds after the last crowded sample.
func _update_beacon_crowd_state(delta: float) -> void:
	_beacon_crowd_accum += delta
	if _beacon_crowd_accum >= _BEACON_CROWD_CHECK_INTERVAL:
		_beacon_crowd_accum = 0.0
		if _is_crowded():
			_beacon_linger_timer = _BEACON_CROWD_LINGER
	if _beacon_linger_timer > 0.0:
		_beacon_linger_timer = maxf(_beacon_linger_timer - delta, 0.0)
	_beacon_crowded = _beacon_linger_timer > 0.0
	# Refresh every active tick (single skater) so a live Self Marker toggle and
	# ghost transitions reflect immediately, not just on a crowd-state change.
	_update_beacon_visibility()


# True once _BEACON_CROWD_COUNT other skaters sit within _BEACON_CROWD_RADIUS of
# the local skater. Counts both teams — overlapping bodies of either jersey are
# what make you lose yourself. Early-outs as soon as the threshold is met.
func _is_crowded() -> bool:
	var players: Dictionary[int, PlayerRecord] = GameManager.get_players()
	var origin: Vector3 = _skater.global_position
	var r2: float = _BEACON_CROWD_RADIUS * _BEACON_CROWD_RADIUS
	var count: int = 0
	for peer_id: int in players:
		var rec: PlayerRecord = players[peer_id]
		if rec == null or rec.skater == null or rec.skater == _skater:
			continue
		if origin.distance_squared_to(rec.skater.global_position) <= r2:
			count += 1
			if count >= _BEACON_CROWD_COUNT:
				return true
	return false


func _ring_color_for_relation(relation: int) -> Color:
	match relation:
		RingRelation.SELF:     return PlayerPrefs.ring_color_self
		RingRelation.TEAMMATE: return PlayerPrefs.ring_color_team
		RingRelation.ENEMY:    return PlayerPrefs.ring_color_enemy
		_:                     return MenuStyle.HUD_ICE


# Latch all per-skater HUD chrome off. Used by the replay viewer (which
# disables physics processing, so the update() check never runs) and live
# spectator mode. Applies immediately so the rings/labels disappear on the
# next render rather than waiting for the next physics tick.
func set_world_hud_hidden(hidden: bool) -> void:
	_force_world_hud_hidden = hidden
	if hidden:
		_hidden_for_replay = true
		if _ring_mesh != null: _ring_mesh.visible = false
		if _stamina_ring_mesh != null: _stamina_ring_mesh.visible = false
		if _chevron_mesh != null: _chevron_mesh.visible = false
		if _chevron_mesh2 != null: _chevron_mesh2.visible = false
		if _name_label != null: _name_label.visible = false
		if _slapper_indicator != null: _slapper_indicator.visible = false
		if _slapper_ring_mesh != null: _slapper_ring_mesh.visible = false
		if _self_beacon != null: _self_beacon.visible = false


func update_slapper_indicator_convergence(ratio: float) -> void:
	_slapper_current_ring_scale = lerpf(
			_SLAPPER_RING_MIN_SCALE, 1.0, clampf(ratio, 0.0, 1.0))
	_rebuild_slapper_geometry()


func set_slapshot_arrow(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = -1.0) -> void:
	if _slapper_arrow_mesh == null:
		return
	if not active:
		_slapper_arrow_mesh.visible = false
		return
	var r: float = radius if radius > 0.0 else _slapper_zone_radius_cached
	_apply_slapshot_zone_transform(offset_x, offset_z, r)
	_slapper_arrow_mesh.visible = true
	_rebuild_slapper_geometry()


func update_slapshot_arrow_direction(world_dir: Vector3) -> void:
	if _slapper_arrow_root == null or not _slapper_arrow_mesh.visible:
		return
	if world_dir.length() < 0.001:
		return
	var local_dir: Vector3 = _skater.global_transform.basis.inverse() * world_dir
	local_dir.y = 0.0
	if local_dir.length() < 0.001:
		return
	_slapper_arrow_root.rotation.y = atan2(local_dir.x, local_dir.z)


func set_slapper_indicator(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = 0.5) -> void:
	if _slapper_ring_mesh == null or _slapper_reticle_node == null:
		return
	if not active:
		_slapper_ring_mesh.visible = false
		_slapper_reticle_node.visible = false
		return
	_apply_slapshot_zone_transform(offset_x, offset_z, radius)
	_slapper_ring_mesh.visible = true
	_slapper_reticle_node.visible = true
	update_slapper_indicator_convergence(1.0)


func set_slapper_indicator_ready(_is_ready: bool) -> void:
	pass


func update_slapper_indicator_window(_t: float) -> void:
	pass


func apply_ghost(ghost: bool) -> void:
	# While the per-skater HUD is force-hidden (replay viewer / spectator) or
	# latched off for a replay cinematic, an un-ghost must NOT re-show the ring or
	# name label. Replay playback re-applies is_ghost every frame, and update() —
	# which would otherwise re-hide and re-anchor these — either returns early
	# (goal/post-game replay, spectator) or never runs at all (offline viewer,
	# physics disabled). A leaked ring then floats at the skater's body-centre
	# origin instead of on the ice. The beacon below is already gated the same way
	# via _update_beacon_visibility().
	var hud_hidden: bool = _force_world_hud_hidden or _hidden_for_replay
	if _ring_mesh != null:
		_ring_mesh.visible = not ghost and not hud_hidden
	if _name_label != null:
		_name_label.visible = not ghost and not hud_hidden
	# The stamina ring is left alone: like the beacon, it stays useful while
	# ghosted (sprinting back to tag up), and its own show logic re-gates it.
	if ghost:
		if _slapper_arrow_mesh != null:
			_slapper_arrow_mesh.visible = false
		if _slapper_ring_mesh != null:
			_slapper_ring_mesh.visible = false
		if _slapper_reticle_node != null:
			_slapper_reticle_node.visible = false
	# set_ghost() writes _skater.is_ghost before calling here, so the gate sees
	# the up-to-date ghost state (beacon stays visible while ghosted).
	_update_beacon_visibility()


# ── Private: zone transform ───────────────────────────────────────────────────

func _apply_slapshot_zone_transform(offset_x: float, offset_z: float, radius: float) -> void:
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	_slapper_indicator.position = Vector3(blade_side_sign * offset_x, 0.0, offset_z)
	_slapper_indicator.scale = Vector3(radius, 1.0, radius)
	# Re-anchor to ice level — the Skater root sits at body-center height, so
	# the local Y=0 just written puts the ring at chest height in world. The
	# per-frame anchor in _refresh_height_anchors_if_skater_moved would catch
	# this on a Y change, but skater Y is constant during play so it never
	# re-fires after the initial frame; do it explicitly here every time we
	# rebase the position. Setting global Y rebases local Y without touching XZ.
	_slapper_indicator.global_position.y = 0.0
	_slapper_zone_radius_cached = radius
	# Counter-scale the centre crosshair so it stays at fixed world size
	# regardless of the parent indicator's radius scale.
	if _slapper_reticle_node != null:
		var inv: float = 1.0 / max(radius, 0.001)
		_slapper_reticle_node.scale = Vector3(inv, 1.0, inv)


# ── Private: slapper geometry rebuild ────────────────────────────────────────

func _rebuild_slapper_geometry() -> void:
	if _slapper_arrow_mesh == null or _slapper_ring_mesh == null:
		return
	# Short-circuit when nothing's changed. Convergence ticks where the puck
	# is momentarily stationary, plus all calls after the charge ends, hit
	# this path and skip allocating + uploading identical geometry.
	var ring_visible: bool = _slapper_ring_mesh.visible
	if (is_equal_approx(_slapper_current_ring_scale, _last_rebuild_ring_scale)
			and is_equal_approx(_slapper_zone_radius_cached, _last_rebuild_radius)
			and ring_visible == _last_rebuild_ring_visible):
		return
	_last_rebuild_ring_scale = _slapper_current_ring_scale
	_last_rebuild_radius = _slapper_zone_radius_cached
	_last_rebuild_ring_visible = ring_visible

	var r: float = _slapper_current_ring_scale
	var w: float = _ARROW_SHAFT_HALF_W_UNIT
	# Counter-scale stroke thickness so lines stay at HUD_LINE_THIN world meters.
	var t_unit: float = MenuStyle.HUD_LINE_THIN / max(_slapper_zone_radius_cached, 0.001)
	var tip_z: float = _ARROW_TIP_DISTANCE_UNIT
	var head_len: float = _ARROW_HEAD_LEN_UNIT
	var head_half_w: float = _ARROW_HEAD_HALF_W_UNIT
	var shoulder_z: float = tip_z - head_len

	# ── Arrow mesh (shaft sides + shoulders + head diagonals) ──
	_arrow_verts.clear()
	_arrow_normals.clear()
	_arrow_indices.clear()
	var shaft_base_z: float = 0.0
	if ring_visible and r > w:
		shaft_base_z = sqrt(r * r - w * w)
	if shaft_base_z < shoulder_z:
		for sign_x: float in [-1.0, 1.0]:
			var shaft_tail := Vector2(sign_x * w, shaft_base_z)
			var shaft_top  := Vector2(sign_x * w, shoulder_z)
			_append_strip(_arrow_verts, _arrow_normals, _arrow_indices, shaft_tail, shaft_top, t_unit)
	var tip := Vector2(0.0, tip_z)
	for sign_x_h: float in [-1.0, 1.0]:
		var shoulder_in  := Vector2(sign_x_h * w, shoulder_z)
		var shoulder_out := Vector2(sign_x_h * head_half_w, shoulder_z)
		_append_strip(_arrow_verts, _arrow_normals, _arrow_indices, shoulder_in, shoulder_out, t_unit)
		_append_strip(_arrow_verts, _arrow_normals, _arrow_indices, shoulder_out, tip, t_unit)
	_upload_to_mesh(_arrow_mesh_resource, _arrow_verts, _arrow_normals, _arrow_indices)

	# ── Ring mesh (partial-arc annulus with gap on the arrow tail side) ──
	_ring_verts.clear()
	_ring_normals.clear()
	_ring_indices.clear()
	if r > w + t_unit:
		var gap_half: float = asin(clampf(w / r, -1.0, 1.0))
		var sweep_total: float = TAU - 2.0 * gap_half
		var seg_count: int = max(8, int(ceil(_RING_SEGMENTS * sweep_total / TAU)))
		_append_partial_ring(_ring_verts, _ring_normals, _ring_indices,
				r - t_unit, r,
				gap_half, TAU - gap_half, seg_count)
	_upload_to_mesh(_ring_mesh_resource, _ring_verts, _ring_normals, _ring_indices)


func _upload_to_mesh(
		mesh: ArrayMesh,
		verts: PackedVector3Array,
		normals: PackedVector3Array,
		indices: PackedInt32Array) -> void:
	mesh.clear_surfaces()
	if verts.size() == 0:
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


# ── Private: mesh builders ────────────────────────────────────────────────────

func _create_ring_mesh(inner_r: float, outer_r: float, segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for i: int in segments:
		var a0: float = TAU * i / segments
		var a1: float = TAU * (i + 1) / segments
		var base: int = verts.size()
		verts.append(Vector3(cos(a0) * inner_r, 0.0, sin(a0) * inner_r))
		verts.append(Vector3(cos(a0) * outer_r, 0.0, sin(a0) * outer_r))
		verts.append(Vector3(cos(a1) * inner_r, 0.0, sin(a1) * inner_r))
		verts.append(Vector3(cos(a1) * outer_r, 0.0, sin(a1) * outer_r))
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Bakes a clockwise-from-12-o'clock UV.x onto every vertex so the charge-ring
# shader can use it as an angular fill mask.
func _create_ring_mesh_with_uv(inner_r: float, outer_r: float, segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for i: int in segments:
		var t0: float = float(i) / float(segments)
		var t1: float = float(i + 1) / float(segments)
		var a0: float = -PI * 0.5 - t0 * TAU
		var a1: float = -PI * 0.5 - t1 * TAU
		var base: int = verts.size()
		verts.append(Vector3(cos(a0) * inner_r, 0.0, sin(a0) * inner_r))
		verts.append(Vector3(cos(a0) * outer_r, 0.0, sin(a0) * outer_r))
		verts.append(Vector3(cos(a1) * inner_r, 0.0, sin(a1) * inner_r))
		verts.append(Vector3(cos(a1) * outer_r, 0.0, sin(a1) * outer_r))
		uvs.append(Vector2(t0, 0.0))
		uvs.append(Vector2(t0, 1.0))
		uvs.append(Vector2(t1, 0.0))
		uvs.append(Vector2(t1, 1.0))
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Upward-pointing "^" chevron drawn flat on the ice.
func _create_chevron_mesh() -> ArrayMesh:
	var size: float = 0.14
	var leg_len: float = size * 0.7
	var thickness: float = MenuStyle.HUD_LINE_THIN
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var legs: Array = [
		{ "rot": deg_to_rad(135.0), "anchor": Vector3.ZERO },
		{ "rot": deg_to_rad(-135.0), "anchor": Vector3.ZERO },
	]
	for leg: Dictionary in legs:
		var rot_y: float = leg.rot
		var anchor: Vector3 = leg.anchor
		var dir := Vector3(sin(rot_y), 0.0, -cos(rot_y))
		var perp := Vector3(cos(rot_y), 0.0, sin(rot_y))
		var half_t: float = thickness * 0.5
		var p0: Vector3 = anchor + perp * half_t
		var p1: Vector3 = anchor - perp * half_t
		var p2: Vector3 = anchor + dir * leg_len + perp * half_t
		var p3: Vector3 = anchor + dir * leg_len - perp * half_t
		var base: int = verts.size()
		verts.append(p0); verts.append(p1); verts.append(p2); verts.append(p3)
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Centre crosshair for the slapper one-timer reticle.
func _create_reticle_mesh(half_len: float) -> MeshInstance3D:
	var thickness: float = MenuStyle.HUD_LINE_THIN
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var half_t: float = thickness * 0.5
	_append_quad(verts, normals, indices,
			-half_len, -half_t, -half_len, half_t,
			half_len, half_t, half_len, -half_t)
	_append_quad(verts, normals, indices,
			-half_t, -half_len, -half_t, half_len,
			half_t, half_len, half_t, -half_len)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	return inst


func _append_strip(
		verts: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
		a_pt: Vector2, b_pt: Vector2, thickness: float) -> void:
	var edge: Vector2 = b_pt - a_pt
	var edge_len: float = edge.length()
	if edge_len < 0.0001:
		return
	var edge_dir: Vector2 = edge / edge_len
	var edge_perp := Vector2(-edge_dir.y, edge_dir.x)
	var half_t: float = thickness * 0.5
	var p0: Vector2 = a_pt + edge_perp * half_t
	var p1: Vector2 = a_pt - edge_perp * half_t
	var p2: Vector2 = b_pt - edge_perp * half_t
	var p3: Vector2 = b_pt + edge_perp * half_t
	_append_quad(verts, normals, indices,
			p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)


func _append_partial_ring(
		verts: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
		inner_r: float, outer_r: float,
		start_angle: float, end_angle: float, segments: int) -> void:
	if segments <= 0:
		return
	var sweep: float = end_angle - start_angle
	for i: int in segments:
		var t0: float = float(i) / float(segments)
		var t1: float = float(i + 1) / float(segments)
		var a0: float = start_angle + sweep * t0
		var a1: float = start_angle + sweep * t1
		var s0: float = sin(a0); var c0: float = cos(a0)
		var s1: float = sin(a1); var c1: float = cos(a1)
		var base: int = verts.size()
		verts.append(Vector3(s0 * inner_r, 0.0, c0 * inner_r))
		verts.append(Vector3(s0 * outer_r, 0.0, c0 * outer_r))
		verts.append(Vector3(s1 * inner_r, 0.0, c1 * inner_r))
		verts.append(Vector3(s1 * outer_r, 0.0, c1 * outer_r))
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])


func _append_quad(
		verts: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
		x0: float, z0: float, x1: float, z1: float,
		x2: float, z2: float, x3: float, z3: float) -> void:
	var base: int = verts.size()
	verts.append(Vector3(x0, 0.0, z0))
	verts.append(Vector3(x1, 0.0, z1))
	verts.append(Vector3(x2, 0.0, z2))
	verts.append(Vector3(x3, 0.0, z3))
	for _n: int in 4:
		normals.append(Vector3.UP)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


# Downward-pointing triangle in the local XY plane (billboard space): the apex
# sits at the bottom and points down at the skater; the base spans the top.
func _create_beacon_mesh(half_w: float, half_h: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	verts.append(Vector3(0.0, -half_h, 0.0))     # apex (points down)
	verts.append(Vector3(-half_w, half_h, 0.0))  # top-left
	verts.append(Vector3(half_w, half_h, 0.0))   # top-right
	for _n: int in 3:
		normals.append(Vector3.BACK)
	indices.append_array([0, 1, 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Billboarded, unshaded, no-depth-test material for the self-beacon. The outline
# (lower render_priority) draws behind the fill so the marker keeps a dark edge
# against bright ice or a busy scrum. billboard_keep_scale preserves the
# per-tick pulse scale written to the parent node.
func _make_beacon_material(color: Color, render_priority: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.no_depth_test = true
	mat.render_priority = render_priority
	mat.albedo_color = color
	return mat


func _make_hud_ice_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(MenuStyle.HUD_ICE.r, MenuStyle.HUD_ICE.g,
			MenuStyle.HUD_ICE.b, MenuStyle.HUD_OPACITY)
	return mat


func _make_stamina_ring_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = _STAMINA_RING_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("fill", 1.0)
	mat.set_shader_parameter("fill_color", MenuStyle.HUD_RING_SELF)
	mat.set_shader_parameter("track_color", _STAMINA_TRACK_COLOR)
	mat.set_shader_parameter("opacity", MenuStyle.HUD_OPACITY)
	return mat


