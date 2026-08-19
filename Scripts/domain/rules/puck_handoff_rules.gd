class_name PuckHandoffRules

# Pure math for the client loose puck's render-target seams. Every loose-puck
# target sits at ~host present via the shared prediction, so there is no
# cross-timeline handoff to slew — what remains is the snap decision the
# position smoother runs every frame.

# Velocity-aware snap decision for the render-position smoother. A moving
# puck's error toward its render target decomposes into an ALONG-TRACK part
# (expected: pure timeline offset, magnitude ~velocity x timeline gap — e.g.
# the release-seed → snapshot handover seam, or a prediction → interpolation
# fallback) and a CROSS-TRACK part (genuine divergence: a bounce that
# differed, a deflection the client missed). Only cross-track error at
# snap_dist means the trajectory itself is wrong; along-track error is judged
# against the distance the puck covers in along_snap_time so a fast puck's
# expected timeline offset never triggers a teleport. Below min_speed the
# decomposition is meaningless (and covers the teleport cases — faceoff/goal
# resets drop the puck at rest), so it falls back to the plain distance check.
static func needs_hard_snap(error: Vector3, vel: Vector3, snap_dist: float,
		along_snap_time: float, min_speed: float) -> bool:
	var speed: float = vel.length()
	if speed < min_speed:
		return error.length() > snap_dist
	var vhat: Vector3 = vel / speed
	var along: float = error.dot(vhat)
	var cross: Vector3 = error - vhat * along
	if cross.length() > snap_dist:
		return true
	return absf(along) > maxf(snap_dist, speed * along_snap_time)
