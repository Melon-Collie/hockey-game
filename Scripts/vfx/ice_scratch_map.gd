class_name IceScratchMap
extends Node3D

# Persistent skate-mark accumulator. A SubViewport with CLEAR_MODE_NEVER acts
# as a paint canvas — each frame we draw a line segment from each blade's
# previous pixel position to its current one, so the marks form continuous
# scratches rather than discrete blobs. The ice shader samples this texture
# as a surface overlay.
#
# Wiped at the start of each period via clear(), which flips the viewport's
# clear mode back to ONCE (clears once, then reverts to NEVER on its own).

# Match SkaterVFX gating constants so visual trails and persistent scratches
# react to the same situations.
const TRAIL_MIN_SPEED: float = 0.5
# A blade this far above the lower of the two boots is airborne (the recovery
# swing, the crossover clearance step) and leaves no mark. Relative to the
# other boot rather than an absolute ice height, so crouch depth and body drop
# never bias the read.
const LIFT_EPS_M: float = 0.03
# Fraction of blade_intensity a zero-load (gliding) blade still paints — a
# glide whispers, a loaded edge (push, under-push, scrape) bites to full.
const GLIDE_ALPHA_FRAC: float = 0.35

@export var rink_width: float = 26.0
@export var rink_length: float = 60.0
# Texture pixels per meter of rink. 60 → 1560×3600 (~5.6 MP, ~22 MB at RGBA8).
# Bigger = crisper scratches at close range; smaller = cheaper memory & fill.
@export var px_per_meter: float = 60.0
# Stroke width in world meters. ~2 cm matches a thin skate-blade scratch.
# At 60 px/m this renders as ~1.2 px wide with antialiasing.
@export var blade_width_m: float = 0.02
# Alpha per blade pass. Low value so the same pixel can be re-scratched many
# times before saturating — at 0.10 it takes ~30 overlapping passes to reach
# near-full white, so a single skate-by leaves a subtle trail and only
# repeatedly-traveled paths build into visible scratches.
@export var blade_intensity: float = 0.10

var _viewport: SubViewport
var _painter: Node2D
# Eraser canvas item, drawn after the painter with a multiply blend: a black
# stroke drives the accumulated framebuffer's RGB to zero, and the ice shader
# reads only scratch_tex.r — so the resurfacer's squeegee genuinely cleans.
var _eraser: Node2D
# Pending line segments flattened as [from0, to0, from1, to1, ...], with one
# alpha per segment alongside.
var _pending_segments: PackedVector2Array = PackedVector2Array()
var _pending_alpha: PackedFloat32Array = PackedFloat32Array()
# Pending wipe strokes, same flattened layout, with one width (px) per segment.
var _pending_wipes: PackedVector2Array = PackedVector2Array()
var _pending_wipe_widths: PackedFloat32Array = PackedFloat32Array()
# Per-skater previous state: value is [center_world: Vector3, left_blade_px:
# Vector2, right_blade_px: Vector2], used to draw a continuous stroke between
# frames. Keyed by Skater.get_instance_id() rather than the Skater node — a
# typed Dictionary[Skater, Array] would reject erase() of a freed key when
# a skater (e.g. a tutorial puppet bot) gets queue_freed before the per-tick
# cleanup drops its stale entry. Plain int keys sidestep the validator.
var _prev_state: Dictionary[int, Array] = {}
# Reusable scratch for stale-key sweep — cleared (capacity kept) each frame so
# the per-frame cleanup allocates nothing in steady state (see _process).
var _stale_ids: Array[int] = []
# Live Skater list, refreshed only when the roster moves (see _live_skaters).
var _skaters_cache: Array = []

func _init() -> void:
	# Instantiate the SubViewport up front so get_texture() is safe to call
	# immediately after IceScratchMap.new() / add_child() — _ready() doesn't
	# run synchronously inside add_child() at runtime, which would otherwise
	# null-deref when HockeyRink rebuilds the ice on a shader-param change.
	_viewport = SubViewport.new()

func _ready() -> void:
	_viewport.size = Vector2i(
		maxi(int(rink_width * px_per_meter), 1),
		maxi(int(rink_length * px_per_meter), 1)
	)
	_viewport.transparent_bg = true  # clears to (0,0,0,0) = no scratch
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.disable_3d = true
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	add_child(_viewport)

	_painter = Node2D.new()
	_painter.draw.connect(_on_painter_draw)
	_viewport.add_child(_painter)

	# Sibling after the painter so a same-frame wipe wins over a stroke drawn
	# under the machine; the stroke simply repaints next frame.
	_eraser = Node2D.new()
	var eraser_mat := CanvasItemMaterial.new()
	eraser_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	_eraser.material = eraser_mat
	_eraser.draw.connect(_on_eraser_draw)
	_viewport.add_child(_eraser)

