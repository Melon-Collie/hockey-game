class_name ShotReleaseRules

# Host-side validation and clamping for client shot-release claims
# (`release_puck` / `release_puck_one_timer` RPCs). The shot-release path is
# the only client→host claim that doesn't go through a claim resolver, so the
# same discipline the resolvers apply (PickupClaimResolver / PokeClaimResolver
# / HitClaimResolver) lives here as pure rules: every client-supplied lag-comp
# parameter is clamped to a bounded range, and one-timer eligibility is gated
# on server-visible puck state.
#
# Design rule: lag compensation is a privilege, the shot itself is not. A
# stale or forged timestamp earns zero back-date / zero RTT advance rather
# than rejecting the shot — a legit client during NTP warmup stamps 0 and must
# still be able to shoot. Only the one-timer range gate (in GameManager) can
# reject a shot outright, because firing one requires the puck to actually be
# near the shooter.

# Mirrors PickupClaimResolver.MAX_CLAIM_AGE_S — a release timestamp older than
# this earns no lag-comp benefits.
const MAX_CLAIM_AGE_S: float = 0.2

# Float-rounding slack on the age boundary. 0.2 isn't representable, so
# `now - host_timestamp` for a stamp at exactly MAX_CLAIM_AGE_S can land an ULP
# above it and wrongly reject an at-boundary claim. 1 µs is negligible against
# the 200 ms window. Applied to both age comparisons so they agree at the edge.
const _AGE_EPSILON_S: float = 0.000001

# Hard ceiling on the claimed RTT used for the release-point forward advance.
# Without it, a forged rtt_ms teleports the puck (direction * power * rtt/2)
# arbitrarily far downfield on every shot.
const MAX_RTT_MS: float = 300.0
# The claimed RTT may exceed the host's own measurement of that peer by this
# factor plus slack (the client's latest unaveraged sample legitimately spikes
# above the smoothed host-side ping).
const RTT_MEASURED_HEADROOM: float = 1.5
const RTT_MEASURED_SLACK_MS: float = 30.0

# Legit elevated shots cap the apex at max_apex_above_blade = 1.5 m, giving a
# max vertical ratio of ~0.46 at minimum backhand wrister power. 0.6 leaves
# headroom for tuning while blocking near-vertical forged directions.
const MAX_DIRECTION_Y: float = 0.6

# Slack added to the one-timer range gate: covers shooter drift between the
# client's stamp and host processing, plus interpolation error on the rewound
# puck. Generous on purpose — the client already enforced the tight check.
const ONE_TIMER_RANGE_SLACK_M: float = 1.0

# Maximum horizontal distance a shot origin may sit from the shooter's body
# center — roughly full stick + arm reach. The client sends its true release
# point (its locally-predicted blade) so the host fires the puck from exactly
# where the shooter shot; the host trusts that point but clamps it to this
# radius of the shooter's host-live body so a forged origin can't fire from
# across the rink. The body barely moves in the RPC window (unlike the swinging
# blade), so it's a stable anchor. Generous on purpose — this is an anti-abuse
# fence, not a precision check (the client's point is already the right one).
const MAX_ORIGIN_REACH_M: float = 2.5


# Clamp a client-claimed RTT against the host's own measurement of that peer.
# `host_measured_ms <= 0` means no sample yet (just connected) — fall back to
# the hard ceiling only.
static func clamp_rtt_ms(claimed_ms: float, host_measured_ms: float) -> float:
	if not is_finite(claimed_ms):
		return 0.0
	var ceiling: float = MAX_RTT_MS
	if host_measured_ms > 0.0:
		ceiling = minf(host_measured_ms * RTT_MEASURED_HEADROOM + RTT_MEASURED_SLACK_MS, MAX_RTT_MS)
	return clampf(claimed_ms, 0.0, ceiling)


# Goalie-reaction back-date for a release stamped `host_timestamp`, evaluated
# at host time `now`. Future stamps and stamps older than MAX_CLAIM_AGE_S
# (forged, or the pre-warmup zero stamp) earn zero back-date.
static func clamp_back_date(now: float, host_timestamp: float) -> float:
	if not is_finite(host_timestamp):
		return 0.0
	var elapsed: float = now - host_timestamp
	if elapsed < 0.0 or elapsed > MAX_CLAIM_AGE_S + _AGE_EPSILON_S:
		return 0.0
	return elapsed


# Whether a release timestamp is fresh enough to drive a state-buffer rewind.
static func is_timestamp_fresh(now: float, host_timestamp: float) -> bool:
	if not is_finite(host_timestamp):
		return false
	var elapsed: float = now - host_timestamp
	return elapsed >= 0.0 and elapsed <= MAX_CLAIM_AGE_S + _AGE_EPSILON_S


# Normalize a client-supplied shot direction and clamp its elevation angle.
# Returns Vector3.ZERO for degenerate input (zero-length, non-finite, or
# straight up/down) — the caller drops the shot.
static func sanitize_direction(direction: Vector3) -> Vector3:
	if not direction.is_finite() or direction.length_squared() < 0.0001:
		return Vector3.ZERO
	var dir: Vector3 = direction.normalized()
	var xz_len: float = Vector2(dir.x, dir.z).length()
	if xz_len < 0.0001:
		return Vector3.ZERO
	if absf(dir.y) > MAX_DIRECTION_Y:
		var clamped_y: float = signf(dir.y) * MAX_DIRECTION_Y
		var xz_scale: float = sqrt(1.0 - clamped_y * clamped_y) / xz_len
		dir = Vector3(dir.x * xz_scale, clamped_y, dir.z * xz_scale)
	return dir


# Clamp a client-supplied shot power to the shooter's host-known maximum
# (attribute-scaled controller export, plus any legit bonus the caller folds
# into `max_power`).
static func clamp_power(power: float, max_power: float) -> float:
	if not is_finite(power):
		return 0.0
	return clampf(power, 0.0, max_power)


# Validate a client-supplied shot ORIGIN against the shooter's body. Clamps the
# horizontal (XZ) offset to `max_reach`; the y component is passed through
# untouched (the host overrides it with release()'s elevation y anyway). A
# non-finite origin falls back to the shooter's body position. See
# MAX_ORIGIN_REACH_M for why the body — not the buffered blade — is the anchor.
static func clamp_origin(client_origin: Vector3, shooter_pos: Vector3, max_reach: float = MAX_ORIGIN_REACH_M) -> Vector3:
	if not client_origin.is_finite():
		return shooter_pos
	var off := Vector2(client_origin.x - shooter_pos.x, client_origin.z - shooter_pos.z)
	if off.length() > max_reach:
		off = off.normalized() * max_reach
	return Vector3(shooter_pos.x + off.x, client_origin.y, shooter_pos.z + off.y)


# One-timer range gate: the (rewound) puck the shooter saw must be within the
# slapper zone radius plus speed leniency — the same formula the client's
# `_effective_one_timer_leniency` uses — plus server-side slack.
static func one_timer_in_range(zone_xz: Vector2, puck_xz: Vector2,
		zone_radius: float, puck_speed: float, leniency_time: float) -> bool:
	var max_dist: float = zone_radius + puck_speed * leniency_time + ONE_TIMER_RANGE_SLACK_M
	return zone_xz.distance_to(puck_xz) <= max_dist
