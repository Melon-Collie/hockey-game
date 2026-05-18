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
const TELEPORT_THRESHOLD: float = 1.0
const BLADE_X_OFFSET: float = 0.12

@export var rink_width: float = 26.0
@export var rink_length: float = 60.0
# Texture pixels per meter of rink. 40 → 1040×2400 (~2.4 MP, ~10 MB at RGBA8).
# Bigger = crisper scratches at close range; smaller = cheaper memory & fill.
@export var px_per_meter: float = 40.0
# Stroke width in world meters. ~3 cm matches a real skate blade footprint.
@export var blade_width_m: float = 0.03
# Alpha per blade pass. Low value so the same pixel can be re-scratched many
# times before saturating — at 0.12 it takes ~30 overlapping passes to reach
# near-full white, vs ~5 at 0.35.
@export var blade_intensity: float = 0.18

var _viewport: SubViewport
var _painter: Node2D
# Pending line segments flattened as [from0, to0, from1, to1, ...].
var _pending_segments: PackedVector2Array = PackedVector2Array()
# Per-skater previous state: [center_world: Vector3, left_blade_px: Vector2,
# right_blade_px: Vector2]. Used to draw a continuous stroke between frames.
var _prev_state: Dictionary = {}

func _ready() -> void:
	_viewport = SubViewport.new()
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

func get_texture() -> ViewportTexture:
	return _viewport.get_texture()

func clear() -> void:
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_pending_segments.clear()
	_prev_state.clear()

func _process(_delta: float) -> void:
	var skaters: Array = get_tree().get_nodes_in_group("skaters")
	var px_x: float = float(_viewport.size.x) / rink_width
	var px_z: float = float(_viewport.size.y) / rink_length
	var half_w: float = rink_width * 0.5
	var half_l: float = rink_length * 0.5

	# Drop entries for skaters that left the tree.
	for tracked: Object in _prev_state.keys():
		if not is_instance_valid(tracked):
			_prev_state.erase(tracked)

	for node: Node in skaters:
		var skater: Skater = node as Skater
		if skater == null:
			continue
		var pos: Vector3 = skater.global_position
		var right: Vector3 = skater.global_transform.basis.x
		var left_world: Vector3 = pos + right * (-BLADE_X_OFFSET)
		var right_world: Vector3 = pos + right * BLADE_X_OFFSET
		# World (x, z) -> viewport pixel. +Z maps to small image-Y so it
		# matches the convention HockeyRink._add_ice uses for line drawing.
		var left_px: Vector2 = Vector2(
			(left_world.x + half_w) * px_x,
			(half_l - left_world.z) * px_z
		)
		var right_px: Vector2 = Vector2(
			(right_world.x + half_w) * px_x,
			(half_l - right_world.z) * px_z
		)

		var prev: Variant = _prev_state.get(skater, null)
		# Always update prev state so next frame has a baseline, even if we
		# skip painting this frame (ghost / teleport / too-slow).
		_prev_state[skater] = [pos, left_px, right_px]

		if skater.is_ghost or prev == null:
			continue
		var prev_pos: Vector3 = prev[0]
		if (pos - prev_pos).length() > TELEPORT_THRESHOLD:
			continue
		var flat_vel: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
		if flat_vel.length() < TRAIL_MIN_SPEED:
			continue
		var prev_left: Vector2 = prev[1]
		var prev_right: Vector2 = prev[2]
		_pending_segments.push_back(prev_left)
		_pending_segments.push_back(left_px)
		_pending_segments.push_back(prev_right)
		_pending_segments.push_back(right_px)

	# Always queue a redraw — with CLEAR_MODE_NEVER, the SubViewport re-executes
	# each canvas item's cached command list every frame, which would re-apply
	# the previous frame's strokes onto the accumulated framebuffer and saturate
	# pixels almost immediately. Forcing a redraw replaces the cached list (with
	# an empty one when there are no pending segments), so old strokes don't
	# re-stamp themselves.
	_painter.queue_redraw()

func _on_painter_draw() -> void:
	var width_px: float = blade_width_m * (float(_viewport.size.x) / rink_width)
	var col: Color = Color(1.0, 1.0, 1.0, blade_intensity)
	var i: int = 0
	while i < _pending_segments.size():
		_painter.draw_line(_pending_segments[i], _pending_segments[i + 1],
							col, width_px, true)
		i += 2
	_pending_segments.clear()
