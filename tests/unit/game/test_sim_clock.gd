extends GutTest

# The tick-domain simulation clock (NetworkManager.next_sim_offset).
#
# Godot runs physics from an accumulator inside the main loop, so at 60 fps with
# a 120 Hz tick TWO steps execute back to back and only then does the frame
# render. Both read the same Time.get_ticks_msec() — at 1 ms resolution, the same
# value. A wall-derived stamp therefore hands two different ticks the SAME
# instant, and RemoteController's dedupe (strictly-greater) silently drops the
# second input. These pin the property that makes that impossible.

const TICK: float = 1.0 / 120.0
const SLEW: float = 0.0001


func _sim_time(offset: float, ticks: int) -> float:
	return float(ticks) * TICK + offset


# ── The headline invariant ───────────────────────────────────────────────────

func test_stamps_advance_a_tick_even_when_the_wall_clock_is_frozen() -> void:
	# The burst case: several physics steps inside one rendered frame, all
	# reading an identical wall clock. Stamps must still separate.
	var wall: float = 100.0
	var offset: float = 0.0
	var prev: float = _sim_time(offset, 0)
	for tick: int in range(1, 9):
		offset = NetworkManager.next_sim_offset(offset, tick, wall)
		var now: float = _sim_time(offset, tick)
		assert_gt(now - prev, TICK - SLEW - 1e-9,
				"tick %d must advance a full tick minus at most the slew" % tick)
		prev = now


func test_a_full_frame_of_bursting_never_collides() -> void:
	# 60 fps host, 120 Hz tick, one second: the wall clock steps 16.67 ms every
	# OTHER tick and stands still in between. No two stamps may be equal.
	var seen: Array[float] = []
	var offset: float = 0.0
	var wall: float = 50.0
	for tick: int in range(1, 121):
		if tick % 2 == 1:
			wall += 2.0 * TICK  # the frame boundary; both steps then share it
		offset = NetworkManager.next_sim_offset(offset, tick, wall)
		var stamp: float = _sim_time(offset, tick)
		for other: float in seen:
			assert_gt(absf(stamp - other), 1e-4,
					"stamps must stay distinguishable on the 0.1 ms wire grid")
		seen.append(stamp)


# ── Tracking ─────────────────────────────────────────────────────────────────

func test_slew_tracks_a_slow_drift_without_chasing_jitter() -> void:
	# Host ticking marginally fast: sim time must follow, not diverge.
	var offset: float = 0.0
	var wall: float = 0.0
	for tick: int in range(1, 2001):
		wall += TICK * 1.0002  # +0.02% drift
		offset = NetworkManager.next_sim_offset(offset, tick, wall)
	assert_almost_eq(_sim_time(offset, 2000), wall, 0.005,
			"a slow drift is tracked to within a few ms")


func test_frame_jitter_is_rejected_not_followed() -> void:
	# A single one-frame excursion must move sim time by at most the slew, not by
	# the excursion — this is the whole reason the servo saw frame cadence as
	# lateness.
	var offset: float = 0.0
	var settled: float = NetworkManager.next_sim_offset(offset, 1, TICK)
	var jittered: float = NetworkManager.next_sim_offset(settled, 2, 2.0 * TICK + 0.0167)
	assert_almost_eq(jittered - settled, SLEW, 1e-9,
			"a 16.7 ms wall excursion moves the offset by one slew step, no more")


func test_large_error_snaps_rather_than_crawling() -> void:
	# NTP warmup / a step change in the offset: crawling at 0.1 ms/tick would
	# take tens of seconds, so beyond the resync bound it jumps.
	var offset: float = 0.0
	var snapped: float = NetworkManager.next_sim_offset(offset, 1, TICK + 5.0)
	assert_almost_eq(snapped, 5.0, 1e-9)
