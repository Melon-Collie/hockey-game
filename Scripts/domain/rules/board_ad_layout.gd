class_name BoardAdLayout
extends RefCounted

# Packs fixed-width sponsor panels into whatever stretch of the dasher boards is
# not already spoken for — the painted stripes and the player benches come first,
# ads fill what is left.
#
# Everything here works in ARC LENGTH along the boards, and that domain is a
# circle: arc 0 and arc `perimeter` are the same point on the wall, so a reserved
# stretch can straddle the seam and so can a free run. Inputs are normalized into
# [0, perimeter) and the wrap is handled once, in free_runs().
#
# Intervals are (start, length) pairs on the way in and on the way out — never
# (start, end) — so a caller can hand a result straight back as a reservation.
#
# There is no RNG here. The layout is a function of the rink's dimensions, which
# every machine builds from the same constants, so the boards agree across a
# lobby without replicating anything.

const EPSILON: float = 0.0001


# Normalizes, splits at the seam, sorts, and merges `intervals` into a disjoint
# ascending list. An interval longer than the perimeter is clamped to it rather
# than lapping the rink.
static func merge_reserved(perimeter: float, intervals: Array[Vector2]) -> Array[Vector2]:
	var merged: Array[Vector2] = []
	if perimeter <= EPSILON:
		return merged

	# Cut anything crossing the seam into a head and a tail so the merge below
	# can work on plain ascending spans.
	var spans: Array[Vector2] = []   # (start, end), both inside [0, perimeter]
	for interval: Vector2 in intervals:
		var length: float = minf(interval.y, perimeter)
		if length <= EPSILON:
			continue
		var start: float = fposmod(interval.x, perimeter)
		var end: float = start + length
		if end <= perimeter + EPSILON:
			spans.append(Vector2(start, minf(end, perimeter)))
		else:
			spans.append(Vector2(start, perimeter))
			spans.append(Vector2(0.0, end - perimeter))
	spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

	for span: Vector2 in spans:
		if merged.is_empty():
			merged.append(span)
			continue
		var last: Vector2 = merged[merged.size() - 1]
		if span.x <= last.y + EPSILON:
			merged[merged.size() - 1] = Vector2(last.x, maxf(last.y, span.y))
		else:
			merged.append(span)

	for i: int in merged.size():
		merged[i] = Vector2(merged[i].x, merged[i].y - merged[i].x)
	return merged


# The gaps between the reserved stretches. A run's start is inside
# [0, perimeter), but its length may carry it past the seam — the run that spans
# arc 0 is returned once, starting at the last reservation's end, rather than as
# two pieces.
static func free_runs(perimeter: float, reserved: Array[Vector2]) -> Array[Vector2]:
	var runs: Array[Vector2] = []
	if perimeter <= EPSILON:
		return runs
	var blocked: Array[Vector2] = merge_reserved(perimeter, reserved)
	if blocked.is_empty():
		# Nothing reserved: the whole loop is one run. It has no natural start,
		# so arc 0 is as good as any — the caller's run margin lands there.
		runs.append(Vector2(0.0, perimeter))
		return runs

	for i: int in blocked.size():
		var run_start: float = blocked[i].x + blocked[i].y
		var next_start: float = blocked[(i + 1) % blocked.size()].x
		if i == blocked.size() - 1:
			next_start += perimeter   # the run that wraps the seam
		var length: float = next_start - run_start
		if length > EPSILON:
			runs.append(Vector2(run_start, length))
	return runs


# Fills each free run with as many `panel_width` panels as fit, given `min_gap`
# of bare board between neighbours and `run_margin` of bare board at each end of
# the run. Slack left over after the last panel is spread into the gaps rather
# than dumped at one end, so a run reads as an evenly spaced set instead of a
# block with a hole beside it.
#
# Returns (arc start, width) pairs sorted by start, with every start inside
# [0, perimeter). A panel may still run past the seam — it is one panel, and the
# geometry that follows the arc does not care where the numbering began.
static func place_panels(perimeter: float, reserved: Array[Vector2],
		panel_width: float, min_gap: float, run_margin: float) -> Array[Vector2]:
	var placements: Array[Vector2] = []
	if perimeter <= EPSILON or panel_width <= EPSILON:
		return placements

	for run: Vector2 in free_runs(perimeter, reserved):
		var usable: float = run.y - 2.0 * run_margin
		if usable < panel_width - EPSILON:
			continue
		# The largest n with n panels and n-1 gaps inside `usable`.
		var count: int = int(floor((usable + min_gap) / (panel_width + min_gap)))
		if count < 1:
			continue
		var cursor: float = run.x + run_margin
		var gap: float = min_gap
		if count == 1:
			cursor += (usable - panel_width) * 0.5
		else:
			# >= min_gap by construction of `count`.
			gap = (usable - float(count) * panel_width) / float(count - 1)
		for _i: int in count:
			placements.append(Vector2(fposmod(cursor, perimeter), panel_width))
			cursor += panel_width + gap

	placements.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	return placements
