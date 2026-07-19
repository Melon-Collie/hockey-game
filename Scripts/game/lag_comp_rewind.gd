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


# Host-time at which to query StateBufferManager for the claimant's
# locally-predicted entity. RTT does not enter the formula — the rewind depth
# is a function of the INPUT_LEAD_SEC convention, so validation is
# RTT-independent and lower-ping players don't beat higher-ping players on
# legitimately-stamped claims.
static func self_view_time(host_timestamp: float) -> float:
	return host_timestamp + NetworkManager.INPUT_LEAD_SEC


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


# Stage-3 forward-prediction depth: how many physics ticks a remote body is
# intent-integrated forward from its interpolated-past base toward host-present.
# The client (RemoteController render) and the host (HitClaimResolver claim rewind)
# BOTH call this with the SAME fraction (Constants.REMOTE_FORWARD_PREDICT_FRACTION)
# and interp_delay, so their tick counts — and therefore the predicted positions —
# agree, keeping render == rewind. `fraction` is a param (not read here) so the
# formula is unit-testable at any value even while the shipped constant varies.
# The delay is clamped to the same ceiling remote_view_time uses — the host-side
# caller feeds it the raw client-reported interp_delay_ms, and without the clamp
# a crafted claim (or a NaN/huge warmup glitch) turns the integration loop into
# an unbounded host stall.
static func forward_predict_ticks(fraction: float, interp_delay_s: float) -> int:
	if not is_finite(interp_delay_s):
		return 0
	var delay_s: float = clampf(interp_delay_s, 0.0, _INTERP_DELAY_CLAMP_MS_MAX / 1000.0)
	return roundi(clampf(fraction, 0.0, 1.0) * delay_s * float(Constants.PHYSICS_TICK))


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
