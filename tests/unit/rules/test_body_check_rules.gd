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


# ── attacker_restitution ──────────────────────────────────────────────────────
# The attacker's rebound eases from base (glancing) down to floor (drive through)
# as the delivered impulse rises between min_impulse and ref_impulse.

func test_restitution_full_below_min() -> void:
	assert_almost_eq(BodyCheckRules.attacker_restitution(4.0, 0.25, 0.0, 4.0, 11.0), 0.25, 0.0001,
			"at/below min impulse → full base rebound")
	assert_almost_eq(BodyCheckRules.attacker_restitution(1.0, 0.25, 0.0, 4.0, 11.0), 0.25, 0.0001,
			"below min clamps to base")

func test_restitution_floor_at_or_above_ref() -> void:
	assert_almost_eq(BodyCheckRules.attacker_restitution(11.0, 0.25, 0.0, 4.0, 11.0), 0.0, 0.0001,
			"full-strength hit drives through → floor rebound")
	assert_almost_eq(BodyCheckRules.attacker_restitution(20.0, 0.25, 0.0, 4.0, 11.0), 0.0, 0.0001,
			"above ref clamps to floor")

func test_restitution_lerps_between() -> void:
	# midpoint 7.5 between 4 and 11 → halfway from 0.25 to 0.0 = 0.125
	assert_almost_eq(BodyCheckRules.attacker_restitution(7.5, 0.25, 0.0, 4.0, 11.0), 0.125, 0.0001,
			"midpoint impulse → half the rebound")
	assert_lt(BodyCheckRules.attacker_restitution(9.0, 0.25, 0.0, 4.0, 11.0),
			BodyCheckRules.attacker_restitution(6.0, 0.25, 0.0, 4.0, 11.0),
			"harder hit → less rebound (more drive-through)")

func test_restitution_degenerate_band_is_safe() -> void:
	assert_almost_eq(BodyCheckRules.attacker_restitution(10.0, 0.25, 0.0, 11.0, 11.0), 0.25, 0.0001,
			"ref<=min never divides by zero — falls back to base")

func test_restitution_honors_nonzero_floor() -> void:
	assert_almost_eq(BodyCheckRules.attacker_restitution(11.0, 0.25, 0.1, 4.0, 11.0), 0.1, 0.0001,
			"a full hit eases to the configured floor, not necessarily zero")


# ── delivered_transfer_impulse ────────────────────────────────────────────────
# The shared "how hard did it land on the victim" magnitude — closing speed × mass
# ratio × brace-adjusted transfer — that the knockback, stagger, strip, and (the
# point of these cases) the attacker's drive-through vs peel-off rebound all key off.

func test_delivered_impulse_matches_raw_formula() -> void:
	# approach 8 × weight_ratio 1.0 × transfer 0.45, unbraced.
	assert_almost_eq(BodyCheckRules.delivered_transfer_impulse(8.0, 1.0, 0.45, 0.4, false),
			3.6, 0.0001, "unbraced delivered impulse = approach × weight_ratio × transfer")

func test_delivered_impulse_brace_cuts_it() -> void:
	var open: float = BodyCheckRules.delivered_transfer_impulse(8.0, 1.0, 0.45, 0.4, false)
	var braced: float = BodyCheckRules.delivered_transfer_impulse(8.0, 1.0, 0.45, 0.4, true)
	assert_lt(braced, open, "a braced victim absorbs less of the hit")
	assert_almost_eq(braced, open * 0.4, 0.0001, "brace scales the delivered impulse by brace_resistance")

