class_name LagCompRewind

# Time-base helpers for lag-compensated validation. The host's claim resolvers
# (PickupClaimResolver, PokeClaimResolver, HitClaimResolver) and shot-release
# goalie rewind all need to reproduce what a client saw at their view-time. Two
# rendering perspectives drive the rewind:
#
#   SELF view:   the entity the claimant rendered via local prediction (their
#                own skater body / blade). The client's view at host-timestamp T
#                was the result of the input stamped T + INPUT_LEAD_SEC. The
#                host's gated processing applied that input at host-wall
#                T + INPUT_LEAD_SEC and StateBufferManager captured the
#                resulting state with that timestamp.
#
#   REMOTE view: anything the claimant rendered via interpolation (other
#                skaters, loose puck, remote-carried puck, and the goalie —
#                clients render the goalie purely from the interpolated host
#                pose broadcast).
#
# Pick the perspective per entity. Hit checks need both — see HitClaimResolver
# for the canonical two-rewind pattern. Pickup/poke rewind the blade as SELF
# and the puck as REMOTE. Shot release rewinds the shooter's blade as SELF (the
# firing origin) and the goalie as REMOTE.

const _INTERP_DELAY_CLAMP_MS_MAX: float = 200.0

# Claim-stamp plausibility bounds. A legit claim is stamped with the client's
# estimated_host_time() at send and arrives ~one-way later, so its age at
# arrival is one_way + frame alignment + NTP error. The claim resolvers'
# MAX_CLAIM_AGE_S (200ms) bounds age absolutely, but inside that window the
# earlier stamp wins contested pickups outright — a claimant backdating
# ~190ms would win essentially every 50/50 puck ("timestamp shopping").
# Validating age against the host's own ping measurement for that peer
# shrinks the shoppable window to real jitter. Future stamps are never legit.
const _STAMP_FUTURE_SLACK_S: float = 0.05
const _STAMP_PAST_SLACK_S: float = 0.1  # frame alignment + ping jitter + NTP error
# Conservative RTT assumed when the host has no ping sample for the peer yet
# (warmup, or a modified client that deliberately never calls report_ping to
# escape the past bound). Must exceed a real bad-link one-way + slack so a
# legitimate high-ping claim in the warmup gap isn't rejected, while still
# denying the "no sample -> unbounded backdate" hole. The real teeth are the
# host-measured RTT (P0 part a); this is the floor that holds until it lands.
const _STAMP_NO_SAMPLE_RTT_MS: float = 150.0


# `peer_rtt_ms` is the host-measured ping for the claiming peer
# (NetworkManager.get_peer_ping_ms); <= 0 means no sample yet, in which case a
# conservative default RTT bounds the past age (NOT unbounded — a client that
# never reports must not thereby win every backdated 50/50). The resolvers'
# absolute MAX_CLAIM_AGE_S cap still holds on top of this.
static func is_claim_stamp_plausible(now: float, host_timestamp: float, peer_rtt_ms: float) -> bool:
	if not is_finite(host_timestamp):
		return false
	var elapsed: float = now - host_timestamp
	if elapsed < -_STAMP_FUTURE_SLACK_S:
		return false
	var effective_rtt_ms: float = peer_rtt_ms if peer_rtt_ms > 0.0 else _STAMP_NO_SAMPLE_RTT_MS
	return elapsed <= effective_rtt_ms / 2000.0 + _STAMP_PAST_SLACK_S


# Generous allowance over the link-derived floor for the client's LEGITIMATE
# jitter margin (its adaptive delay adds the measured PDV spread, which can
# genuinely spike). The bound halves the exploit window on a clean link; it is
# not, and cannot be, exact — the host can't see the client's downstream PDV.
const _INTERP_DELAY_JITTER_ALLOWANCE_MS: float = 100.0


# Anti-cheat bound on the claim-carried interp_delay_ms — the companion of
# is_claim_stamp_plausible, completing the P0/P1 family. The client self-reports
# the interpolation delay its render used, and every remote-view rewind AND the
# stage-3 forward-predict depth trust it. Bounded only by the flat 200 ms cap, a
# modified client on a 20 ms link could report the cap and get victims rewound
# ~175 ms further into the past than it ever saw ("hit them where they were").
# The host bounds the report against what the delay SHOULD be on the measured
# link: one-way + one broadcast interval + the jitter allowance. No ping sample
# yet → the same conservative default RTT the stamp check uses.
static func plausible_interp_delay_ms(reported_ms: float, peer_rtt_ms: float) -> float:
	if not is_finite(reported_ms):
		return 0.0
	var rtt: float = peer_rtt_ms if peer_rtt_ms > 0.0 else _STAMP_NO_SAMPLE_RTT_MS
	var ceiling: float = rtt / 2.0 + 1000.0 / float(Constants.STATE_RATE) \
			+ _INTERP_DELAY_JITTER_ALLOWANCE_MS
	var bounded: float = clampf(reported_ms, 0.0, minf(ceiling, _INTERP_DELAY_CLAMP_MS_MAX))
	# Telemetry: legit players should never trip this — sustained clamps mean
	# the allowance is too tight (mis-rewinding honest high-jitter claims) or a
	# client is inflating its delay. >1 ms guard skips float noise.
	if reported_ms - bounded > 1.0:
		NetworkTelemetry.record_delay_clamped(reported_ms - bounded)
	return bounded


