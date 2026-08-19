class_name ArenaRinksideLayout

# Where the rinkside furniture stands, as numbers rather than as geometry.
#
# Its own file because three unrelated things need the same spans and none of
# them should have to know about the others: `ArenaRinkside` builds the
# furniture, `ArenaBowlRake` cuts the crowd and the terraces away from behind it,
# and `HockeyRink` treats the stretch of board a bench sits behind as a gate and
# a doorway rather than somewhere an ad can go.

# Player benches: two team benches on the +X side straddling center ice. 3v3
# fields no reserves, so they're empty furniture — the break in the crowd wall is
# what sells the rink.
const BENCH_CENTER_Z: float = 4.4    # bench centers at ±this along the boards
const BENCH_HALF_LEN: float = 3.0    # half-length of each bench along Z
const BENCH_SEAT_X_OFFSET: float = 0.33  # seat center outward of the first tread's inner edge
const BENCH_SEAT_HEIGHT: float = 0.46

# Penalty boxes and the off-ice officials between them, on the −X boards
# opposite the player benches — which is where a real rink puts them, and which
# is also the only stretch of this bowl that was an unbroken run of crowd. Two
# boxes flank centre ice with the timekeeper's table in the gap, so the whole
# assembly spans |z| < PENALTY_BOX_CENTER_Z + PENALTY_BOX_HALF_LEN.
const PENALTY_BOX_CENTER_Z: float = 2.9
const PENALTY_BOX_HALF_LEN: float = 1.7
const OFFICIALS_HALF_LEN: float = 1.0
const OFFICIALS_HEIGHT: float = 0.78
# Bench behind the officials' table, the crew's equivalent of the seat block a
# penalized player gets. Shallow enough to clear the table's own back face.
const OFFICIALS_SEAT_DEPTH: float = 0.36

# Outward of the furniture they work behind, so staff read as standing at it.
const STAFF_BEHIND_BENCH: float = 0.92
const STAFF_BEHIND_TABLE: float = 0.88

# Spectator rows cleared behind the glass, and how far past the furniture's own
# span the clearance runs.
const BENCH_CLEAR_ROWS: int = 2
const BENCH_CLEAR_MARGIN: float = 0.3


# True when a spectator slot falls inside a rinkside furniture cutout: the first
# BENCH_CLEAR_ROWS rows on either side of the bowl, along the full stretch the
# furniture occupies — the player benches on +X, the penalty boxes and officials'
# table on −X. Both spans include the GAP between their two halves, which is
# gate and staff area rather than seating; fans at ice level in that sliver read
# as people sitting between the benches.
# Sample points are (x, z) packed as Vector2(x, y).
static func in_bench_zone(row: int, p: Vector2) -> bool:
	if row >= BENCH_CLEAR_ROWS:
		return false
	if p.x >= 0.0:
		return absf(p.y) < BENCH_CENTER_Z + BENCH_HALF_LEN + BENCH_CLEAR_MARGIN
	return absf(p.y) < PENALTY_BOX_CENTER_Z + PENALTY_BOX_HALF_LEN + BENCH_CLEAR_MARGIN
