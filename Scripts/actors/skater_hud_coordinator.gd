class_name SkaterHUDCoordinator
extends RefCounted

# ── HUD geometry constants ────────────────────────────────────────────────────
# Slot ring sits just inside RING_OUTER_R. The stamina ring is concentric,
# just inside the slot ring's inner edge with a small gap. Chevron and player
# name sit below the rings on the screen-down side.
const RING_LINE_SCALE: float     = 2.0   # line-thickness bump for readability; visual only, never a hitbox
const RING_OUTER_R: float        = 0.45
# The slot ring is no longer a mesh — the ice shader draws it analytically from
# these radii (see IceRingField). Kept here because everything else on the rig
# is still laid out relative to the ring's outer edge.
const RING_INNER_R: float        = RING_OUTER_R - MenuStyle.HUD_LINE_THIN * RING_LINE_SCALE

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
const STAMINA_TRACK_COLOR := Color(0.06, 0.08, 0.11, 0.55)  # read by IceRingField

# Player-name placement — a billboarded Label3D sitting just outside the slot
# ring, on the screen-down side. WORLD-sized (pixel_size, not fixed_size), so a
# name is the same size on the ice whatever the camera is doing, and grows and
# shrinks with zoom like everything else out there. Drawing it in the 2D pass
# instead saved a node per skater but could only pick an integer font size, so
# the text stepped between sizes as the camera breathed.
const _NAME_RADIUS: float   = RING_OUTER_R + 0.10
const _NAME_FONT_SIZE: int  = 40
const _NAME_PIXEL_SIZE: float = 0.005
const _NAME_ICE_Y: float    = 0.05
const _CHEVRON_RADIUS: float = RING_OUTER_R + 0.10
const _CHEVRON_OFFSET_DEG: float = 60.0
# Screen-up gap between the stacked chevrons — one per loft rung above flat:
# "^" = LOW, "^^" = MID, "^^^" = HIGH. PUBLIC because the ice shader draws them
# now: IceRingField hands this over at setup so the spacing has one home rather
# than a copy in the shader that silently drifts from this one.
const CHEVRON_STACK_GAP: float = 0.11

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

# Smart-ping chat bubble. A billboarded Label3D that floats above the PINGER's
# head for a beat, showing the resolved team message ("Pass to me!", "Cover
# him!", ...). Built lazily on the first ping (most skaters never ping), holds
# fully visible then fades out; position is rewritten each frame like the
# beacon. Sits above the self-beacon apex so the two never overlap on the
# local player's own skater.
const _PING_BUBBLE_HOVER_OFFSET: float = 1.62
const _PING_BUBBLE_HOLD_S: float = 2.4
const _PING_BUBBLE_FADE_S: float = 0.5
const _PING_BUBBLE_OUTLINE_A: float = 0.85

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

# Ring minimum scale for the slapper one-timer indicator, in multiples of the
# zone radius. The arrow geometry is the shader's own (ice.gdshader draws it);
# RETICLE_HALF_LENGTH is PUSHED into `reticle_half_len` by IceRingField, so
# neither is mirrored here.
const _SLAPPER_RING_MIN_SCALE: float   = 0.15
const RETICLE_HALF_LENGTH: float       = 0.06
const _RING_SEGMENTS: int              = 48
const _SLAPPER_HUD_Y: float            = 0.05

# Slot-ring relationship to the LOCAL player, resolved live so a late-spawning
# local player and mid-game slot swaps self-correct. UNKNOWN keeps the neutral
# HUD_ICE tint (the pre-coloring default).
enum RingRelation { UNKNOWN = -1, SELF = 0, TEAMMATE = 1, ENEMY = 2 }

var _skater: Skater

# Drawn by the ice shader (see IceRingField), so what survives is the state it
# needs. The gauge was a 64-segment MeshInstance3D carrying its own ShaderMaterial
# whose world transform was rewritten every frame to follow the skater and
# re-align the fill origin to the camera.
var _stamina_visible: bool = false
var _stamina_fill: float = 1.0
var _stamina_color: Color = Color.WHITE

