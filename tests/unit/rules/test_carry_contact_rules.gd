extends GutTest

# CarryContactRules — the stroke solver for the motion-keyed stickhandling
# push model (docs/stickhandling-push-model-plan.md). Signs: v_perp is the
# blade-contact velocity along +face_normal; the returned side is where the
# blade sits, so it must trail the stroke (oppose v_perp). v_in is positive
# toward the body.

const FLIP: float = 0.8
const RAMP_MIN: float = 0.8
const RAMP_MAX: float = 2.5
const BAND: float = 0.15


# ── stroke_side ───────────────────────────────────────────────────────────────

func test_stroke_flips_blade_to_trailing_side() -> void:
	assert_eq(CarryContactRules.stroke_side(1, 2.0, FLIP), -1,
			"stroke along +face_normal puts the blade at -face_normal")
	assert_eq(CarryContactRules.stroke_side(-1, -2.0, FLIP), 1,
			"stroke along -face_normal puts the blade at +face_normal")


func test_below_flip_speed_holds_current_side() -> void:
	assert_eq(CarryContactRules.stroke_side(1, 0.5, FLIP), 1)
	assert_eq(CarryContactRules.stroke_side(-1, -0.5, FLIP), -1)
	assert_eq(CarryContactRules.stroke_side(1, 0.0, FLIP), 1,
			"rest is the cradle — no flip without a stroke")


func test_stroke_toward_held_side_is_a_no_op() -> void:
	# Blade already trails the motion — pushing harder must not flip it away.
	assert_eq(CarryContactRules.stroke_side(-1, 2.0, FLIP), -1)
	assert_eq(CarryContactRules.stroke_side(1, -2.0, FLIP), 1)


func test_threshold_is_the_hysteresis() -> void:
	# Magnitude wobbling around the bar with one sign never flip-flops; only a
	# genuine opposite stroke back above the bar flips again.
	var side: int = CarryContactRules.stroke_side(1, 0.9, FLIP)
	assert_eq(side, -1, "real stroke flips")
	side = CarryContactRules.stroke_side(side, 0.7, FLIP)
	assert_eq(side, -1, "sub-bar wobble holds")
	side = CarryContactRules.stroke_side(side, 1.1, FLIP)
	assert_eq(side, -1, "same-direction stroke holds")
	side = CarryContactRules.stroke_side(side, -0.9, FLIP)
	assert_eq(side, 1, "opposite stroke above the bar flips back")


func test_exactly_at_flip_speed_flips() -> void:
	assert_eq(CarryContactRules.stroke_side(1, FLIP, FLIP), -1)


# ── pull_gesture ──────────────────────────────────────────────────────────────

func test_pull_gesture_ramp_endpoints() -> void:
	assert_eq(CarryContactRules.pull_gesture(RAMP_MIN, RAMP_MIN, RAMP_MAX), 0.0)
	assert_eq(CarryContactRules.pull_gesture(RAMP_MAX, RAMP_MIN, RAMP_MAX), 1.0)
	assert_eq(CarryContactRules.pull_gesture(10.0, RAMP_MIN, RAMP_MAX), 1.0)


func test_pull_gesture_midpoint_and_monotonic() -> void:
	var mid: float = CarryContactRules.pull_gesture(
			(RAMP_MIN + RAMP_MAX) * 0.5, RAMP_MIN, RAMP_MAX)
	assert_almost_eq(mid, 0.5, 0.0001)
	var prev: float = -1.0
	for i in 10:
		var v: float = RAMP_MIN + (RAMP_MAX - RAMP_MIN) * float(i) / 9.0
		var g: float = CarryContactRules.pull_gesture(v, RAMP_MIN, RAMP_MAX)
		assert_true(g >= prev, "ramp must be monotonic")
		prev = g


func test_outward_push_never_engages_pull_grammar() -> void:
	assert_eq(CarryContactRules.pull_gesture(-3.0, RAMP_MIN, RAMP_MAX), 0.0)
	assert_eq(CarryContactRules.pull_gesture(0.0, RAMP_MIN, RAMP_MAX), 0.0)


# ── forehand_weight ───────────────────────────────────────────────────────────

func test_forehand_weight_extremes_and_centre() -> void:
	assert_eq(CarryContactRules.forehand_weight(0.5, BAND), 1.0,
			"deep forehand side — full toe drag")
	assert_eq(CarryContactRules.forehand_weight(-0.5, BAND), 0.0,
			"deep backhand side — full heel cradle")
	assert_almost_eq(CarryContactRules.forehand_weight(0.0, BAND), 0.5, 0.0001,
			"body centre splits the grammars")


func test_forehand_weight_blend_band_edges() -> void:
	assert_almost_eq(CarryContactRules.forehand_weight(BAND, BAND), 1.0, 0.0001)
	assert_almost_eq(CarryContactRules.forehand_weight(-BAND, BAND), 0.0, 0.0001)


func test_forehand_weight_zero_band_is_a_hard_split() -> void:
	assert_eq(CarryContactRules.forehand_weight(0.001, 0.0), 1.0)
	assert_eq(CarryContactRules.forehand_weight(-0.001, 0.0), 0.0)
	assert_eq(CarryContactRules.forehand_weight(0.0, 0.0), 1.0)
