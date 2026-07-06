class_name GaitIntentRules

# Pure input-intent gait signals — the reads that need to know what the player
# is TRYING to do rather than what the body is doing. Every input here is
# already-replicated state (move_intent from the v15 intent byte, velocity,
# facing), so each signal renders identically on local, bot, and remote
# skaters with zero extra wire cost. Frame convention matches CarveRules:
# Vector2(x, z); travelling / facing "up-ice" is (0, −1).
#
# All signals return a 0..1 engagement (shuffle is signed ±1 by side) and are
# meant to be smoothed by the caller — the wire intent is an 8-way octant, so
# raw flips are discrete.


# Dig-in: a held direction at low speed is a skater fighting for their first
# strides (or grinding against a pin) — full at a standstill, fading to zero
# by fade_speed where the ordinary speed-driven gait has taken over.
static func dig_in(has_intent: bool, ground_speed: float, fade_speed: float) -> float:
	if not has_intent or fade_speed <= 0.001:
		return 0.0
	return clampf(1.0 - ground_speed / fade_speed, 0.0, 1.0)


# Reversal: intent opposing travel at speed — the stop-and-go weight shift.
# Ramps from start_opposition (−dot of the normalized vectors) to full at
# dead-opposite; zero below min_speed (a slow reversal is just a step).
static func reversal(travel_xz: Vector2, intent_xz: Vector2, ground_speed: float,
		min_speed: float, start_opposition: float) -> float:
	if ground_speed < min_speed:
		return 0.0
	if travel_xz.length_squared() < 0.01 or intent_xz.length_squared() < 0.0025:
		return 0.0
	var opposition: float = -travel_xz.normalized().dot(intent_xz.normalized())
	return clampf((opposition - start_opposition) / maxf(1.0 - start_opposition, 0.001),
			0.0, 1.0)


# Shuffle: intent held ACROSS the facing at low speed — the net-front
# side-step read. Takes the intent in the BODY frame; the return is SIGNED by
# the lateral direction (+ = body-frame +X) so the caller leans the right
# way. Magnitude ramps from start_lateral (lateral fraction of the intent) to
# 1 at a pure sidestep, faded out by fade_speed where crossovers take over.
static func shuffle(local_intent_xz: Vector2, ground_speed: float,
		fade_speed: float, start_lateral: float) -> float:
	if fade_speed <= 0.001 or local_intent_xz.length_squared() < 0.0025:
		return 0.0
	var speed_fade: float = clampf(1.0 - ground_speed / fade_speed, 0.0, 1.0)
	if speed_fade <= 0.0:
		return 0.0
	var lat: float = local_intent_xz.normalized().x
	var mag: float = clampf((absf(lat) - start_lateral) / maxf(1.0 - start_lateral, 0.001),
			0.0, 1.0)
	return mag * signf(lat) * speed_fade


# Backpedal: intent held BEHIND the facing — a defender's deliberate
# back-skate, as opposed to drifting backward off a check. Takes the intent
# in the BODY frame; ramps from start_backward (backward fraction of the
# intent) to 1 holding straight back.
static func backpedal(local_intent_xz: Vector2, start_backward: float) -> float:
	if local_intent_xz.length_squared() < 0.0025:
		return 0.0
	var back: float = local_intent_xz.normalized().y  # forward = (0, −1)
	return clampf((back - start_backward) / maxf(1.0 - start_backward, 0.001), 0.0, 1.0)