# Player name. Billboarded Label3D, top_level so the plate keeps its screen-down
# placement while the body spins under it, and opted OUT of physics
# interpolation: this whole coordinator runs at render rate and writes the
# skater's INTERPOLATED pose, so handing the result to the interpolator as well
# would lag it a tick behind the body it is labelling.
var _name_label: Label3D = null

# Overhead self-beacon. LAZY — null until the ring-relation resolver reports
# SELF, and freed again if it stops (see _apply_self_beacon_relation), so exactly
# one exists in the scene rather than one per skater. It was built eagerly in
# setup(), which put three nodes and two materials on all ten skaters at 5v5 so
# that ONE could show a marker; with Self Marker DISABLED it was thirty nodes for
# nothing. Same idiom as the ping bubble below, and the same reasoning that moved
# the flat-on-ice chrome into the shader — this one just cannot go there, because
# it floats above the head.
#
# `_self_beacon` is top_level (world transform rewritten each frame, like the
# name label) and parents an outline + fill MeshInstance.
# `_self_beacon_active` latches whether the resolver currently reports SELF;
# actual visibility also gates on ghost/replay/spectator state.
var _self_beacon: Node3D = null
var _self_beacon_fill_mat: StandardMaterial3D = null
var _self_beacon_active: bool = false
# Crowd-gate state. `_beacon_crowded` is the latched "enough skaters nearby"
# result; `_beacon_linger_timer` holds it on briefly after the crowd clears.
var _beacon_crowded: bool = false
var _beacon_crowd_accum: float = _BEACON_CROWD_CHECK_INTERVAL
var _beacon_linger_timer: float = 0.0

# Smart-ping chat bubble (lazy-built; null until this skater's first ping).
# `_ping_bubble_time_left` counts down HOLD+FADE; the fade tail drives alpha.
var _ping_label: Label3D = null
var _ping_bubble_time_left: float = 0.0

# Slapper one-timer indicator, drawn by the ice shader (see IceRingField). It was
# five nodes — indicator root, reticle, arrow root, arrow, ring — on EVERY
# skater, so that at most one could show them. What survives is the state the
# shader needs; the placement, rotation and stroke geometry it used to carry in
# transforms and rebuilt ArrayMeshes are now the shader's job.
var _slapper_indicator_on: bool = false   # reticle + convergence ring
var _slapper_arrow_on: bool = false
# Skater-LOCAL, exactly as the indicator node's transform was: the world frame is
# derived at read time, so the indicator still swings with the body.
var _slapper_offset_local: Vector3 = Vector3.ZERO
var _slapper_arrow_angle: float = 0.0

var _slapper_zone_radius_cached: float = 0.5
var _slapper_current_ring_scale: float = 1.0
# Force-hide all per-skater HUD chrome regardless of replay-mode state. Used
# by the offline replay viewer and live spectator mode, where the director's
# cameras (broadcast / chase / POV / free) keep a clean broadcast look — the
# flat ring decals were designed for the local player's own top-down framing.
# Latched once at setup; persists for the actor's lifetime.
var _force_world_hud_hidden: bool = false


# Per-frame caches. `update()` runs every rendered frame across every skater, so
# anything derived from infrequently-changing inputs (camera orientation,
# shader-param values) is recomputed only on change.
var _cached_cam_basis_y: Vector3 = Vector3.ZERO
var _cached_screen_down: Vector2 = Vector2(0.0, 1.0)
var _cached_arc_base_angle: float = 0.0
var _cached_chevron_dir: Vector3 = Vector3(0.0, 0.0, 1.0)

