extends GutTest

# XGShare — the cumulative expected-goals share curve behind the post-game
# analytics screen's share chart.

const _PERIOD_S: float = 300.0


func _shot(team: int, xg: float, period: int, clock_s: float,
		outcome: int = ShotEvent.Outcome.SAVED) -> ShotEvent:
	return ShotEvent.make(1, team, Vector3.ZERO, xg, outcome,
			ShotEvent.ShotType.SHOT, outcome != ShotEvent.Outcome.MISSED, period, clock_s)


func _typed(events: Array) -> Array[ShotEvent]:
	var out: Array[ShotEvent] = []
	for e: Variant in events:
		out.append(e as ShotEvent)
	return out


# ── Elapsed time ─────────────────────────────────────────────────────────────

func test_elapsed_counts_up_from_a_countdown_clock() -> void:
	# 4:00 remaining in P2 of 5-minute periods = 6:00 elapsed.
	assert_almost_eq(XGShare.elapsed_seconds(_shot(0, 0.1, 2, 240.0), _PERIOD_S),
			360.0, 0.001)


func test_elapsed_treats_the_opening_faceoff_as_zero() -> void:
	assert_almost_eq(XGShare.elapsed_seconds(_shot(0, 0.1, 1, _PERIOD_S), _PERIOD_S),
			0.0, 0.001)


# ── The share itself ─────────────────────────────────────────────────────────

func test_share_is_the_running_ratio_of_chance_quality() -> void:
	var data: Dictionary = XGShare.series(_typed([
		_shot(0, 0.30, 1, 290.0),   # home alone: 100%
		_shot(1, 0.30, 1, 280.0),   # matched:     50%
		_shot(1, 0.60, 1, 270.0),   # 0.3 vs 0.9:  25%
	]), _PERIOD_S)
	var shares: PackedFloat32Array = data["share"]
	assert_eq(shares.size(), 3)
	assert_almost_eq(shares[0], 1.0, 0.001)
	assert_almost_eq(shares[1], 0.5, 0.001)
	assert_almost_eq(shares[2], 0.25, 0.001)


func test_series_is_chronological_regardless_of_input_order() -> void:
	# The tracker buffers in resolution order, which is chronological, but a
	# reconstructed history (Supabase rows, a .mreplay footer) has no such
	# guarantee — the curve has to sort for itself or it draws backwards.
	var data: Dictionary = XGShare.series(_typed([
		_shot(1, 0.40, 3, 100.0),
		_shot(0, 0.40, 1, 200.0),
		_shot(0, 0.40, 2, 150.0),
	]), _PERIOD_S)
	var ts: PackedFloat32Array = data["t"]
	assert_eq(ts.size(), 3)
	assert_true(ts[0] < ts[1] and ts[1] < ts[2], "events must come out in time order")
	# Home takes the first two, so it leads 100% then 100%, then splits 2:1.
	var shares: PackedFloat32Array = data["share"]
	assert_almost_eq(shares[2], 2.0 / 3.0, 0.001)


func test_blocked_attempts_move_neither_side() -> void:
	# Fenwick convention: a blocked shot carries no xG, so it must not appear in
	# the series at all — including as a flat point, which would read as an event
	# that changed nothing rather than one that never counted.
	var data: Dictionary = XGShare.series(_typed([
		_shot(0, 0.50, 1, 290.0),
		_shot(1, 0.90, 1, 280.0, ShotEvent.Outcome.BLOCKED),
	]), _PERIOD_S)
	assert_eq((data["share"] as PackedFloat32Array).size(), 1)
	assert_almost_eq(XGShare.final_share(_typed([
		_shot(0, 0.50, 1, 290.0),
		_shot(1, 0.90, 1, 280.0, ShotEvent.Outcome.BLOCKED),
	])), 1.0, 0.001)


func test_goals_are_tagged_with_the_scoring_side() -> void:
	var data: Dictionary = XGShare.series(_typed([
		_shot(0, 0.20, 1, 290.0),
		_shot(1, 0.20, 1, 280.0, ShotEvent.Outcome.GOAL),
		_shot(0, 0.20, 1, 270.0, ShotEvent.Outcome.MISSED),
	]), _PERIOD_S)
	var goals: PackedInt32Array = data["goal_team"]
	assert_eq(goals[0], -1, "a save is not a goal")
	assert_eq(goals[1], 1, "the away goal is tagged to the away side")
	assert_eq(goals[2], -1, "a miss is not a goal")


# ── Degenerate inputs ────────────────────────────────────────────────────────

func test_no_shots_reports_an_even_game() -> void:
	# 0/0 is undefined; before anything has happened nobody deserves it more.
	assert_almost_eq(XGShare.final_share(_typed([])), XGShare.EVEN, 0.001)
	assert_eq((XGShare.series(_typed([]), _PERIOD_S)["t"] as PackedFloat32Array).size(), 0)


func test_zero_xg_shots_still_report_an_even_game() -> void:
	# Every attempt counted but none carried any danger — the denominator is
	# still zero, so this must not divide by it.
	assert_almost_eq(XGShare.final_share(_typed([
		_shot(0, 0.0, 1, 290.0), _shot(1, 0.0, 1, 280.0),
	])), XGShare.EVEN, 0.001)


func test_share_stays_bounded() -> void:
	# One-sided games are the point of the chart, but the curve is drawn against a
	# 0..1 axis, so the value can never leave it.
	var shares: PackedFloat32Array = XGShare.series(_typed([
		_shot(0, 2.5, 1, 290.0), _shot(0, 2.5, 1, 280.0),
	]), _PERIOD_S)["share"]
	assert_eq(shares.size(), 2)
	for s: float in shares:
		assert_between(s, 0.0, 1.0)


func test_final_share_matches_the_last_point_of_the_series() -> void:
	# The chart's end-of-game callout reads the curve's last value; the tape and
	# any prose read final_share. They cannot be allowed to disagree.
	var events: Array[ShotEvent] = _typed([
		_shot(0, 0.31, 1, 250.0),
		_shot(1, 0.12, 2, 100.0, ShotEvent.Outcome.GOAL),
		_shot(0, 0.07, 3, 40.0, ShotEvent.Outcome.MISSED),
	])
	var shares: PackedFloat32Array = XGShare.series(events, _PERIOD_S)["share"]
	assert_almost_eq(shares[shares.size() - 1], XGShare.final_share(events), 0.0001)
