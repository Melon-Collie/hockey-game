class_name JerseyDecal
extends Node2D

# Draws the jersey base color, hem stripe, and player name/number into a
# SubViewport that the torso material samples as its albedo texture.
# Same render-to-texture pattern the rink uses for its center-ice
# MITTS/ARENA decals (see CenterIceDecals). Real TTF rendering via
# BigShouldersDisplay-Black — no more bitmap fonts.
#
# The torso's CylinderMesh wraps this 2D texture around its surface;
# text painted at x=BACK_CENTER_X lands on the +Z back of the skater
# (paired with the torso material's uv1_offset.x = 0.25).

const FONT: Font = preload("res://Assets/Fonts/BigShouldersDisplay-Black.ttf")
const IMG_W: int = 512
const IMG_H: int = 256
const BACK_CENTER_X: int = 128         # paired with uv1_offset.x = 0.25
# Godot's CylinderMesh allocates roughly the top half of the texture's V
# range to the side surface and the bottom half to the cap disks. Content
# drawn past this Y gets sampled by the flat top/bottom caps (visible from
# above on the gameplay camera) instead of the side, so keep visible
# elements inside [0, SIDE_V_MAX_PX).
const SIDE_V_MAX_PX: int = IMG_H / 2   # 128 — bottom of the side surface in image-y
const HEM_HEIGHT: int = 18
const HEM_Y_TOP: int = SIDE_V_MAX_PX - HEM_HEIGHT  # hem sits just inside the side range
const NAME_FONT_SIZE: int = 28
const NUMBER_FONT_SIZE: int = 56
const NAME_Y_TOP: int = 8              # visual top of the name (px from image top)
const NUMBER_Y_TOP: int = 40           # visual top of the number
const NAME_OUTLINE_PX: int = 3
const NUMBER_OUTLINE_PX: int = 5

var jersey_color: Color = Color.WHITE
var stripe_color: Color = Color.BLACK
var player_name: String = ""
var jersey_number: int = 0
var text_color: Color = Color.BLACK
var text_outline_color: Color = Color.BLACK


func _draw() -> void:
	draw_rect(Rect2(0, 0, IMG_W, IMG_H), jersey_color, true)
	draw_rect(Rect2(0, HEM_Y_TOP, IMG_W, HEM_HEIGHT), stripe_color, true)

	var name_upper: String = player_name.to_upper()
	if name_upper.length() > 0:
		_draw_centered(name_upper, NAME_FONT_SIZE, NAME_Y_TOP, NAME_OUTLINE_PX)
	var num_str: String = str(jersey_number)
	if num_str.length() > 0:
		_draw_centered(num_str, NUMBER_FONT_SIZE, NUMBER_Y_TOP, NUMBER_OUTLINE_PX)


# Draws a string centered horizontally at BACK_CENTER_X with its visual
# top at y_top. draw_string positions text by baseline, so we add the
# font's ascent to convert from "top edge" coords to baseline coords.
# Outline is drawn first so the fill sits on top of it.
func _draw_centered(s: String, font_size: int, y_top: int, outline_px: int) -> void:
	var width: float = FONT.get_string_size(
			s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var ascent: float = FONT.get_ascent(font_size)
	var x: float = float(BACK_CENTER_X) - width * 0.5
	var y_baseline: float = float(y_top) + ascent
	var pos := Vector2(x, y_baseline)
	if outline_px > 0:
		draw_string_outline(FONT, pos, s,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline_px, text_outline_color)
	draw_string(FONT, pos, s,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)


# Updates the cached uniform inputs and queues a redraw. Caller should
# also bump the parent SubViewport's render_target_update_mode to
# UPDATE_ONCE so the texture refreshes on the next frame.
func update_jersey(
		j_color: Color, s_color: Color,
		p_name: String, p_number: int, t_color: Color, t_outline: Color) -> void:
	jersey_color = j_color
	stripe_color = s_color
	player_name = p_name
	jersey_number = p_number
	text_color = t_color
	text_outline_color = t_outline
	queue_redraw()
