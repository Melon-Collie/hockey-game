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
#                skaters, loose puck, remote-carried puck, and — although the
#                client runs goalie AI locally rather than interpolating — the
#                goalie, because the client's AI tracked the interpolated puck
#                from T - interp_delay).
#
# Pick the perspective per entity. Hit checks need both — see HitClaimResolver
# for the canonical two-rewind pattern. Pickup/poke rewind the blade as SELF
# and the puck as REMOTE.

const _INTERP_DELAY_CLAMP_MS_MAX: float = 200.0


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
