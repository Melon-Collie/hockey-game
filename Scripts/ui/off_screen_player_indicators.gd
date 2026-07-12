class_name OffScreenPlayerIndicators
extends Control

const _ARROW_BASE_SIZE: float = 36.0
const _ARROW_MIN_SCALE: float = 0.45
const _ARROW_MAX_SCALE: float = 1.0
const _NEAR_DISTANCE: float = 6.0
const _FAR_DISTANCE: float = 30.0
const _EDGE_MARGIN: float = 28.0
const _OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
# Puck indicator uses inverted colors (black fill, white outline) so it reads
# as visually distinct from the jersey-colored player arrows.
const _PUCK_FILL_COLOR: Color = Color(0.0, 0.0, 0.0, 0.95)
const _PUCK_OUTLINE_COLOR: Color = Color(1.0, 1.0, 1.0, 0.85)
const _OUTLINE_WIDTH: float = 2.0
const _NUMBER_FONT_SIZE: int = 18
const _NUMBER_MIN_FONT_SIZE: int = 12
const _NUMBER_OFFSET_FACTOR: float = 0.95

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	# Replay cuts to broadcast cameras with no "local player" frame of reference,
	# so the teammate arrows would point from a stale anchor through the wrong cam.
	if NetworkManager.is_replay_mode():
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var local_record: PlayerRecord = GameManager.get_local_player()
	if local_record == null or local_record.skater == null:
		return
	var rect_size: Vector2 = size
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		return
	var local_pos: Vector3 = local_record.skater.global_position
	var center: Vector2 = rect_size * 0.5
	var inner: Rect2 = Rect2(
		Vector2(_EDGE_MARGIN, _EDGE_MARGIN),
		rect_size - Vector2(_EDGE_MARGIN * 2.0, _EDGE_MARGIN * 2.0))
	var screen_rect: Rect2 = Rect2(Vector2.ZERO, rect_size)

	var players: Dictionary[int, PlayerRecord] = GameManager.get_players()
	for peer_id: int in players:
		var record: PlayerRecord = players[peer_id]
		if record == null or record.is_local or record.skater == null or record.team == null:
			continue
		var world_pos: Vector3 = record.skater.global_position
		var behind: bool = camera.is_position_behind(world_pos)
		var raw: Vector2 = camera.unproject_position(world_pos)
		if not behind and screen_rect.has_point(raw):
			continue
		var dir: Vector2
		if behind:
			# unproject_position returns the wrong-side point when behind the camera; mirror it.
			dir = (center - raw).normalized()
		else:
			dir = (raw - center).normalized()
		if dir == Vector2.ZERO or not (is_finite(dir.x) and is_finite(dir.y)):
			continue
		var edge_pos: Vector2 = _intersect_rect_from_center(center, dir, inner)
		var dist: float = local_pos.distance_to(world_pos)
		var t: float = clampf(inverse_lerp(_NEAR_DISTANCE, _FAR_DISTANCE, dist), 0.0, 1.0)
		var arrow_scale: float = lerpf(_ARROW_MAX_SCALE, _ARROW_MIN_SCALE, t)
		_draw_arrow(edge_pos, dir, arrow_scale, record.jersey_color)
		_draw_number(edge_pos, dir, arrow_scale, record.jersey_number, record.text_color, record.text_outline_color)

	# Puck indicator: black-filled, white-outlined arrow distinct from the
	# jersey-colored player arrows. Drawn after the players so it sits on top
	# in the (rare) case of overlap at a screen corner. Two cases share the
	# arrow style: puck off-screen (edge arrow pointing at it) and puck
	# on-screen but hidden behind the opaque board stack (arrow hovering over
	# the spot, pointing down at it — a rimming puck hugs the wall inside the
	# ~30 cm occlusion shadow the boards cast at the default camera tilt).
	var puck: Puck = GameManager.puck
	if puck != null:
		var puck_world_pos: Vector3 = puck.global_position
		var puck_behind: bool = camera.is_position_behind(puck_world_pos)
		var puck_raw: Vector2 = camera.unproject_position(puck_world_pos)
		var puck_dist: float = local_pos.distance_to(puck_world_pos)
		var puck_t: float = clampf(inverse_lerp(_NEAR_DISTANCE, _FAR_DISTANCE, puck_dist), 0.0, 1.0)
		var puck_scale: float = lerpf(_ARROW_MAX_SCALE, _ARROW_MIN_SCALE, puck_t)
		if puck_behind or not screen_rect.has_point(puck_raw):
			var puck_dir: Vector2
			if puck_behind:
				puck_dir = (center - puck_raw).normalized()
			else:
				puck_dir = (puck_raw - center).normalized()
			if puck_dir != Vector2.ZERO and is_finite(puck_dir.x) and is_finite(puck_dir.y):
				var puck_edge_pos: Vector2 = _intersect_rect_from_center(center, puck_dir, inner)
				_draw_arrow(puck_edge_pos, puck_dir, puck_scale, _PUCK_FILL_COLOR, _PUCK_OUTLINE_COLOR)
		elif _puck_hidden_by_boards(camera, puck_world_pos):
			var hover_pos: Vector2 = puck_raw - Vector2(0.0, _ARROW_BASE_SIZE * puck_scale)
			_draw_arrow(hover_pos, Vector2.DOWN, puck_scale, _PUCK_FILL_COLOR, _PUCK_OUTLINE_COLOR)