func test_braced_victim_makes_attacker_peel_off_not_drive_through() -> void:
	# Regression guard for the "stuck to them" fix: the SAME committed hit (high
	# closing speed, equal masses) into an open vs a braced victim. The open victim is
	# sent flying → the attacker's rebound falls toward the floor (drives through onto
	# the loose puck); the braced victim holds → the brace cuts the delivered impulse,
	# so the attacker keeps a real rebound and peels off in a battle instead of gluing.
	var open: float = BodyCheckRules.delivered_transfer_impulse(14.0, 1.2, 0.45, 0.4, false)
	var braced: float = BodyCheckRules.delivered_transfer_impulse(14.0, 1.2, 0.45, 0.4, true)
	var rebound_open: float = BodyCheckRules.attacker_restitution(open, 0.25, 0.0, 4.0, 11.0)
	var rebound_braced: float = BodyCheckRules.attacker_restitution(braced, 0.25, 0.0, 4.0, 11.0)
	assert_gt(rebound_braced, rebound_open, "braced victim → more attacker rebound (peel off, not drive through)")
	assert_gt(rebound_braced, 0.0, "a braced hit leaves a real rebound so the bodies separate")


# ── puck_strip_impulse ──────────────────────────────────────────────────────────
# The strip decision must key off the SAME delivered impulse as the stagger, so
# Physical (transfer), both masses, and closing speed all move it.

func test_puck_strip_impulse_matches_delivered_knockback() -> void:
	# Locks the algebra identity against the knockback formula in
	# Skater._resolve_player_collisions: delivered = approach × weight_ratio ×
	# effective_transfer, and impact_force = attacker_weight × approach.
	var approach: float = 7.0
	var att_weight: float = 1.18
	var vic_weight: float = 0.82
	var transfer: float = 0.55
	var impact_force: float = att_weight * approach
	var weight_ratio: float = att_weight / vic_weight
	var expected: float = approach * weight_ratio * transfer  # effective_transfer, unbraced
	assert_almost_eq(
			BodyCheckRules.puck_strip_impulse(impact_force, transfer, vic_weight, 0.4, false),
			expected, 1e-5, "reconstruction must equal the knockback magnitude")

func test_puck_strip_impulse_scales_with_physical() -> void:
	# Same hit, higher attacker transfer (Physical) → more likely to strip.
	var enforcer: float = BodyCheckRules.puck_strip_impulse(6.0, 0.61, 1.0, 0.4, false)
	var weakling: float = BodyCheckRules.puck_strip_impulse(6.0, 0.29, 1.0, 0.4, false)
	assert_gt(enforcer, weakling, "higher Physical/transfer delivers a harder strip impulse")

func test_puck_strip_impulse_scales_inverse_with_victim_mass() -> void:
	# Same hit, heavier victim → harder to dislodge the puck.
	var light: float = BodyCheckRules.puck_strip_impulse(6.0, 0.45, 0.82, 0.4, false)
	var heavy: float = BodyCheckRules.puck_strip_impulse(6.0, 0.45, 1.18, 0.4, false)
	assert_gt(light, heavy, "a heavier victim absorbs more of the hit — smaller strip impulse")

func test_puck_strip_impulse_brace_reduces_when_braced() -> void:
	var braced: float = BodyCheckRules.puck_strip_impulse(6.0, 0.45, 1.0, 0.4, true)
	var unbraced: float = BodyCheckRules.puck_strip_impulse(6.0, 0.45, 1.0, 0.4, false)
	assert_lt(braced, unbraced, "an actively braced victim protects the puck (brace_resistance < 1)")
	# Braced value = unbraced × brace_resistance.
	assert_almost_eq(braced, unbraced * 0.4, 1e-5, "brace scales the delivered impulse by brace_resistance")

func test_puck_strip_impulse_baseline_preserves_legacy_strip_point() -> void:
	# Medium build vs medium build (weights 1.0, transfer 0.45, unbraced): the old
	# code stripped at impact_force = weight×approach ≥ 6.0. The new delivered
	# impulse at that same point is 6.0 × 0.45 = 2.7 — the recalibrated threshold.
	assert_almost_eq(
			BodyCheckRules.puck_strip_impulse(6.0, 0.45, 1.0, 0.4, false),
			2.7, 1e-5, "baseline medium-vs-medium strip point maps to the 2.7 threshold")
