extends GutTest

# PuckShadowComparator — the Phase-0 divergence instrument. The shadow model is
# AITrajectory.step_puck (tested separately); these tests pin the ACCOUNTING: it
# records ~0 divergence when the real puck follows the model, real divergence when it
# doesn't, buckets post-bounce vs free-flight, counts Jolt escapes (the shadow can't),
# and resets cleanly. Synthetic "real" observations, so it runs headless.

const DT: float = 1.0 / 120.0


# A real puck that PERFECTLY follows the analytic model (chained step_puck) must
# produce ~0 divergence — the shadow re-derives the identical trajectory.
func test_free_run_zero_divergence_when_real_matches_model() -> void:
	var comp := PuckShadowComparator.new()
	comp.mode = PuckShadowComparator.Mode.FREE_RUN
	var p := Vector3(0, 0, 2)
	var v := Vector3(6, 0, 0)
	comp.observe(p, v, false, DT)  # seed
	for _i in 30:
		var s: Transform3D = AITrajectory.step_puck(p, v, DT)
		p = s.origin
		v = s.basis.x
		comp.observe(p, v, false, DT)
	assert_lt(comp.div_max, 1e-4, "real == model -> shadow matches, ~0 divergence")
	assert_gt(comp.samples, 0)


# A real puck that IGNORES friction (constant velocity) must diverge from the
# friction-applying shadow — and the divergence must accumulate over the flight.
func test_free_run_records_divergence_when_real_differs() -> void:
	var comp := PuckShadowComparator.new()
	comp.mode = PuckShadowComparator.Mode.FREE_RUN
	var p := Vector3(0, 0, 2)
	var v := Vector3(6, 0, 0)  # constant — no friction applied to "real"
	comp.observe(p, v, false, DT)  # seed
	for _i in 60:
		p += v * DT  # real: pure constant velocity, no friction
		comp.observe(p, v, false, DT)
	assert_gt(comp.div_max, 0.0, "friction gap -> nonzero divergence")
	assert_gt(comp.avg_divergence(), 0.0)


# The real (Jolt) puck outside the analytic boundary is an escape (the shadow, clamped
# by step_puck, cannot be). This is the rim-around "falls out of the arena" measure.
func test_counts_real_puck_escapes() -> void:
	var comp := PuckShadowComparator.new()
	var inside := Vector3(0, 0, 0)
	var outside := Vector3(GameRules.INNER_HALF_WIDTH + 1.0, 0, 0)
	comp.observe(inside, Vector3(5, 0, 0), false, DT)   # seed, in-rink
	assert_eq(comp.real_escape_ticks, 0)
	comp.observe(outside, Vector3(5, 0, 0), false, DT)  # Jolt left the rink
	assert_eq(comp.real_escape_ticks, 1, "real puck outside boundary counts as an escape")


func test_shadow_stays_contained_after_stepping() -> void:
	# Seed from an in-rink spot heading hard at the +X board; the stepped shadow must
	# stay inside the boundary (step_puck clamps), unlike Jolt.
	var comp := PuckShadowComparator.new()
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.3, 0, 0)
	comp.observe(pos, Vector3(40, 0, 0), false, DT)  # seed
	var shadow: Vector3 = comp.observe(Vector3(GameRules.INNER_HALF_WIDTH + 2.0, 0, 0), Vector3(40, 0, 0), true, DT)
	var clamped: Vector2 = GameRules.clamp_to_rink_inner(Vector2(shadow.x, shadow.z))
	assert_almost_eq(clamped.x, shadow.x, 0.01, "stepped shadow stayed inside the rink (x)")