# Slot-ring relationship tint. The resolver (installed by PlayerRegistry)
# returns a RingRelation each refresh; recolor is re-evaluated on a coarse
# interval rather than every physics tick since relationship changes rarely
# (local-player spawn, slot swap). RingRelation values are non-negative; -2 is
# an unreachable sentinel that forces the first refresh to apply.
const _RING_RECOLOR_INTERVAL: float = 0.25
var _ring_relation_resolver: Callable = Callable()
# Whether the ring should be drawn at all — replaces the mesh's `visible` flag
# now that IceRingField reads state instead of the tree. TRUE by default, and
# that matters: it replaced a MeshInstance3D, which is born `visible = true`.
# Only the replay/spectator latch and the ghost pass ever write it, and neither
# runs on an ordinary skater — so defaulting it false left the ring hidden from
# spawn until the first goal replay restored it. (An UNKNOWN-relation ring still
# cannot flash: ring_visible() also gates on a resolved relation.)
var _ring_visible: bool = true
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
	_name_label = Label3D.new()
	_name_label.name = "PlayerNameLabel"
	_name_label.top_level = true
	_name_label.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Reads through a scrum: the plate exists to be read, and on a top-down
	# camera it is bodies, not scenery, that would occlude it.
	_name_label.no_depth_test = true
	_name_label.fixed_size = false
	_name_label.font_size = _NAME_FONT_SIZE
	_name_label.outline_size = 0
	_name_label.modulate = Color(MenuStyle.HUD_ICE.r, MenuStyle.HUD_ICE.g,
			MenuStyle.HUD_ICE.b, MenuStyle.HUD_OPACITY)
	_name_label.pixel_size = _NAME_PIXEL_SIZE
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skater.add_child(_name_label)


