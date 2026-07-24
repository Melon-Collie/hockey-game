class_name JerseyDecal
extends Node2D

# Draws the jersey base color, optional yoke (top band), procedural stripe
# array, and player name/number into a SubViewport that the torso material
# samples as its albedo texture. The torso's CylinderMesh wraps this 2D
# texture around its surface; text at x=BACK_CENTER_X lands on the +Z back
# of the skater (paired with the torso material's uv1_offset.x = 0.25).
#
# Stripes follow the v2 schema convention: each stripe has pos∈[0,1] (band
# center) and width∈[0,1] (band height as a fraction of the visible torso
# UV region). Stripes paint in array order; later overpaints earlier, so
# stacked stripes sharing pos with shrinking widths produce concentric
# centered bands.
#
# 'No outline' on text: if text_outline_color == text_color, skip the
# outline pass entirely (rather than drawing an outline of equal color,
# which looks identical but costs draw calls).

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")
const NAME_FONT: Font = preload("res://Assets/Fonts/Manrope-SemiBold.ttf")
const IMG_W: int = 512
const IMG_H: int = 256
const BACK_CENTER_X: int = 128         # paired with uv1_offset.x = 0.25
# Godot's CylinderMesh allocates roughly the top half of the texture's V
# range to the side surface; cap disks use the bottom half. All visible
# torso side content stays inside [0, SIDE_V_MAX_PX).
const SIDE_V_MAX_PX: int = IMG_H / 2   # 128 — bottom of the side surface
# Top-cap disk region after the torso material's uv1_offset.x = 0.25:
# the cap UV centers at (0.5, 0.75) with radius 0.25, so its bounding rect
# is U ∈ [0.25, 0.75] × V ∈ [0.5, 1.0] = pixels [128, 384] × [128, 256].
# Disjoint from the bottom cap (which wraps to x ∈ [384, 512] ∪ [0, 128]),
# so filling this rect paints only the top cap. Only the inscribed disk
# is actually sampled by the mesh; rect fill is just simpler than circle.
const TOP_CAP_RECT: Rect2 = Rect2(128, 128, 256, 128)
const NAME_FONT_SIZE: int = 28
const NUMBER_FONT_SIZE: int = 56
const NAME_Y_TOP: int = 8
const NUMBER_Y_TOP: int = 40
const NAME_OUTLINE_PX: int = 3
const NUMBER_OUTLINE_PX: int = 5

var jersey_color: Color = Color.WHITE
var yoke_color: Variant = null            # Color or null
var stripes: Array[Dictionary] = []       # [{pos, width, color}]
var player_name: String = ""
var jersey_number: int = 0
var text_color: Color = Color.BLACK
var text_outline_color: Color = Color.BLACK


func _draw() -> void:
	# Base fill across the whole texture so cap disks aren't transparent.
	draw_rect(Rect2(0, 0, IMG_W, IMG_H), jersey_color, true)
	# Optional yoke — paints the flat top disk of the torso cylinder by
	# overpainting the top-cap region of the texture.
	if yoke_color is Color:
		draw_rect(TOP_CAP_RECT, yoke_color, true)
	# Stripes paint in array order over the side region [0, SIDE_V_MAX_PX].
	for stripe: Dictionary in stripes:
		var band: Vector2i = _stripe_band(stripe, SIDE_V_MAX_PX)
		if band.y > band.x:
			draw_rect(Rect2(0, band.x, IMG_W, band.y - band.x), stripe.color, true)

	var name_upper: String = player_name.to_upper()
	if name_upper.length() > 0:
		_draw_centered(NAME_FONT, name_upper, NAME_FONT_SIZE, NAME_Y_TOP, NAME_OUTLINE_PX)
	var num_str: String = str(jersey_number)
	if num_str.length() > 0:
		_draw_centered(FONT, num_str, NUMBER_FONT_SIZE, NUMBER_Y_TOP, NUMBER_OUTLINE_PX)


# Converts a v2 stripe {pos, width} over a region of height region_px into
# [y_start, y_end] pixel coords, clamped to the region. width is the band's
# total height as a fraction of the region; pos is the center.
static func _stripe_band(stripe: Dictionary, region_px: int) -> Vector2i:
	var center: float = float(stripe.pos) * float(region_px)
	var half: float   = float(stripe.width) * float(region_px) * 0.5
	var y0: int = clampi(int(round(center - half)), 0, region_px)
	var y1: int = clampi(int(round(center + half)), 0, region_px)
	return Vector2i(y0, y1)


# Outline is drawn first so the fill sits on top of it. Outline pass is
# skipped when outline_color matches text_color (the "no outline" sentinel).
func _draw_centered(font: Font, s: String, font_size: int, y_top: int, outline_px: int) -> void:
	var width: float = font.get_string_size(
			s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var ascent: float = font.get_ascent(font_size)
	var x: float = float(BACK_CENTER_X) - width * 0.5
	var y_baseline: float = float(y_top) + ascent
	var pos := Vector2(x, y_baseline)
	if outline_px > 0 and not text_outline_color.is_equal_approx(text_color):
		draw_string_outline(font, pos, s,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline_px, text_outline_color)
	draw_string(font, pos, s,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)


func update_jersey(
		j_color: Color, j_yoke: Variant, j_stripes: Array[Dictionary],
		p_name: String, p_number: int, t_color: Color, t_outline: Color) -> void:
	jersey_color = j_color
	yoke_color = j_yoke
	stripes = j_stripes
	player_name = p_name
	jersey_number = p_number
	text_color = t_color
	text_outline_color = t_outline
	queue_redraw()
