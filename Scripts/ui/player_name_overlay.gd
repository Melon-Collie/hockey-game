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
# FIXED size, deliberately not scaled by camera distance. The Label3D grew and
# shrank with zoom because pixel_size made it world-sized, and reproducing that
# in 2D looked worse than the original did: font sizes are integers, so a
# continuously changing scale steps between them and the text visibly jitters as
# the camera breathes. A name plate is HUD, not scenery — it should read the same
# whatever the camera is doing, which is also what the sibling 2D overlay
# (OffScreenPlayerIndicators) already does with its jersey numbers.
const _FONT_SIZE: int = 16

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
		var width: float = _font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _FONT_SIZE).x
		draw_string(_font, origin - Vector2(width * 0.5, 0.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, _FONT_SIZE, color)
