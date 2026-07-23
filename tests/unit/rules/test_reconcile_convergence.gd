extends GutTest

# Property / soak tests for the reconcile + lag-comp decision rules.
#
# The existing suites pin the individual thresholds (test_reconciliation_rules,
# test_reconcile_stale_ack) and the rewind formulas (test_lag_comp_rewind). This
# file adds the PROPERTIES that only show up over a stream or a trajectory — the
# behaviours a single-point unit test can't see:
#
#   * reconcile actually CONVERGES a desync (the whole point of it): once a snap
#     sets client = server, the shared deterministic step keeps them identical —
#     the residual collapses to zero and stays there. If it didn't, reconcile
#     would thrash forever.
#   * the skater rotation gate uses angle_difference, so a +179deg / -179deg pair
#     is a small delta (no snap), not a 358deg one (spurious snap).
#   * the stale-ack gate, run over a realistic repeats+jitter broadcast stream,
#     accepts only genuine advances and the accepted stream is strictly rising.
#   * the lag-comp rewind is monotonic in host time and independent of RTT across
#     the whole clamp band — the low-ping-advantage regression guard.

const DT: float = 1.0 / 120.0
const ICE: float = 0.0175
const MAX_SPEED: float = 38.0
const MAX_HEIGHT: float = 3.0
const R: float = 0.065
const EPS: float = 1e-3  # PredictedState.TS_MATCH_EPSILON


func _advance_tick(pos: Vector3, vel: Vector3,
		fs: PuckGeometryCollision.Result, tr: PuckAuthorityRules.TickResult) -> Transform3D:
	var substeps: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), DT)
	var sub_dt: float = DT / float(substeps)
	var p: Vector3 = pos
	var v: Vector3 = vel
	for _sub in substeps:
		tr.touched_post = false
		tr.touched_net = false
		PuckAuthorityRules.step_frame_substep(p, v, sub_dt, R, MAX_SPEED, ICE, MAX_HEIGHT, fs, tr)
		p = tr.position
		v = tr.velocity
	if p.y < ICE:
		p.y = ICE
		if v.y < 0.0:
			v.y = 0.0
	return Transform3D(Basis(v, Vector3.ZERO, Vector3.ZERO), p)


# ── A. Reconcile converges a puck desync ──────────────────────────────────────
# The load-bearing property: a hard snap fixes a desync PERMANENTLY, because the
# post-snap trajectory is deterministic. Model a client that predicted from a
# wrong start (a dropped snapshot), so it drifts from the host. The moment the
# error trips puck_needs_hard_snap, the client snaps to the host state; from
# there both advance the SAME shared step, so the residual is zero forever after.
# This is why the netcode can tolerate a divergence at all.
func test_hard_snap_converges_puck_prediction() -> void:
	var fs_h := PuckGeometryCollision.Result.new()
	var tr_h := PuckAuthorityRules.TickResult.new()
	var fs_c := PuckGeometryCollision.Result.new()
	var tr_c := PuckAuthorityRules.TickResult.new()
	# Host truth and a client that started 1.5 m off with a slightly wrong velocity.
	var hp := Vector3(0.0, ICE, 0.0)
	var hv := Vector3(18.0, 0.0, 6.0)
	var cp: Vector3 = hp + Vector3(1.5, 0.0, 0.0)
	var cv: Vector3 = hv + Vector3(1.0, 0.0, -0.5)
	var snap_threshold: float = 0.5  # hard-snap distance
	var snapped: bool = false
	var post_snap_max_residual: float = 0.0
	for _t in 180:
		var h: Transform3D = _advance_tick(hp, hv, fs_h, tr_h)
		hp = h.origin
		hv = h.basis.x
		var c: Transform3D = _advance_tick(cp, cv, fs_c, tr_c)
		cp = c.origin
		cv = c.basis.x
		if not snapped:
			if ReconciliationRules.puck_needs_hard_snap(cp, hp, snap_threshold):
				# Snap: client adopts the authoritative pos + vel.
				cp = hp
				cv = hv
				snapped = true
		else:
			post_snap_max_residual = maxf(post_snap_max_residual, cp.distance_to(hp))
	assert_true(snapped, "the injected desync must trip a hard snap")
	assert_almost_eq(post_snap_max_residual, 0.0, 1e-6,
			"after the snap the client tracks the host with zero residual (convergence)")


