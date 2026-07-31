class_name PlayerNameOverlay
extends Control

# Every skater's name plate, drawn by ONE CanvasItem.
#
# Each was a billboarded Label3D parented to its skater: ten nodes at 5v5, ten
# draws in the 3D transparent pass, and ten world transforms rewritten every
# frame to place a plate that only ever needed a screen position. Projecting the
# same anchor and drawing the text here collapses all of it into one node and one
# canvas item — the same move the minimap's dynamic layer makes, and the same one
# OffScreenPlayerIndicators already used for its arrows.
#
# BEHAVIOUR CHANGE, deliberate and worth knowing: the Label3D had
# no_depth_test = false, so a plate could be occluded by a body standing in front
# of it. A 2D pass has no depth to test against, so plates now always draw on
# top. For a nameplate that is the conventional choice — the label exists to be
# read — but it is a change, not a port.
#
# Size still tracks camera distance rather than being fixed: the anchor and a
# point one text-height above it are both projected, and the pixel gap between
# them IS the font size. That reproduces what pixel_size gave the Label3D, so
# names grow and shrink with zoom exactly as before.

# World height of the text, matching the Label3D it replaces: font_size 40 at
# pixel_size 0.005.
const _TEXT_WORLD_HEIGHT: float = 0.20
# Below this the plate is unreadable anyway, and tiny text at distance reads as
# noise around the rink.
const _MIN_FONT_PX: float = 7.0
const _MAX_FONT_PX: float = 64.0

var _font: Font = MenuStyle.UI_FONT


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	# Replays cut to broadcast cameras and the per-skater HUD hides itself for
	# the cinematic; the same bail as the minimap and the off-screen arrows.
	if NetworkManager.is_replay_mode():
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var up: Vector3 = camera.global_transform.basis.y * _TEXT_WORLD_HEIGHT
	var color: Color = Color(MenuStyle.HUD_ICE.r, MenuStyle.HUD_ICE.g,
			MenuStyle.HUD_ICE.b, MenuStyle.HUD_OPACITY)
	for node: Node in get_tree().get_nodes_in_group("skaters"):
		var skater: Skater = node as Skater
		if skater == null or not skater.name_plate_visible():
			continue
		var text: String = skater.name_plate_text()
		if text.is_empty():
			continue
		var anchor: Vector3 = skater.name_plate_anchor()
		# unproject_position returns a mirrored point for anything behind the
		# camera, which would scatter plates across the screen.
		if camera.is_position_behind(anchor):
			continue
		var origin: Vector2 = camera.unproject_position(anchor)
		# The projected height of a fixed world height IS the perspective scale,
		# so this needs no distance maths of its own.
		var font_px: float = absf(camera.unproject_position(anchor + up).y - origin.y)
		if font_px < _MIN_FONT_PX:
			continue
		font_px = minf(font_px, _MAX_FONT_PX)
		var size: int = int(font_px)
		var width: float = _font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x
		draw_string(_font, origin - Vector2(width * 0.5, 0.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, color)
