class_name IceScratchMap
extends Node3D

# Persistent skate-mark accumulator. A SubViewport with CLEAR_MODE_NEVER acts
# as a paint canvas — each frame we draw the blade footprints for every active
# skater on top of whatever was painted before, so the texture grows scratchier
# over time. The ice shader samples this texture as a surface overlay.
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
# Radius of each blade footprint in world meters.
@export var blade_radius_m: float = 0.04
# Alpha per blade pass. Compounds across frames as the blade sweeps a pixel;
# ~0.35 saturates a pixel after ~5 passes (one skate-by).
@export var blade_intensity: float = 0.35

var _viewport: SubViewport
var _painter: Node2D
var _pending_paints: PackedVector2Array = PackedVector2Array()
var _prev_positions: Dictionary = {}  # Skater -> Vector3

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
	_pending_paints.clear()

func _process(_delta: float) -> void:
	var skaters: Array = get_tree().get_nodes_in_group("skaters")
	var px_x: float = float(_viewport.size.x) / rink_width
	var px_z: float = float(_viewport.size.y) / rink_length
	var half_w: float = rink_width * 0.5
	var half_l: float = rink_length * 0.5

	# Drop entries for skaters that left the tree.
	for tracked: Object in _prev_positions.keys():
		if not is_instance_valid(tracked):
			_prev_positions.erase(tracked)

	for node: Node in skaters:
		var skater: Skater = node as Skater
		if skater == null:
			continue
		var pos: Vector3 = skater.global_position
		var had_prev: bool = _prev_positions.has(skater)
		var prev: Vector3 = _prev_positions.get(skater, pos)
		_prev_positions[skater] = pos
		if skater.is_ghost:
			continue
		# Teleport guard: reconcile snaps and faceoff resets must not draw a
		# streak between old and new positions. Same threshold as SkaterVFX.
		if had_prev and (pos - prev).length() > TELEPORT_THRESHOLD:
			continue
		var flat_vel: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
		if flat_vel.length() < TRAIL_MIN_SPEED:
			continue
		var right: Vector3 = skater.global_transform.basis.x
		for side_x: float in [-BLADE_X_OFFSET, BLADE_X_OFFSET]:
			var bp: Vector3 = pos + right * side_x
			# World (x, z) -> viewport pixel. +Z world maps to top of image,
			# matching the convention HockeyRink._add_ice uses when painting
			# rink lines into the albedo texture.
			var px: float = (bp.x + half_w) * px_x
			var py: float = (half_l - bp.z) * px_z
			_pending_paints.push_back(Vector2(px, py))

	if _pending_paints.size() > 0:
		_painter.queue_redraw()

func _on_painter_draw() -> void:
	var radius_px: float = blade_radius_m * (float(_viewport.size.x) / rink_width)
	var col: Color = Color(1.0, 1.0, 1.0, blade_intensity)
	for p: Vector2 in _pending_paints:
		_painter.draw_circle(p, radius_px, col)
	_pending_paints.clear()
