class_name ArenaBowlRake
extends RefCounted

# The bowl in section: how far out and how high each row sits, where the two
# decks meet, where the shell stands, and where the rinkside furniture cuts the
# terracing down to a flat well.
#
# `ArenaBowlPath` answers "where does a ring at offset X run"; this answers
# "which offsets and heights are there". Everything that places something in the
# stands — the concrete, the crowd, the seats, the staff — asks here rather than
# re-deriving `base_outward_offset + i * tread_depth` for itself.

var _spec: ArenaBowlSpec
var _path: ArenaBowlPath

# Spacing the shell wall is resampled at before its openings are cut. Well under
# the narrowest portal, so an opening always spans several segments.
const VOMITORY_SAMPLE_M: float = 0.25

# ── Ribbon board clearance ───────────────────────────────────────────────────
# The strip hangs on the upper deck's fascia, and the lower bowl's portals are
# cut into the same wall. Both numbers live here rather than with the signage,
# because the concrete has to be poured around them.
const RIBBON_HEIGHT: float = 0.55
# Gap between the strip and the upper deck's lip above it. The board hangs from
# the TOP of the fascia rather than the middle of it — that is where a real one
# goes, and on a fascia tall enough to be a storey it also leaves the lower half
# of the wall free for the concourse portals.
const RIBBON_FASCIA_MARGIN: float = 0.25


func _init(spec: ArenaBowlSpec, path: ArenaBowlPath) -> void:
	_spec = spec
	_path = path


# ── Row placement ────────────────────────────────────────────────────────────

func lower_row_count() -> int:
	return _spec.num_terraces


func upper_row_count() -> int:
	return _spec.upper_terraces


# Outward offset of lower-bowl row `i`'s inner (rink-facing) edge.
func lower_row_offset(i: int) -> float:
	return _spec.base_outward_offset + i * _spec.tread_depth


func lower_row_y(i: int) -> float:
	return _spec.stands_base_y + i * _spec.riser_height


func upper_row_offset(j: int) -> float:
	return upper_deck_inner_offset() + j * _spec.tread_depth


func upper_row_y(j: int) -> float:
	return upper_deck_base_y() + j * _spec.upper_riser_height


# Where an occupant (or the seat under them) sits on a row: inset slightly
# outward from the tread's inner edge so their feet aren't on the riser corner.
func seat_inset() -> float:
	return _spec.spectator_inset_from_riser


# ── Derived deck geometry ────────────────────────────────────────────────────

# Tread height of the lower bowl's back row — also the walkway level.
func lower_top_tread_y() -> float:
	return _spec.stands_base_y + (_spec.num_terraces - 1) * _spec.riser_height


# Outward offset of the upper deck's first row (= the fascia ring).
func upper_deck_inner_offset() -> float:
	return _spec.base_outward_offset + _spec.num_terraces * _spec.tread_depth \
			+ _spec.walkway_depth


# Tread height of the upper deck's first row (= the fascia top).
func upper_deck_base_y() -> float:
	return lower_top_tread_y() + _spec.upper_deck_rise


# Outward offset of the shell wall: behind the upper deck's back row, or
# straight behind the walkway when the deck is disabled.
func shell_offset() -> float:
	return upper_deck_inner_offset() + _spec.upper_terraces * _spec.tread_depth


# Tread height of the very back spectator row, whichever deck that is on.
func top_tread_y() -> float:
	if _spec.upper_terraces > 0:
		return upper_deck_base_y() \
				+ (_spec.upper_terraces - 1) * _spec.upper_riser_height
	return lower_top_tread_y()


# ── Rinkside wells ───────────────────────────────────────────────────────────

# Floor height of row `row` at `p`. Inside a rinkside furniture cutout every
# cleared row is one flat well at the bowl's base, so the people working there
# share a floor with the furniture they work at; everywhere else it is that
# row's own tread. A real rink pours a flat bench area and starts the seating
# rake behind it — terracing straight through would stand a coach half a metre
# above the bench they are leaning on.
# `p` is (x, z) packed as Vector2(x, y), matching ArenaRinksideLayout.
func row_floor_y(row: int, p: Vector2) -> float:
	if ArenaRinksideLayout.in_bench_zone(row, p):
		return _spec.stands_base_y
	return _spec.stands_base_y + float(row) * _spec.riser_height


# Bottom of row `row`'s riser at `p`: the floor of the row in front of it, which
# is what makes the row behind a well carry the whole rise out of it in one step.
# Row 0 has no row in front — its riser is the bowl's own front face.
func riser_bottom_y(row: int, p: Vector2) -> float:
	if row == 0:
		return _spec.stands_base_y - _spec.riser_height
	return row_floor_y(row - 1, p)


# Floor height for someone standing `beyond` metres past the terraces' inner
# edge, at (x, z). Staff stand about a metre back from the furniture they work
# at, which is past the first tread — inside a cutout that is still the well's
# floor, so they end up on the same level as that furniture rather than a riser
# above it.
func floor_y_at(beyond: float, p: Vector2) -> float:
	var row: int = clampi(floori(beyond / _spec.tread_depth), 0,
			maxi(_spec.num_terraces - 1, 0))
	return row_floor_y(row, p)


# ── Vomitories ───────────────────────────────────────────────────────────────

func vomitories_wanted() -> bool:
	return _spec.vomitories_enabled and _spec.num_aisles > 0 \
			and _spec.vomitory_width > 0.0 and _spec.vomitory_height > 0.0


# Top of the lower bowl's portals. They share the fascia with the ribbon board,
# which hangs under the upper deck's lip, so the lintel stops clear of it. A
# fascia too short for both (a shallow `upper_deck_rise`) yields the wall to the
# ribbon and gets no portals — the caller checks for that by comparing this
# against the walkway height.
func fascia_portal_head() -> float:
	if not vomitories_wanted():
		return -INF
	return minf(lower_top_tread_y() + _spec.vomitory_height,
			upper_deck_base_y() - RIBBON_HEIGHT - RIBBON_FASCIA_MARGIN * 2.0)


# True where a wall is a doorway rather than a wall. Shares the aisles' spacing
# so a portal lands at the head of every stairway, but takes its own width — a
# vomitory is wider than the steps that feed it.
func in_vomitory(s: float) -> bool:
	if not vomitories_wanted():
		return false
	var seg: float = _path.base_path_length() / float(_spec.num_aisles)
	var into: float = fposmod(s, seg)
	return minf(into, seg - into) < _spec.vomitory_width * 0.5


# Per-segment: is the wall between point i and i+1 a doorway? Shared by the
# shell mesh and the tunnels so the hole and what fills it can never disagree.
func shell_cut_flags(wall: PackedVector2Array) -> PackedByteArray:
	var count: int = wall.size()
	var cut := PackedByteArray()
	cut.resize(count)
	for i: int in count:
		var mid: Vector2 = (wall[i] + wall[(i + 1) % count]) * 0.5
		cut[i] = 1 if in_vomitory(_path.base_path_s(mid)) else 0
	return cut