# Hard bound on the claim-carried adaptive lead extra — mirrors
# ClockSync.MAX_LEAD_EXTRA_S (pinned by test) so a modified client can't push
# its self-view rewind arbitrarily forward by inflating the reported lead.
const _INPUT_LEAD_EXTRA_MAX_S: float = 0.05


# Host-time at which to query StateBufferManager for the claimant's
# locally-predicted entity. RTT does not enter the formula — the rewind depth
# is a function of the input-lead stamping convention, so validation is
# RTT-independent and lower-ping players don't beat higher-ping players on
# legitimately-stamped claims. Since the lead ADAPTS (ClockSync's servo raises
# the stamp lead when the host queue runs dry), claims carry the lead the
# client stamped with and the rewind follows it — bounded to
# [INPUT_LEAD_SEC, INPUT_LEAD_SEC + extra max]. input_lead_ms < 0 (or absent
# — the host's own local claims) uses the base constant.
static func self_view_time(host_timestamp: float, input_lead_ms: float = -1.0) -> float:
	return host_timestamp + clamped_lead_s(input_lead_ms)


# The claim-carried input lead, in seconds, bounded to the range a legitimate
# client can actually stamp with. Shared by every consumer of the lead — the two
# view-times and the forward-predict depth — so a modified client cannot buy
# itself a different rewind depth in one of them. A negative or absent value
# (the host's own local claims, bots) falls back to the base constant.
static func clamped_lead_s(input_lead_ms: float = -1.0) -> float:
	if input_lead_ms < 0.0 or not is_finite(input_lead_ms):
		return NetworkManager.INPUT_LEAD_SEC
	return clampf(input_lead_ms / 1000.0,
			NetworkManager.INPUT_LEAD_SEC, NetworkManager.INPUT_LEAD_SEC + _INPUT_LEAD_EXTRA_MAX_S)


# Host-time at which to query StateBufferManager for any entity the claimant
# rendered via interpolation (or, for the goalie, via AI tracking the
# interpolated puck). `interp_delay_ms` is clamped to a sane range so a
# malicious or warmup-glitched claim can't query arbitrarily far back.
static func remote_view_time(host_timestamp: float, interp_delay_ms: float) -> float:
	return host_timestamp - clampf(interp_delay_ms, 0.0, _INTERP_DELAY_CLAMP_MS_MAX) / 1000.0


# Timestamp one physics tick before `view_time` — used as the prev-snapshot
# endpoint in swept-segment pickup/poke tests. Works for either perspective.
static func prev_tick(view_time: float) -> float:
	return view_time - 1.0 / float(Constants.PHYSICS_TICK)


# Host-time at which to query the LOOSE puck for a claim. The claimant renders
# the loose puck predicted to its estimate of host present — i.e. AT the claim
# stamp — so the host rewinds its own history to the stamp itself (the callers'
# freshness gates clamp a stale/future stamp). Kept as a named seam rather than
# inlined so every loose-puck rewind states which timeline it reads. The
# CARRIED puck is unaffected — it rides the carrier's render timeline
# (remote_view + forward_predict_skater); this helper is only for claims
# against a loose puck (pickup / deflect verdicts, the one-timer range gate).
static func puck_view_time(host_timestamp: float, input_lead_ms: float = -1.0) -> float:
	return host_timestamp + clamped_lead_s(input_lead_ms)


# Stage-3 forward-prediction depth: how many physics ticks a remote body is
# intent-integrated forward from its interpolated-past base toward host-present.
# The client (RemoteController render) and the host claim rewinds (hit / poke /
# stick-lift, via forward_predict_skater below) ALL call this with the SAME
# fraction (Constants.REMOTE_FORWARD_PREDICT_FRACTION) and interp_delay, so
# their tick counts — and therefore the predicted positions — agree, keeping
# render == rewind. `fraction` is a param (not read here) so the
# formula is unit-testable at any value even while the shipped constant varies.
# The delay is clamped to the same ceiling remote_view_time uses — the host-side
# caller feeds it the raw client-reported interp_delay_ms, and without the clamp
# a crafted claim (or a NaN/huge warmup glitch) turns the integration loop into
# an unbounded host stall.
static func forward_predict_ticks(fraction: float, interp_delay_s: float,
		lead_s: float = 0.0) -> int:
	if not is_finite(interp_delay_s) or not is_finite(lead_s):
		return 0
	var delay_s: float = clampf(interp_delay_s, 0.0, _INTERP_DELAY_CLAMP_MS_MAX / 1000.0)
	var lead: float = clampf(lead_s, 0.0,
			NetworkManager.INPUT_LEAD_SEC + _INPUT_LEAD_EXTRA_MAX_S)
	return roundi(clampf(fraction, 0.0, 1.0) * (delay_s + lead) * float(Constants.PHYSICS_TICK))