func get_texture() -> ViewportTexture:
	return _viewport.get_texture()

func clear() -> void:
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_pending_segments.clear()
	_pending_alpha.clear()
	_pending_wipes.clear()
	_pending_wipe_widths.clear()
	_prev_state.clear()


# Queue an eraser stroke (world-space endpoints, width in meters) — the
# resurfacer's squeegee. Dropped while the map is disabled: the viewport
# isn't repainting, so pendings would only pile up.
func queue_wipe_segment(from_world: Vector3, to_world: Vector3, width_m: float) -> void:
	if _viewport == null \
			or _viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED:
		return
	var px_x: float = float(_viewport.size.x) / rink_width
	var px_z: float = float(_viewport.size.y) / rink_length
	var half_w: float = rink_width * 0.5
	var half_l: float = rink_length * 0.5
	_pending_wipes.push_back(Vector2(
			(from_world.x + half_w) * px_x, (from_world.z + half_l) * px_z))
	_pending_wipes.push_back(Vector2(
			(to_world.x + half_w) * px_x, (to_world.z + half_l) * px_z))
	_pending_wipe_widths.push_back(width_m * px_x)

# Toggled from PlayerPrefs.apply_video(). When disabled, the viewport stops
# repainting and existing scratches are wiped so the ice shader samples an
# empty overlay.
func set_enabled(enabled: bool) -> void:
	if _viewport == null:
		return
	if enabled:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		process_mode = Node.PROCESS_MODE_INHERIT
	else:
		clear()
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		process_mode = Node.PROCESS_MODE_DISABLED

func _process(_delta: float) -> void:
	# Freeze accumulation during goal replays. The cinematic rewinds skater
	# state, and painting their replayed motion onto the live texture would
	# leave fake marks behind once the replay ends. Clearing _prev_state
	# also ensures the first post-replay frame doesn't draw a streak from
	# a pre-replay position to wherever the skater resumes.
	if NetworkManager.is_replay_mode():
		_pending_segments.clear()
		_pending_alpha.clear()
		_pending_wipes.clear()
		_pending_wipe_widths.clear()
		_prev_state.clear()
		_painter.queue_redraw()
		_eraser.queue_redraw()
		return

	var skaters: Array = _live_skaters()
	var px_x: float = float(_viewport.size.x) / rink_width
	var px_z: float = float(_viewport.size.y) / rink_length
	var half_w: float = rink_width * 0.5
	var half_l: float = rink_length * 0.5

	# Drop entries for skaters that left the tree. instance_from_id returns null
	# once the object is gone and is_instance_valid filters that. Iterate the dict
	# directly (no per-frame .keys() Array alloc) and defer erase() to a reusable
	# scratch — mutating a Dictionary mid-iteration is unsafe.
	_stale_ids.clear()
	for id: int in _prev_state:
		var tracked: Skater = instance_from_id(id) as Skater
		if not is_instance_valid(tracked):
			_stale_ids.push_back(id)
	for id: int in _stale_ids:
		_prev_state.erase(id)

	for node: Node in skaters:
		var skater: Skater = node as Skater
		if skater == null:
			continue
		# Marks follow the SKATES, not the torso: the FOOT bones compose
		# everything the gait wrote (stride pitch, hip yaw through crossovers /
		# stops / pivots, the mohawk V), so crossovers scratch crossing arcs
		# and C-cuts scratch lobes instead of two parallel rails under the
		# body. blade_mark_position reads the skeleton's INTERPOLATED transform,
		# so a stroke lands under the skate as drawn rather than up to a tick of
		# travel ahead of it.
		#
		# `pos` stays the raw sim position on purpose: it only feeds the teleport
		# guard below, which wants to compare tick states, not rendered ones.
		var pos: Vector3 = skater.global_position
		var left_world: Vector3 = skater.blade_mark_position(true)
		var right_world: Vector3 = skater.blade_mark_position(false)
		# World (x, z) -> viewport pixel. Godot's PlaneMesh places UV (0,0) at
		# world (-size.x/2, -size.y/2), so UV.y — and therefore pixel-Y when this
		# texture is sampled — increases with world Z. HockeyRink's baked lines
		# are Z-symmetric and so can't reveal a flipped axis; skate marks can.
		var left_px: Vector2 = Vector2(
			(left_world.x + half_w) * px_x,
			(left_world.z + half_l) * px_z
		)
		var right_px: Vector2 = Vector2(
			(right_world.x + half_w) * px_x,
			(right_world.z + half_l) * px_z
		)

		var id: int = skater.get_instance_id()
		var had_prev: bool = _prev_state.has(id)
		var entry: Array = _prev_state[id] if had_prev else []
		# Capture the previous baseline before overwriting it. Always update the
		# baseline so next frame has one, even if we skip painting this frame
		# (ghost / teleport / too-slow).
		var prev_pos: Vector3
		var prev_left: Vector2
		var prev_right: Vector2
		if had_prev:
			prev_pos = entry[0]
			prev_left = entry[1]
			prev_right = entry[2]
			# Reuse the existing 3-slot Array in place — Vector2/Vector3 are
			# inline value-type Variants, so this allocates nothing. A fresh
			# [pos, left_px, right_px] literal per skater per frame would be the
			# dominant heap churn in this file.
			entry[0] = pos
			entry[1] = left_px
			entry[2] = right_px
		else:
			entry = [pos, left_px, right_px]
			_prev_state[id] = entry

		if skater.is_ghost or not had_prev:
			continue
		if (pos - prev_pos).length() > IceVFX.TELEPORT_THRESHOLD:
			continue
		var flat_vel: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
		if flat_vel.length() < TRAIL_MIN_SPEED:
			continue
		# Per blade: an airborne skate (recovery swing, clearance step) leaves
		# no mark, and a grounded one paints at an alpha scaled by its edge
		# load — the stride reads as alternating bitten push strokes with gaps,
		# not two continuous rails.
		var base_y: float = minf(left_world.y, right_world.y)
		if left_world.y - base_y < LIFT_EPS_M:
			_pending_segments.push_back(prev_left)
			_pending_segments.push_back(left_px)
			_pending_alpha.push_back(blade_intensity * (GLIDE_ALPHA_FRAC
					+ (1.0 - GLIDE_ALPHA_FRAC) * skater.edge_load(true)))
		if right_world.y - base_y < LIFT_EPS_M:
			_pending_segments.push_back(prev_right)
			_pending_segments.push_back(right_px)
			_pending_alpha.push_back(blade_intensity * (GLIDE_ALPHA_FRAC
					+ (1.0 - GLIDE_ALPHA_FRAC) * skater.edge_load(false)))

	# Always queue a redraw — with CLEAR_MODE_NEVER, the SubViewport re-executes
	# each canvas item's cached command list every frame, which would re-apply
	# the previous frame's strokes onto the accumulated framebuffer and saturate
	# pixels almost immediately. Forcing a redraw replaces the cached list (with
	# an empty one when there are no pending segments), so old strokes don't
	# re-stamp themselves. The eraser needs the same treatment or a stale wipe
	# would re-erase its lane every frame and new scratches there could never
	# accumulate.
	_painter.queue_redraw()
	_eraser.queue_redraw()

