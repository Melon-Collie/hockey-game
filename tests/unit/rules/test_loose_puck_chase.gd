extends GutTest

# AILoosePuckChase is pure-function. Tests verify momentum-aware
# intercept election (a bot skating toward the puck beats a closer bot
# coasting away), bounded puck-lead (the bot in a fast puck's path wins
# over the nearer-right-now bot), and incumbent hysteresis (the current
# chaser keeps the role unless a challenger clearly beats them).

const REF: float = 9.0   # AIActionScoring.SKATER_REF_SPEED_M_S


func _skater(pos: Vector3, vel: Vector3 = Vector3.ZERO) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = pos
	s.velocity = vel
	return s


func _states(entries: Dictionary) -> Dictionary:
	# entries: peer_id -> SkaterNetworkState
	return entries


func _caps(max_speed: float, sprint_mult: float = -1.0) -> AISkaterCaps:
	var c := AISkaterCaps.new()
	c.max_speed = max_speed
	if sprint_mult > 0.0:
		c.sprint_speed_mult = sprint_mult
	return c


func test_stationary_puck_picks_closest() -> void:
	var states := {
		100: _skater(Vector3(3, 0, 0)),
		200: _skater(Vector3(6, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(pid, 100, "nearest stationary bot wins when nobody has momentum")


func test_faster_skater_wins_the_race_from_further_out() -> void:
	# A nearer slow skater vs a further fast one, both stationary. With league
	# speeds the nearer wins; giving the far skater a real top-speed edge (Speed)
	# flips the race — a burner genuinely gets to a loose puck first. The race
	# must be LONG enough for top speed to engage: the calibrated ETA charges
	# both builds the same standing-start ramp, so acceleration decides short
	# races and the cap only pays past its ramp distance — which is the real
	# physics (a 6 m sprint is won by position, not top gear).
	var states := {
		100: _skater(Vector3(0, 0, 12)),  # nearer
		200: _skater(Vector3(0, 0, 16)),  # further
	}
	var league: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(league, 100, "with equal speed the nearer skater wins")
	var by_build: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1,
			{100: _caps(6.0), 200: _caps(14.0)})
	assert_eq(by_build, 200, "a much faster skater wins the race from further out")


func test_momentum_beats_raw_distance() -> void:
	# Bot 100 is closer (2 m) but coasting AWAY from the puck; bot 200 is
	# farther (4 m) but skating hard toward it. Raw-distance election
	# would pick 100; momentum-aware election picks 200.
	var states := {
		100: _skater(Vector3(2, 0, 0), Vector3(5, 0, 0)),    # moving +x, away
		200: _skater(Vector3(4, 0, 0), Vector3(-8, 0, 0)),   # moving -x, toward
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(pid, 200, "bot skating toward the puck beats a closer bot coasting away")


func test_puck_lead_picks_bot_in_path() -> void:
	# Puck rips toward +x at 10 m/s. Bot 100 sits behind it (-2 m), bot
	# 200 is ahead in its path (+5 m). Nearer-right-now is 100, but with
	# a bounded lead the puck arrives at 200's feet first.
	var states := {
		100: _skater(Vector3(-2, 0, 0)),
		200: _skater(Vector3(5, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3(10, 0, 0), -1)
	assert_eq(pid, 200, "lead points the chase at the bot in the puck's path")

	# Control: with a near-stationary puck (no lead), the nearer bot wins.
	var pid_slow: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(pid_slow, 100, "no lead on a settled puck — nearest wins")


func test_hysteresis_keeps_incumbent() -> void:
	# Bot 200 is marginally closer, but bot 100 is the incumbent chaser.
	# The HYSTERESIS_S margin keeps 100 on the puck (no flip-flop).
	var states := {
		100: _skater(Vector3(3.0, 0, 0)),
		200: _skater(Vector3(2.9, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, 100)
	assert_eq(pid, 100, "incumbent keeps the chase against a marginal challenger")


func test_hysteresis_yields_to_clear_challenger() -> void:
	# Same incumbent (100), but now 200 is much closer — beyond the
	# hysteresis margin — so the role hands over.
	var states := {
		100: _skater(Vector3(3.0, 0, 0)),
		200: _skater(Vector3(1.0, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, 100)
	assert_eq(pid, 200, "a clearly faster teammate takes over from the incumbent")


func test_empty_team_returns_minus_one() -> void:
	var pid: int = AILoosePuckChase.elect(
			{}, [], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(pid, -1, "no skaters -> no chaser")


func test_tie_breaks_to_lower_peer_id() -> void:
	var states := {
		200: _skater(Vector3(3, 0, 0)),
		100: _skater(Vector3(3, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [200, 100], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(pid, 100, "identical candidates resolve to the lower peer_id")


func test_missing_skater_state_is_skipped() -> void:
	# teammate_ids can name a peer that isn't in skater_states yet (mid
	# spawn / swap). It's skipped, not crashed on.
	var states := {
		100: _skater(Vector3(5, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 999], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(pid, 100, "a teammate id with no state is ignored")


func test_stale_incumbent_falls_back_to_election() -> void:
	# prev_elected names a bot no longer on the team; election proceeds
	# as if there were no incumbent.
	var states := {
		100: _skater(Vector3(3, 0, 0)),
		200: _skater(Vector3(6, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, 999)
	assert_eq(pid, 100, "stale incumbent gives no one the discount — nearest wins")


# ── Path race (fast pucks) ───────────────────────────────────────────────────
# A rim's race runs on its predicted path, not its current position — the
# tail-chaser a metre behind it can never finish the race the position read
# says he's winning (docs/breakout-plan.md, iteration 3).

func test_rim_elects_downstream_skater_over_tail_chaser() -> void:
	# Hard rim up the wall: teammate 100 trails it by 1.5 m at 8 m/s (the
	# nearest-right-now read) but the puck outruns him for the whole
	# horizon; teammate 200 stands 24 m downstream, 2 m off the wall — the
	# rim comes TO him. Position-based election picked the tail-chaser.
	var states := {
		100: _skater(Vector3(12, 0, -11.5), Vector3(0, 0, 8)),
		200: _skater(Vector3(10, 0, 14)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3(12, 0, -10), Vector3(0, 0, 15), -1)
	assert_eq(pid, 200, "the rim's path elects the downstream skater, not the tail-chaser")


func test_path_intercept_time_reads_arrival_of_the_puck() -> void:
	# Skater parked in a fast puck's path: his intercept time is when the
	# PUCK arrives (~20 m at rim pace → ~1.5 s), not his skate time to the
	# puck's current spot (20 m from rest ≈ 2.9 s).
	var traj: Array[Vector3] = AILoosePuckChase.race_trajectory(
			Vector3(12, 0, 0), Vector3(0, 0, 15))
	var dt: float = AILoosePuckChase.RACE_LOOKAHEAD_S / float(AILoosePuckChase.RACE_STEPS)
	var t: float = AILoosePuckChase.path_intercept_time(
			traj, dt, Vector3(12, 0, 20), Vector3.ZERO, REF)
	assert_between(t, 1.0, 2.0, "intercept ≈ the puck's own arrival at the parked skater")


func test_rim_race_not_lost_for_downstream_defender() -> void:
	# loose_puck_race_lost on the same rim: the opponent tail-chasing 1.5 m
	# back "wins" every current-position ETA, but can never finish; the
	# downstream defender's path intercept is the only makeable one, so HIS
	# race is alive. (Before the path race he declined here and the rim
	# rode the zone untouched — the breakout-harness dither.)
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = Vector3(12, 0, -10)
	snap.puck_state.velocity = Vector3(0, 0, 15)
	snap.skater_states[1] = _skater(Vector3(10, 0, 14))
	snap.skater_states[2] = _skater(Vector3(12, 0, -11.5), Vector3(0, 0, 8))
	var lost: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(10, 0, 14), Vector3.ZERO, REF,
			0, {1: 0, 2: 1}, {})
	assert_false(lost, "the downstream defender's path intercept keeps the race alive")
	# Control: the same puck SETTLED at the opponent's feet is honestly lost.
	snap.puck_state.position = Vector3(12, 0, -11.0)
	snap.puck_state.velocity = Vector3.ZERO
	var lost_settled: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(10, 0, 14), Vector3.ZERO, REF,
			0, {1: 0, 2: 1}, {})
	assert_true(lost_settled, "a settled puck at the opponent's feet is honestly lost")


# ── Sprint-aware races (BotSprintRules.race_speed via race_vmax) ─────────────

func test_sprint_gear_wins_the_long_race() -> void:
	# Equal cruise speed, equal 20 m race — but 100 is a burner (strong-
	# Speed sprint ceiling 1.16) and 200 a plodder (1.07). Cruise-priced
	# reads called this a tie broken by peer id; the sprint-aware race
	# elects the extra gear. This is Speed's headline separation finally
	# reaching the AI's race reads.
	var states := {
		100: _skater(Vector3(0, 0, 20)),
		200: _skater(Vector3(20, 0, 20)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3(10, 0, 0), Vector3.ZERO, -1,
			{100: _caps(9.0, 1.16), 200: _caps(9.0, 1.07)})
	assert_eq(pid, 100, "the burner's sprint gear wins an otherwise even race")
	var flipped: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3(10, 0, 0), Vector3.ZERO, -1,
			{100: _caps(9.0, 1.07), 200: _caps(9.0, 1.16)})
	assert_eq(flipped, 200, "and it is the gear deciding it, not the peer id")


func test_gassed_skater_loses_the_race_to_fresh_legs() -> void:
	# Same builds, same distance — but 100's pool is nearly empty (below
	# the sprint engage floor) while 200 is fresh. Fresh legs win the race
	# a stamina-blind read called a tie.
	var states := {
		100: _skater(Vector3(0, 0, 20)),
		200: _skater(Vector3(20, 0, 20)),
	}
	states[100].stamina = 0.1
	states[200].stamina = 1.0
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3(10, 0, 0), Vector3.ZERO, -1)
	assert_eq(pid, 200, "fresh legs beat a gassed skater over the same ground")


func test_dead_puck_elects_nobody() -> void:
	# A covered / phase-locked puck (pickup_locked, no carrier) can't be
	# played, so nobody is elected to chase it — bots fall back to their
	# positional roles instead of hovering over the goalie's smother. The
	# next playable frame elects a fresh chaser as usual.
	var states := {
		100: _skater(Vector3(1, 0, 0)),
		200: _skater(Vector3(6, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1, {}, false)
	assert_eq(pid, -1, "dead puck → no chaser, even with eligible skaters")
	var pid_incumbent: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, 100, {}, false)
	assert_eq(pid_incumbent, -1, "incumbency doesn't survive a dead puck")
	var pid_live: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1, {}, true)
	assert_eq(pid_live, 100, "playable again → normal election resumes")