# Stage-3 shared reconstruction: intent-integrate a remote-rendered skater from
# its rewound (interpolated-past) snapshot to the instant the claimant actually
# rendered it, filling caller-owned `scratch`. Returns true when integration ran
# (fraction > 0, valid inputs); false = fraction 0 / no controller — caller uses
# the raw snapshot, the exact legacy render == rewind. One helper so every claim
# resolver reconstructs identically to RemoteController's render:
#  - same primitive (SkaterMovementRules.integrate_forward), same shared
#    fraction/decay constants, same has_puck=false convention;
#  - intent quantized through the wire codec (quantize_move_intent) so the host's
#    raw buffered intent (bots are analog) matches what clients decoded;
#  - depth from the claim-carried interp_delay_ms — the same value the
#    claimant's render used that frame.
static func forward_predict_skater(snap: SkaterNetworkState, ctrl: SkaterController,
		interp_delay_ms: float, input_lead_ms: float,
		scratch: SkaterMovementRules.ForwardResult) -> bool:
	if snap == null or ctrl == null:
		return false
	var ticks: int = forward_predict_ticks(
			Constants.REMOTE_FORWARD_PREDICT_FRACTION, interp_delay_ms / 1000.0,
			clamped_lead_s(input_lead_ms))
	if ticks <= 0:
		return false
	return _integrate_skater(snap, ctrl, ticks, scratch)


# The CLAIMANT'S OWN body at their self-view instant is not in the buffer, and
# cannot be: the host holds a client's input until its stamp comes due, so at
# claim arrival (host clock ~ host_ts + one_way) the newest capture sits at
# host_ts + one_way while self_view_time asks for host_ts + lead. Whenever the
# lead exceeds the one-way trip — every link under ~2x the lead, i.e. MOST of
# them, and the cleaner the link the worse it is — the lookup lands past the
# newest sample, and StateBufferManager._find_bracket answers a future query
# with the newest entry and no signal at all. The claimant's own body is then
# rewound SHORT by (lead - one_way), dragging the reach and continuity clamps
# back toward a stale body and eating honest claims at full extension. Measured
# worst case: at the servo's 50 ms lead cap on a 20 ms link, 65 ms of
# under-rewind, ~0.59 m at skating speed against a 0.7 m contact diameter.
#
# Returns the displacement to ADD to body-anchored quantities read from the
# self-view snapshot (position, blade_contact_world — the blade rides the body,
# the same rigid translation the carrier reconstructions above apply to a
# carried puck / stick shaft). Vector3.ZERO when the lookup was answerable, so a
# link whose one-way already exceeds the lead is untouched. Depth is bounded by
# the same lead ceiling the self-view rewind is bounded by, so a crafted claim
# cannot buy itself integration distance.
static func self_view_catch_up(snap: SkaterNetworkState, ctrl: SkaterController,
		self_view_t: float, newest_ts: float,
		scratch: SkaterMovementRules.ForwardResult) -> Vector3:
	if snap == null or ctrl == null or newest_ts < 0.0 or not is_finite(self_view_t):
		return Vector3.ZERO
	var gap: float = minf(self_view_t - newest_ts,
			NetworkManager.INPUT_LEAD_SEC + _INPUT_LEAD_EXTRA_MAX_S)
	var ticks: int = roundi(gap * float(Constants.PHYSICS_TICK))
	if ticks <= 0:
		return Vector3.ZERO
	if not _integrate_skater(snap, ctrl, ticks, scratch):
		return Vector3.ZERO
	return scratch.position - snap.position


