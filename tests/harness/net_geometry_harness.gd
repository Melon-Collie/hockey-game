class_name NetGeometryHarness
extends RefCounted

# Deterministic simulation of the CLAIM GEOMETRY seam: when a client sees its
# blade reach the puck, does the host's rewind agree?
#
# Third of the netcode harnesses. NetTimingHarness covers the input pipeline,
# NetRewindHarness covers buffer answerability — "was the lookup in range". This
# one covers the question those two deliberately leave open: was the ANSWER
# right. It is the quantity behind the playtest's 45% pickup-claim miss rate,
# and until now the only way to measure it was to ship a build and read the
# host's telemetry afterwards.
#
# Structure mirrors the real seam:
#   host    — advances the puck and a sweeping blade, captures both every tick
#   link    — snapshots reach the client one_way later
#   client  — knows its OWN blade exactly (locally predicted), and PREDICTS the
#             puck from its newest received snapshot to its render instant
#   client  — runs PuckInteractionRules.check_pickup on what it rendered; a hit
#             sends a claim
#   host    — rewinds blade to self_view_time and puck to puck_view_time, runs
#             the SAME check_pickup, and either confirms or misses
#
# Because the blade is exact on both sides, EVERY disagreement is puck
# prediction error. That is the isolation the harness is for: a false negative
# here is a claim the player earned and the host refused.
#
# WHAT IS DELIBERATELY NOT MODELLED, and why: the puck solver. Client and host
# run the identical shared step from the identical snapshot, so it contributes
# exactly zero divergence by construction — simulating it would test
# determinism, which is not in question, and would hide the variable that is.
# What decides a miss is PREDICTION SPAN against events the client could not
# know about, so the puck moves at constant velocity and the host injects
# unmodelled deflections (a stick, a body, a save). Longer span + more
# unmodelled events = more misses, and that relationship is the measurement.
#
# THE CRITICAL PROPERTY, as with the other two: it reproduces a known effect on
# demand. `RenderMode` switches the client's puck target between host-present
# (pre-v59) and host-present + input lead (shipping), and the suite asserts the
# longer span measurably raises the miss rate — the regression flagged when the
# clock unification landed, which could not be proven from a single playtest.

const _PEER: int = 3


enum RenderMode {
	AT_HOST_PRESENT,  # pre-v59: puck rendered at estimated_host_time()
	AT_INPUT_STAMP,   # shipping: estimated_host_time() + input lead
}


class Config:
	var rtt_ms: float = 30.0
	var input_lead_ms: float = 25.0
	var duration_s: float = 6.0
	var render_mode: RenderMode = RenderMode.AT_INPUT_STAMP
	# How often the host perturbs the puck in a way the client cannot predict —
	# a deflection off a stick or body. 0 disables.
	var deflect_every_ticks: int = 0
	# Magnitude of that velocity change. What decides whether it costs a claim is
	# geometric and worth stating: the rendered puck is wrong by roughly
	# (velocity error x span), where span = one_way + lead, so a miss needs
	#     velocity error > pickup_radius / span
	# — about 5.5 m/s at 30 ms RTT with a 0.30 m radius. A real deflection off a
	# stick or skate clears that easily; a graze does not, which is why gentle
	# perturbations produce a 0% miss rate rather than a small one.
	var deflect_speed: float = 10.0
	var puck_speed: float = 12.0
	# How far off the puck's CENTRE the player actually places the blade — their
	# own aim error, independent of any network effect. Small, so what decides a
	# miss is prediction error rather than aim.
	var blade_offset_m: float = 0.05
	var pickup_radius: float = 0.30
	var seed: int = 991


class Result:
	var client_hits: int = 0        # frames the client's own view said "I got it"
	var host_confirms: int = 0      # ...that the host's rewind agreed with
	var false_negatives: int = 0    # client saw a hit, host rewound to a miss
	var max_puck_error_m: float = 0.0
	var mean_puck_error_m: float = 0.0
	var samples: int = 0

	func miss_rate() -> float:
		return 0.0 if client_hits == 0 else float(false_negatives) / float(client_hits)

	func summary() -> String:
		return ("client_hits=%d confirms=%d false_neg=%d miss_rate=%.1f%% "
				+ "puck_err_mean=%.3fm max=%.3fm") % [
				client_hits, host_confirms, false_negatives, miss_rate() * 100.0,
				mean_puck_error_m, max_puck_error_m]


