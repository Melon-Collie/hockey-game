extends GutTest

# SkaterCollisionRules — analytic disc-vs-disc resolution (the body-check contact
# core). Pure math: positional separation + a single no-bounce inelastic impulse.

const R := 0.5   # test disc radius; two at 0.5 overlap when centers are < 1.0 apart


func _res() -> SkaterCollisionRules.Result:
	return SkaterCollisionRules.Result.new()


# ── no contact ────────────────────────────────────────────────────────────────

func test_no_overlap_does_nothing() -> void:
	var out := _res()
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3.ZERO, 80.0, R,
		Vector3(2.0, 0.0, 0.0), Vector3.ZERO, 80.0, R,
		1.0)
	assert_false(out.overlapping, "discs 2 m apart are not overlapping")
	assert_false(out.impulse_applied)
	assert_eq(out.sep_a, Vector3.ZERO)
	assert_eq(out.dvel_b, Vector3.ZERO)


# ── separation ────────────────────────────────────────────────────────────────

func test_overlap_separates_along_axis() -> void:
	var out := _res()
	# Centers 0.6 apart on X, radii sum 1.0 → overlap 0.4. Stationary → sep only.
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3.ZERO, 80.0, R,
		Vector3(0.6, 0.0, 0.0), Vector3.ZERO, 80.0, R,
		1.0)
	assert_true(out.overlapping)
	assert_false(out.impulse_applied, "no closing velocity → no hit impulse")
	# A pushed -X, B pushed +X, equal masses → half the overlap each.
	assert_almost_eq(out.sep_a.x, -0.2, 0.0001)
	assert_almost_eq(out.sep_b.x, 0.2, 0.0001)
	# Full overlap resolved.
	assert_almost_eq((out.sep_b - out.sep_a).x, 0.4, 0.0001)


func test_lighter_body_pushed_more_on_separation() -> void:
	var out := _res()
	# A heavy (120), B light (60). Overlap 0.4. B should move ~2x A.
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3.ZERO, 120.0, R,
		Vector3(0.6, 0.0, 0.0), Vector3.ZERO, 60.0, R,
		1.0)
	# inv_a=1/120, inv_b=1/60 → B's share is 2x A's.
	assert_almost_eq(absf(out.sep_b.x) / absf(out.sep_a.x), 2.0, 0.001)
	assert_almost_eq((out.sep_b - out.sep_a).x, 0.4, 0.0001)


# ── inelastic impulse ─────────────────────────────────────────────────────────

func test_closing_launches_victim_and_slows_attacker() -> void:
	var out := _res()
	# A closing on B at 6 m/s along +X, overlapping, equal masses, full transfer.
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3(6.0, 0.0, 0.0), 80.0, R,
		Vector3(0.8, 0.0, 0.0), Vector3.ZERO, 80.0, R,
		1.0)
	assert_true(out.impulse_applied)
	assert_almost_eq(out.closing_speed, 6.0, 0.0001)
	# Equal mass, transfer 1 → converge to shared 3 m/s: A loses 3, B gains 3.
	assert_almost_eq(out.dvel_a.x, -3.0, 0.001, "attacker decelerates by half the closing")
	assert_almost_eq(out.dvel_b.x, 3.0, 0.001, "victim launched by half the closing")


func test_no_bounce_attacker_never_reverses() -> void:
	var out := _res()
	# Whatever the transfer, the attacker's post-impulse velocity along the axis
	# must not go negative (a reversal would be a pinball bounce).
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3(5.0, 0.0, 0.0), 80.0, R,
		Vector3(0.8, 0.0, 0.0), Vector3.ZERO, 80.0, R,
		1.0)
	var post_a: float = 5.0 + out.dvel_a.x
	assert_true(post_a >= 0.0, "attacker must not be pushed backward past a stop")
	# At equal mass / full transfer it converges to the shared speed (5+0)/2, not below.
	assert_almost_eq(post_a, 2.5, 0.001)


func test_heavy_attacker_drives_through_light_victim() -> void:
	var out := _res()
	# Heavy A (150) closing on light B (55) at 6 m/s, full transfer.
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3(6.0, 0.0, 0.0), 150.0, R,
		Vector3(0.8, 0.0, 0.0), Vector3.ZERO, 55.0, R,
		1.0)
	# Attacker barely slows (drive-through), victim is launched hard.
	assert_true(absf(out.dvel_a.x) < absf(out.dvel_b.x),
		"heavy attacker changes velocity less than the light victim")
	# Victim Δv ≈ closing × m_a/(m_a+m_b) = 6 × 150/205 ≈ 4.39
	assert_almost_eq(out.dvel_b.x, 6.0 * 150.0 / 205.0, 0.01)
	# Attacker Δv ≈ -closing × m_b/(m_a+m_b) = -6 × 55/205 ≈ -1.61
	assert_almost_eq(out.dvel_a.x, -6.0 * 55.0 / 205.0, 0.01)


