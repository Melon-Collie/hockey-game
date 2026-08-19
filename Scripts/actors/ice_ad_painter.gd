class_name IceAdPainter
extends Node2D

# Paints the in-ice sponsor wordmarks into an atlas that the ice shader stamps
# onto the sheet BEFORE its Beer-Lambert fade — same treatment as the lines
# baked into the albedo — so an ad reads as printed into the ice rather than
# laid on top of it. Only the lettering is painted: an in-ice ad is a mark
# frozen into the sheet, so a panel field or border would read as a decal
# sitting on it. That is also why the board palette cannot be reused verbatim
# here — see MAX_INK_LUMINANCE.
#
# One cell per slot, packed in a row. The alternative — one rink-sized image the
# shader indexes with the rink UV directly — spends ~94% of its pixels on the
# blank ice between six slots, so the atlas buys 2.5x the linear resolution for
# less than half the memory. What it costs is that the shader has to find which
# slot a fragment falls in; see `ads_world` in ice.gdshader.
#
# A cell's pixel axes match the rink's: +x is world +X (the slot's short axis,
# which sets the cap height) and +y is world +Z (its long axis). The wordmark is
# rotated a quarter turn inside that, so it runs the length of the rink and
# reads from the broadcast side.

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")

# Cell resolution. The wordmarks are the finest thing in this atlas, and the ice
# is viewed nearly face-on (75 degrees of camera tilt), so a slot is magnified
# roughly 2x on a 1080p screen at normal camera height — this is set to cover
# that rather than to match the ice albedo's 80 px/m.
const PX_PER_METER: float = 100.0
# Transparent margin around every cell, so linear filtering at a cell edge can
# only ever pull in blank ice rather than the neighbouring sponsor.
const GUTTER_PX: int = 2
# ads_world[] / ads_atlas[] in ice.gdshader are this long — shader arrays cannot
# be sized at runtime. Raise both together.
const MAX_SLOTS: int = 8

# Under-ice, not on it — but the shader composites this BEFORE the Beer-Lambert
# fade, which then washes it toward the ice fog colour, so what reaches the eye
# is a good deal fainter than the number suggests. It is set by how the wordmarks
# read in a capture, not by how they read on the palette.
const TEXT_ALPHA: float = 0.92
# Fractions of the slot's short axis (its cap height) and long axis.
const NAME_HEIGHT_FRACTION: float = 0.42
const TAG_HEIGHT_FRACTION: float = 0.19
const TEXT_INSET_FRACTION: float = 0.06

# The ice IS the field here, and it is white. A board panel's `fg` is the wordmark
# chosen to sit on that panel's dark `bg`, so reading it in-ice paints near-white
# lettering onto near-white ice — invisible at any alpha, and more so after the
# Beer-Lambert fade washes it further toward the ice colour. In-ice lettering
# therefore takes the brand's OWN dark colour: `bg` for the wordmark (dark by
# construction, since the boards behind the panels are white and every field had
# to carry a white mark), and the `accent` tagline darkened into the same band.
const MAX_INK_LUMINANCE: float = 0.45


# `color` darkened until it is dark enough to read against white ice. Below the
# ceiling it passes through, so a brand that already owns a deep colour keeps it
# exactly.
static func ice_ink(color: Color) -> Color:
	var lum: float = color.get_luminance()
	if lum <= MAX_INK_LUMINANCE:
		return color
	return color.darkened(1.0 - MAX_INK_LUMINANCE / lum)

# AdBrands.ICE_SLOTS entries, with the brand already resolved into `brand`.
var slots: Array[Dictionary] = []


static func cell_px(slot_size: Vector2) -> Vector2i:
	return Vector2i(
			maxi(1, roundi(slot_size.x * PX_PER_METER)),
			maxi(1, roundi(slot_size.y * PX_PER_METER)))


# Cells sit in one row, each in its own gutter, so the atlas is as tall as the
# longest slot and as wide as all of them end to end.
static func atlas_size(slots_in: Array[Dictionary]) -> Vector2i:
	var width: int = GUTTER_PX
	var height: int = 0
	for slot: Dictionary in slots_in:
		var cell: Vector2i = cell_px(slot.size as Vector2)
		width += cell.x + GUTTER_PX
		height = maxi(height, cell.y)
	return Vector2i(maxi(width, 1), height + 2 * GUTTER_PX)


static func cell_origin(slots_in: Array[Dictionary], index: int) -> Vector2i:
	var x: int = GUTTER_PX
	for i: int in index:
		x += cell_px(slots_in[i].size as Vector2).x + GUTTER_PX
	return Vector2i(x, GUTTER_PX)


# The atlas UV rect the shader samples for slot `index`.
static func cell_uv(slots_in: Array[Dictionary], index: int) -> Rect2:
	var atlas := Vector2(atlas_size(slots_in))
	return Rect2(Vector2(cell_origin(slots_in, index)) / atlas,
			Vector2(cell_px(slots_in[index].size as Vector2)) / atlas)


func _draw() -> void:
	for index: int in slots.size():
		_draw_cell(index)


func _draw_cell(index: int) -> void:
	var brand: Dictionary = slots[index].brand
	var cell: Vector2i = cell_px(slots[index].size as Vector2)
	var centre := Vector2(cell_origin(slots, index)) + Vector2(cell) * 0.5
	# Rotating by −π/2 sends local +x to the cell's −y and local +y to its +x, so
	# the wordmark's baseline runs the slot's long axis and the drawing rect is
	# the cell transposed.
	var half := Vector2(cell.y, cell.x) * 0.5
	var rect := Rect2(-half, half * 2.0)

	draw_set_transform(centre, -PI * 0.5, Vector2.ONE)

	var name_text: String = brand.name
	var tag_text: String = brand.tag
	var inset: float = rect.size.x * TEXT_INSET_FRACTION
	var available: float = rect.size.x - 2.0 * inset
	var name_size: int = maxi(1, int(rect.size.y * NAME_HEIGHT_FRACTION))
	var tag_size: int = maxi(1, int(rect.size.y * TAG_HEIGHT_FRACTION))
	name_size = _fit(name_text, name_size, available)
	tag_size = _fit(tag_text, tag_size, available)

	# Wordmark above centre, tagline below it — the slot is wide enough on its
	# short axis to stack them, unlike the board cells.
	var name_h: float = FONT.get_ascent(name_size) - FONT.get_descent(name_size)
	var tag_h: float = FONT.get_ascent(tag_size) - FONT.get_descent(tag_size)
	var gap: float = rect.size.y * 0.06
	var block: float = name_h + gap + tag_h
	var name_baseline: float = -block * 0.5 + name_h
	var tag_baseline: float = name_baseline + gap + tag_h

	_draw_centred(name_text, name_size, name_baseline,
			Color(ice_ink(brand.bg as Color), TEXT_ALPHA))
	_draw_centred(tag_text, tag_size, tag_baseline,
			Color(ice_ink(brand.accent as Color), TEXT_ALPHA))

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_centred(text: String, size: int, baseline: float, color: Color) -> void:
	var text_w: float = FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(FONT, Vector2(-text_w * 0.5, baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _fit(text: String, size: int, available: float) -> int:
	var width: float = FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if width <= available or width <= 0.0:
		return size
	return maxi(1, int(float(size) * available / width))
