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
	_cfg.knockdown_impulse = 11.0
	_cfg.knockdown_ref_impulse = 16.0
	_cfg.min_knockdown_seconds = 0.7
	_cfg.max_knockdown_seconds = 1.5


# ── knockdown_seconds_from_impulse ────────────────────────────────────────────

func test_no_knockdown_below_threshold() -> void:
	assert_almost_eq(BodyCheckRules.knockdown_seconds_from_impulse(9.0, _cfg), 0.0, 0.0001,
			"a hit that staggers but is below knockdown_impulse does not knock down")
	assert_almost_eq(BodyCheckRules.knockdown_seconds_from_impulse(10.99, _cfg), 0.0, 0.0001,
			"just below the threshold → no knockdown")

func test_knockdown_at_threshold_is_min_seconds() -> void:
	assert_almost_eq(BodyCheckRules.knockdown_seconds_from_impulse(11.0, _cfg), 0.7, 0.0001,
			"at the threshold → the minimum down time")

func test_knockdown_scales_to_max() -> void:
	assert_almost_eq(BodyCheckRules.knockdown_seconds_from_impulse(16.0, _cfg), 1.5, 0.0001,
			"at the reference impulse → the maximum down time")
	assert_almost_eq(BodyCheckRules.knockdown_seconds_from_impulse(30.0, _cfg), 1.5, 0.0001,
			"above the reference clamps to max")
	# Midpoint (13.5) → halfway between 0.7 and 1.5 = 1.1
	assert_almost_eq(BodyCheckRules.knockdown_seconds_from_impulse(13.5, _cfg), 1.1, 0.0001,
			"scales linearly between threshold and reference")

func test_knockdown_disabled_when_threshold_zero() -> void:
	_cfg.knockdown_impulse = 0.0
	assert_almost_eq(BodyCheckRules.knockdown_seconds_from_impulse(50.0, _cfg), 0.0, 0.0001,
			"knockdown_impulse 0 disables knockdowns entirely")


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


# ── puck_strip_impulse ──────────────────────────────────────────────────────────
# The strip decision must key off the SAME delivered impulse as the stagger —
# the real applied knockback |dvel_b|, reconstructed through the collision
# resolver's own victim_kick — so the transfer, both masses, and closing speed
# all move it and the reconstruction can never drift from the physics. (In v4 the
# transfer is flat across builds — 0.65 — so mass is the build differentiator; the
# transfer-scaling test below still pins the function's monotonicity in that arg.)

func test_puck_strip_impulse_matches_resolver_knockback() -> void:
	# Locks the identity against a LIVE SkaterCollisionRules.resolve contact:
	# the strip magnitude reconstructed from impact_force (= attacker_weight ×
	# closing) must equal the |dvel_b| the resolver actually applies for the
	# same closing speed, masses, and transfer.
	var att_weight: float = 1.18
	var vic_weight: float = 0.82
	var transfer: float = 0.55
	var out := SkaterCollisionRules.Result.new()
	SkaterCollisionRules.resolve(out,
			Vector3.ZERO, Vector3(7.0, 0.0, 0.0), att_weight, 0.42,
			Vector3(0.8, 0.0, 0.0), Vector3.ZERO, vic_weight, 0.42, transfer)
	assert_true(out.impulse_applied)
	var impact_force: float = att_weight * out.closing_speed
	assert_almost_eq(
			BodyCheckRules.puck_strip_impulse(
					impact_force, att_weight, transfer, vic_weight, 0.4, false),
			out.dvel_b.length(), 1e-5,
			"reconstruction must equal the applied knockback magnitude")

func test_puck_strip_impulse_scales_with_transfer() -> void:
	# Same hit, higher attacker transfer → more likely to strip (monotonic in the
	# transfer arg; in v4 the transfer is flat across builds, but the resolver term
	# still moves the strip magnitude).
	var high: float = BodyCheckRules.puck_strip_impulse(6.0, 1.0, 0.65, 1.0, 0.4, false)
	var low: float = BodyCheckRules.puck_strip_impulse(6.0, 1.0, 0.30, 1.0, 0.4, false)
	assert_gt(high, low, "higher transfer delivers a harder strip impulse")

func test_puck_strip_impulse_scales_inverse_with_victim_mass() -> void:
	# Same hit, heavier victim → harder to dislodge the puck.
	var light: float = BodyCheckRules.puck_strip_impulse(6.0, 1.0, 0.45, 0.82, 0.4, false)
	var heavy: float = BodyCheckRules.puck_strip_impulse(6.0, 1.0, 0.45, 1.18, 0.4, false)
	assert_gt(light, heavy, "a heavier victim absorbs more of the hit — smaller strip impulse")

func test_puck_strip_impulse_brace_reduces_when_braced() -> void:
	var braced: float = BodyCheckRules.puck_strip_impulse(6.0, 1.0, 0.45, 1.0, 0.4, true)
	var unbraced: float = BodyCheckRules.puck_strip_impulse(6.0, 1.0, 0.45, 1.0, 0.4, false)
	assert_lt(braced, unbraced, "an actively braced victim protects the puck (brace_resistance < 1)")
	# Braced value = unbraced × brace_resistance.
	assert_almost_eq(braced, unbraced * 0.4, 1e-5, "brace scales the delivered impulse by brace_resistance")

func test_puck_strip_impulse_baseline_strip_point_is_reachable() -> void:
	# Medium build vs medium build (weights 1.0, transfer 0.65, unbraced). The
	# strip THRESHOLD value is unchanged at 1.35, but the 0.65 transfer re-anchors
	# where it sits in closing speed: 6 m/s closing now over-strips (6.0 × 0.65 ×
	# 0.5 = 1.95), and the threshold itself lands at a reachable ~4.15 m/s closing
	# (1.35 / (0.65 × 0.5)). This is the drifted-breakpoint fix — a full check/strip
	# no longer needs ~6 m/s closing.
	assert_almost_eq(
			BodyCheckRules.puck_strip_impulse(6.0, 1.0, 0.65, 1.0, 0.4, false),
			1.95, 1e-5, "medium-vs-medium at 6 m/s closing over-strips at the 0.65 transfer")
	assert_almost_eq(
			BodyCheckRules.puck_strip_impulse(1.35 / 0.325, 1.0, 0.65, 1.0, 0.4, false),
			1.35, 1e-5, "the 1.35 strip threshold lands at ~4.15 m/s closing")
