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
	# speeds the nearer wins; giving the far skater a real top-speed edge
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


# ── Election eligibility: campers + non-committal humans ─────────────────────

func test_camped_finisher_is_skipped_in_election() -> void:
	# The nearer teammate is a one-timer camper (opted out of loose-puck
	# work): electing him froze the team — he refused the chase and nobody
	# else was elected. The next-best teammate takes the election.
	var states := {
		100: _skater(Vector3(3, 0, 0)),
		200: _skater(Vector3(6, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1, {}, true,
			[], [100])
	assert_eq(pid, 200, "the camper is skipped; the next teammate chases")


func test_all_camped_falls_back_to_raw_election() -> void:
	# Someone must own the puck read — with every teammate filtered, the
	# raw election runs (the camper's own veto still governs its behavior).
	var states := {
		100: _skater(Vector3(3, 0, 0)),
		200: _skater(Vector3(6, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1, {}, true,
			[], [100, 200])
	assert_eq(pid, 100, "filters excluding everyone fall back to the raw best")


func test_afk_human_does_not_suppress_the_election() -> void:
	# A human 4 m from the puck, standing still — the election can't make
	# him skate, and treating him as a guaranteed collector froze every bot
	# out of the pickup. The bot gets elected instead.
	var states := {
		100: _skater(Vector3(4, 0, 0)),            # human, stationary
		200: _skater(Vector3(8, 0, 0)),            # bot, further out
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1, {}, true,
			[100], [])
	assert_eq(pid, 200, "a non-committal human yields the election to a bot")


func test_committed_human_keeps_the_election() -> void:
	# Same human actually skating for the puck: he suppresses the bots
	# exactly as before.
	var states := {
		100: _skater(Vector3(4, 0, 0), Vector3(-4, 0, 0)),   # closing hard
		200: _skater(Vector3(8, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1, {}, true,
			[100], [])
	assert_eq(pid, 100, "a human genuinely playing the puck keeps the election")


func test_human_on_the_puck_keeps_the_election() -> void:
	# A human INSIDE the contest band counts as on the puck regardless of
	# velocity — he can simply reach it.
	var states := {
		100: _skater(Vector3(1.2, 0, 0)),          # human, on the puck
		200: _skater(Vector3(6, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1, {}, true,
			[100], [])
	assert_eq(pid, 100, "a human on the puck keeps the election")


func test_race_not_lost_to_an_opponent_ignoring_the_puck() -> void:
	# Settled puck, opponent nearer but standing flat-footed 4 m away, not
	# moving for it: his hypothetical sprint ETA beats ours, but he is not
	# running any race — declining here left the puck sitting between two
	# staring teams. Our chase stays alive.
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = Vector3.ZERO
	snap.puck_state.velocity = Vector3.ZERO
	snap.skater_states[1] = _skater(Vector3(0, 0, 8))     # us
	snap.skater_states[2] = _skater(Vector3(0, 0, -4))    # idle opponent
	var lost: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(0, 0, 8), Vector3.ZERO, REF,
			0, {1: 0, 2: 1}, {})
	assert_false(lost, "an opponent not running the race can't talk us out of it")
	# Control: the same opponent actually closing on the puck wins it back.
	snap.skater_states[2] = _skater(Vector3(0, 0, -4), Vector3(0, 0, 5))
	var lost_live: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(0, 0, 8), Vector3.ZERO, REF,
			0, {1: 0, 2: 1}, {})
	assert_true(lost_live, "a committed nearer opponent honestly wins the race")


func test_rim_race_not_lost_to_an_opponent_off_the_rim_line() -> void:
	# The fast-puck twin of the test above, and the one the user actually sees:
	# a puck rimming the wall at 8 m/s with an opponent parked 12 m away in the
	# middle of the ice, flat-footed and nowhere near the rim's line. His
	# path-race ETA "wins" (the horizon fallback), but he is running no race —
	# and declining on him sent our chaser RETREATING to the pre-contain point
	# while the rim rode the whole zone untouched.
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = Vector3(-10, 0, -12.5)
	snap.puck_state.velocity = Vector3(8, 0, 0)
	snap.skater_states[1] = _skater(Vector3(-12, 0, -11))    # us, trailing it
	snap.skater_states[2] = _skater(Vector3(4, 0, -1))       # idle, mid-ice
	var lost: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(-12, 0, -11), Vector3.ZERO, REF,
			0, {1: 0, 2: 1}, {})
	assert_false(lost, "a body off the rim's line and standing still is no veto")
	# Control: an opponent parked ON the rim's line downstream IS committed —
	# standing where the puck is coming to you is the whole play.
	snap.skater_states[2] = _skater(Vector3(4, 0, -12.5))
	var lost_on_line: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(-12, 0, -11), Vector3.ZERO, REF,
			0, {1: 0, 2: 1}, {})
	assert_true(lost_on_line, "an opponent standing in the rim's path honestly wins it")


# ── Incidental reach (a free puck at your feet is yours) ─────────────────────

func test_puck_sliding_through_reach_is_played_by_whoever_it_reaches() -> void:
	# 6 m/s puck whose line passes 1 m off a parked bot's skates. The election
	# is not the question here — the puck comes to HIM, so the reach read fires
	# regardless of who owns the chase.
	var comes: bool = AILoosePuckChase.puck_comes_to_reach(
			Vector3(-6, 0, 0), Vector3(6, 0, 0),
			Vector3(0, 0, 1.0), Vector3.ZERO, REF, 1.8)
	assert_true(comes, "a puck sliding a metre off the stick is inside the band")


func test_reach_band_ignores_a_puck_that_never_comes_near() -> void:
	var comes: bool = AILoosePuckChase.puck_comes_to_reach(
			Vector3(-6, 0, 0), Vector3(6, 0, 0),
			Vector3(0, 0, 9.0), Vector3.ZERO, REF, 1.8)
	assert_false(comes, "a puck passing 9 m away is somebody else's race")


func test_reach_band_is_not_tripped_by_a_puck_too_fast_to_meet() -> void:
	# A 30 m/s slapper up the length of the rink whose line runs 3 m off a
	# STANDING bot: geometrically inside the band, but he cannot get his body
	# there in the ~0.1 s the puck takes to cross. The timing gate is what keeps
	# the band from becoming a flat radius — it self-narrows with puck speed.
	# (Down the LENGTH so the end-board bounce can't carry it back inside the
	# 3 s horizon and legitimately re-offer the puck.)
	var comes: bool = AILoosePuckChase.puck_comes_to_reach(
			Vector3(0, 0, -25), Vector3(0, 0, 30),
			Vector3(3.0, 0, -22), Vector3.ZERO, REF, 1.8)
	assert_false(comes, "no body gets 3 m sideways inside a slapshot's flight")


func test_reach_band_survives_a_coarse_walk_step() -> void:
	# At 15 m/s the path walk samples every 3.75 m, so a point-sampled band test
	# steps clean OVER a bot the puck passes a metre from. The segment-wise read
	# catches the crossing between samples. (Puck seeded a half-step back so the
	# crossing lands mid-segment.)
	var comes: bool = AILoosePuckChase.puck_comes_to_reach(
			Vector3(-1.9, 0, 0), Vector3(15, 0, 0),
			Vector3(0, 0, 1.0), Vector3.ZERO, REF, 1.8)
	assert_true(comes, "the crossing is found between walk samples, not just on them")


func test_reach_band_covers_a_settled_puck_at_your_feet() -> void:
	var comes: bool = AILoosePuckChase.puck_comes_to_reach(
			Vector3(1.0, 0, 0.5), Vector3.ZERO,
			Vector3.ZERO, Vector3.ZERO, REF, 1.8)
	assert_true(comes, "a dead puck inside the stick is picked up, election or not")
	var far: bool = AILoosePuckChase.puck_comes_to_reach(
			Vector3(8, 0, 0), Vector3.ZERO,
			Vector3.ZERO, Vector3.ZERO, REF, 1.8)
	assert_false(far, "a dead puck 8 m away is the election's business")


# ── Containment gate (losing a race is only a reason to STOP if it buys something)

func test_lost_race_is_still_run_when_a_teammate_is_home() -> void:
	# Puck dumped deep into the attacking corner, an opponent clearly winning
	# it. Our chaser loses the race — but two teammates sit goal-side of the
	# pickup, so there is no counter to pre-contain and giving up buys nothing.
	# That is the forecheck, and refusing it measured as a dump-in that the
	# dumping team never chased at all.
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = Vector3(-6, 0, -24)
	snap.puck_state.velocity = Vector3.ZERO
	snap.skater_states[1] = _skater(Vector3(-4, 0, -14))            # us, chasing
	snap.skater_states[2] = _skater(Vector3(0, 0, 2))               # teammate, home
	snap.skater_states[11] = _skater(Vector3(-6, 0, -22),
			Vector3(0, 0, -4))                                      # opponent, winning
	var teams := {1: 0, 2: 0, 11: 1}
	# own_goal_dir +1 → our net at +Z, so the teammate at z=2 is goal-side of
	# a pickup at z=-24.
	var lost: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(-4, 0, -14), Vector3.ZERO, REF, 0, teams, {}, 1, 1.0)
	assert_false(lost, "a lost race with support behind us is a forecheck, not a stop")


func test_last_man_still_declines_a_lost_race() -> void:
	# Same race, but now the only teammate is UP-ice of the pickup: we are the
	# last man, and pushing after a puck we cannot win is the "third man keeps
	# chasing while the counter develops" failure the decline exists for.
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = Vector3(-6, 0, -24)
	snap.puck_state.velocity = Vector3.ZERO
	snap.skater_states[1] = _skater(Vector3(-4, 0, -14))            # us
	snap.skater_states[2] = _skater(Vector3(2, 0, -26))             # teammate, deeper
	snap.skater_states[11] = _skater(Vector3(-6, 0, -22),
			Vector3(0, 0, -4))                                      # opponent, winning
	var teams := {1: 0, 2: 0, 11: 1}
	var lost: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(-4, 0, -14), Vector3.ZERO, REF, 0, teams, {}, 1, 1.0)
	assert_true(lost, "the last man with nobody home still pre-contains")


func test_a_puck_rimmed_into_our_own_corner_is_still_chased() -> void:
	# The hole the goal-side read alone left. When the puck is the DEEPEST object
	# in our own end — rimmed into our corner, past everybody — no teammate CAN
	# be goal-side of it, so the containment valve was unsatisfiable exactly
	# where declining costs the most: every eligible bot declined and the puck
	# sat in our own corner untouched (93 of 98 idle ticks on the engagement
	# harness, nearest man 13.4 m and closing).
	#
	# Our net is at +Z here (own_goal_dir +1), so a puck at z = +24 is behind us
	# all. Both teammates are up-ice of it and neither can ever be goal-side —
	# but both are sitting in front of our own net, so the house is covered and
	# leaving to pressure is free. Doctrine: a loose puck in our end is always
	# pressured; "don't chase" is about a puck CARRIER in a low-danger area.
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = Vector3(11, 0, 24)
	snap.puck_state.velocity = Vector3.ZERO
	snap.skater_states[1] = _skater(Vector3(6, 0, 20))              # us, nearest
	snap.skater_states[2] = _skater(Vector3(1, 0, 21))              # mate, net front
	snap.skater_states[3] = _skater(Vector3(-2, 0, 19))             # mate, slot
	snap.skater_states[11] = _skater(Vector3(10, 0, 23),
			Vector3(0, 0, 4))                                       # opponent, winning
	var teams := {1: 0, 2: 0, 3: 0, 11: 1}
	var lost: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(6, 0, 20), Vector3.ZERO, REF, 0, teams, {}, 1, 1.0)
	assert_false(lost,
			"a puck behind our whole team is pressured while the house is covered")

	# The contrast that keeps the last-man case alive: same puck, same lost
	# race, but the mates are stranded up-ice at the far blue line. Nobody can
	# hold the house, so the nearest man stops and covers the net front instead
	# of chasing it into the corner.
	var alone := WorldSnapshot.new()
	alone.puck_state = PuckNetworkState.new()
	alone.puck_state.position = Vector3(11, 0, 24)
	alone.puck_state.velocity = Vector3.ZERO
	alone.skater_states[1] = _skater(Vector3(6, 0, 20))
	alone.skater_states[2] = _skater(Vector3(1, 0, -8))             # caught up-ice
	alone.skater_states[3] = _skater(Vector3(-2, 0, -10))           # caught up-ice
	alone.skater_states[11] = _skater(Vector3(10, 0, 23), Vector3(0, 0, 4))
	var lost_alone: bool = AIRoleHelpers.loose_puck_race_lost(
			alone, Vector3(6, 0, 20), Vector3.ZERO, REF, 0, teams, {}, 1, 1.0)
	assert_true(lost_alone,
			"with nobody able to hold the house the last man covers the net front")


func test_a_ghosted_teammate_is_not_containment() -> void:
	# A teammate serving an offside ghost can't play the puck or the body, so
	# he can't be the reason we stop chasing.
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = Vector3(-6, 0, -24)
	snap.puck_state.velocity = Vector3.ZERO
	snap.skater_states[1] = _skater(Vector3(-4, 0, -14))
	snap.skater_states[2] = _skater(Vector3(0, 0, 2))
	snap.skater_states[2].is_ghost = true
	snap.skater_states[11] = _skater(Vector3(-6, 0, -22), Vector3(0, 0, -4))
	var teams := {1: 0, 2: 0, 11: 1}
	var lost: bool = AIRoleHelpers.loose_puck_race_lost(
			snap, Vector3(-4, 0, -14), Vector3.ZERO, REF, 0, teams, {}, 1, 1.0)
	assert_true(lost, "a ghosted teammate contains nothing")


# ── Teammate yield (don't stab at your own teammate's puck) ──────────────────
# The contest rule stays symmetric — a real jam should leave the puck loose.
# What we stop is our own two bots MANUFACTURING a jam.

func _blade(pos: Vector3, blade: Vector3) -> SkaterNetworkState:
	var s := _skater(pos)
	s.blade_contact_world = blade
	return s


func test_yields_when_a_teammates_blade_is_clearly_first() -> void:
	var puck := Vector3.ZERO
	var states := {
		100: _blade(Vector3(0, 0, 1.5), Vector3(0, 0, 0.6)),   # us, blade 0.6 out
		101: _blade(Vector3(0, 0, -1.0), Vector3(0, 0, -0.1)),  # mate, blade 0.1 out
	}
	assert_true(AILoosePuckChase.teammate_first_to_puck(
			states, [100, 101], 100, states[100].blade_contact_world, puck),
			"a teammate with his stick on it gets it — we don't stab")


func test_does_not_yield_when_we_are_first() -> void:
	var puck := Vector3.ZERO
	var states := {
		100: _blade(Vector3(0, 0, 1.0), Vector3(0, 0, 0.1)),
		101: _blade(Vector3(0, 0, -1.5), Vector3(0, 0, -0.6)),
	}
	assert_false(AILoosePuckChase.teammate_first_to_puck(
			states, [100, 101], 100, states[100].blade_contact_world, puck),
			"the nearer blade takes it")


func test_yield_is_deadlock_free() -> void:
	# Both bots run the read; at most one can yield, or a puck between two
	# teammates would sit there forever. True at a dead tie AND at any gap.
	var puck := Vector3.ZERO
	for gap: float in [0.0, 0.05, 0.2, 0.26, 0.5]:
		var states := {
			100: _blade(Vector3(0, 0, 1), Vector3(0, 0, 0.1)),
			101: _blade(Vector3(0, 0, -1), Vector3(0, 0, -(0.1 + gap))),
		}
		var a: bool = AILoosePuckChase.teammate_first_to_puck(
				states, [100, 101], 100, states[100].blade_contact_world, puck)
		var b: bool = AILoosePuckChase.teammate_first_to_puck(
				states, [100, 101], 101, states[101].blade_contact_world, puck)
		assert_false(a and b, "both yielded at gap %.2f — the puck would sit" % gap)


func test_a_distant_teammate_blade_does_not_make_us_yield() -> void:
	# His blade is nearer than ours, but neither is on the puck — nobody is
	# about to take anything, so there is nothing to yield to.
	var puck := Vector3.ZERO
	var states := {
		100: _blade(Vector3(0, 0, 6), Vector3(0, 0, 5.0)),
		101: _blade(Vector3(0, 0, -4), Vector3(0, 0, -3.0)),
	}
	assert_false(AILoosePuckChase.teammate_first_to_puck(
			states, [100, 101], 100, states[100].blade_contact_world, puck),
			"a blade 3 m off the puck isn't first to anything")


func test_a_ghosted_teammate_is_not_yielded_to() -> void:
	var puck := Vector3.ZERO
	var states := {
		100: _blade(Vector3(0, 0, 1.5), Vector3(0, 0, 0.6)),
		101: _blade(Vector3(0, 0, -1.0), Vector3(0, 0, -0.1)),
	}
	states[101].is_ghost = true
	assert_false(AILoosePuckChase.teammate_first_to_puck(
			states, [100, 101], 100, states[100].blade_contact_world, puck),
			"a ghosted teammate can't play the puck, so he isn't first to it")


func test_missing_blade_field_does_not_yield() -> void:
	# blade_contact_world is host-only; an absent value must not be read as a
	# blade parked at the origin (which would sit on a puck at the origin).
	var puck := Vector3.ZERO
	var states := {
		100: _blade(Vector3(0, 0, 1.5), Vector3(0, 0, 0.6)),
		101: _skater(Vector3(0, 0, -1.0)),
	}
	assert_false(AILoosePuckChase.teammate_first_to_puck(
			states, [100, 101], 100, states[100].blade_contact_world, puck),
			"an absent blade field is not a blade on the puck")
