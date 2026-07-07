class_name ReconciliationRules

# Pure rules for deciding when to overwrite client-side prediction with
# server-authoritative state. Keeping these as isolated functions lets us
# test threshold behavior without a live skater/puck.

# LocalController: should we snap the skater to server state and replay
# unacknowledged inputs? True when either position, velocity, or upper-body
# rotation has diverged far enough that soft reconciliation would look wrong.
# The upper-body check is gated on a non-zero threshold so existing call
# sites and tests that don't pass rotation parameters keep working.
static func skater_needs_reconcile(
		client_position: Vector3,
		client_velocity: Vector3,
		server_position: Vector3,
		server_velocity: Vector3,
		position_threshold: float,
		velocity_threshold: float,
		client_upper_body_rotation: float = 0.0,
		server_upper_body_rotation: float = 0.0,
		upper_body_rotation_threshold: float = 0.0) -> bool:
	if client_position.distance_to(server_position) >= position_threshold:
		return true
	if client_velocity.distance_to(server_velocity) >= velocity_threshold:
		return true
	if upper_body_rotation_threshold > 0.0:
		var angle_delta: float = absf(angle_difference(
				client_upper_body_rotation, server_upper_body_rotation))
		if angle_delta >= upper_body_rotation_threshold:
			return true
	return false

# LocalController stale-ack gate: is this broadcast's ack (the host's
# last_processed_host_timestamp) newer than the last one a reconcile already
# consumed? The host broadcasts world state every tick but only advances the
# ack when it pops a due input, so consecutive broadcasts routinely repeat the
# same ack. A reconcile at ack T matches its prediction and then trims that
# prediction away, so re-running the comparison for a repeated ack finds no
# match, falls back to the live (prediction-lead-ahead) position, and fires a
# spurious snap. Only a strictly-newer ack carries a fresh confirmed input to
# compare against. Epsilon absorbs the 0.1ms wire-grid quantization of the ack
# so a re-sent value never reads as "advanced" by a rounding hair.
static func ack_is_new(ack_ts: float, last_ack_ts: float, epsilon: float) -> bool:
	return ack_ts > last_ack_ts + epsilon

# PuckController: has the client-predicted puck drifted so far from the
# server's position that we need a hard snap (teleport / physics-glitch
# level)? Below this threshold, the caller runs a softer velocity+position
# lerp so Jolt doesn't get fought mid-bounce.
static func puck_needs_hard_snap(
		client_position: Vector3,
		server_position: Vector3,
		threshold: float) -> bool:
	return client_position.distance_to(server_position) > threshold
