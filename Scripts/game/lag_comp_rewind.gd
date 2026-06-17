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


# `peer_rtt_ms` is the host-measured ping for the claiming peer
# (NetworkManager.get_peer_ping_ms); <= 0 means no sample yet, in which case
# only the future bound applies (the resolvers' age cap still holds).
static func is_claim_stamp_plausible(now: float, host_timestamp: float, peer_rtt_ms: float) -> bool:
	if not is_finite(host_timestamp):
		return false
	var elapsed: float = now - host_timestamp
	if elapsed < -_STAMP_FUTURE_SLACK_S:
		return false
	if peer_rtt_ms <= 0.0:
		return true
	return elapsed <= peer_rtt_ms / 2000.0 + _STAMP_PAST_SLACK_S


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