static func _push(buf: StateBufferManager, blade: Vector3, puck: Vector3, ts: float) -> void:
	# Mirror of StateBufferManager.capture()'s ring writes. capture() pulls from
	# live controllers, which cannot be stood up headless; every lookup the tests
	# actually exercise is the shipping implementation reading what this wrote.
	if not buf._skater_buffers.has(_PEER):
		buf._alloc_skater(_PEER)
	var sp: int = buf._skater_ptrs[_PEER]
	var sslot: SkaterNetworkState = buf._skater_buffers[_PEER][sp]
	sslot.position = blade
	sslot.blade_contact_world = blade
	sslot.host_timestamp = ts
	buf._skater_ptrs[_PEER] = (sp + 1) % StateBufferManager.BUFFER_SIZE
	buf._skater_counts[_PEER] = mini(
			buf._skater_counts.get(_PEER, 0) + 1, StateBufferManager.BUFFER_SIZE)

	if buf._puck_buffer.is_empty():
		buf._puck_buffer.resize(StateBufferManager.BUFFER_SIZE)
		for i: int in StateBufferManager.BUFFER_SIZE:
			buf._puck_buffer[i] = PuckNetworkState.new()
	var pslot: PuckNetworkState = buf._puck_buffer[buf._puck_ptr]
	pslot.position = puck
	pslot.carrier_peer_id = -1
	pslot.host_timestamp = ts
	buf._puck_ptr = (buf._puck_ptr + 1) % StateBufferManager.BUFFER_SIZE
	buf._puck_count = mini(buf._puck_count + 1, StateBufferManager.BUFFER_SIZE)

	buf._newest_ts = ts
	buf._capture_count += 1


# The player aims at WHAT THEY SEE: the client puts its blade on the puck it
# rendered, so from its own view the grab always connects. That is the honest
# model of a pickup attempt, and it makes the host's verdict the whole
# measurement — the miss rate becomes exactly the fraction of attempts where the
# client's predicted puck was further from the true puck than the pickup radius
# tolerates.
#
# The blade is still EXACT on both sides: the client predicts its own body
# locally, and the host reads that same pose out of its buffer at self_view_time
# rather than predicting it. So no disagreement below is ever a blade error.


class _Pending:
	var stamp: float = 0.0          # claim stamp (the client's host-time at send)
	var target_t: float = 0.0       # the instant the client rendered
	var rendered: Vector3 = Vector3.ZERO
	var rendered_prev: Vector3 = Vector3.ZERO


