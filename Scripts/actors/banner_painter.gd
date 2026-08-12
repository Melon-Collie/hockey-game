class_name BannerPainter
extends Node2D

# Paints the rafter-banner atlas: one portrait cell per BannerRegistry entry,
# rendered once into a SubViewport that every hanging banner samples through its
# own cell — so the whole roof's worth of history is one material and one draw.
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
# A championship banner is mostly its year; a retired number is mostly its
# number. Both stack a large line over a small one, so one layout serves both —
# only the split between the two changes.
const TITLE_TOP_SIZE: int = 40
const TITLE_BOTTOM_SIZE: int = 96
const NUMBER_TOP_SIZE: int = 150
const NUMBER_BOTTOM_SIZE: int = 30

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
	for index: int in banners.size():
		var column: int = index % COLUMNS
		var row: int = floori(float(index) / float(COLUMNS))
		_draw_cell(Vector2(column * CELL_PX.x, row * CELL_PX.y), banners[index])


func _draw_cell(origin: Vector2, banner: Dictionary) -> void:
	var cell := Vector2(CELL_PX)
	draw_rect(Rect2(origin, cell), banner.trim as Color)
	draw_rect(Rect2(origin + Vector2(BORDER_PX, BORDER_PX),
			cell - Vector2(BORDER_PX, BORDER_PX) * 2.0), banner.field as Color)

	var is_number: bool = (banner.kind as int) == BannerRegistry.Kind.NUMBER
	var top_size: int = NUMBER_TOP_SIZE if is_number else TITLE_TOP_SIZE
	var bottom_size: int = NUMBER_BOTTOM_SIZE if is_number else TITLE_BOTTOM_SIZE
	var available: float = cell.x - 2.0 * PAD_PX
	top_size = _fit(banner.top as String, top_size, available)
	bottom_size = _fit(banner.bottom as String, bottom_size, available)

	# Rule between the two lines, at the optical middle rather than the true
	# one — the lower line is the heavier of the pair on a title banner.
	var rule_y: float = origin.y + cell.y * (0.46 if is_number else 0.40)
	draw_rect(Rect2(origin.x + PAD_PX, rule_y, cell.x - 2.0 * PAD_PX, 3.0),
			banner.trim as Color)

	_draw_centred(banner.top as String, top_size,
			origin.x + cell.x * 0.5, rule_y - cell.y * 0.05, banner.ink as Color, true)
	_draw_centred(banner.bottom as String, bottom_size,
			origin.x + cell.x * 0.5, rule_y + cell.y * 0.05, banner.ink as Color, false)


# `anchor_y` is the edge the line sits against: its baseline when `above` (the
# text hangs off the bottom of that line), its cap top otherwise.
func _draw_centred(text: String, size: int, centre_x: float, anchor_y: float,
		color: Color, above: bool) -> void:
	var width: float = FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline: float = anchor_y if above else anchor_y + FONT.get_ascent(size)
	draw_string(FONT, Vector2(centre_x - width * 0.5, baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _fit(text: String, size: int, available: float) -> int:
	var width: float = FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if width <= available or width <= 0.0:
		return size
	return maxi(1, int(float(size) * available / width))