# The mirror property: an UNsnapped divergence (threshold never reached because
# the two never separate) must stay quietly under the bar — the soft path — never
# manufacturing a snap when prediction is already good. A perfectly-seeded client
# equals the host every tick, so puck_needs_hard_snap is false throughout.
func test_matching_prediction_never_snaps() -> void:
	var fs_h := PuckGeometryCollision.Result.new()
	var tr_h := PuckAuthorityRules.TickResult.new()
	var fs_c := PuckGeometryCollision.Result.new()
	var tr_c := PuckAuthorityRules.TickResult.new()
	var hp := Vector3(-3.0, ICE, 4.0)
	var hv := Vector3(12.0, 1.5, -20.0)
	var cp: Vector3 = hp
	var cv: Vector3 = hv
	var false_snaps: int = 0
	for _t in 180:
		var h: Transform3D = _advance_tick(hp, hv, fs_h, tr_h)
		hp = h.origin
		hv = h.basis.x
		var c: Transform3D = _advance_tick(cp, cv, fs_c, tr_c)
		cp = c.origin
		cv = c.basis.x
		if ReconciliationRules.puck_needs_hard_snap(cp, hp, 0.5):
			false_snaps += 1
	assert_eq(false_snaps, 0, "a correctly-seeded prediction must never hard-snap")


# ── B. Skater rotation gate wraps at +/-pi ────────────────────────────────────
# The upper-body rotation branch uses angle_difference, so the shortest signed
# arc drives the decision. A client at +179deg and a server at -179deg are 2deg
# apart, not 358deg — the naive abs(a - b) would fire a spurious reconcile every
# time the facing crossed the wrap. Pin both directions of the wrap.
func test_rotation_reconcile_respects_angle_wrap() -> void:
	var thr: float = deg_to_rad(15.0)
	# 2deg apart across the +/-pi seam: no reconcile.
	var near_wrap: bool = ReconciliationRules.skater_needs_reconcile(
			Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
			0.05, 0.1,
			deg_to_rad(179.0), deg_to_rad(-179.0), thr)
	assert_false(near_wrap, "179deg vs -179deg is a 2deg delta — must not reconcile")
	# A genuine 40deg rotation delta: reconcile.
	var real_turn: bool = ReconciliationRules.skater_needs_reconcile(
			Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
			0.05, 0.1,
			deg_to_rad(10.0), deg_to_rad(50.0), thr)
	assert_true(real_turn, "a real 40deg rotation delta exceeds the 15deg gate")
	# Zero threshold keeps the branch fully off (back-compat with rotation-less callers).
	var disabled: bool = ReconciliationRules.skater_needs_reconcile(
			Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
			0.05, 0.1,
			deg_to_rad(0.0), deg_to_rad(170.0), 0.0)
	assert_false(disabled, "a zero rotation threshold disables the rotation branch entirely")


# Property soak: over many random client/server pairs, skater_needs_reconcile is
# TRUE iff at least one of the three deltas (pos, vel, wrapped-rotation) meets its
# threshold — an independent recomputation of the gate, so a future short-circuit
# reorder or a dropped branch can't pass silently.
func test_skater_reconcile_matches_independent_gate() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EA71E
	var pos_thr: float = 0.1
	var vel_thr: float = 0.25
	var rot_thr: float = deg_to_rad(15.0)
	var disagreements: int = 0
	for _i in 500:
		var cp := Vector3(rng.randf_range(-2, 2), 0, rng.randf_range(-2, 2))
		var sp := Vector3(rng.randf_range(-2, 2), 0, rng.randf_range(-2, 2))
		var cvv := Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3))
		var svv := Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3))
		var cr: float = rng.randf_range(-PI, PI)
		var sr: float = rng.randf_range(-PI, PI)
		var expected: bool = cp.distance_to(sp) >= pos_thr \
				or cvv.distance_to(svv) >= vel_thr \
				or absf(angle_difference(cr, sr)) >= rot_thr
		var got: bool = ReconciliationRules.skater_needs_reconcile(
				cp, cvv, sp, svv, pos_thr, vel_thr, cr, sr, rot_thr)
		if got != expected:
			disagreements += 1
	assert_eq(disagreements, 0,
			"skater_needs_reconcile must equal (pos OR vel OR wrapped-rotation) over the threshold")


