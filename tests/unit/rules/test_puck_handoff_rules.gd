extends GutTest

# PuckHandoffRules — the loose puck's velocity-aware snap decision.
# needs_hard_snap decomposes smoother error into along-track (expected
# timeline offset — never a teleport) and cross-track (genuine divergence —
# snap at the classic distance). These tests pin the low-speed degradation and
# the decomposition thresholds. (timeline_lead, the old trajectory-mode →
# interpolation render-time slew, was deleted with Phase 4b — every loose-puck
# target now sits at ~host present, so there is no cross-timeline handoff.)

const MIN_SPEED: float = 2.0
const SNAP_DIST: float = 2.0
const ALONG_TIME: float = 0.3


# ── needs_hard_snap ───────────────────────────────────────────────────────────

func test_along_track_error_within_velocity_budget_does_not_snap() -> void:
	# 25 m/s puck, 3 m of pure along-track error — well past the static 2 m snap
	# distance, but under 25 × 0.3 = 7.5 m of expected timeline offset. The old
	# distance-only check teleported exactly this case on every shot handoff.
	assert_false(PuckHandoffRules.needs_hard_snap(
			Vector3(3.0, 0.0, 0.0), Vector3(25.0, 0.0, 0.0),
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"along-track error under speed × along_snap_time must not snap")

func test_along_track_error_beyond_velocity_budget_snaps() -> void:
	assert_true(PuckHandoffRules.needs_hard_snap(
			Vector3(8.0, 0.0, 0.0), Vector3(25.0, 0.0, 0.0),
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"8 m along-track at 25 m/s exceeds the 7.5 m budget → snap")

func test_along_track_budget_never_below_snap_dist() -> void:
	# At 5 m/s the velocity budget (1.5 m) is below snap_dist; the static
	# distance still governs so slow pucks keep the classic 2 m tolerance.
	assert_false(PuckHandoffRules.needs_hard_snap(
			Vector3(1.8, 0.0, 0.0), Vector3(5.0, 0.0, 0.0),
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"along-track under snap_dist never snaps regardless of speed")

func test_cross_track_error_snaps_at_snap_dist() -> void:
	# Trajectory direction is wrong by > snap_dist — a bounce that genuinely
	# differed. Speed does not buy cross-track tolerance.
	assert_true(PuckHandoffRules.needs_hard_snap(
			Vector3(0.0, 0.0, 2.5), Vector3(25.0, 0.0, 0.0),
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"cross-track error past snap_dist → snap even on a fast puck")
	assert_false(PuckHandoffRules.needs_hard_snap(
			Vector3(0.0, 0.0, 1.5), Vector3(25.0, 0.0, 0.0),
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"cross-track error under snap_dist stays with the smoother")

func test_mixed_error_judged_per_component() -> void:
	# 3 m along (within the fast budget) + 1 m cross (under snap_dist) — both
	# components tolerable even though the total distance (~3.16 m) exceeds the
	# static snap distance.
	assert_false(PuckHandoffRules.needs_hard_snap(
			Vector3(3.0, 0.0, 1.0), Vector3(25.0, 0.0, 0.0),
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"components within their own budgets → no snap")

func test_low_speed_falls_back_to_distance_check() -> void:
	# At rest (faceoff/goal reset teleports) the decomposition is meaningless;
	# the plain distance check must still catch the teleport.
	assert_true(PuckHandoffRules.needs_hard_snap(
			Vector3(2.5, 0.0, 0.0), Vector3.ZERO,
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"below min_speed, distance > snap_dist → snap")
	assert_false(PuckHandoffRules.needs_hard_snap(
			Vector3(1.5, 0.0, 0.0), Vector3.ZERO,
			SNAP_DIST, ALONG_TIME, MIN_SPEED),
			"below min_speed, distance under snap_dist → no snap")