# Shared integration core for both reconstructions above — one body, so the
# remote-render rewind and the self-view catch-up can never drift apart.
static func _integrate_skater(snap: SkaterNetworkState, ctrl: SkaterController,
		ticks: int, scratch: SkaterMovementRules.ForwardResult) -> bool:
	var nm: RefCounted = ctrl.native_movement()
	if nm != null:
		# get_movement_config() is still consulted for its side effect of
		# re-normalizing cfg.thrust to base — but the native instance was
		# configured from the base-thrust build, so it already integrates at
		# base + the symmetric stagger scaling, same as the client render.
		nm.integrate_forward(
				snap.position, snap.velocity,
				WorldStateCodec.quantize_move_intent(snap.move_intent),
				atan2(snap.facing.x, snap.facing.y), false,
				snap.brake_intent, snap.sprint_active,
				1.0 / float(Constants.PHYSICS_TICK), ticks,
				Constants.FORWARD_PREDICT_INTENT_DECAY_TICKS,
				snap.stagger_timer, true)
		scratch.position = nm.get_forward_position()
		scratch.velocity = nm.get_forward_velocity()
		return true
	SkaterMovementRules.integrate_forward(
			snap.position, snap.velocity,
			WorldStateCodec.quantize_move_intent(snap.move_intent),
			atan2(snap.facing.x, snap.facing.y), false,
			snap.brake_intent, snap.sprint_active,
			ctrl.get_movement_config(), 1.0 / float(Constants.PHYSICS_TICK),
			ticks, Constants.FORWARD_PREDICT_INTENT_DECAY_TICKS, scratch,
			snap.stagger_timer, ctrl.get_body_check_config())
	return true


# Structural anti-cheat for client-authoritative blade claims. A pickup / poke /
# stick-lift claim now carries the client's OWN blade geometry (its "aim" — the
# precise thing the client is authoritative over, exactly as AAA FPS lag-comp
# takes the shooter's aim from the usercmd), instead of the host reconstructing
# the claimant's blade from its lossy self-view snapshot. The host trusts that
# aim but pins it to within the claimant's physical reach of the
# SERVER-authoritative body, so a modified client can't teleport its blade onto a
# distant puck. `max_reach` is the skater's fully-extended arm+stick+blade span
# (AISkaterCaps.max_blade_reach) — a real measurement, not a tuned margin. Points
# already within reach pass through untouched; only an impossible reach is pulled
# back to the reach sphere along the aim line (graceful — never rejects a legal
# claim over body-position residual, which the reach ceiling comfortably absorbs).
# max_reach <= 0 (no caps entry for the peer) skips the clamp.
static func clamp_client_blade(point: Vector3, body: Vector3, max_reach: float) -> Vector3:
	if max_reach <= 0.0:
		return point
	var offset: Vector3 = point - body
	var d: float = offset.length()
	if d <= max_reach:
		return point
	return body + offset * (max_reach / d)


# Second, tighter anti-cheat bound on the client-authoritative blade, layered on
# top of the reach clamp. The reach clamp alone leaves the whole arm+stick+blade
# sphere (~2.5 m) free, so a modified client could aim its blade straight at the
# puck on every contested tick ("always-max-reach, always-catch"). But the host
# INDEPENDENTLY reconstructs that skater's blade from the client's own replicated
# inputs (SkaterNetworkState.blade_contact_world, buffered + interpolated), so it
# knows roughly where the blade actually was. Pin the client point to within a
# physically-plausible continuity distance of that reconstruction: a legit precise
# aim differs from the lossy reconstruction only by the reconstruction error, so
# it passes untouched; a synthesized teleport onto the puck is pulled back.
#
# `reconstructed == ZERO` means the host has no sample for this skater at the
# rewind instant (warmup, or the host-only field never populated) — skip the
# clamp and lean on the reach clamp alone, exactly as if this bound didn't exist.
# GRACEFUL: like the reach clamp, it never rejects a claim, only clips an
# impossible offset along the aim line (angular aim preserved, distance capped).
static func continuity_clamp(point: Vector3, reconstructed: Vector3, max_offset: float) -> Vector3:
	if reconstructed == Vector3.ZERO or max_offset <= 0.0:
		return point
	var offset: Vector3 = point - reconstructed
	var d: float = offset.length()
	if d <= max_offset:
		return point
	return reconstructed + offset * (max_offset / d)


# Max legitimate distance between the client's exact-view-time blade and the
# host's buffer-reconstructed blade (continuity_clamp's `max_offset`). The
# reconstruction lags the true blade by the buffer interpolation window: the blade
# (Hands-scaled `blade_speed`, a real cap) traverses this far over that window,
# plus slack for IK smoothing, body translation, and NTP error. CONSERVATIVE by
# design — sized to clear fast-dangle / packet-loss reconstruction lag so a legit
# claim is never pulled (which would re-introduce the grab-then-lose bug that made
# the blade client-authoritative in the first place). Tighten from the
# pickup/poke/stick-lift claim-miss telemetry once validated on a real link.
const _BLADE_CONTINUITY_WINDOW_S: float = 0.033
const _BLADE_CONTINUITY_SLACK_M: float = 0.30

static func blade_continuity_tolerance(blade_speed: float) -> float:
	return maxf(blade_speed, 0.0) * _BLADE_CONTINUITY_WINDOW_S + _BLADE_CONTINUITY_SLACK_M
