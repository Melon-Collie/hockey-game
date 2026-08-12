class_name RibbonPainter
extends Node2D

# Paints the fascia ribbon board's scrolling strip: one cell per AdBrands entry
# in a single long row, rendered once into a SubViewport that the band samples
# with U repeating. The scroll is a UV offset on the material, not a repaint —
# the strip is drawn once for the life of the arena and then simply slides.
#
# The strip has to be seamless in U, so nothing straddles a cell boundary and
# the field colour runs edge to edge. The band's repeat count is a whole number
# for the same reason (see ArenaStands._RIBBON_REPEATS).

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")

# One cell per sponsor, laid end to end. The 10:1 aspect is what a 0.55 m band
# looks like when a message gets its share of the bowl's perimeter.
const CELL_PX: Vector2i = Vector2i(480, 48)
const PAD_PX: float = 26.0
const NAME_SIZE: int = 30
const TAG_SIZE: int = 19
const TAG_GAP_PX: float = 12.0
# Unlit LED: the field is near-black and the type carries all the brightness,
# which is what makes the board read as emitting rather than as a painted sign.
const FIELD: Color = Color(0.03, 0.03, 0.045)
const SEPARATOR: Color = Color(0.16, 0.17, 0.22)

var brands: Array[Dictionary] = []


static func strip_size(count: int) -> Vector2i:
	return Vector2i(CELL_PX.x * maxi(count, 1), CELL_PX.y)


func _draw() -> void:
	var strip := Vector2(strip_size(brands.size()))
	draw_rect(Rect2(Vector2.ZERO, strip), FIELD)
	for index: int in brands.size():
		_draw_cell(float(index * CELL_PX.x), brands[index])


func _draw_cell(x0: float, brand: Dictionary) -> void:
	# Divider at the cell's leading edge. Cell 0 gets one too — it is the seam
	# where the strip wraps, and a divider there is exactly what belongs.
	draw_rect(Rect2(x0, CELL_PX.y * 0.25, 2.0, CELL_PX.y * 0.5), SEPARATOR)

	var name_text: String = brand.name
	var tag_text: String = brand.tag
	var name_size: int = NAME_SIZE
	var tag_size: int = TAG_SIZE
	var available: float = float(CELL_PX.x) - 2.0 * PAD_PX
	var name_w: float = FONT.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size).x
	var tag_w: float = FONT.get_string_size(tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size).x
	var total: float = name_w + TAG_GAP_PX + tag_w
	if total > available:
		var scale: float = available / total
		name_size = maxi(1, int(float(name_size) * scale))
		tag_size = maxi(1, int(float(tag_size) * scale))
		name_w = FONT.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size).x
		tag_w = FONT.get_string_size(tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size).x
		total = name_w + TAG_GAP_PX + tag_w

	var ascent: float = FONT.get_ascent(name_size)
	var descent: float = FONT.get_descent(name_size)
	var baseline: float = float(CELL_PX.y) * 0.5 + (ascent - descent) * 0.5
	var cursor: float = x0 + (float(CELL_PX.x) - total) * 0.5

	# The accent rather than the wordmark colour: an LED board is one hue per
	# message, and the accent is the brand's brightest.
	draw_string(FONT, Vector2(cursor, baseline), name_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, name_size, brand.accent as Color)
	draw_string(FONT, Vector2(cursor + name_w + TAG_GAP_PX, baseline), tag_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size, (brand.accent as Color).darkened(0.35))