# True when the camera→puck sightline passes through the opaque board stack
# (kickplate + white board + cap rail — everything below GameRules.
# BOARD_TOP_HEIGHT; above that is transparent glass). Pure math against the
# same rounded-rect boundary the physics collide with, no raycast: the rink
# interior is convex, so the sightline can only enter a wall if the camera's
# ground (XZ) position is outside the boundary, and then the puck→camera
# segment crosses the boundary exactly once. Bisect that crossing and compare
# its height to the board top. An escaped puck (already outside the boundary
# itself — the whistle-pending case) crosses at t=0, so it reads hidden
# whenever it's below board-top height, which is exactly right.
func _puck_hidden_by_boards(camera: Camera3D, puck_pos: Vector3) -> bool:
	var cam_pos: Vector3 = camera.global_position
	var cam_xz := Vector2(cam_pos.x, cam_pos.z)
	if GameRules.clamp_to_rink_inner(cam_xz).distance_squared_to(cam_xz) < 1e-9:
		return false  # camera XZ inside the (convex) rink — sightline never crosses a wall
	var puck_xz := Vector2(puck_pos.x, puck_pos.z)
	# t = 0 at the puck, t = 1 at the camera.
	var t_cross: float = 0.0
	if GameRules.clamp_to_rink_inner(puck_xz).distance_squared_to(puck_xz) < 1e-9:
		var lo: float = 0.0  # inside end
		var hi: float = 1.0  # outside end
		for _i: int in range(20):
			var mid: float = (lo + hi) * 0.5
			var mid_xz: Vector2 = puck_xz.lerp(cam_xz, mid)
			if GameRules.clamp_to_rink_inner(mid_xz).distance_squared_to(mid_xz) < 1e-9:
				lo = mid
			else:
				hi = mid
		t_cross = hi
	var crossing_y: float = lerpf(puck_pos.y, cam_pos.y, t_cross)
	return crossing_y < GameRules.BOARD_TOP_HEIGHT


func _draw_arrow(pos: Vector2, dir: Vector2, arrow_scale: float, color: Color, outline_color: Color = _OUTLINE_COLOR) -> void:
	var sz: float = _ARROW_BASE_SIZE * arrow_scale
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var tip: Vector2 = pos + dir * (sz * 0.55)
	var base_left: Vector2 = pos - dir * (sz * 0.45) + perp * (sz * 0.40)
	var base_right: Vector2 = pos - dir * (sz * 0.45) - perp * (sz * 0.40)
	var fill: PackedVector2Array = PackedVector2Array([tip, base_left, base_right])
	var fill_colors: PackedColorArray = PackedColorArray([color, color, color])
	draw_polygon(fill, fill_colors)
	var outline: PackedVector2Array = PackedVector2Array([tip, base_left, base_right, tip])
	draw_polyline(outline, outline_color, _OUTLINE_WIDTH, true)

func _draw_number(pos: Vector2, dir: Vector2, arrow_scale: float, number: int, text_color: Color, outline_color: Color) -> void:
	var sz: float = _ARROW_BASE_SIZE * arrow_scale
	var font: Font = ThemeDB.fallback_font
	var font_size: int = maxi(_NUMBER_MIN_FONT_SIZE, int(_NUMBER_FONT_SIZE * arrow_scale))
	var text: String = str(number)
	var text_size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var ascent: float = font.get_ascent(font_size)
	var descent: float = font.get_descent(font_size)
	var center: Vector2 = pos - dir * (sz * _NUMBER_OFFSET_FACTOR)
	var baseline: Vector2 = Vector2(center.x - text_size.x * 0.5, center.y + (ascent - descent) * 0.5)
	draw_string_outline(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, int(_OUTLINE_WIDTH), outline_color)
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)

func _intersect_rect_from_center(c: Vector2, dir: Vector2, r: Rect2) -> Vector2:
	var t_x: float = INF
	var t_y: float = INF
	if dir.x > 0.0001:
		t_x = (r.position.x + r.size.x - c.x) / dir.x
	elif dir.x < -0.0001:
		t_x = (r.position.x - c.x) / dir.x
	if dir.y > 0.0001:
		t_y = (r.position.y + r.size.y - c.y) / dir.y
	elif dir.y < -0.0001:
		t_y = (r.position.y - c.y) / dir.y
	return c + dir * minf(t_x, t_y)
