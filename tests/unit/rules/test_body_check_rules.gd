extends GutTest

# BodyCheckRules — pure stagger/stamina-bite math for body checks. The victim
# impulse magnitude drives a 0..1 intensity that scales both the stagger window
# and the stamina drain; the per-tick thrust penalty eases back as the timer
# decays. These tests pin the normalization, the endpoints, and the coupling
# between hit strength and recovery-window length.

var _cfg: BodyCheckRules.Config

func before_each() -> void:
	_cfg = BodyCheckRules.Config.new()
	_cfg.min_impulse = 3.0
	_cfg.ref_impulse = 9.0
	_cfg.max_stagger_seconds = 1.0
	_cfg.max_stamina_drain = 0.35
	_cfg.max_thrust_penalty = 0.5


# ── intensity ─────────────────────────────────────────────────────────────────

func test_intensity_zero_at_or_below_min() -> void:
	assert_almost_eq(BodyCheckRules.intensity(3.0, _cfg), 0.0, 0.0001, "at min → 0")
	assert_almost_eq(BodyCheckRules.intensity(1.0, _cfg), 0.0, 0.0001, "below min clamps to 0")

func test_intensity_full_at_or_above_ref() -> void:
	assert_almost_eq(BodyCheckRules.intensity(9.0, _cfg), 1.0, 0.0001, "at ref → 1")
	assert_almost_eq(BodyCheckRules.intensity(20.0, _cfg), 1.0, 0.0001, "above ref clamps to 1")

func test_intensity_linear_midpoint() -> void:
	# halfway between 3 and 9 is 6 → 0.5
	assert_almost_eq(BodyCheckRules.intensity(6.0, _cfg), 0.5, 0.0001, "midpoint → 0.5")

func test_intensity_degenerate_config_is_safe() -> void:
	_cfg.ref_impulse = _cfg.min_impulse
	assert_almost_eq(BodyCheckRules.intensity(10.0, _cfg), 0.0, 0.0001, "ref<=min never divides by zero")


# ── stagger_seconds_from_impulse ──────────────────────────────────────────────

func test_no_stagger_for_trivial_bump() -> void:
	assert_almost_eq(BodyCheckRules.stagger_seconds_from_impulse(2.0, _cfg), 0.0, 0.0001,
			"below min → no stagger window")

func test_stagger_scales_with_strength() -> void:
	var medium: float = BodyCheckRules.stagger_seconds_from_impulse(6.0, _cfg)
	var hard: float = BodyCheckRules.stagger_seconds_from_impulse(9.0, _cfg)
	assert_almost_eq(medium, 0.5, 0.0001, "midpoint hit → half window")
	assert_almost_eq(hard, 1.0, 0.0001, "full hit → full window")
	assert_gt(hard, medium, "harder hit → longer recovery window")


# ── incremental_stamina_drain ─────────────────────────────────────────────────

func test_clean_hit_from_settled_bites_full_intensity() -> void:
	# prev_stagger_timer 0 → full intensity-scaled drain (same as a from-zero bite).
	assert_almost_eq(BodyCheckRules.incremental_stamina_drain(0.0, 3.0, _cfg), 0.0, 0.0001, "min → no drain")
	assert_almost_eq(BodyCheckRules.incremental_stamina_drain(0.0, 9.0, _cfg), 0.35, 0.0001, "full → max drain")
	assert_almost_eq(BodyCheckRules.incremental_stamina_drain(0.0, 6.0, _cfg), 0.175, 0.0001, "midpoint → half drain")

func test_no_drain_when_hit_not_harder_than_residual() -> void:
	# A full hit lands a 1.0s window; a follow-up no harder than the residual bites nothing.
	assert_almost_eq(BodyCheckRules.incremental_stamina_drain(1.0, 9.0, _cfg), 0.0, 0.0001,
			"equal-strength re-hit during stagger → no extra drain")
	assert_almost_eq(BodyCheckRules.incremental_stamina_drain(0.6, 6.0, _cfg), 0.0, 0.0001,
			"weaker re-hit than residual → no extra drain")

func test_sustained_contact_only_tops_up() -> void:
	# A full hit (add=1.0s) one decay-tick into an existing 0.99s stagger charges
	# only the 0.01s top-up: (1.0-0.99)/1.0 * 0.35.
	assert_almost_eq(BodyCheckRules.incremental_stamina_drain(0.99, 9.0, _cfg), 0.0035, 0.0001,
			"sustained contact bites only the incremental severity")


# ── thrust_mult ───────────────────────────────────────────────────────────────

func test_thrust_unpenalized_when_not_staggered() -> void:
	assert_almost_eq(BodyCheckRules.thrust_mult(0.0, _cfg), 1.0, 0.0001, "no stagger → full thrust")

func test_thrust_penalty_peaks_at_full_window() -> void:
	# full window remaining → 1 - 1.0*0.5 = 0.5
	assert_almost_eq(BodyCheckRules.thrust_mult(1.0, _cfg), 0.5, 0.0001, "full stagger → half thrust")

func test_thrust_penalty_eases_back_as_timer_decays() -> void:
	# half window remaining → 1 - 0.5*0.5 = 0.75
	assert_almost_eq(BodyCheckRules.thrust_mult(0.5, _cfg), 0.75, 0.0001, "decayed stagger → partial penalty")
	assert_gt(BodyCheckRules.thrust_mult(0.25, _cfg), BodyCheckRules.thrust_mult(0.75, _cfg),
			"less time remaining → smaller penalty")

func test_thrust_mult_clamps_overlong_timer() -> void:
	# a timer past the reference window still caps the penalty at the peak
	assert_almost_eq(BodyCheckRules.thrust_mult(5.0, _cfg), 0.5, 0.0001, "over-window timer caps at peak penalty")
