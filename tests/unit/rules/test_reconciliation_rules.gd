extends GutTest

# ReconciliationRules — threshold checks for deciding when to overwrite
# client-side prediction with server state.

# ── skater_needs_reconcile ───────────────────────────────────────────────────

func test_skater_no_reconcile_when_close() -> void:
	var result: bool = ReconciliationRules.skater_needs_reconcile(
		Vector3.ZERO, Vector3.ZERO,     # client pos + vel
		Vector3(0.01, 0, 0), Vector3.ZERO,  # server (tiny pos diff)
		0.05, 0.1)                      # thresholds
	assert_false(result, "0.01 pos error is under 0.05 threshold")

func test_skater_reconcile_when_position_exceeds_threshold() -> void:
	var result: bool = ReconciliationRules.skater_needs_reconcile(
		Vector3.ZERO, Vector3.ZERO,
		Vector3(0.2, 0, 0), Vector3.ZERO,
		0.05, 0.1)
	assert_true(result, "0.2 pos error exceeds 0.05")

func test_skater_reconcile_when_velocity_exceeds_threshold() -> void:
	var result: bool = ReconciliationRules.skater_needs_reconcile(
		Vector3.ZERO, Vector3.ZERO,
		Vector3.ZERO, Vector3(0.5, 0, 0),
		0.05, 0.1)
	assert_true(result, "0.5 vel error exceeds 0.1")

func test_skater_reconcile_at_exact_threshold() -> void:
	# Using >= semantics: exactly equal triggers reconcile
	var result: bool = ReconciliationRules.skater_needs_reconcile(
		Vector3.ZERO, Vector3.ZERO,
		Vector3(0.05, 0, 0), Vector3.ZERO,
		0.05, 0.1)
	assert_true(result, "equal to threshold counts as reconcile")

func test_skater_no_reconcile_when_both_under() -> void:
	var result: bool = ReconciliationRules.skater_needs_reconcile(
		Vector3(1, 0, 0), Vector3(2, 0, 0),
		Vector3(1.01, 0, 0), Vector3(2.05, 0, 0),
		0.05, 0.1)
	assert_false(result, "both deltas under thresholds → no reconcile")

# ── puck_needs_hard_snap ─────────────────────────────────────────────────────

func test_puck_no_snap_within_threshold() -> void:
	var result: bool = ReconciliationRules.puck_needs_hard_snap(
		Vector3.ZERO, Vector3(2, 0, 0), 3.0)
	assert_false(result, "2.0 error under 3.0 threshold")

func test_puck_snap_past_threshold() -> void:
	var result: bool = ReconciliationRules.puck_needs_hard_snap(
		Vector3.ZERO, Vector3(5, 0, 0), 3.0)
	assert_true(result, "5.0 error past 3.0 threshold")

func test_puck_no_snap_at_exact_threshold() -> void:
	# Using > semantics: exactly equal does NOT snap (only strictly greater)
	var result: bool = ReconciliationRules.puck_needs_hard_snap(
		Vector3.ZERO, Vector3(3, 0, 0), 3.0)
	assert_false(result, "strictly greater than threshold required")

# ── classify_match_miss ──────────────────────────────────────────────────────
# Epsilon used throughout: 1ms, matching PredictedState.TS_MATCH_EPSILON.

func test_miss_empty_history() -> void:
	# is_empty=true dominates regardless of the (unused) bound args.
	var r: int = ReconciliationRules.classify_match_miss(true, 0.0, 0.0, 5.0, 1e-3)
	assert_eq(r, ReconciliationRules.MatchMiss.EMPTY, "empty history → EMPTY")

func test_miss_older_than_oldest() -> void:
	# ack sits before the oldest kept prediction (cleared / over-trimmed).
	var r: int = ReconciliationRules.classify_match_miss(false, 10.0, 12.0, 9.0, 1e-3)
	assert_eq(r, ReconciliationRules.MatchMiss.OLDER, "ack < oldest → OLDER")

func test_miss_newer_than_newest() -> void:
	# ack sits after the newest prediction (not stored yet).
	var r: int = ReconciliationRules.classify_match_miss(false, 10.0, 12.0, 13.0, 1e-3)
	assert_eq(r, ReconciliationRules.MatchMiss.NEWER, "ack > newest → NEWER")

func test_miss_gap_between_bounds() -> void:
	# ack falls inside [oldest, newest] but find_at still missed → a real hole.
	var r: int = ReconciliationRules.classify_match_miss(false, 10.0, 12.0, 11.0, 1e-3)
	assert_eq(r, ReconciliationRules.MatchMiss.GAP, "ack between bounds → GAP")

func test_miss_within_epsilon_of_oldest_is_gap_not_older() -> void:
	# The epsilon band around a bound belongs to find_at (a match); a genuine miss
	# just inside it classifies as GAP, never OLDER/NEWER — so the band can't be
	# double-counted as "older/newer" when the real cause is a same-instant hole.
	var r: int = ReconciliationRules.classify_match_miss(false, 10.0, 12.0, 10.0 - 0.5e-3, 1e-3)
	assert_eq(r, ReconciliationRules.MatchMiss.GAP, "within epsilon below oldest → GAP")

func test_miss_within_epsilon_of_newest_is_gap_not_newer() -> void:
	var r: int = ReconciliationRules.classify_match_miss(false, 10.0, 12.0, 12.0 + 0.5e-3, 1e-3)
	assert_eq(r, ReconciliationRules.MatchMiss.GAP, "within epsilon above newest → GAP")