# ── C. Stale-ack gate over a realistic broadcast stream ───────────────────────
# The host broadcasts every tick but only advances the ack when it pops a due
# input, so the stream is mostly repeats with the odd wire-jitter and a genuine
# advance every few frames. ack_is_new must accept only the true advances, and
# the accepted subsequence must be strictly increasing — no repeat, no jitter,
# and no rounding hair can slip through as a fresh reconcile.
func test_ack_stream_accepts_only_true_advances() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xACC5
	var last_accepted: float = 0.0
	var host_ack: float = 100.0
	var accepted: Array[float] = []
	var true_advances: int = 0
	for _i in 4000:
		var roll: float = rng.randf()
		if roll < 0.25:
			# A due input popped: advance by one-or-more input spacings (~8.33ms).
			host_ack += DT * float(rng.randi_range(1, 3))
			true_advances += 1
		# else: re-broadcast the same ack (a repeat), optionally with 0.1ms wire jitter.
		var wire: float = host_ack
		if rng.randf() < 0.5:
			wire = round(host_ack * 10000.0) / 10000.0  # 0.1ms grid requantize
		if ReconciliationRules.ack_is_new(wire, last_accepted, EPS):
			accepted.append(wire)
			last_accepted = wire
	# Every accepted ack strictly exceeds the previous accepted one by > epsilon.
	var strictly_rising: bool = true
	for i in range(1, accepted.size()):
		if accepted[i] <= accepted[i - 1] + EPS:
			strictly_rising = false
			break
	assert_true(strictly_rising, "the accepted ack subsequence must be strictly rising by > epsilon")
	# Repeats/jitter add nothing: acceptances never exceed the number of genuine
	# advances (they can be fewer — two sub-epsilon micro-advances could fold, but
	# with >= one tick spacing here each advance is distinct and accepted).
	assert_eq(accepted.size(), true_advances,
			"exactly the genuine advances are accepted; repeats and wire jitter are rejected")


# ── D. Lag-comp rewind: monotonic + RTT-independent across the band ───────────
# self_view_time = host_time + INPUT_LEAD, unconditionally — strictly increasing
# in host time and invariant to any notional RTT (the property that stops a
# low-ping player from getting an earlier — advantaged — pickup rewind).
func test_self_view_time_monotonic_and_rtt_independent() -> void:
	var prev: float = -INF
	var t: float = 0.0
	while t <= 500.0:
		var v: float = LagCompRewind.self_view_time(t)
		assert_almost_eq(v, t + NetworkManager.INPUT_LEAD_SEC, 1e-9,
				"self_view_time is host_time + INPUT_LEAD at t=%.1f" % t)
		assert_gt(v, prev, "self_view_time strictly increases in host time")
		prev = v
		t += 7.3  # an irregular step so the grid can't accidentally line up


# remote_view_time = host_time - clamp(interp_delay, 0, 200ms). Monotonic in host
# time; the interp-delay clamp is stable and correct across the whole band
# (below 0 clamps to the host instant, above 200ms clamps to the 200ms floor).
func test_remote_view_time_clamp_band() -> void:
	# Monotonic in host time at a fixed interp delay.
	var prev: float = -INF
	var host: float = 0.0
	while host <= 300.0:
		var v: float = LagCompRewind.remote_view_time(host, 75.0)
		assert_almost_eq(v, host - 0.075, 1e-9, "75ms interp delay rewinds 75ms")
		assert_gt(v, prev, "remote_view_time strictly increases in host time")
		prev = v
		host += 11.0
	# The clamp band, at a fixed host time.
	assert_almost_eq(LagCompRewind.remote_view_time(100.0, -50.0), 100.0, 1e-9,
			"negative interp delay clamps to the host instant (no future rewind)")
	assert_almost_eq(LagCompRewind.remote_view_time(100.0, 0.0), 100.0, 1e-9,
			"zero interp delay is the host instant")
	assert_almost_eq(LagCompRewind.remote_view_time(100.0, 200.0), 100.0 - 0.2, 1e-9,
			"200ms is the clamp ceiling exactly")
	assert_almost_eq(LagCompRewind.remote_view_time(100.0, 5000.0), 100.0 - 0.2, 1e-9,
			"anything past 200ms clamps to the 200ms floor")
