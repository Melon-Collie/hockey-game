extends GutTest

# FaceoffDrawRules — pure math for the faceoff draw (rolling-peak buffer + timing).

# ── decay_peak_speed ─────────────────────────────────────────────────────────

func test_fresh_crest_captures_current_speed() -> void:
	# Live blade faster than the decayed peak → the crest is the current speed.
	var result: float = FaceoffDrawRules.decay_peak_speed(2.0, 5.0, 10.0, 1.0 / 120.0)
	assert_almost_eq(result, 5.0, 0.001, "a faster live sweep becomes the new peak")

func test_peak_bleeds_off_when_no_new_crest() -> void:
	# Live blade slow, so the retained peak decays by decay_per_sec * delta.
	var result: float = FaceoffDrawRules.decay_peak_speed(5.0, 0.0, 10.0, 0.1)
	assert_almost_eq(result, 4.0, 0.001, "peak sheds decay_per_sec*delta with no fresh crest")

func test_peak_never_goes_below_current() -> void:
	# Even mid-decay, a current sweep at least holds the floor.
	var result: float = FaceoffDrawRules.decay_peak_speed(5.0, 4.5, 10.0, 0.1)
	assert_almost_eq(result, 4.5, 0.001, "current speed floors the decayed peak")

func test_a_hard_swing_is_remembered_briefly() -> void:
	# A 6 m/s crest at 12 m/s/s decay still reads ~4.8 m/s an eighth-second later,
	# so a swipe that crests a few ticks before contact still lands as a strong draw.
	var peak: float = 6.0
	for i in range(15):  # 15 ticks @ 120 Hz ≈ 0.125 s of no new crest
		peak = FaceoffDrawRules.decay_peak_speed(peak, 0.0, 12.0, 1.0 / 120.0)
	assert_true(peak > 4.0, "a hard swipe stays strong across the buffer window")

# ── timing_weight ────────────────────────────────────────────────────────────

func test_crest_before_drop_is_neutral() -> void:
	# Early swings aren't punished — they just don't earn the bonus.
	assert_almost_eq(FaceoffDrawRules.timing_weight(-0.1, 0.35, 0.4, 0.7), 1.0, 0.001)
	assert_almost_eq(FaceoffDrawRules.timing_weight(0.0, 0.35, 0.4, 0.7), 1.0, 0.001)

func test_crest_on_drop_gets_full_bonus() -> void:
	# Crest a hair after the drop → the peak reward (1.0 + bonus).
	var w: float = FaceoffDrawRules.timing_weight(0.0001, 0.35, 0.4, 0.7)
	assert_almost_eq(w, 1.4, 0.01, "reacting on the drop earns the full bonus")

func test_late_stab_eases_to_min_weight() -> void:
	# A crest at/after the miss window is floored at min_weight.
	assert_almost_eq(FaceoffDrawRules.timing_weight(0.35, 0.35, 0.4, 0.7), 0.7, 0.001)
	assert_almost_eq(FaceoffDrawRules.timing_weight(1.0, 0.35, 0.4, 0.7), 0.7, 0.001)

func test_timing_decays_monotonically_after_drop() -> void:
	var early: float = FaceoffDrawRules.timing_weight(0.05, 0.35, 0.4, 0.7)
	var mid: float = FaceoffDrawRules.timing_weight(0.175, 0.35, 0.4, 0.7)
	var late: float = FaceoffDrawRules.timing_weight(0.30, 0.35, 0.4, 0.7)
	assert_true(early > mid and mid > late, "the bonus eases down the later you crest")

func test_zero_miss_window_falls_to_min() -> void:
	# Degenerate config guard: no window means any post-drop crest is a floor weight.
	assert_almost_eq(FaceoffDrawRules.timing_weight(0.01, 0.0, 0.4, 0.7), 0.7, 0.001)
