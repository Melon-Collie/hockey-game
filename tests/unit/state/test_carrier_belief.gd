extends GutTest

# CarrierBelief — the bots' lagged TEAM possession belief.
#
# The contract worth pinning is the commit rule: a blip that REVERTS inside the
# window is absorbed (that is the whole point of the delay), but a genuine run of
# DISTINCT carriers commits on schedule. The previous implementation restarted
# the timer on every change, which absorbed blips correctly and then inverted
# under load — through a scramble the clock reset on each new toucher, so the
# belief could stall indefinitely and no bot would read the turnover.

const DELAY := 0.2
const DT := 1.0 / 120.0

var belief: CarrierBelief


func before_each() -> void:
	belief = CarrierBelief.new()


# Run `ticks` frames with a constant truth; returns the final belief.
func _run(real_carrier: int, ticks: int) -> int:
	var out: int = belief.perceived
	for i: int in ticks:
		out = belief.update(real_carrier, DELAY, DT)
	return out


func test_starts_believing_nobody_has_it() -> void:
	assert_eq(belief.perceived, -1)


func test_zero_delay_tracks_truth_exactly() -> void:
	# Perfect-reaction difficulty: no lag at all.
	assert_eq(belief.update(7, 0.0, DT), 7)
	assert_eq(belief.update(-1, 0.0, DT), -1)


func test_commits_after_the_delay() -> void:
	assert_eq(_run(7, 10), -1, "still lagging a few ticks in")
	assert_eq(_run(7, 20), 7, "committed once the delay elapsed")


func test_holds_the_prior_belief_through_the_window() -> void:
	_run(7, 30)
	assert_eq(belief.perceived, 7)
	# Puck comes loose; the belief must lag by the reaction delay.
	assert_eq(_run(-1, 5), 7, "belief lags a real change by the reaction time")
	assert_eq(_run(-1, 25), -1, "then commits")


func test_reverting_blip_is_absorbed() -> void:
	# The de-twitch case: a puck grazes a stick and comes straight back. The
	# belief must never flicker.
	_run(7, 30)
	_run(9, 5)                      # brief graze by peer 9
	assert_eq(belief.perceived, 7, "no commit mid-blip")
	assert_eq(_run(7, 5), 7, "reverting to the believed carrier re-arms cleanly")
	# And the re-arm is full: a later divergence still gets the whole delay.
	assert_eq(_run(9, 10), 7, "fresh divergence starts a fresh full window")


func test_scramble_of_distinct_carriers_still_commits() -> void:
	# The regression this rule exists for. A contested scramble where the puck
	# keeps changing hands must NOT defer the belief forever — under the old
	# restart-on-every-change rule this never committed.
	_run(7, 30)
	assert_eq(belief.perceived, 7)
	var truths: Array[int] = [-1, 9, -1, 11, -1, 12, -1, 9]
	var committed_away := false
	for t: int in truths:
		for i: int in 4:            # ~0.033 s each — all well under DELAY
			if belief.update(t, DELAY, DT) != 7:
				committed_away = true
	assert_true(committed_away,
			"belief must commit off the stale carrier during a scramble")


func test_commits_to_current_truth_not_the_intermediate() -> void:
	# After the reaction time you see what is happening NOW — not the value that
	# happened to open the window and has since been superseded.
	_run(7, 30)
	_run(9, 12)                     # diverges, window opens, not yet committed
	assert_eq(belief.perceived, 7)
	var out: int = _run(11, 20)     # truth moved on before the commit landed
	assert_eq(out, 11, "commits to the live truth, not the stale intermediate")


func test_reset_drops_belief_from_a_previous_match() -> void:
	_run(7, 30)
	assert_eq(belief.perceived, 7)
	belief.reset()
	assert_eq(belief.perceived, -1)
