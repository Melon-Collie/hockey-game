class_name ShotReleaseRules

# Host-side validation and clamping for shot releases. EVERY release — wrister,
# slapper, one-timer — is host-derived from the replayed input stream (no shot
# RPC), so nothing here arbitrates a client-supplied claim any more; the clamps
# stay as defense-in-depth on the params the host itself derives. The
# shot-release path is the only path that doesn't go through a claim resolver,
# so the same discipline the resolvers apply (PickupClaimResolver /
# PokeClaimResolver / HitClaimResolver) lives here as pure rules, and one-timer
# eligibility is gated on server-visible puck state.
#
# Design rule: lag compensation is a privilege, the shot itself is not. A
# stale or forged timestamp earns zero back-date / zero RTT advance rather
# than rejecting the shot — a legit client during NTP warmup stamps 0 and must
# still be able to shoot. Only the one-timer contact test can refuse a shot
# outright, because firing one requires the swing to actually have met the puck.

# The absolute age bound on any client-stamped claim, and the single source for
# it: LagCompRewind.claim_is_fresh reads this constant, and the four claim
# resolvers go through that. A release timestamp older than this earns no
# lag-comp benefits.
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

# Legit lofted shots cap the pre-normalization Y/XZ ratio at
# ShotMechanics.MAX_LOFT_RATIO (1.0 = 45°), i.e. a normalized direction y of
# ~0.707. 0.75 leaves headroom for float noise while still blocking
# near-vertical forged directions.
const MAX_DIRECTION_Y: float = 0.75

# Maximum horizontal distance a shot origin may sit from the shooter's body
# center — roughly full stick + arm reach. The origin the host fires from is now
# its own blade on the tick it replays the release input, so this is pure
# defense-in-depth: it fences any origin handed to `clamp_origin` to a reachable
# radius of the shooter's body, which is a stable anchor (the body barely moves
# tick to tick, unlike the swinging blade). Generous on purpose — an anti-abuse
# fence, not a precision check.
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


# One-timer eligibility, as one question. A one-timer is a possession-less grab
# — the host teleports the puck onto the shooter's blade and fires it — so every
# reason an ordinary corral would be refused refuses this too.
#
# `shooter_on_cooldown` is the load-bearing one and the least obvious: it is the
# IDEMPOTENCY guard. `has_carrier` alone cannot see a resolution of the SAME
# swing on an adjacent tick, because that resolution ends with the puck loose —
# carrier back to null, the redirect waved through, puck fired twice. The
# release that resolved it stamps the shooter's reattach cooldown, so "did this
# skater just put this puck in flight" is the question that actually discriminates.
# It doubles as the self-rebound rule the ordinary corral already applies.
static func one_timer_claim_blocked(has_carrier: bool, pickup_locked: bool,
		movement_locked: bool, shooter_is_ghost: bool, shooter_on_cooldown: bool) -> bool:
	return has_carrier or pickup_locked or movement_locked \
			or shooter_is_ghost or shooter_on_cooldown


# Has the puck been played out from under this swing? The contact test runs
# against the puck as the SHOOTER saw it (one input lead back), so it
# necessarily passes against the puck that was on their blade — it cannot notice
# that the puck has since been fired somewhere else, and firing anyway drags it
# back out of that flight and re-fires it.
#
# The case: two shooters commit one-timers on the same feed. The first swing to
# resolve sets the carrier, releases, and leaves the puck loose again — so the
# second finds `carrier == null`, evaluates against its own view where the puck
# was right on its blade, and passes every other gate. Same shape when the loser
# is a carried release resolved on an adjacent tick. A release can only happen
# while somebody possessed the puck, so a release AFTER this shooter committed
# means the puck was corralled out of their swing — the swing genuinely missed,
# whoever ends up with it.
#
# Simultaneous one-timers are therefore arbitrated by whose swing resolves
# first, matching the poke / stick-lift / hit doctrine (Scripts/game/CLAUDE.md)
# rather than the contested-pickup one — the loser whiffs, it does not split the
# puck.
static func one_timer_claim_is_stale(claim_host_timestamp: float, puck_last_played_time: float) -> bool:
	return puck_last_played_time > claim_host_timestamp


