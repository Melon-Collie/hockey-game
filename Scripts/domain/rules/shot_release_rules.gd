class_name ShotReleaseRules

# Host-side validation and clamping for shot releases. Regular wrister/slapper
# releases are now host-derived from the input stream (no RPC), but these clamps
# still apply as defense-in-depth; the one-timer release (`release_puck_one_timer`
# RPC) still flows from the client. The shot-release path is the only path that
# doesn't go through a claim resolver, so the
# same discipline the resolvers apply (PickupClaimResolver / PokeClaimResolver
# / HitClaimResolver) lives here as pure rules: every client-supplied lag-comp
# parameter is clamped to a bounded range, and one-timer eligibility is gated
# on server-visible puck state.
#
# Design rule: lag compensation is a privilege, the shot itself is not. A
# stale or forged timestamp earns zero back-date / zero RTT advance rather
# than rejecting the shot — a legit client during NTP warmup stamps 0 and must
# still be able to shoot. Only the one-timer contact gate (in GameManager) can
# reject a shot outright, because firing one requires the puck to actually be
# near the shooter.
#
# Second design rule, and it is what separates a one-timer from an FPS hitscan:
# compensation may decide WHETHER a shot connects, but it may never move the
# puck. The puck is a shared object every player is watching, so a claim that
# resolves in the shooter's past has to fire from where the puck is NOW —
# dragging it back onto the blade reads as a teleport on every other screen and
# scales with the shooter's ping. Hence one_timer_within_reach: the compensation
# is bounded by a stick's actual reach, not by the rewind window.

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

# Legit lofted shots cap the pre-normalization Y/XZ ratio at
# ShotMechanics.MAX_LOFT_RATIO (1.0 = 45°), i.e. a normalized direction y of
# ~0.707. 0.75 leaves headroom for float noise while still blocking
# near-vertical forged directions.
const MAX_DIRECTION_Y: float = 0.75

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


# One-timer eligibility, as one question. A one-timer claim is a possession-less
# grab — the host teleports the puck onto the claimant's blade and fires it — so
# every reason an ordinary corral would be refused refuses this too.
#
# `shooter_on_cooldown` is the load-bearing one and the least obvious: it is this
# claim's IDEMPOTENCY guard. `has_carrier` alone cannot see a concurrent
# host-side resolution of the SAME swing, because that resolution ends with the
# puck loose — carrier back to null, claim waved through, puck fired twice. The
# release that resolved it stamps the shooter's reattach cooldown, so "did this
# skater just put this puck in flight" is the question that actually discriminates.
# It doubles as the self-rebound rule the ordinary corral already applies.
static func one_timer_claim_blocked(has_carrier: bool, pickup_locked: bool,
		movement_locked: bool, shooter_is_ghost: bool, shooter_on_cooldown: bool) -> bool:
	return has_carrier or pickup_locked or movement_locked \
			or shooter_is_ghost or shooter_on_cooldown


# Has the puck been played out from under this claim? The range gate rewinds to
# the claimant's own stamp, so it necessarily passes against the puck they saw —
# it cannot notice that the puck has since been fired somewhere else, and
# applying the claim anyway drags it back out of that flight and re-fires it.
#
# The case: two shooters commit one-timers on the same feed. The first claim to
# arrive sets the carrier, releases, and leaves the puck loose again — so the
# second claim finds `carrier == null`, rewinds to its own view where the puck
# was right on its blade, and passes every other gate. Same shape when the loser
# is the shooter's own host-side sim (a carried release the client didn't know
# about). A release can only happen while somebody possessed the puck, so a
# release AFTER the claimant committed means the puck was corralled out of their
# swing — the swing genuinely missed, whoever ends up with it.
#
# Simultaneous claims are therefore arbitrated by arrival order, matching the
# poke / stick-lift / hit doctrine (Scripts/game/CLAUDE.md) rather than the
# contested-pickup one — a one-timer that loses the race whiffs, it does not
# split the puck.
static func one_timer_claim_is_stale(claim_host_timestamp: float, puck_last_played_time: float) -> bool:
	return puck_last_played_time > claim_host_timestamp


