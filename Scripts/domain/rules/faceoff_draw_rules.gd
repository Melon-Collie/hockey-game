class_name FaceoffDrawRules

# Pure math for the faceoff draw ("winning the draw"). A contested pickup at a
# faceoff reads each center's blade momentum to decide where the puck squirts
# (see PuckCollisionRules.contested_pickup_velocity). Feeding the RAW per-tick
# blade velocity made the draw feel random: winning required the blade to be at
# peak speed on the single tick the puck went live. These helpers let the caller
# feed a short rolling PEAK of the swipe (so a well-aimed sweep still counts even
# if it crests a few ticks off the contact instant) scaled by a TIMING weight (so
# reacting on the drop beats a late stab). No engine deps — fully unit-testable.

# Rolling-peak decay. Given the retained peak swipe speed and the live blade speed
# this tick, return the new peak: the live speed when it's a fresh crest, else the
# retained peak bled down by decay_per_sec. So "the best swipe in roughly the last
# peak/decay_per_sec seconds" survives — recent crests count, stale ones fade,
# which also gives a natural pre-roll (a swing just before the drop still lands)
# without remembering an early guess forever.
static func decay_peak_speed(peak_speed: float, current_speed: float,
		decay_per_sec: float, delta: float) -> float:
	return maxf(current_speed, peak_speed - decay_per_sec * delta)

# Timing weight applied to a center's contest momentum, rewarding a blade crest
# that lands on the drop. `since_drop` is (crest_time - drop_time) in seconds:
#   <= 0  crest BEFORE (or exactly on) the drop → neutral 1.0. Early swings aren't
#         punished in v1 — they simply don't earn the bonus (and the decay above
#         has already bled a too-early swing down on its own).
#   > 0   crest AFTER the drop → starts at the peak reward (1.0 + bonus) right on
#         the drop and eases to min_weight by miss_window_s as the crest lands
#         later (a slow, mistimed stab).
# bonus >= 0, 0 < min_weight <= 1, miss_window_s > 0.
static func timing_weight(since_drop: float, miss_window_s: float,
		bonus: float, min_weight: float) -> float:
	if since_drop <= 0.0:
		return 1.0
	if miss_window_s <= 0.0:
		return min_weight
	var t: float = clampf(since_drop / miss_window_s, 0.0, 1.0)
	return lerpf(1.0 + bonus, min_weight, t)
