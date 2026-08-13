class_name BannerPainter
extends Node2D

# Paints the rafter-banner atlas: one portrait cell per BannerRegistry entry,
# rendered once into a SubViewport that every hanging banner samples through its
# own cell — so the whole roof's worth of names is one material and one draw.
#
# Same construction as BoardAdPainter, and portrait for the same reason its
# cells are letterbox: the cell aspect is a contract with the geometry, and
# ArenaStands derives banner WIDTH from the hang height times this ratio so the
# cloth is never stretched.

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")

const CELL_PX: Vector2i = Vector2i(256, 416)
const COLUMNS: int = 4
const UV_INSET_PX: float = 1.0

const BORDER_PX: float = 9.0
const PAD_PX: float = 22.0
const NUMBER_SIZE: int = 200
const NAME_SIZE: int = 38
# Where the rule between number and name sits, as a fraction of cell height. The
# number gets the larger share because it is the larger mark; each line is then
# centred within its own band, which keeps the cloth filled instead of stacking
# both against the rule and leaving the bottom third empty.
const RULE_FRACTION: float = 0.60

var banners: Array[Dictionary] = []


static func row_count(count: int) -> int:
	return maxi(1, ceili(float(count) / float(COLUMNS)))


static func atlas_size(count: int) -> Vector2i:
	return Vector2i(CELL_PX.x * COLUMNS, CELL_PX.y * row_count(count))


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
	# Type is sized ONCE across the whole set rather than per cell. Fitting each
	# banner on its own would leave "7" at full height beside a shrunken "27",
	# and a row of retired numbers at four different sizes reads as a mistake.
	var available: float = float(CELL_PX.x) - 2.0 * PAD_PX
	var number_size: int = NUMBER_SIZE
	var name_size: int = NAME_SIZE
	for banner: Dictionary in banners:
		number_size = mini(number_size, _fit(banner.number as String, NUMBER_SIZE, available))
		name_size = mini(name_size, _fit(banner.name as String, NAME_SIZE, available))

	for index: int in banners.size():
		var column: int = index % COLUMNS
		var row: int = floori(float(index) / float(COLUMNS))
		_draw_cell(Vector2(column * CELL_PX.x, row * CELL_PX.y), banners[index],
				number_size, name_size)


func _draw_cell(origin: Vector2, banner: Dictionary, number_size: int,
		name_size: int) -> void:
	var cell := Vector2(CELL_PX)
	draw_rect(Rect2(origin, cell), banner.trim as Color)
	draw_rect(Rect2(origin + Vector2(BORDER_PX, BORDER_PX),
			cell - Vector2(BORDER_PX, BORDER_PX) * 2.0), banner.field as Color)

	var rule_y: float = origin.y + cell.y * RULE_FRACTION
	draw_rect(Rect2(origin.x + PAD_PX, rule_y, cell.x - 2.0 * PAD_PX, 3.0),
			banner.trim as Color)

	var centre_x: float = origin.x + cell.x * 0.5
	_draw_centred(banner.number as String, number_size, centre_x,
			origin.y + BORDER_PX, rule_y, banner.ink as Color)
	_draw_centred(banner.name as String, name_size, centre_x,
			rule_y, origin.y + cell.y - BORDER_PX, banner.ink as Color)


# Centred horizontally on `centre_x` and optically centred in the vertical band
# [top, bottom] — draw_string takes a baseline, so the line is shifted by half
# the ascender/descender difference to sit on the band's middle.
func _draw_centred(text: String, size: int, centre_x: float, top: float,
		bottom: float, color: Color) -> void:
	var width: float = FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var ascent: float = FONT.get_ascent(size)
	var descent: float = FONT.get_descent(size)
	var baseline: float = (top + bottom) * 0.5 + (ascent - descent) * 0.5
	draw_string(FONT, Vector2(centre_x - width * 0.5, baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _fit(text: String, size: int, available: float) -> int:
	var width: float = FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if width <= available or width <= 0.0:
		return size
	return maxi(1, int(float(size) * available / width))
