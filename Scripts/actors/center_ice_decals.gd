class_name CenterIceDecals
extends Node2D

# Draws the Mitts skater logo and "MITTS" / "ARENA" curved text into a
# SubViewport that the ice shader samples as a decal overlay. Lives at the
# same parallax depth as the painted rink lines — so it reads as paint on
# the concrete under the ice, with the same Beer-Lambert fade.

const LOGO_TEX: Texture2D = preload("res://Assets/logos/Mitts_logo_skater.png")
const FONT: Font = preload("res://Assets/Fonts/BigShouldersDisplay-Black.ttf")
const TEXT_TOP: String = "MITTS"
const TEXT_BOTTOM: String = "ARENA"

# Center-ice faceoff circle radius is 4.572 m (15 ft). The logo sits inside
# the dot area; the text rides just inside the circle's outline.
const FACEOFF_CIRCLE_RADIUS_M: float = 4.572
const LOGO_DIAMETER_M: float = 3.0
const TEXT_RADIUS_FRACTION: float = 0.84
const TEXT_HEIGHT_M: float = 0.8
const TEXT_SPACING_FRACTION: float = 0.12

var img_size: Vector2 = Vector2.ZERO
var px_per_meter: float = 80.0
var text_color: Color = Color(0.0, 0.220, 0.659)

func _draw() -> void:
	var center: Vector2 = img_size * 0.5

	var logo_px: float = LOGO_DIAMETER_M * px_per_meter
	var logo_rect: Rect2 = Rect2(center - Vector2(logo_px, logo_px) * 0.5,
								  Vector2(logo_px, logo_px))
	draw_texture_rect(LOGO_TEX, logo_rect, false, text_color)

	var text_radius: float = FACEOFF_CIRCLE_RADIUS_M * px_per_meter * TEXT_RADIUS_FRACTION
	var font_size: int = int(TEXT_HEIGHT_M * px_per_meter)

	# Top arch: feet toward center, reads L→R from the broadcast side.
	_draw_arched_text(TEXT_TOP, center, text_radius, -PI * 0.5, font_size, true)
	# Bottom arch: feet still toward center (so it reads from the same side).
	_draw_arched_text(TEXT_BOTTOM, center, text_radius, PI * 0.5, font_size, false)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_arched_text(text: String, center: Vector2, radius: float,
					   base_angle: float, font_size: int, is_top: bool) -> void:
	var spacing_px: float = float(font_size) * TEXT_SPACING_FRACTION
	var char_widths: PackedFloat32Array = PackedFloat32Array()
	var total_width: float = 0.0
	for i: int in text.length():
		var w: float = FONT.get_string_size(text[i], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		char_widths.append(w)
		total_width += w
	total_width += spacing_px * (text.length() - 1)
	var total_angle: float = total_width / radius

	# Top arch traverses angles in increasing direction (CW on screen) to read L→R.
	# Bottom arch traverses in decreasing direction so it also reads L→R when
	# viewed right-side up from the same side.
	var dir: float = 1.0 if is_top else -1.0
	var start_angle: float = base_angle - dir * total_angle * 0.5
	var rot_offset: float = PI * 0.5 if is_top else -PI * 0.5

	# Vertical center adjustment so the optical middle of the glyph sits on
	# the circle. ascent/2 below the baseline is a good approximation for
	# uppercase-only block lettering.
	var ascent: float = FONT.get_ascent(font_size)
	var v_offset: float = ascent * 0.5

	var current_angle: float = start_angle
	for i: int in text.length():
		var w: float = char_widths[i]
		var char_arc: float = w / radius
		var char_angle: float = current_angle + dir * char_arc * 0.5
		var pos: Vector2 = center + Vector2(cos(char_angle), sin(char_angle)) * radius
		draw_set_transform(pos, char_angle + rot_offset, Vector2.ONE)
		draw_string(FONT, Vector2(-w * 0.5, v_offset), text[i],
					HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
		current_angle += dir * (char_arc + spacing_px / radius)
