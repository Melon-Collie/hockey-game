class_name PuckHandoffRules

# Pure math for the client puck's trajectory-prediction → interpolation handoff.
#
# During shot prediction the puck renders at ~client-present (each host
# broadcast is projected forward by the full RTT), while interpolation renders
# a full interp_delay BEHIND host-present (render == lag-comp rewind). The two
# timelines are therefore split by ~RTT/2 + interp_delay, and a naive handoff
# jumps the puck BACKWARD along its own flight path by velocity x that split —
# routinely metres on a shot, which either hard-snaps or visibly rubber-bands
# against the puck's motion. Perceptual research is unambiguous that a smooth,
# consistent offset beats a variable-magnitude jump (constant delays up to
# ~300 ms go unnoticed while jitter at 200 ms degrades everything — Normoyle
# et al., ACM SAP 2014), and shipped netcode amortizes corrections over a
# smoothing window rather than snapping (Source's cl_smoothtime ~0.1 s).
#
# The handoff therefore slews TIME, not position: at the moment prediction
# ends, interpolation starts with a temporary render-time lead sized so its
# first target lands where the live puck already is, then the lead decays at a
# fixed rate < 1 s/s. The puck never moves backward — it briefly renders at
# (1 - rate) of its true pace, reading as the puck dying off the pads/boards,
# while the timeline eases from "leading" back to the shared interpolated past.
# Cross-track error (a bounce that genuinely differed between client and host)
# is deliberately NOT absorbed by the lead — it stays with the position
# smoother, which is what needs_hard_snap below keeps honest.

# Render-time lead (seconds) that makes the interpolation timeline line up with
# the live puck at handoff. Rather than deriving it from RTT theory (which
# jitters), measure it: project the live puck position onto the host trajectory
# through the newest buffered sample (`newest_pos` + t x `newest_vel`) and find
# the host-timeline instant whose position best matches — newest_ts plus the
# along-track distance over speed. The lead is that instant minus the base
# interpolation render time, floored at 0 (a puck already behind the interp
# timeline needs no slew) and capped at max_lead (a wildly divergent bounce
# projects nonsense — cap it and let the position smoother eat the rest).
# Linear projection ignores ice friction; over a <= max_lead window the error
# is centimetres and lands in the smoother as residual.
# Below min_speed the along-track direction is meaningless (and a slow puck's
# timeline gap is tiny anyway) → no slew.
static func timeline_lead(live_pos: Vector3, newest_pos: Vector3, newest_vel: Vector3,
		newest_ts: float, base_render_time: float, max_lead: float, min_speed: float) -> float:
	var speed: float = newest_vel.length()
	if speed < min_speed:
		return 0.0
	var along_m: float = (live_pos - newest_pos).dot(newest_vel / speed)
	var matched_time: float = newest_ts + along_m / speed
	return clampf(matched_time - base_render_time, 0.0, max_lead)


# Velocity-aware snap decision for the render-position smoother. A moving
# puck's error toward its interp target decomposes into an ALONG-TRACK part
# (expected: pure timeline offset, magnitude ~velocity x timeline gap — the
# thing the slew absorbs) and a CROSS-TRACK part (genuine divergence: a bounce
# that differed, a deflection the client missed). Only cross-track error at
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