# ── One-timer contact ─────────────────────────────────────────────────────────
# A one-timer is judged in the SHOOTER'S OWN FRAME: the puck's offset from the
# slapper-zone centre when the swing committed, and the same offset when the
# blade arrives at the end of the retention hold. Relative offsets, so a shooter
# who carries the zone along with them costs nothing to model.
#
# The beat asks one question — did the puck cross the blade's zone while the
# stick was coming down — which is the distance from the zone centre to the
# SEGMENT joining those two offsets. Two properties fall out of that, and the
# old test (a ring of `zone_radius + puck_speed * beat + slack`, ~6 m wide around
# a 0.5 m marker on a 25 m/s feed) had neither:
#
#   - The ring that counts is the ring the player is shown. Timing tolerance
#     comes from the LENGTH OF THE BEAT — the hold, plus the puck's own dwell
#     inside the zone, ~150 ms of commit window on a hard feed — which is a real
#     quantity, rather than from inflating the target.
#   - It is one-sided, as the physics is. A commit made before the feed is
#     anywhere near still whiffs, because the segment never reaches the zone; a
#     symmetric ring rewarded firing 5 m early exactly as much as firing on time.
static func one_timer_contact_distance(commit_offset: Vector2, release_offset: Vector2) -> float:
	if not commit_offset.is_finite() or not release_offset.is_finite():
		return INF
	var seg: Vector2 = release_offset - commit_offset
	var seg_len_sq: float = seg.length_squared()
	if seg_len_sq < 0.000001:
		return release_offset.length()
	var t: float = clampf(-commit_offset.dot(seg) / seg_len_sq, 0.0, 1.0)
	return (commit_offset + seg * t).length()


static func one_timer_contact(commit_offset: Vector2, release_offset: Vector2,
		zone_radius: float) -> bool:
	return one_timer_contact_distance(commit_offset, release_offset) <= zone_radius


# Physical ceiling on how far the puck can travel THROUGH THE SHOOTER'S FRAME
# during one retention hold: the hardest shot in the game (40 m/s, plus headroom
# for attribute scaling) closing head-on with a sprinting skater (~10 m/s). The
# two offsets are client-authoritative — the claimant's own view of its own blade
# zone, the same class of thing the pickup / poke claims' blade geometry is — so
# this is the bound that stops a forged pair sweeping a rink-long segment
# through the zone centre and passing the contact test from anywhere.
const ONE_TIMER_MAX_BEAT_CLOSING_SPEED: float = 60.0

static func one_timer_beat_plausible(commit_offset: Vector2, release_offset: Vector2,
		beat_s: float) -> bool:
	if not commit_offset.is_finite() or not release_offset.is_finite():
		return false
	return commit_offset.distance_to(release_offset) \
			<= ONE_TIMER_MAX_BEAT_CLOSING_SPEED * maxf(beat_s, 0.0)


# The host's own, live-geometry half of the gate. Lag compensation decides
# WHETHER the shooter connected with the puck they saw; it may never conjure a
# stick onto a puck that is nowhere near one now. Unlike a hitscan, a one-timer
# moves a shared object every player is watching, so the compensation has to stay
# inside something physical — the shooter's fully-extended reach
# (AISkaterCaps.max_blade_reach), measured against the host's LIVE puck at the
# instant the claim is applied. Beyond it the swing whiffs rather than dragging
# the puck back onto the blade from where the link left it.
# `max_reach <= 0` (no caps entry for the peer) skips the bound, the same
# graceful convention the claim resolvers' reach clamp uses.
static func one_timer_within_reach(puck_xz: Vector2, body_xz: Vector2, max_reach: float) -> bool:
	if max_reach <= 0.0:
		return true
	return body_xz.distance_to(puck_xz) <= max_reach


# One-timer power: max slapper power scaled by a center-proximity bonus — a puck
# struck dead-center in the slapper zone gets +center_bonus, one at the edge gets
# -center_bonus, lerping linearly through 0 at half-radius. `contact_distance` is
# the beat's closest approach (one_timer_contact_distance), i.e. how squarely the
# blade actually met the puck. Shared by the client's local prediction
# (_try_one_timer_release) and the host's authoritative re-derive
# (on_remote_one_timer_release) so both compute the identical power — host
# authority over the shot, one source of truth for the formula.
static func one_timer_power(base_power: float, center_bonus: float,
		contact_distance: float, zone_radius: float) -> float:
	if zone_radius <= 0.0:
		return base_power
	var proximity: float = clampf(1.0 - contact_distance / zone_radius, 0.0, 1.0)
	return base_power * (1.0 + center_bonus * (2.0 * proximity - 1.0))
