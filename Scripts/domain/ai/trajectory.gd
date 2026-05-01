class_name AITrajectory

# Forward-simulate a skater / puck position N steps ahead. Returns
# the position at each step (index 0 = t=dt, index N-1 = t=N*dt).
# Callers either pluck a single step (man-to-man lead) or scan the
# whole array (intercept search, lane prediction).
#
# Currently constant-velocity with rink clamping on each step. The
# clamp matters: a mark hugging the boards isn't actually at
# pos + vel * 0.5s — they bounce / scrape against the wall, and an
# unclamped lead would put the defender's anchor inside the boards.
#
# Future sophistication (acceleration term, friction, reaction-delay
# floor, steering-anchor pull) lands inside the for-loop here without
# touching call sites. Cost is trivial — a few skaters × 6 steps at
# 6 Hz brain tick.

static func predict(pos: Vector3, vel: Vector3,
		steps: int, dt: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var p: Vector3 = pos
	for i: int in range(steps):
		p += vel * dt
		var clamped_xz: Vector2 = GameRules.clamp_to_rink_inner(Vector2(p.x, p.z))
		p = Vector3(clamped_xz.x, p.y, clamped_xz.y)
		out.append(p)
	return out


# Convenience: position at a single lead time. Matches the common case
# of "where will this skater be in T seconds" without forcing callers
# to pick a step count. Steps default to 6 — granular enough that the
# rink clamp catches mid-flight wall contact, cheap enough at 6 Hz.
static func predict_at(pos: Vector3, vel: Vector3, lead_time_s: float,
		steps: int = 6) -> Vector3:
	if lead_time_s <= 0.0 or steps <= 0:
		return pos
	var dt: float = lead_time_s / float(steps)
	var traj: Array[Vector3] = predict(pos, vel, steps, dt)
	return traj[traj.size() - 1]
