extends GutTest

# NetworkSessionSummary — pure session-long fold of per-second telemetry into
# max / avg (+ min for MIN_KEYS) plus felt-lag markers.

func _make() -> NetworkSessionSummary:
	return NetworkSessionSummary.new()

func test_empty_has_no_data() -> void:
	var s := _make()
	assert_false(s.has_data())
	assert_eq(s.seconds, 0)

func test_single_observe_sets_max_and_avg() -> void:
	var s := _make()
	s.observe({"rtt_ms": 50.0})
	assert_true(s.has_data())
	var d := s.to_dict()
	assert_eq(d["rtt_ms_max"], 50.0)
	assert_eq(d["rtt_ms_avg"], 50.0)

func test_max_tracks_peak_avg_tracks_mean() -> void:
	var s := _make()
	s.observe({"rtt_ms": 40.0})
	s.observe({"rtt_ms": 80.0})
	s.observe({"rtt_ms": 60.0})
	var d := s.to_dict()
	assert_eq(d["rtt_ms_max"], 80.0)
	assert_almost_eq(float(d["rtt_ms_avg"]), 60.0, 0.001)

func test_min_emitted_only_for_min_keys() -> void:
	var s := _make()
	s.observe({"sim_rate_hz": 120.0, "rtt_ms": 30.0})
	s.observe({"sim_rate_hz": 90.0, "rtt_ms": 50.0})
	var d := s.to_dict()
	# sim_rate_hz is a MIN_KEY: its session minimum is the diagnostic extreme.
	assert_eq(d["sim_rate_hz_min"], 90.0)
	assert_eq(d["sim_rate_hz_max"], 120.0)
	# rtt_ms is not a MIN_KEY, so no _min column.
	assert_false(d.has("rtt_ms_min"))

func test_reconcile_match_pct_is_a_min_key() -> void:
	# Lower match % is the bad direction — confirm it carries a _min.
	var s := _make()
	s.observe({"reconcile_match_pct": 100.0})
	s.observe({"reconcile_match_pct": 70.0})
	var d := s.to_dict()
	assert_eq(d["reconcile_match_pct_min"], 70.0)

func test_client_fps_is_a_min_key() -> void:
	# Lower fps is the bad direction (worse felt smoothness), so keep the session
	# minimum — the worst framerate a tester dropped to.
	var s := _make()
	s.observe({"client_fps": 144.0})
	s.observe({"client_fps": 58.0})
	var d := s.to_dict()
	assert_eq(d["client_fps_min"], 58.0)
	assert_eq(d["client_fps_max"], 144.0)

func test_duration_counts_observed_windows() -> void:
	var s := _make()
	for _i in 5:
		s.observe({"rtt_ms": 10.0})
	assert_eq(s.seconds, 5)
	assert_eq(s.to_dict()["duration_sec"], 5)

func test_keys_appearing_later_still_average_over_full_session() -> void:
	# A metric that only shows up partway through (e.g. sim_rate omitted on a
	# client until it hosts) still divides by total seconds — documents the
	# averaging denominator so callers aren't surprised.
	var s := _make()
	s.observe({"rtt_ms": 10.0})
	s.observe({"rtt_ms": 10.0, "sim_rate_hz": 120.0})
	var d := s.to_dict()
	assert_almost_eq(float(d["sim_rate_hz_avg"]), 60.0, 0.001)

func test_felt_lag_marker_recorded_with_timestamp() -> void:
	var s := _make()
	s.record_felt_lag(12.5, {"rtt_ms": 99.0})
	assert_eq(s.felt_lag_count, 1)
	var markers: Array = s.to_dict()["felt_lag_markers"]
	assert_eq(markers.size(), 1)
	assert_eq(markers[0]["at_sec"], 12.5)
	assert_eq(markers[0]["rtt_ms"], 99.0)

func test_felt_lag_markers_capped_but_count_keeps_climbing() -> void:
	var s := _make()
	for i in NetworkSessionSummary.MAX_FELT_LAG_MARKERS + 10:
		s.record_felt_lag(float(i), {})
	var markers: Array = s.to_dict()["felt_lag_markers"]
	assert_eq(markers.size(), NetworkSessionSummary.MAX_FELT_LAG_MARKERS)
	assert_eq(s.felt_lag_count, NetworkSessionSummary.MAX_FELT_LAG_MARKERS + 10)

func test_marker_snapshot_is_copied_not_aliased() -> void:
	# record_felt_lag duplicates the snapshot; mutating the caller's dict after
	# must not change the stored marker.
	var s := _make()
	var snap := {"rtt_ms": 1.0}
	s.record_felt_lag(0.0, snap)
	snap["rtt_ms"] = 999.0
	assert_eq(s.to_dict()["felt_lag_markers"][0]["rtt_ms"], 1.0)
