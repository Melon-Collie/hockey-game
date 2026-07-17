extends GutTest

# PuckHandoffRules — pure math for the trajectory-prediction → interpolation
# handoff. timeline_lead sizes the temporary render-time lead by projecting the
# live (predicted) puck onto the host trajectory through the newest buffered
# sample; needs_hard_snap decomposes smoother error into along-track (expected
# timeline offset — never a teleport) and cross-track (genuine divergence —
# snap at the classic distance). These tests pin the projection geometry, the
# floor/cap, the low-speed degradations, and the decomposition thresholds.

const MAX_LEAD: float = 0.35
const MIN_SPEED: float = 2.0
const SNAP_DIST: float = 2.0
const ALONG_TIME: float = 0.3


# ── timeline_lead ─────────────────────────────────────────────────────────────

func test_lead_matches_along_track_gap() -> void:
	# Newest sample at ts 10.0, puck flying +X at 20 m/s. Live puck is 2 m
	# further along the trajectory → the matching host instant is 10.0 + 0.1 s.
	# With the base interp render time at 9.95, the lead is 0.15 s.
	var lead: float = PuckHandoffRules.timeline_lead(
			Vector3(12.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0),
			10.0, 9.95, MAX_LEAD, MIN_SPEED)
	assert_almost_eq(lead, 0.15, 0.0001,
			"lead = (newest_ts + along_m/speed) - base_render_time")

func test_lead_ignores_cross_track_offset() -> void:
	# Same along-track position, but the live puck is 1.5 m off to the side
	# (a bounce that differed). The projection reads only the along component —
	# cross-track error is the position smoother's job, not the slew's.
	var straight: float = PuckHandoffRules.timeline_lead(
			Vector3(12.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0),
			10.0, 9.95, MAX_LEAD, MIN_SPEED)
	var offset: float = PuckHandoffRules.timeline_lead(
			Vector3(12.0, 0.0, 1.5), Vector3(10.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0),
			10.0, 9.95, MAX_LEAD, MIN_SPEED)
	assert_almost_eq(offset, straight, 0.0001,
			"perpendicular offset must not change the timeline lead")

func test_lead_floors_at_zero_when_live_puck_is_behind() -> void:
	# Live puck projects BEHIND the interp render point — no slew needed; a
	# negative lead (rendering extra-far in the past) would be nonsense.
	var lead: float = PuckHandoffRules.timeline_lead(
			Vector3(9.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0),
			10.0, 10.2, MAX_LEAD, MIN_SPEED)
	assert_almost_eq(lead, 0.0, 0.0001, "behind the interp point → lead 0")

func test_lead_caps_at_max() -> void:
	# A wildly divergent bounce projects far up the host line — the cap bounds
	# the slew and leaves the rest to the cross-track smoother.
	var lead: float = PuckHandoffRules.timeline_lead(
			Vector3(40.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0),
			10.0, 9.95, MAX_LEAD, MIN_SPEED)
	assert_almost_eq(lead, MAX_LEAD, 0.0001, "lead clamps to max_lead")

func test_lead_zero_below_min_speed() -> void:
	# A nearly-stopped puck has no meaningful trajectory direction (and a tiny
	# timeline gap) — no slew.
	var lead: float = PuckHandoffRules.timeline_lead(
			Vector3(12.0, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), Vector3(0.5, 0.0, 0.0),
			10.0, 9.95, MAX_LEAD, MIN_SPEED)
	assert_almost_eq(lead, 0.0, 0.0001, "below min_speed → no slew")


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