# Places every piece of on-ice chrome, at RENDER rate — so each placement reads
# the skater's rendered pose (see Skater.render_transform), never
# global_position. Mixing the two clocks is what makes a plate or a marker crawl
# against the body it belongs to on a high-refresh display.
func update(delta: float) -> void:
	if _force_world_hud_hidden or NetworkManager.is_replay_mode() or GameManager.is_local_spectator():
		if not _hidden_for_replay:
			_hidden_for_replay = true
			_ring_visible = false
			_stamina_visible = false
			_name_label.visible = false
			if _self_beacon != null: _self_beacon.visible = false
			if _ping_label != null:
				_ping_label.visible = false
				_ping_bubble_time_left = 0.0
		return
	if _hidden_for_replay:
		_hidden_for_replay = false
		# Restore the always-visible chrome. The stamina gauge, the slapper
		# indicator and the beacon are gated by their own show logic (driven from
		# skater / stamina state) and re-enable themselves as needed.
		_ring_visible = true
		_name_label.visible = true
		_update_beacon_visibility()

	_refresh_screen_down_cache_if_camera_changed()

	var render_pos: Vector3 = _skater.render_transform().origin
	if _name_label.visible:
		_name_label.global_position = Vector3(
				render_pos.x + _cached_screen_down.x * _NAME_RADIUS,
				_NAME_ICE_Y,
				render_pos.z + _cached_screen_down.y * _NAME_RADIUS)

	_ring_recolor_accum += delta
	if _ring_recolor_accum >= _RING_RECOLOR_INTERVAL:
		_ring_recolor_accum = 0.0
		_refresh_ring_color()

	# Overhead self-beacon: re-evaluate the crowd gate (self-only), then float
	# above the head with a gentle vertical bob and a scale pulse. Only the local
	# player's own skater is ever active, so this runs for a single skater.
	if _self_beacon != null and _self_beacon_active:
		_update_beacon_crowd_state(delta)
	if _self_beacon != null and _self_beacon.visible:
		var now: float = Time.get_ticks_msec() * 0.001
		var bob: float = sin(now * TAU * _BEACON_BOB_HZ) * _BEACON_BOB_AMPLITUDE
		_self_beacon.global_position = Vector3(
				render_pos.x,
				render_pos.y + _BEACON_HOVER_OFFSET + bob,
				render_pos.z)
		var pulse_t: float = 0.5 + 0.5 * sin(now * TAU * _BEACON_PULSE_HZ)
		var s: float = lerpf(_BEACON_PULSE_MIN_SCALE, _BEACON_PULSE_MAX_SCALE, pulse_t)
		_self_beacon.scale = Vector3(s, s, s)

	# Smart-ping chat bubble: hold above the head, then fade out. Only ticks
	# while a bubble is live, so the idle cost is one branch.
	if _ping_label != null and _ping_bubble_time_left > 0.0:
		_ping_bubble_time_left -= delta
		if _ping_bubble_time_left <= 0.0:
			_ping_label.visible = false
		else:
			_ping_label.global_position = Vector3(
					render_pos.x,
					render_pos.y + _PING_BUBBLE_HOVER_OFFSET,
					render_pos.z)
			var bubble_a: float = clampf(
					_ping_bubble_time_left / _PING_BUBBLE_FADE_S, 0.0, 1.0)
			_ping_label.modulate.a = bubble_a
			_ping_label.outline_modulate.a = _PING_BUBBLE_OUTLINE_A * bubble_a

	# Elevation chevrons are drawn by the ice shader (IceRingField reads
	# chevron_stack() / chevron_apex()), so nothing is placed here.

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
	var controller: SkaterController = null
	if _ring_relation_cached == RingRelation.SELF:
		var record: PlayerRecord = GameManager.get_local_player()
		controller = record.controller if record != null else null
	if controller == null:
		_stamina_visible = false
		return
	var s: float = clampf(controller.stamina, 0.0, 1.0)
	var locked: bool = controller.is_sprint_exhausted()
	# Hidden while full (the BOTW rule): the gauge only earns screen space
	# while the pool is actually in play.
	_stamina_visible = s < _STAMINA_SHOW_BELOW or locked
	if not _stamina_visible:
		return
	_stamina_fill = s
	# Fill color: normal tracks the player's own picked ring color (the gauge
	# reads as part of "you"); amber when low; flashing red while locked out.
	var col: Color
	if locked:
		var flash_t: float = 0.5 + 0.5 * sin(
				Time.get_ticks_msec() * 0.001 * TAU * _STAMINA_LOCKED_FLASH_HZ)
		col = MenuStyle.DANGER.lerp(STAMINA_TRACK_COLOR, flash_t * 0.6)
	elif s < _STAMINA_LOW_FRACTION:
		col = _STAMINA_LOW_COLOR
	else:
		col = PlayerPrefs.ring_color_self
	_stamina_color = col


# ── Read by IceRingField each frame (stamina gauge) ─────────────────────────
func stamina_gauge_visible() -> bool:
	return _stamina_visible


func stamina_gauge_fill() -> float:
	return _stamina_fill


func stamina_gauge_color() -> Color:
	return _stamina_color


# The gauge's 12 o'clock is camera screen-UP, not a body direction — the node
# rig got that by yawing the ring to _cached_arc_base_angle every frame.
func stamina_gauge_up() -> Vector2:
	return -_cached_screen_down


# Concentric with the slot ring, so it reads the same rendered pose the ring
# does — a raw read here would slide the gauge out of its own ring at speed.
func stamina_gauge_center() -> Vector2:
	var pos: Vector3 = _skater.render_transform().origin
	return Vector2(pos.x, pos.z)


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


func set_player_name(p_name: String) -> void:
	_name_label.text = p_name


