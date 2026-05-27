class_name ShoulderDecal
extends Node2D

# Draws a small jersey-base + player number that the shoulder spheres
# sample as their material albedo. Same render-to-texture pattern as
# JerseyDecal — one viewport shared by both shoulders, per skater.
# The number sits at the equator of the texture (V≈0.5) so it lands on
# the equator of the sphere; the coordinator's per-shoulder uv1_offset
# rotates the wrap so the number faces outward on each side.

const FONT: Font = preload("res://Assets/Fonts/BigShouldersDisplay-Black.ttf")
const IMG_W: int = 256
const IMG_H: int = 256
const NUMBER_FONT_SIZE: int = 56
const NUMBER_OUTLINE_PX: int = 5

var jersey_color: Color = Color.WHITE
var jersey_number: int = 0
var text_color: Color = Color.BLACK
var text_outline_color: Color = Color.BLACK


func _draw() -> void:
	draw_rect(Rect2(0, 0, IMG_W, IMG_H), jersey_color, true)
	var num_str: String = str(jersey_number)
	if num_str.length() == 0:
		return
	var size: Vector2 = FONT.get_string_size(
			num_str, HORIZONTAL_ALIGNMENT_LEFT, -1, NUMBER_FONT_SIZE)
	var ascent: float = FONT.get_ascent(NUMBER_FONT_SIZE)
	# Center the text bounding box on (IMG_W/2, IMG_H/2); convert top-edge
	# Y to baseline Y by adding ascent.
	var x: float = (float(IMG_W) - size.x) * 0.5
	var y_baseline: float = (float(IMG_H) - size.y) * 0.5 + ascent
	var pos := Vector2(x, y_baseline)
	draw_string_outline(FONT, pos, num_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, NUMBER_FONT_SIZE, NUMBER_OUTLINE_PX, text_outline_color)
	draw_string(FONT, pos, num_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, NUMBER_FONT_SIZE, text_color)


func update_shoulder(j_color: Color, p_number: int, t_color: Color, t_outline: Color) -> void:
	jersey_color = j_color
	jersey_number = p_number
	text_color = t_color
	text_outline_color = t_outline
	queue_redraw()
