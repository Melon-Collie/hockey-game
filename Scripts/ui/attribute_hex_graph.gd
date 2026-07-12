class_name AttributeHexGraph
extends Control

# Six-axis radar ("hex graph") of a player's attribute build — Speed, Agility,
# Hands, Size, Physical, Shot in PlayerAttributes' canonical order, clockwise
# from the top vertex. A pure _draw() Control: the grid is two reference
# hexagons (the level-5 ceiling and the all-medium level-3 ring, so a spike or
# dump reads against the baseline build at a glance) plus spokes, with the
# build itself as a filled accent polygon. Level 1 renders on an inner ring,
# not at the center, so a dumped stat still contributes a visible shape.
#
# Used on the pre-game matchup screen: one small unlabeled hex per roster row
# (accent = team color) and one larger `show_labels` legend hex under the VS
# that names the axes once for all of them. Redraws only on set_build /
# resize — nothing per-frame.

const _AXES: int = 6
const _AXIS_LABELS: Array[String] = ["SPD", "AGI", "HND", "SIZ", "PHY", "SHT"]
const _LABEL_FONT_SIZE: int = 11
const _LABEL_PAD: float = 16.0

const _GRID_OUTER := Color(1.0, 1.0, 1.0, 0.16)
const _GRID_MEDIUM := Color(1.0, 1.0, 1.0, 0.09)
const _GRID_SPOKE := Color(1.0, 1.0, 1.0, 0.12)
const _FILL_ALPHA: float = 0.30

@export var accent: Color = MenuStyle.TEAL
# Legend variant: names the axes around the grid. Combine with an empty build
# (never call set_build) for a pure axis key.
@export var show_labels: bool = false

var _levels: Array[int] = []


func set_build(attrs: PlayerAttributes, p_accent: Color) -> void:
	_levels = [attrs.speed, attrs.agility, attrs.hands,
			attrs.size, attrs.physical, attrs.shot]
	accent = p_accent
	queue_redraw()


func _draw() -> void:
	var center: Vector2 = size / 2.0
	var pad: float = _LABEL_PAD if show_labels else 2.0
	var radius: float = minf(size.x, size.y) / 2.0 - pad
	if radius <= 0.0:
		return
	draw_polyline(_ring(center, radius), _GRID_OUTER, 1.0, true)
	draw_polyline(_ring(center, radius * _level_frac(PlayerAttributes.LEVEL_MEDIUM)),
			_GRID_MEDIUM, 1.0, true)
	for i: int in _AXES:
		draw_line(center, center + _dir(i) * radius, _GRID_SPOKE, 1.0, true)
	if _levels.size() == _AXES:
		var pts := PackedVector2Array()
		for i: int in _AXES:
			pts.append(center + _dir(i) * radius * _level_frac(_levels[i]))
		draw_colored_polygon(pts, Color(accent.r, accent.g, accent.b, _FILL_ALPHA))
		pts.append(pts[0])  # close the outline
		draw_polyline(pts, accent, 1.5, true)
	if show_labels:
		_draw_axis_labels(center, radius)


# Vertex i's unit direction: top vertex first, clockwise.
func _dir(i: int) -> Vector2:
	var angle: float = -PI / 2.0 + float(i) * TAU / float(_AXES)
	return Vector2(cos(angle), sin(angle))


func _level_frac(level: int) -> float:
	return float(level) / float(PlayerAttributes.LEVEL_MAX)


func _ring(center: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i: int in _AXES + 1:  # +1 closes the loop
		pts.append(center + _dir(i % _AXES) * radius)
	return pts


func _draw_axis_labels(center: Vector2, radius: float) -> void:
	var font: Font = MenuStyle.DISPLAY_FONT
	for i: int in _AXES:
		var text: String = _AXIS_LABELS[i]
		var dir: Vector2 = _dir(i)
		var text_size: Vector2 = font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, _LABEL_FONT_SIZE)
		var pos: Vector2 = center + dir * (radius + 5.0)
		pos.x -= text_size.x / 2.0 - dir.x * (text_size.x / 2.0 + 2.0)
		# Baseline placement: labels above the hex sit on their descent, side
		# and below labels drop by their ascent so they clear the grid.
		var ascent: float = font.get_ascent(_LABEL_FONT_SIZE)
		if dir.y < -0.3:
			pos.y -= 3.0
		elif dir.y > 0.3:
			pos.y += ascent
		else:
			pos.y += ascent / 2.0 - 2.0
		draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				_LABEL_FONT_SIZE, MenuStyle.BROADCAST_DIM)
