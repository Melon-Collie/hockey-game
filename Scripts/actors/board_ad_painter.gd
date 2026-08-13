class_name BoardAdPainter
extends Node2D

# Paints the dasher-board sponsor atlas — one cell per AdBrands entry, laid out
# in a grid and rendered once into a SubViewport. Every ad panel on the boards
# samples that one texture through its own cell, so the whole perimeter of
# advertising costs a single material and a single draw call.
#
# Cells are drawn, not blitted from art files: a sponsor is a row in AdBrands
# rather than a PNG plus its .import, and the wordmark rasterizes crisp at
# whatever resolution the atlas happens to be built at.

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")

# The cell aspect is a contract with the board geometry: HockeyRink derives its
# panel WIDTH from the board band's height times this ratio, so the art is never
# stretched. Change the ratio and the panels on the wall follow.
const CELL_PX: Vector2i = Vector2i(512, 96)
const COLUMNS: int = 4
# Pull each sampled rect a texel off its cell edge so linear filtering cannot
# drag in the neighbouring cell — or, on the last row, the transparent gutter.
const UV_INSET_PX: float = 1.0

const PAD_PX: float = 20.0
const RULE_PX: float = 7.0
const NAME_SIZE: int = 56
const TAG_SIZE: int = 30
const TAG_GAP_PX: float = 16.0

var brands: Array[Dictionary] = []


static func row_count(count: int) -> int:
	return maxi(1, ceili(float(count) / float(COLUMNS)))


static func atlas_size(count: int) -> Vector2i:
	return Vector2i(CELL_PX.x * COLUMNS, CELL_PX.y * row_count(count))


# The UV rect a panel showing brand `index` should sample.
static func cell_uv(index: int, count: int) -> Rect2:
	var atlas: Vector2i = atlas_size(count)
	var column: int = index % COLUMNS
	var row: int = floori(float(index) / float(COLUMNS))
	var origin := Vector2(
			float(column * CELL_PX.x) + UV_INSET_PX,
			float(row * CELL_PX.y) + UV_INSET_PX)
	var size := Vector2(
			float(CELL_PX.x) - 2.0 * UV_INSET_PX,
			float(CELL_PX.y) - 2.0 * UV_INSET_PX)
	return Rect2(origin / Vector2(atlas), size / Vector2(atlas))


func _draw() -> void:
	for index: int in brands.size():
		var column: int = index % COLUMNS
		var row: int = floori(float(index) / float(COLUMNS))
		_draw_cell(Vector2(column * CELL_PX.x, row * CELL_PX.y), brands[index])


func _draw_cell(origin: Vector2, brand: Dictionary) -> void:
	var cell := Vector2(CELL_PX)
	draw_rect(Rect2(origin, cell), brand.bg as Color)
	# Accent rule along the bottom edge — the one piece of structure that keeps a
	# cell from reading as a floating word when the board is glimpsed in motion.
	draw_rect(Rect2(origin + Vector2(0.0, cell.y - RULE_PX),
			Vector2(cell.x, RULE_PX)), brand.accent as Color)

	var name_text: String = brand.name
	var tag_text: String = brand.tag
	var name_size: int = NAME_SIZE
	var tag_size: int = TAG_SIZE
	var available: float = cell.x - 2.0 * PAD_PX
	var name_w: float = FONT.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size).x
	var tag_w: float = FONT.get_string_size(tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size).x
	var total: float = name_w + TAG_GAP_PX + tag_w
	if total > available:
		# Longer sponsor names shrink to fit rather than spilling off the panel.
		var scale: float = available / total
		name_size = maxi(1, int(float(name_size) * scale))
		tag_size = maxi(1, int(float(tag_size) * scale))
		name_w = FONT.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size).x
		tag_w = FONT.get_string_size(tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size).x
		total = name_w + TAG_GAP_PX + tag_w

	# Optically centre the wordmark in the field above the rule: draw_string
	# takes a baseline, so shift by half the ascender/descender difference.
	var field_h: float = cell.y - RULE_PX
	var ascent: float = FONT.get_ascent(name_size)
	var descent: float = FONT.get_descent(name_size)
	var baseline: float = origin.y + field_h * 0.5 + (ascent - descent) * 0.5
	var cursor: float = origin.x + (cell.x - total) * 0.5

	draw_string(FONT, Vector2(cursor, baseline), name_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, name_size, brand.fg as Color)
	draw_string(FONT, Vector2(cursor + name_w + TAG_GAP_PX, baseline), tag_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size, brand.accent as Color)