# Shows the smart-ping chat bubble above this skater's head. Called (via the
# Skater delegate) from GameManager._on_smart_ping_received for teammates of
# the pinger; a fresh ping restarts the hold/fade cycle. Lazy-built: most
# skaters never ping, so the Label3D only exists once one does.
func show_ping_bubble(text: String) -> void:
	if _skater == null:
		return
	if _ping_label == null:
		_ping_label = Label3D.new()
		_ping_label.name = "PingBubble"
		_ping_label.top_level = true
		_ping_label.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_ping_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		# Reads through a scrum — a team call-out must never hide behind bodies.
		_ping_label.no_depth_test = true
		_ping_label.render_priority = 2
		_ping_label.font_size = 48
		_ping_label.outline_size = 10
		_ping_label.pixel_size = 0.005
		_ping_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_ping_label.visible = false
		_skater.add_child(_ping_label)
	_ping_label.text = text
	_ping_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_ping_label.outline_modulate = Color(0.0, 0.0, 0.0, _PING_BUBBLE_OUTLINE_A)
	var render_pos: Vector3 = _skater.render_transform().origin
	_ping_label.global_position = Vector3(
			render_pos.x,
			render_pos.y + _PING_BUBBLE_HOVER_OFFSET,
			render_pos.z)
	_ping_label.visible = true
	_ping_bubble_time_left = _PING_BUBBLE_HOLD_S + _PING_BUBBLE_FADE_S


# Installs the resolver that maps this skater to a RingRelation (self/teammate/
# enemy) relative to the local player, then applies the color immediately so
# the ring is correct on the spawn frame rather than after the first interval.
func set_ring_relation_resolver(resolver: Callable) -> void:
	_ring_relation_resolver = resolver
	_ring_recolor_accum = 0.0
	_refresh_ring_color()


# Re-resolves the relationship and rewrites the slot-ring tint only when it
# changes. The colour is read per frame by IceRingField and handed to the ice
# shader as a uniform, so there is no per-skater material to bleed through —
# what this caches IS the ring.
func _refresh_ring_color() -> void:
	if not _ring_relation_resolver.is_valid():
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
	_apply_self_beacon_relation(relation)


# Show the overhead beacon only when this skater is the local player's own, and
# keep its fill in sync with the user-picked self ring color. Stays visible
# while ghosted — being ghosted (offside/icing) is exactly when steering back
# to tag the blue line makes the self cue most valuable — so only replay /
# spectator hiding gates it.
func _apply_self_beacon_relation(relation: int) -> void:
	_self_beacon_active = (relation == RingRelation.SELF)
	if _self_beacon_active:
		_ensure_self_beacon()
	elif _self_beacon != null:
		# Stopped being the local player's skater — a slot swap or a spectator
		# takeover. Drop it so the invariant stays "at most one in the scene";
		# rebuilding on the next latch is a swap-time cost, not a per-frame one.
		_self_beacon.queue_free()
		_self_beacon = null
		_self_beacon_fill_mat = null
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


# Builds the beacon on first SELF latch. Outline (larger, dark) draws behind the
# bright fill via render_priority; both are no-depth-test so the marker stays
# readable through a scrum.
func _ensure_self_beacon() -> void:
	if _self_beacon != null:
		return
	_self_beacon = Node3D.new()
	_self_beacon.name = "SelfBeacon"
	_self_beacon.top_level = true
	# Placed from the rendered pose at render rate, like the name plate — and
	# unlike it, carrying a wall-clock bob and pulse the interpolator would chew
	# into a stutter by resampling them at the tick rate.
	_self_beacon.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
		_ring_visible = false
		_stamina_visible = false
		_name_label.visible = false
		_slapper_indicator_on = false
		_slapper_arrow_on = false
		if _self_beacon != null: _self_beacon.visible = false


func update_slapper_indicator_convergence(ratio: float) -> void:
	_slapper_current_ring_scale = lerpf(
			_SLAPPER_RING_MIN_SCALE, 1.0, clampf(ratio, 0.0, 1.0))


func set_slapshot_arrow(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = -1.0) -> void:
	if not active:
		_slapper_arrow_on = false
		return
	_store_slapper_zone(offset_x, offset_z,
			radius if radius > 0.0 else _slapper_zone_radius_cached)
	_slapper_arrow_on = true