# Extra time the HOST holds a remote carrier's caught-one-timer window open,
# beyond `one_timer_window_duration`.
#
# The window is a cancel deadline, and the two sides do not arm it at the same
# instant: the host arms it on the tick it grants the pickup, the carrier's own
# client arms it when the grant RPC lands — one way later — and its release then
# takes an input lead to reach the host. So the client's honest, unextended
# window sits `one_way + input_lead` LATER in input-stamp space than the host's.
# Without this grace the tail of it hangs past the host's deadline, where the
# host's sim has already cancelled the wind-up back to carry: the release input
# arrives to a skater who is no longer winding up and the shot silently never
# happens, while the client predicted it and watches the puck snap back.
#
# Both sides tick the window one input per tick, so shifting the host's end by
# exactly that offset makes the two cancel on the SAME input stamp. The
# broadcast interval is slack against ping-estimate error, and it is deliberately
# one-sided: too little grace eats shots, too much only leaves the host briefly
# still holding a wind-up the client dropped, which the next broadcast settles.
# Clamped so a garbage ping reading can't hold a wind-up open indefinitely.
const ONE_TIMER_WINDOW_GRACE_MAX_S: float = 0.30

static func one_timer_window_grace(peer_rtt_ms: float, input_lead_s: float,
		broadcast_interval_s: float) -> float:
	if not is_finite(peer_rtt_ms) or peer_rtt_ms <= 0.0:
		return 0.0
	return clampf(peer_rtt_ms / 2000.0 + input_lead_s + broadcast_interval_s,
			0.0, ONE_TIMER_WINDOW_GRACE_MAX_S)


# One-timer contact test: did this swing actually meet the puck?
#
# The blade sweeps the slapper zone at ice level at the END of the retention
# hold, so the question is whether the PUCK'S OWN PATH carried it through that
# zone within the swing's timing tolerance. `back_time` is how far behind the
# strike instant the path still counts (the retention hold — the puck has
# already travelled that far since the player committed — plus the human timing
# window); `forward_time` is that same window ahead. Distances come out of the
# puck's velocity, so the tolerance is measured ALONG ITS LINE: lateral reach
# stays `zone_radius` no matter how hard the feed was.
#
# That directionality is the whole point. The gate this replaced inflated the
# ring isotropically (`zone_radius + speed * time`), which on a 25 m/s feed
# turned a 0.5 m zone into a ~5 m disc — a puck sailing metres WIDE of the
# shooter, never reachable at any timing, connected. Timing slop is the thing
# a one-timer window is supposed to forgive; position slop is not.
#
# `puck_airborne` is the same blade-plane gate every other stick interaction
# uses (PuckReceptionRules.blade_can_interact with a grounded blade): a slapper
# comes down onto the ice, so a puck still in the air is swung under.
static func one_timer_connects(zone_xz: Vector2, zone_radius: float,
		puck_xz: Vector2, puck_vel_xz: Vector2, puck_airborne: bool,
		back_time: float, forward_time: float) -> bool:
	if not PuckReceptionRules.blade_can_interact(false, puck_airborne):
		return false
	var from: Vector2 = puck_xz - puck_vel_xz * back_time
	var to: Vector2 = puck_xz + puck_vel_xz * forward_time
	var seg: Vector2 = to - from
	var len_sq: float = seg.length_squared()
	var t: float = 0.0
	if len_sq > 1e-10:
		t = clampf((zone_xz - from).dot(seg) / len_sq, 0.0, 1.0)
	return zone_xz.distance_squared_to(from + seg * t) <= zone_radius * zone_radius


# One-timer power: max slapper power scaled by a center-proximity bonus — a puck
# struck dead-center in the slapper zone gets +center_bonus, one at the edge gets
# -center_bonus, lerping linearly through 0 at half-radius. Both one-timer
# release paths — the leniency redirect and the caught-and-pinned slapshot —
# grade the bonus through here, so how centred the catch was pays the same
# either way.
static func one_timer_power(base_power: float, center_bonus: float,
		zone_xz: Vector2, puck_xz: Vector2, zone_radius: float) -> float:
	if zone_radius <= 0.0:
		return base_power
	var proximity: float = clampf(1.0 - zone_xz.distance_to(puck_xz) / zone_radius, 0.0, 1.0)
	return base_power * (1.0 + center_bonus * (2.0 * proximity - 1.0))
