class_name IceAdPainter
extends Node2D

# Paints the in-ice sponsor wordmarks into a full-rink SubViewport that the ice
# shader composites BEFORE its Beer-Lambert fade — same treatment as the lines
# baked into the albedo — so an ad reads as printed into the sheet rather than
# laid on top of it. Only the lettering is painted: an in-ice ad is a mark frozen
# into the sheet, so a panel field or border would read as a decal on top of it.
#
# Coordinate convention matches CenterIceDecals — world +X → image +X,
# world +Z → image −Y, wordmarks rotated so their up direction points to image
# −X — so every piece of art frozen into this ice reads the same way round.
# In that rotated frame a slot's local +x runs along world +Z, which is why the
# slots in AdBrands are long in Z: the wordmark runs the length of the rink.

const FONT: Font = preload("res://Assets/Fonts/BarlowSemiCondensed-ExtraBold.ttf")

# Under-ice, not on it — but the shader composites this BEFORE the Beer-Lambert
# fade, which then washes it toward the ice fog colour, so what reaches the eye
# is a good deal fainter than the number suggests. It is set by how the wordmarks
# read in a capture, not by how they read on the palette.
const TEXT_ALPHA: float = 0.92
# Fractions of the slot's short axis (its cap height) and long axis.
const NAME_HEIGHT_FRACTION: float = 0.42
const TAG_HEIGHT_FRACTION: float = 0.19
const TEXT_INSET_FRACTION: float = 0.06

var img_size: Vector2 = Vector2.ZERO
var px_per_meter: float = 40.0
var rink_size: Vector2 = Vector2(26.0, 60.0)
# AdBrands.ICE_SLOTS entries, with the brand already resolved into `brand`.
var slots: Array[Dictionary] = []


func _draw() -> void:
	for slot: Dictionary in slots:
		_draw_slot(slot)


func _draw_slot(slot: Dictionary) -> void:
	var brand: Dictionary = slot.brand
	var extent: Vector2 = slot.size
	# Rotating by −π/2 sends local +x to world +Z and local +y to world +X, so
	# the slot's local half-extents are its Z half-length by its X half-width.
	var half := Vector2(extent.y, extent.x) * 0.5 * px_per_meter
	var rect := Rect2(-half, half * 2.0)

	draw_set_transform(_world_to_image(slot.center), -PI * 0.5, Vector2.ONE)

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

	_draw_centred(name_text, name_size, name_baseline, Color(brand.fg as Color, TEXT_ALPHA))
	_draw_centred(tag_text, tag_size, tag_baseline, Color(brand.accent as Color, TEXT_ALPHA))

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


# World XZ in metres → pixel in the full-rink image.
func _world_to_image(world_xz: Vector2) -> Vector2:
	return Vector2(
			img_size.x * 0.5 + world_xz.x * px_per_meter,
			img_size.y * 0.5 - world_xz.y * px_per_meter)
