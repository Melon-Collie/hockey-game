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

func test_total_keys_emit_session_sum_only() -> void:
	# Rare-event tripwires (hard snaps, blade jumps) observe per-window COUNTS
	# and ship a single session total — no max/avg pair that would smear a
	# handful of discrete events into a meaningless rate.
	var s := _make()
	s.observe({"puck_hard_snaps": 2.0})
	s.observe({"puck_hard_snaps": 0.0})
	s.observe({"puck_hard_snaps": 1.0})
	var d := s.to_dict()
	assert_eq(d["puck_hard_snaps_total"], 3.0)
	assert_false(d.has("puck_hard_snaps_max"))
	assert_false(d.has("puck_hard_snaps_avg"))
	assert_false(d.has("puck_hard_snaps_min"))

func test_blade_jumps_is_a_total_key() -> void:
	var s := _make()
	s.observe({"blade_jumps": 1.0})
	s.observe({"blade_jumps": 4.0})
	assert_eq(s.to_dict()["blade_jumps_total"], 5.0)

func test_buffer_depths_are_min_keys() -> void:
	# Interp buffers running dry (lower) is the bad direction — the session
	# minimum is the diagnostic extreme.
	var s := _make()
	s.observe({"buffer_depth_skater": 3.0, "buffer_depth_puck": 4.0})
	s.observe({"buffer_depth_skater": 0.0, "buffer_depth_puck": 2.0})
	var d := s.to_dict()
	assert_eq(d["buffer_depth_skater_min"], 0.0)
	assert_eq(d["buffer_depth_puck_min"], 2.0)

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

func test_auto_marker_recorded_with_trigger_and_timestamp() -> void:
	var s := _make()
	s.record_auto_marker(42.0, "puck_hard_snaps", {"puck_mode": "trajectory"})
	assert_eq(s.auto_marker_count, 1)
	var markers: Array = s.to_dict()["auto_markers"]
	assert_eq(markers.size(), 1)
	assert_eq(markers[0]["trigger"], "puck_hard_snaps")
	assert_eq(markers[0]["at_sec"], 42.0)
	assert_eq(markers[0]["puck_mode"], "trajectory")

func test_auto_marker_per_trigger_cooldown() -> void:
	# A sustained failure records its ONSET, not one marker per second; an
	# independent trigger is not throttled by another's cooldown.
	var s := _make()
	s.record_auto_marker(10.0, "host_stall", {})
	s.record_auto_marker(11.0, "host_stall", {})  # inside cooldown — dropped
	s.record_auto_marker(12.0, "extrapolation", {})  # different trigger — fires
	s.record_auto_marker(10.0 + NetworkSessionSummary.AUTO_MARKER_COOLDOWN_SEC, "host_stall", {})
	assert_eq(s.auto_marker_count, 3)
	assert_eq((s.to_dict()["auto_markers"] as Array).size(), 3)

func test_auto_marker_count_climbs_past_storage_cap() -> void:
	var s := _make()
	var t: float = 0.0
	for i in NetworkSessionSummary.MAX_AUTO_MARKERS + 5:
		s.record_auto_marker(t, "host_stall", {})
		t += NetworkSessionSummary.AUTO_MARKER_COOLDOWN_SEC
	assert_eq((s.to_dict()["auto_markers"] as Array).size(), NetworkSessionSummary.MAX_AUTO_MARKERS)
	assert_eq(s.auto_marker_count, NetworkSessionSummary.MAX_AUTO_MARKERS + 5)

func test_history_attached_within_budget_only() -> void:
	# History is the bulky part of a marker; only the first
	# MAX_MARKERS_WITH_HISTORY markers (across both kinds) carry it, keeping
	# the row under the table's jsonb size cap.
	var s := _make()
	var history: Array[Dictionary] = [{"at_sec": 1.0, "rtt_ms": 50.0}]
	for i in NetworkSessionSummary.MAX_MARKERS_WITH_HISTORY:
		s.record_felt_lag(float(i), {}, history)
	s.record_felt_lag(99.0, {}, history)  # budget spent — lightweight marker
	var markers: Array = s.to_dict()["felt_lag_markers"]
	assert_true(markers[0].has("history"))
	assert_eq((markers[0]["history"] as Array)[0]["rtt_ms"], 50.0)
	assert_true(markers[NetworkSessionSummary.MAX_MARKERS_WITH_HISTORY - 1].has("history"))
	assert_false(markers[NetworkSessionSummary.MAX_MARKERS_WITH_HISTORY].has("history"))

func test_history_budget_shared_across_marker_kinds() -> void:
	var s := _make()
	var history: Array[Dictionary] = [{"at_sec": 1.0}]
	for i in NetworkSessionSummary.MAX_MARKERS_WITH_HISTORY:
		s.record_felt_lag(float(i), {}, history)
	s.record_auto_marker(50.0, "host_stall", {}, history)
	var auto: Array = s.to_dict()["auto_markers"]
	assert_false(auto[0].has("history"))

func test_felt_lag_without_history_stays_lightweight() -> void:
	var s := _make()
	s.record_felt_lag(1.0, {"rtt_ms": 10.0})
	assert_false((s.to_dict()["felt_lag_markers"][0] as Dictionary).has("history"))

func test_marker_snapshot_is_copied_not_aliased() -> void:
	# record_felt_lag duplicates the snapshot; mutating the caller's dict after
	# must not change the stored marker.
	var s := _make()
	var snap := {"rtt_ms": 1.0}
	s.record_felt_lag(0.0, snap)
	snap["rtt_ms"] = 999.0
	assert_eq(s.to_dict()["felt_lag_markers"][0]["rtt_ms"], 1.0)
