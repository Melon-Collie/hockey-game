extends GutTest

# NetworkTelemetry folds per-frame samples into per-window metrics. Two of those
# counters — extrapolation and reconcile — were sampled once per RENDERED frame,
# so their raw per-second rates scaled with the client's framerate: a 240fps
# client counted ~4x a 60fps client for identical buffer health, making the raw
# numbers uncomparable across machines (the exact confound seen in playtest rows
# where one tester read extrapolation 192/s and another 58/s for the same near-
# continuous extrapolation).
#
# extrapolation_pct (share of frames) and client_fps normalize that out. These
# tests pin the framerate-independence and guard the arithmetic.

var _saved_instance: NetworkTelemetry = null

func before_each() -> void:
	_saved_instance = NetworkTelemetry.instance

func after_each() -> void:
	NetworkTelemetry.instance = _saved_instance

# Run one 1 s window: `frames` observe_actors calls, the first `extrapolating`
# of them flagged extrapolating, then roll the window over. Returns the telemetry
# so callers can read the published metrics.
func _run_window(frames: int, extrapolating: int) -> NetworkTelemetry:
	var t := NetworkTelemetry.new()
	NetworkTelemetry.instance = t
	for i: int in frames:
		t.observe_actors(3, 10, 0, i < extrapolating)
	t.tick(1.0)  # exactly one 1 s window
	return t


func test_extrapolation_pct_is_framerate_independent() -> void:
	# Same buffer health (75% of frames extrapolating) sampled at 120fps and 60fps.
	var hi := _run_window(120, 90)
	var lo := _run_window(60, 45)
	# The normalized fraction is identical — that's the whole point.
	assert_almost_eq(hi.extrapolation_pct, 75.0, 0.001)
	assert_almost_eq(lo.extrapolation_pct, 75.0, 0.001)
	# client_fps surfaces the framerate that was confounding the raw rate.
	assert_almost_eq(hi.client_fps, 120.0, 0.001)
	assert_almost_eq(lo.client_fps, 60.0, 0.001)
	# The RAW per-sec rate is the misleading one: 2x apart for identical health.
	assert_almost_eq(hi.extrapolation_per_sec, 90.0, 0.001)
	assert_almost_eq(lo.extrapolation_per_sec, 45.0, 0.001)


func test_no_extrapolation_reads_zero_pct() -> void:
	var t := _run_window(120, 0)
	assert_almost_eq(t.extrapolation_pct, 0.0, 0.001)
	assert_almost_eq(t.client_fps, 120.0, 0.001)


func test_all_frames_extrapolating_reads_100_pct() -> void:
	var t := _run_window(90, 90)
	assert_almost_eq(t.extrapolation_pct, 100.0, 0.001)


func test_zero_frames_does_not_divide_by_zero() -> void:
	# A window with no observe_actors calls (e.g. offline / no actors) must not
	# NaN the fraction — guard the _frame_count == 0 denominator.
	var t := NetworkTelemetry.new()
	NetworkTelemetry.instance = t
	t.tick(1.0)
	assert_eq(t.extrapolation_pct, 0.0)
	assert_eq(t.client_fps, 0.0)


func test_pct_and_fps_fold_into_session() -> void:
	# The window metrics must reach the session summary (and thus the Supabase row)
	# as extrapolation_pct_* / client_fps_* keys.
	var t := _run_window(120, 60)
	var d: Dictionary = t.session.to_dict()
	assert_true(d.has("extrapolation_pct_avg"), "extrapolation_pct must fold into the session row")
	assert_true(d.has("client_fps_avg"), "client_fps must fold into the session row")
	assert_true(d.has("client_fps_min"), "client_fps is a MIN_KEY — must carry a session minimum")
	assert_almost_eq(float(d["extrapolation_pct_avg"]), 50.0, 0.001)
