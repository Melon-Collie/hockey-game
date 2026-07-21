class_name AttributeHexGraph
extends Control

# Six-axis radar ("hex graph") of a player's RESOLVED capabilities — Speed,
# Acceleration, Agility, Hands, Shot, Checking, clockwise from the top vertex.
# Under the height-routed model a build is a height dial plus three tiers, so the
# radar plots the net gameplay multipliers those produce (a tall enforcer reads
# high SHT/CHK + low AGI/HND; a small dangler the mirror) rather than raw axis
# picks — the silhouette IS the archetype. A pure _draw() Control: the grid is
# an outer ceiling hexagon and the all-average (1.0-multiplier) ring, so a spike
# or dump reads against the baseline, plus spokes, with the build as a filled
# accent polygon.
#
# Used on the pre-game matchup screen: one small unlabeled hex per roster row
# (accent = team color) and one larger `show_labels` legend hex under the VS
# that names the axes once for all of them. Redraws only on set_build / resize.

const _AXES: int = 6
const _AXIS_LABELS: Array[String] = ["SPD", "ACC", "AGI", "HND", "SHT", "CHK"]
const _LABEL_FONT_SIZE: int = 11
const _LABEL_PAD: float = 16.0

# All resolved multipliers live in ~[0.76, 1.36]. Map to a 0..1 draw fraction so
# the all-average 1.0 sits at the medium ring (0.6, matching the old level-3
# look) and the extremes still read: frac = 0.6 + (mult - 1) * SPREAD, clamped.
const _MEDIUM_FRAC: float = 0.6
const _FRAC_SPREAD: float = 1.2
const _FRAC_MIN: float = 0.12

const _GRID_OUTER := Color(1.0, 1.0, 1.0, 0.16)
const _GRID_MEDIUM := Color(1.0, 1.0, 1.0, 0.09)
const _GRID_SPOKE := Color(1.0, 1.0, 1.0, 0.12)
const _FILL_ALPHA: float = 0.30

@export var accent: Color = MenuStyle.TEAL
# Legend variant: names the axes around the grid. Combine with an empty build
# (never call set_build) for a pure axis key.
@export var show_labels: bool = false

var _fracs: Array[float] = []


func set_build(attrs: PlayerAttributes, p_accent: Color) -> void:
	_fracs = [
		_norm(attrs.speed_mult()),
		_norm(attrs.accel_mult()),
		_norm(attrs.agility_mult()),
		_norm(attrs.hands_blade_mult()),
		_norm(attrs.shot_power_mult()),
		_norm(attrs.check_delivery_mult()),
	]
	accent = p_accent
	queue_redraw()


func _draw() -> void:
	var center: Vector2 = size / 2.0
	var pad: float = _LABEL_PAD if show_labels else 2.0
	var radius: float = minf(size.x, size.y) / 2.0 - pad
	if radius <= 0.0:
		return
	draw_polyline(_ring(center, radius), _GRID_OUTER, 1.0, true)
	draw_polyline(_ring(center, radius * _MEDIUM_FRAC), _GRID_MEDIUM, 1.0, true)
	for i: int in _AXES:
		draw_line(center, center + _dir(i) * radius, _GRID_SPOKE, 1.0, true)
	if _fracs.size() == _AXES:
		var pts := PackedVector2Array()
		for i: int in _AXES:
			pts.append(center + _dir(i) * radius * _fracs[i])
		draw_colored_polygon(pts, Color(accent.r, accent.g, accent.b, _FILL_ALPHA))
		pts.append(pts[0])  # close the outline
		draw_polyline(pts, accent, 1.5, true)
	if show_labels:
		_draw_axis_labels(center, radius)


# Vertex i's unit direction: top vertex first, clockwise.
func _dir(i: int) -> Vector2:
	var angle: float = -PI / 2.0 + float(i) * TAU / float(_AXES)
	return Vector2(cos(angle), sin(angle))


# Resolved multiplier → draw fraction. All-average (1.0) sits at the medium ring.
func _norm(mult: float) -> float:
	return clampf(_MEDIUM_FRAC + (mult - 1.0) * _FRAC_SPREAD, _FRAC_MIN, 1.0)


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
