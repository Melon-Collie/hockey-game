extends GutTest

# AILoosePuckChase is pure-function. Tests verify momentum-aware
# intercept election (a bot skating toward the puck beats a closer bot
# coasting away), bounded puck-lead (the bot in a fast puck's path wins
# over the nearer-right-now bot), and incumbent hysteresis (the current
# chaser keeps the role unless a challenger clearly beats them).

const REF: float = 9.5   # AIActionScoring.SKATER_REF_SPEED_M_S


func _skater(pos: Vector3, vel: Vector3 = Vector3.ZERO) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = pos
	s.velocity = vel
	return s


func _states(entries: Dictionary) -> Dictionary:
	# entries: peer_id -> SkaterNetworkState
	return entries


func test_stationary_puck_picks_closest() -> void:
	var states := {
		100: _skater(Vector3(3, 0, 0)),
		200: _skater(Vector3(6, 0, 0)),
	}
	var pid: int = AILoosePuckChase.elect(
			states, [100, 200], Vector3.ZERO, Vector3.ZERO, -1)
	assert_eq(pid, 100, "nearest stationary bot wins when nobody has momentum")


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