# A board contact routes subsequent divergence into the post-bounce bucket.
func test_post_bounce_bucketing() -> void:
	var comp := PuckShadowComparator.new()
	comp.mode = PuckShadowComparator.Mode.FREE_RUN
	var p := Vector3(0, 0, 0)
	var v := Vector3(6, 0, 0)
	comp.observe(p, v, false, DT)  # seed
	# A couple of clean free-flight ticks (real diverges by ignoring friction).
	for _i in 3:
		p += v * DT
		comp.observe(p, v, false, DT)
	assert_gt(comp.free_flight_div_max, 0.0, "free-flight divergence bucketed")
	assert_eq(comp.post_bounce_div_max, 0.0, "nothing in post-bounce yet")
	# Now a board contact, then more diverging ticks -> post-bounce bucket fills.
	p += v * DT
	comp.observe(p, v, true, DT)  # board_contact
	for _i in 3:
		p += v * DT
		comp.observe(p, v, false, DT)
	assert_gt(comp.post_bounce_div_max, 0.0, "divergence after a board contact bucketed post-bounce")


func test_bounce_angle_recorded_after_contact() -> void:
	var comp := PuckShadowComparator.new()
	comp.mode = PuckShadowComparator.Mode.FREE_RUN
	var p := Vector3(GameRules.INNER_HALF_WIDTH - 0.3, 0, 0)
	var v := Vector3(20, 0, 0)
	comp.observe(p, v, false, DT)                     # seed
	comp.observe(Vector3(GameRules.INNER_HALF_WIDTH - 0.1, 0, 0), v, true, DT)  # board contact
	assert_eq(comp.bounce_events, 0, "bounce angle resolves on the NEXT tick, not the contact tick")
	comp.observe(Vector3(GameRules.INNER_HALF_WIDTH - 0.2, 0, 0), Vector3(-18, 0, 0), false, DT)
	assert_eq(comp.bounce_events, 1, "one bounce-angle sample recorded a tick after contact")
	assert_gte(comp.avg_bounce_angle_err_deg(), 0.0)


func test_reset_session_zeroes_stats() -> void:
	var comp := PuckShadowComparator.new()
	var p := Vector3(0, 0, 0)
	var v := Vector3(6, 0, 0)
	comp.observe(p, v, false, DT)
	for _i in 10:
		p += v * DT
		comp.observe(p, v, false, DT)
	assert_gt(comp.samples, 0)
	comp.reset_session()
	assert_eq(comp.samples, 0)
	assert_eq(comp.div_max, 0.0)
	assert_eq(comp.real_escape_ticks, 0)


func test_per_tick_step_mode_agrees_on_free_flight() -> void:
	# PER_TICK_STEP re-seeds from real each tick and steps ONE tick. Mid-rink with no
	# interaction the one-step position prediction equals real's next position — the
	# forward-Euler position step uses the given (pre-friction) velocity, so friction
	# doesn't move position within a single step. So divergence is ~0: the models agree
	# on straight-line flight, and per-tick error is a bounce/clamp detector, not a
	# friction one.
	var comp := PuckShadowComparator.new()
	comp.mode = PuckShadowComparator.Mode.PER_TICK_STEP
	var p := Vector3(0, 0, 0)
	var v := Vector3(6, 0, 0)
	for _i in 10:
		comp.observe(p, v, false, DT)
		p += v * DT
	assert_gt(comp.samples, 0, "per-tick mode records comparisons")
	assert_lt(comp.div_max, 1e-4, "free-flight one-step prediction matches; error appears at bounces/clamps")


func test_per_tick_step_flags_boundary_clamp_divergence() -> void:
	# The interaction PER_TICK_STEP exists to isolate: when the real puck steps OUTSIDE
	# the boundary (a Jolt escape), the shadow's one-step prediction clamps it inside,
	# so the one-step divergence is nonzero.
	var comp := PuckShadowComparator.new()
	comp.mode = PuckShadowComparator.Mode.PER_TICK_STEP
	comp.observe(Vector3(GameRules.INNER_HALF_WIDTH - 0.05, 0, 0), Vector3(30, 0, 0), false, DT)  # seed, in-rink
	comp.observe(Vector3(GameRules.INNER_HALF_WIDTH + 1.0, 0, 0), Vector3(30, 0, 0), true, DT)   # real escaped
	assert_gt(comp.div_max, 0.0, "shadow clamp vs real escape -> one-step divergence")
