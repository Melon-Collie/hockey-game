class_name ShoulderDecal
extends Node2D

# Draws the shoulder-cap base color + player number into a small viewport
# that the shoulder spheres sample as their material albedo. Same
# render-to-texture pattern as JerseyDecal — one viewport shared by both
# shoulders, per skater. The number sits at the texture equator (V≈0.5)
# so it lands on the sphere's equator; the coordinator's per-shoulder
# uv1_offset rotates the wrap so the number faces outward on each side.
#
# Shoulders carry their own color + text + outline (v2 shoulders block);
# they are not borrowed from the jersey. 'No outline' = outline equal to
# text color → skip the outline pass.

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")
const IMG_W: int = 256
const IMG_H: int = 256
const NUMBER_FONT_SIZE: int = 56
const NUMBER_OUTLINE_PX: int = 5

var shoulder_color: Color = Color.WHITE
var jersey_number: int = 0
var text_color: Color = Color.BLACK
var text_outline_color: Color = Color.BLACK


func _draw() -> void:
	draw_rect(Rect2(0, 0, IMG_W, IMG_H), shoulder_color, true)
	var num_str: String = str(jersey_number)
	if num_str.length() == 0:
		return
	var size: Vector2 = FONT.get_string_size(
			num_str, HORIZONTAL_ALIGNMENT_LEFT, -1, NUMBER_FONT_SIZE)
	var ascent: float = FONT.get_ascent(NUMBER_FONT_SIZE)
	var x: float = (float(IMG_W) - size.x) * 0.5
	var y_baseline: float = (float(IMG_H) - size.y) * 0.5 + ascent
	var pos := Vector2(x, y_baseline)
	if not text_outline_color.is_equal_approx(text_color):
		draw_string_outline(FONT, pos, num_str,
				HORIZONTAL_ALIGNMENT_LEFT, -1, NUMBER_FONT_SIZE, NUMBER_OUTLINE_PX, text_outline_color)
	draw_string(FONT, pos, num_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, NUMBER_FONT_SIZE, text_color)


func update_shoulder(s_color: Color, p_number: int, t_color: Color, t_outline: Color) -> void:
	shoulder_color = s_color
	jersey_number = p_number
	text_color = t_color
	text_outline_color = t_outline
	queue_redraw()