func update_slapshot_arrow_direction(world_dir: Vector3) -> void:
	if not _slapper_arrow_on:
		return
	var local_dir: Vector3 = _skater.global_transform.basis.inverse() * world_dir
	local_dir.y = 0.0
	if local_dir.length() < 0.001:
		return
	_slapper_arrow_angle = atan2(local_dir.x, local_dir.z)


func set_slapper_indicator(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = 0.5) -> void:
	if not active:
		_slapper_indicator_on = false
		return
	_store_slapper_zone(offset_x, offset_z, radius)
	_slapper_indicator_on = true
	update_slapper_indicator_convergence(1.0)


# ── Read by IceRingField each frame ──────────────────────────────────────────
# Local-to-world happens here rather than at store time so the indicator tracks
# the body the way a child node did — through the RENDERED pose, since the ice
# it is painted on is drawn at the render rate.
func slapper_visible() -> bool:
	return _slapper_indicator_on and not _skater.is_ghost


func slapper_arrow_visible() -> bool:
	return _slapper_arrow_on and not _skater.is_ghost


func slapper_center() -> Vector2:
	var world: Vector3 = _skater.render_transform() * _slapper_offset_local
	return Vector2(world.x, world.z)


func slapper_zone_radius() -> float:
	return _slapper_zone_radius_cached


func slapper_ring_scale() -> float:
	return _slapper_current_ring_scale


func slapper_arrow_dir() -> Vector2:
	var local := Vector3(sin(_slapper_arrow_angle), 0.0, cos(_slapper_arrow_angle))
	var world: Vector3 = _skater.render_transform().basis * local
	return Vector2(world.x, world.z)


func set_slapper_indicator_ready(_is_ready: bool) -> void:
	pass


func update_slapper_indicator_window(_t: float) -> void:
	pass


func name_plate_visible() -> bool:
	return _name_label != null and _name_label.visible


# How many chevrons this skater shows (0-3) and where the first apex sits. The
# ice shader stacks the rest screen-up from it, so only the first is sent.
func chevron_stack() -> int:
	if not _ring_visible or _skater.is_ghost:
		return 0
	return clampi(_skater.elevation_level, 0, 3)


func chevron_apex() -> Vector2:
	var pos: Vector3 = _skater.render_transform().origin
	return Vector2(
			pos.x + _cached_chevron_dir.x * _CHEVRON_RADIUS,
			pos.z + _cached_chevron_dir.z * _CHEVRON_RADIUS)


# The camera's screen-down in world XZ. Cached here because this is where the
# camera-change check already lives; one value serves the whole rink.
func screen_down() -> Vector2:
	return _cached_screen_down


# Read by IceRingField each frame. Colour is the cached relation colour, so the
# 0.25 s recolour throttle still governs how often the relation is resolved.
func ring_visible() -> bool:
	return _ring_visible and _ring_relation_cached >= 0


func ring_color() -> Color:
	return _ring_color_cached


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
	_ring_visible = not ghost and not hud_hidden
	_name_label.visible = not ghost and not hud_hidden
	# The stamina ring is left alone: like the beacon, it stays useful while
	# ghosted (sprinting back to tag up), and its own show logic re-gates it.
	# The slapper indicator reads _skater.is_ghost directly (see slapper_visible),
	# so ghosting needs no latch of its own here.
	# set_ghost() writes _skater.is_ghost before calling here, so the gate sees
	# the up-to-date ghost state (beacon stays visible while ghosted).
	_update_beacon_visibility()


# ── Private: zone transform ───────────────────────────────────────────────────

func _store_slapper_zone(offset_x: float, offset_z: float, radius: float) -> void:
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	_slapper_offset_local = Vector3(blade_side_sign * offset_x, 0.0, offset_z)
	_slapper_zone_radius_cached = radius


# ── Private: mesh builders ────────────────────────────────────────────────────

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
