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

# ── bot_draw_heading ─────────────────────────────────────────────────────────

func test_zero_lateral_bias_is_straight_back() -> void:
	# Team 0 center behind the dot pulls toward +Z (own zone); no angle applied.
	var h: Vector3 = FaceoffDrawRules.bot_draw_heading(Vector3(0, 0, 2), true, 0.0)
	assert_almost_eq(h.x, 0.0, 0.001, "no lateral component at zero bias")
	assert_almost_eq(h.z, 1.0, 0.001, "pure straight-back toward own zone")

func test_lefty_pulls_to_its_left() -> void:
	# Team 0 center (own zone +Z, faces -Z). A lefty pulls to their LEFT, which is
	# -X when facing -Z, so the draw carries a -X component.
	var h: Vector3 = FaceoffDrawRules.bot_draw_heading(Vector3(0, 0, 2), true, 0.7)
	assert_true(h.x < 0.0, "left-handed center draws to its left")
	assert_true(h.z > 0.0, "still pulls back toward own zone")

func test_righty_pulls_to_its_right() -> void:
	var h: Vector3 = FaceoffDrawRules.bot_draw_heading(Vector3(0, 0, 2), false, 0.7)
	assert_true(h.x > 0.0, "right-handed center draws to its right")
	assert_true(h.z > 0.0, "still pulls back toward own zone")

func test_draw_side_mirrors_with_team_facing() -> void:
	# Team 1 center sits on -Z and faces +Z, so its left is +X. A lefty there
	# draws to +X — the mirror of the team 0 lefty, as it should on the other dot.
	var h: Vector3 = FaceoffDrawRules.bot_draw_heading(Vector3(0, 0, -2), true, 0.7)
	assert_true(h.x > 0.0, "team 1 lefty pulls to its left (+X, mirror of team 0)")
	assert_true(h.z < 0.0, "pulls back toward its own zone (-Z)")

func test_degenerate_back_dir_returns_zero() -> void:
	assert_eq(FaceoffDrawRules.bot_draw_heading(Vector3.ZERO, true, 0.7), Vector3.ZERO)
