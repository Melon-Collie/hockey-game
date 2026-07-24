class_name GoalieTextDecal
extends Node2D

# Renders name and number on a fully transparent background. Consumed by the
# goalie_jersey.gdshader as the `text_decal` sampler, which projects this
# texture onto the front and back Z faces of the body BoxMesh.
#
# Viewport size (IMG_W x IMG_H = 256 x 320) is aspect-matched to the body
# face (0.48 m wide x 0.60 m tall = 4:5), so pixels are nearly square and
# text is undistorted after projection.
#
# Text is horizontally centred at x = IMG_W / 2 = 128. Vertical positions
# target the upper-chest region (face_v ≈ 0.14–0.60) — the enlarged number
# reads clearly on the goalie's back in post-goal replays.

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")
const IMG_W: int = 256
const IMG_H: int = 320
const CENTER_X: int = IMG_W / 2

const NAME_FONT_SIZE: int = 40
const NUMBER_FONT_SIZE: int = 100
const NAME_Y_TOP: int = 44
const NUMBER_Y_TOP: int = 92
const NAME_OUTLINE_PX: int = 5
const NUMBER_OUTLINE_PX: int = 9

var player_name: String = ""
var jersey_number: int = 0
var text_color: Color = Color.WHITE
var text_outline_color: Color = Color.BLACK


func _draw() -> void:
	# Transparent background — only the glyphs are opaque.
	var name_upper: String = player_name.to_upper()
	if name_upper.length() > 0:
		_draw_centred(name_upper, NAME_FONT_SIZE, NAME_Y_TOP, NAME_OUTLINE_PX)
	if jersey_number > 0:
		_draw_centred(str(jersey_number), NUMBER_FONT_SIZE, NUMBER_Y_TOP, NUMBER_OUTLINE_PX)


func update_text(p_name: String, number: int, t_color: Color, t_outline: Color) -> void:
	player_name = p_name
	jersey_number = number
	text_color = t_color
	text_outline_color = t_outline
	queue_redraw()


func _draw_centred(s: String, font_size: int, y_top: int, outline_px: int) -> void:
	var width: float = FONT.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var ascent: float = FONT.get_ascent(font_size)
	var pos := Vector2(float(CENTER_X) - width * 0.5, float(y_top) + ascent)
	if outline_px > 0 and not text_outline_color.is_equal_approx(text_color):
		draw_string_outline(FONT, pos, s,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline_px, text_outline_color)
	draw_string(FONT, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
