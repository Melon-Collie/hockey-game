class_name HockeyStopRules

# Pure math for the cosmetic hockey-stop pose: when a skater brakes hard at
# speed, the LOWER BODY yaws across the travel direction (legs sideways,
# blades scraping) while the torso keeps facing the play — the signature
# stop silhouette. Everything here derives from the velocity-based effort
# signal the gait already computes, so every machine (local, bot, remote,
# replay) reads the identical engagement from state it already has; nothing
# crosses the wire.
#
# The pose itself (leg yaw blend, scissor, edge roll, stance floor) lives in
# SkaterSkatingCoordinator; this file owns the decisions that must not
# wobble frame-to-frame: engagement hysteresis and the side latch.
#
# Conventions: upper-body/skater local frame with −Z forward, +X right.
# `effort` is the gait's smoothed tangential-acceleration signal in [−1, +1]
# (−1 = braking hard). Yaw values are lower-body rotation.y offsets, where
# POSITIVE rotation.y turns the legs toward −X (left).


# Engage when braking hard at real speed. `effort_threshold` is the fraction
# of full braking effort required (0..1); coasting friction never reaches it,
# so only a deliberate brake (or a wall) triggers the stop.
static func should_engage(
		effort: float, ground_speed: float,
		effort_threshold: float, min_speed: float) -> bool:
	return effort <= -effort_threshold and ground_speed >= min_speed


# Release with hysteresis — well inside the engage bounds, so the pose never
# chatters at the threshold: the brake easing off (effort recovering past
# 40% of the engage bar) or the stop completing (speed collapsing below 40%
# of the engage floor) both end it.
static func should_release(
		effort: float, ground_speed: float,
		effort_threshold: float, min_speed: float) -> bool:
	return effort > -effort_threshold * 0.4 or ground_speed < min_speed * 0.4


# Which hip leads the stop, latched ONCE at engagement (travel direction
# wobbles during the skid; re-deriving per tick would flip the legs
# mid-stop). Lateral drift picks the natural side — momentum sliding toward
# the skater's right (+X) plants the right side; dead-straight travel
# defaults to a right-side stop.
static func latch_side(local_velocity: Vector3) -> float:
	return 1.0 if local_velocity.x >= 0.0 else -1.0


# Lower-body yaw offset that turns the legs perpendicular to TRAVEL (not to
# facing — you stop across your momentum wherever you're looking), on the
# latched side, capped so the rig never fully breaks from under the torso.
# Wrapped before clamping so backward travel resolves to the near-side
# perpendicular instead of a wound-up full turn.
static func stop_yaw(local_velocity: Vector3, side: float, max_yaw: float) -> float:
	var fwd: float = -local_velocity.z
	var lat: float = local_velocity.x
	if Vector2(lat, fwd).length() < 0.01:
		return 0.0
	# Body-frame travel angle: 0 = straight ahead, positive = toward +X (right).
	var travel_angle: float = atan2(lat, fwd)
	var legs_angle: float = wrapf(travel_angle + side * PI * 0.5, -PI, PI)
	# rotation.y positive = legs toward −X (left) = NEGATIVE body-frame angle.
	return clampf(-legs_angle, -max_yaw, max_yaw)