func test_victim_kick_matches_what_resolve_delivers() -> void:
	# victim_kick is the resolver's OWN delivery function, exposed so
	# predictors (AIBodyCheck's commit gate) share the exact formula. Pin the
	# consistency contract: for a live contact, resolve's applied |dvel_b|
	# equals victim_kick at the same closing speed, masses, and transfer —
	# if the delivery model ever changes, this and the AI's prediction move
	# in the same edit or fail here.
	var out := _res()
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3(7.0, 0.0, 0.0), 1.18, R,
		Vector3(0.8, 0.0, 0.0), Vector3(-2.0, 0.0, 0.0), 0.9, R, 0.61)
	assert_true(out.impulse_applied)
	assert_almost_eq(out.dvel_b.length(),
			SkaterCollisionRules.victim_kick(
					out.closing_speed, 1.18, 0.9, 0.61),
			0.0001)


func test_transfer_scales_impulse_linearly() -> void:
	var full := _res()
	var half := _res()
	SkaterCollisionRules.resolve(full,
		Vector3.ZERO, Vector3(6.0, 0.0, 0.0), 80.0, R,
		Vector3(0.8, 0.0, 0.0), Vector3.ZERO, 80.0, R, 1.0)
	SkaterCollisionRules.resolve(half,
		Vector3.ZERO, Vector3(6.0, 0.0, 0.0), 80.0, R,
		Vector3(0.8, 0.0, 0.0), Vector3.ZERO, 80.0, R, 0.5)
	# The uncommitted (half-transfer) hit delivers exactly half the knockback...
	assert_almost_eq(half.dvel_b.x, full.dvel_b.x * 0.5, 0.001)
	# ...and separation is unaffected by transfer (positional, always full).
	assert_almost_eq(half.sep_a.x, full.sep_a.x, 0.0001)


func test_low_transfer_barely_slows_attacker() -> void:
	var out := _res()
	# The "skate into someone uncommitted" case: small transfer → the attacker
	# keeps most of its speed instead of dead-stopping.
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3(6.0, 0.0, 0.0), 80.0, R,
		Vector3(0.8, 0.0, 0.0), Vector3.ZERO, 80.0, R, 0.2)
	var post_a: float = 6.0 + out.dvel_a.x
	assert_true(post_a > 5.0, "uncommitted contact glances off, keeping most speed")


# ── direction / non-contact velocity ──────────────────────────────────────────

func test_separating_pair_gets_no_impulse() -> void:
	var out := _res()
	# Overlapping but B moving away faster than A → not closing.
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3(1.0, 0.0, 0.0), 80.0, R,
		Vector3(0.8, 0.0, 0.0), Vector3(4.0, 0.0, 0.0), 80.0, R, 1.0)
	assert_true(out.overlapping, "still separated positionally")
	assert_false(out.impulse_applied, "moving apart → no hit impulse")
	assert_true(out.closing_speed < 0.0)


func test_impulse_is_along_center_axis_not_velocity() -> void:
	var out := _res()
	# A moving purely +X but offset on Z so the contact axis is diagonal. The
	# knockback must point along the center-to-center axis, not the velocity —
	# this is what kills the frame-to-frame normal jitter of the old resolver.
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3(6.0, 0.0, 0.0), 80.0, R,
		Vector3(0.6, 0.0, 0.6), Vector3.ZERO, 80.0, R, 1.0)
	# Axis is (0.6, 0, 0.6) normalized → equal X and Z components on the victim.
	assert_almost_eq(out.dvel_b.x, out.dvel_b.z, 0.001,
		"knockback follows the center axis (equal X/Z here), not the pure-X velocity")


# ── determinism guard ─────────────────────────────────────────────────────────

func test_coincident_centers_no_nan() -> void:
	var out := _res()
	SkaterCollisionRules.resolve(out,
		Vector3.ZERO, Vector3.ZERO, 80.0, R,
		Vector3.ZERO, Vector3.ZERO, 80.0, R, 1.0)
	assert_true(out.overlapping)
	assert_true(out.sep_a.is_finite() and out.sep_b.is_finite(),
		"coincident centers must resolve to a finite deterministic push, not NaN")
	assert_false(is_nan(out.sep_a.x))