func run(cfg: Config) -> Result:
	var res := Result.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.seed

	var tick: float = Constants.TICK_DURATION
	var one_way: float = cfg.rtt_ms / 2000.0
	var lead_s: float = LagCompRewind.clamped_lead_s(cfg.input_lead_ms)
	var render_ahead: float = lead_s if cfg.render_mode == RenderMode.AT_INPUT_STAMP else 0.0
	var ahead_ticks: int = int(round(render_ahead / tick))
	var delay_ticks: int = int(round(one_way / tick))
	# The local body ALWAYS sits at the input stamp — inputs are applied
	# immediately and stamped a lead ahead, and it cannot leave that instant
	# without introducing local input delay. So the blade's instant is the lead
	# regardless of where the puck is being drawn; only the PUCK's render target
	# moves with RenderMode. Pre-v59 that split is the incoherence itself: the
	# player aimed a blade at H+L using a puck drawn at H.
	var blade_ticks: int = int(round(lead_s / tick))

	var host_buf := StateBufferManager.new()
	var client_buf := StateBufferManager.new()   # the same snapshots, one_way late

	var puck_pos := Vector3.ZERO
	var puck_vel := Vector3(0.0, 0.0, -cfg.puck_speed)
	var truth: Array[Vector3] = []
	# Blade pose the client committed to for a future instant. The host applies
	# the client's inputs when their stamp comes due, so by the time it captures
	# that instant the pose is already decided — no prediction on either side.
	var blade_plan: Dictionary[int, Vector3] = {}
	var pending: Array[_Pending] = []
	var err_sum: float = 0.0

	var total: int = int(cfg.duration_s / tick)
	for i: int in total:
		var now: float = float(i) * tick

		# ── Host: unmodelled perturbation, advance, capture ──────────────────
		if cfg.deflect_every_ticks > 0 and i > 0 and i % cfg.deflect_every_ticks == 0:
			puck_vel += Vector3(rng.randf_range(-1.0, 1.0), 0.0,
					rng.randf_range(-1.0, 1.0)).normalized() * cfg.deflect_speed
		puck_pos += puck_vel * tick
		truth.append(puck_pos)
		_push(host_buf, blade_plan.get(i, puck_pos), puck_pos, now)

		# ── Link ─────────────────────────────────────────────────────────────
		var deliver_i: int = i - delay_ticks
		if deliver_i >= 0:
			_push(client_buf, blade_plan.get(deliver_i, truth[deliver_i]),
					truth[deliver_i], float(deliver_i) * tick)
		if not client_buf.is_ready() or not host_buf.is_ready():
			continue

		# ── Client: predict the puck, put the blade on what it sees ──────────
		# Constant-velocity dead reckon from the newest RECEIVED snapshot. The
		# real client runs the shared analytic solver, which is identical on both
		# sides and so cannot diverge; what neither side can do is know about a
		# perturbation the client has not been told about yet.
		var newest_client: float = client_buf.newest_host_timestamp()
		var base: WorldSnapshot = client_buf.get_state_at(newest_client)
		var base_prev: WorldSnapshot = client_buf.get_state_at(
				LagCompRewind.prev_tick(newest_client))
		if base.puck_state == null or base_prev.puck_state == null:
			continue
		var est_vel: Vector3 = (base.puck_state.position - base_prev.puck_state.position) / tick
		var target_i: int = i + ahead_ticks
		var target_t: float = float(target_i) * tick
		var span: float = target_t - newest_client
		var rendered: Vector3 = base.puck_state.position + est_vel * span
		var rendered_prev: Vector3 = base.puck_state.position + est_vel * (span - tick)

		# The player aims at what they SEE — but the blade lands at the input
		# stamp regardless, which is exactly the pre-v59 mismatch when the puck
		# is drawn somewhere else.
		var blade: Vector3 = rendered + Vector3(cfg.blade_offset_m, 0.0, 0.0)
		var blade_prev: Vector3 = rendered_prev + Vector3(cfg.blade_offset_m, 0.0, 0.0)
		blade_plan[i + blade_ticks] = blade

		if PuckInteractionRules.check_pickup(
				rendered_prev, rendered, blade_prev, blade, cfg.pickup_radius):
			var p := _Pending.new()
			p.stamp = now
			p.target_t = target_t
			p.rendered = rendered
			p.rendered_prev = rendered_prev
			pending.append(p)

		# ── Host: adjudicate every claim whose instant it has now simulated ──
		# DeferredClaimQueue's release condition, and also the first moment the
		# harness knows ground truth for the rendered instant.
		var newest_host: float = host_buf.newest_host_timestamp()
		var keep: Array[_Pending] = []
		for p: _Pending in pending:
			var puck_t: float = LagCompRewind.puck_view_time(p.stamp, cfg.input_lead_ms) \
					if cfg.render_mode == RenderMode.AT_INPUT_STAMP else p.stamp
			var blade_t: float = LagCompRewind.self_view_time(p.stamp, cfg.input_lead_ms)
			if maxf(maxf(puck_t, blade_t), p.target_t) > newest_host:
				keep.append(p)
				continue

			res.client_hits += 1
			var truth_i: int = clampi(int(round(p.target_t / tick)), 0, truth.size() - 1)
			var err: float = p.rendered.distance_to(truth[truth_i])
			res.max_puck_error_m = maxf(res.max_puck_error_m, err)
			err_sum += err
			res.samples += 1

			var hp: WorldSnapshot = host_buf.get_state_at(puck_t)
			var hp_prev: WorldSnapshot = host_buf.get_state_at(LagCompRewind.prev_tick(puck_t))
			var hb: WorldSnapshot = host_buf.get_state_at(blade_t)
			var hb_prev: WorldSnapshot = host_buf.get_state_at(LagCompRewind.prev_tick(blade_t))
			var hbs: SkaterNetworkState = hb.get_skater_state(_PEER)
			var hbs_prev: SkaterNetworkState = hb_prev.get_skater_state(_PEER)
			if hp.puck_state == null or hp_prev.puck_state == null \
					or hbs == null or hbs_prev == null:
				res.client_hits -= 1
				continue

			if PuckInteractionRules.check_pickup(
					hp_prev.puck_state.position, hp.puck_state.position,
					hbs_prev.blade_contact_world, hbs.blade_contact_world, cfg.pickup_radius):
				res.host_confirms += 1
			else:
				res.false_negatives += 1
		pending = keep

	res.mean_puck_error_m = err_sum / float(maxi(res.samples, 1))
	return res
