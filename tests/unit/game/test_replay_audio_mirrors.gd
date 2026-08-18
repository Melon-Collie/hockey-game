extends GutTest

# Guards the live-vs-replay audio mirrors. GameManager scores puck audio during a
# live match; ReplayEventReplayer scores the same events off a recorded stream.
# Both files carry "Kept in sync with ReplayEventReplayer" comments; this is what
# makes them executable.
#
# Why it matters: a drift here is silent by construction. The two paths never run
# at the same time, so nothing ever plays them side by side — a replayed goal
# would simply sound different from the goal it is a replay of, which reads as a
# vague "the replay feels off" rather than a bug anyone can point at.
#
# ReplayEventReplayer names its magic numbers as constants; GameManager inlines
# the same values as literals. That asymmetry is the drift risk, and comparing
# outputs rather than sources is what catches it either way.

const _SPEEDS: Array[float] = [0.0, 1.0, 3.5, 5.0, 12.0, 21.0, 30.0, 60.0]


func test_save_volume_bumps_match() -> void:
	assert_almost_eq(GameManager._POST_SAVE_VOLUME_BUMP_DB,
			ReplayEventReplayer._POST_SAVE_VOLUME_BUMP_DB, 1e-6,
			"post-save volume bump must be identical live and in replay")
	assert_almost_eq(GameManager._PAD_SAVE_VOLUME_BUMP_DB,
			ReplayEventReplayer._PAD_SAVE_VOLUME_BUMP_DB, 1e-6,
			"pad-save volume bump must be identical live and in replay")


# Compared across the speed range rather than by reading the two implementations,
# so a refactor that renames or restructures either side still has to preserve the
# curve. Includes the clamp ends (below the floor, above the ceiling) because those
# are where a mismatched range constant shows up first.
func test_puck_speed_volume_curve_matches() -> void:
	for speed: float in _SPEEDS:
		assert_almost_eq(GameManager._puck_speed_volume(speed),
				ReplayEventReplayer._puck_speed_volume(speed), 1e-6,
				"puck-speed volume must match at %.1f m/s" % speed)


func test_post_pitch_curve_matches() -> void:
	for speed: float in _SPEEDS:
		assert_almost_eq(GameManager._post_pitch(speed),
				ReplayEventReplayer._post_pitch(speed), 1e-6,
				"post-hit pitch must match at %.1f m/s" % speed)