func _on_painter_draw() -> void:
	var width_px: float = blade_width_m * (float(_viewport.size.x) / rink_width)
	var i: int = 0
	var seg: int = 0
	while i < _pending_segments.size():
		_painter.draw_line(_pending_segments[i], _pending_segments[i + 1],
							Color(1.0, 1.0, 1.0, _pending_alpha[seg]), width_px, true)
		i += 2
		seg += 1
	_pending_segments.clear()
	_pending_alpha.clear()


# Multiply-blend black: RGB × 0 = clean ice. Hard-edged (no AA) — a fresh
# resurfacer lane has a crisp boundary anyway — with round end caps so
# successive segments join seamlessly through the U-turn.
func _on_eraser_draw() -> void:
	const BLACK := Color(0.0, 0.0, 0.0, 1.0)
	var i: int = 0
	var seg: int = 0
	while i < _pending_wipes.size():
		var w: float = _pending_wipe_widths[seg]
		_eraser.draw_line(_pending_wipes[i], _pending_wipes[i + 1], BLACK, w, false)
		_eraser.draw_circle(_pending_wipes[i], w * 0.5, BLACK)
		_eraser.draw_circle(_pending_wipes[i + 1], w * 0.5, BLACK)
		i += 2
		seg += 1
	_pending_wipes.clear()
	_pending_wipe_widths.clear()


# The live Skater list, rebuilt only when the roster actually changes —
# get_nodes_in_group() allocates a fresh Array on every call.
#
# Deliberately the GROUP and not PlayerRegistry.skaters(): the standalone replay
# viewer spawns its skaters straight through ActorSpawner, outside the registry,
# and (unlike the goal-replay cinematic) never sets replay mode — so a
# registry-backed list would leave replay playback with no ice scratches.
# Equal counts can still hide a same-frame despawn+spawn, which shows up as a
# freed entry, so the cache is validated as well as counted.
func _live_skaters() -> Array:
	var tree: SceneTree = get_tree()
	if tree.get_node_count_in_group("skaters") != _skaters_cache.size():
		_skaters_cache = tree.get_nodes_in_group("skaters")
		return _skaters_cache
	for n: Node in _skaters_cache:
		if not is_instance_valid(n):
			_skaters_cache = tree.get_nodes_in_group("skaters")
			break
	return _skaters_cache
