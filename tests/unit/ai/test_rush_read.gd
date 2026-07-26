extends GutTest

# AIRushRead — the shared transition-defense perception
# (docs/transition-defense-plan.md §4). These pin the PERCEPTION, before any
# role consumes it: who counts as an attacker, who is back, what the numbers
# read says, and whether coverage is accounted for.
#
# Team 0 defends +Z (our net at +26.65) and attacks -Z. So an opponent rushing
# us travels in +Z, and "goal-side / more defensive" means larger z.

const OUR_NET_Z: float = 26.65
const BLUE: float = 7.29


func _skater(pos: Vector3, vel: Vector3 = Vector3.ZERO) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = pos
	s.velocity = vel
	s.stamina = 1.0
	return s


# Builds a snapshot from {peer_id: [pos, vel]} dicts for each side, with an
# optional carrier. Ours are 1..n, theirs 11..n.
func _snapshot(ours: Dictionary, theirs: Dictionary, carrier: int,
		puck_pos: Vector3 = Vector3.INF) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	for pid: int in ours:
		snap.skater_states[pid] = _skater(ours[pid][0], ours[pid][1])
	for pid: int in theirs:
		snap.skater_states[pid] = _skater(theirs[pid][0], theirs[pid][1])
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier
	if puck_pos.is_finite():
		puck.position = puck_pos
	elif carrier != -1:
		puck.position = snap.skater_states[carrier].position
	snap.puck_state = puck
	return snap


func _team_map(ours: Dictionary, theirs: Dictionary) -> Dictionary:
	var m: Dictionary = {}
	for pid: int in ours:
		m[pid] = 0
	for pid: int in theirs:
		m[pid] = 1
	return m


func _read(ours: Dictionary, theirs: Dictionary, carrier: int,
		puck_pos: Vector3 = Vector3.INF,
		prev: Dictionary = {}) -> AIRushRead:
	var r := AIRushRead.new()
	r.fill(_snapshot(ours, theirs, carrier, puck_pos), 0, OUR_NET_Z,
			_team_map(ours, theirs), {}, prev)
	return r


# ── Attacker filtering — the fix for "bots retreat from phantoms" ────────────

func test_stay_home_defenseman_is_not_an_attacker() -> void:
	# Their carrier rushes us from center ice; their D sits back at THEIR blue
	# line, 20+ m behind the play. He is not part of this rush and must not
	# inflate the threat count (the old channel model priced him at the hardest
	# feed on the rink, which is what collapsed the whole defense).
	var theirs := {
		11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0)],   # carrier, closing
		12: [Vector3(-8.0, 0.0, -20.0), Vector3.ZERO],          # stay-home D
	}
	var ours := {1: [Vector3(0.0, 0.0, 18.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_true(11 in r.attackers, "the carrier is always an attacker")
	assert_false(12 in r.attackers,
			"a D parked 20 m behind the play is not part of the rush")


func test_hard_charging_trailer_is_an_attacker() -> void:
	# The late man is the most dangerous man on a rush. He is BEHIND the puck,
	# so a position-based filter would drop him; the time filter keeps him.
	var theirs := {
		11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0)],
		12: [Vector3(3.0, 0.0, -5.0), Vector3(0.0, 0.0, 8.0)],  # trailing, flying
	}
	var ours := {1: [Vector3(0.0, 0.0, 18.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_true(12 in r.attackers,
			"a trailer joining the rush at speed is an attacker")


# ── Recovery classification ──────────────────────────────────────────────────

func test_goal_side_peer_is_inside() -> void:
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0)]}
	var ours := {1: [Vector3(0.0, 0.0, 18.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.recovery_by_peer.get(1), AIRushRead.Recovery.INSIDE,
			"a peer between the rush and our net is INSIDE")


func test_up_ice_peer_is_not_inside() -> void:
	# Caught up-ice behind the rush — either tracking or beaten, never inside.
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0)]}
	var ours := {1: [Vector3(0.0, 0.0, -12.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_ne(r.recovery_by_peer.get(1), AIRushRead.Recovery.INSIDE,
			"a peer up-ice of the rush is not goal-side of it")


func test_goal_side_is_radial_not_z() -> void:
	# The carrier has driven to the middle, 11 m off our net. A peer out on the
	# boards has a LARGER z — deeper by the naive Z reading — but is actually
	# further from our net than the carrier is, so he is not in front of this
	# rush and must not be counted as such.
	var theirs := {11: [Vector3(0.0, 0.0, 15.0), Vector3(0.0, 0.0, 6.0)]}
	var ours := {1: [Vector3(12.0, 0.0, 16.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_gt(Vector2(12.0, 16.0).distance_to(Vector2(0.0, OUR_NET_Z)),
			Vector2(0.0, 15.0).distance_to(Vector2(0.0, OUR_NET_Z)),
			"scenario check: the peer really is further from the net")
	assert_ne(r.recovery_by_peer.get(1), AIRushRead.Recovery.INSIDE,
			"larger z but further from the net is not goal-side")


# ── Numbers ──────────────────────────────────────────────────────────────────

func test_numbers_even_when_matched() -> void:
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 5.0)]}
	var ours := {1: [Vector3(0.0, 0.0, 16.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.numbers, AIRushRead.Numbers.EVEN_OR_UP,
			"one back against one coming is even")


func test_numbers_down_one_on_a_two_on_one() -> void:
	var theirs := {
		11: [Vector3(-3.0, 0.0, 2.0), Vector3(0.0, 0.0, 6.0)],
		12: [Vector3(3.0, 0.0, 2.0), Vector3(0.0, 0.0, 6.0)],
	}
	var ours := {1: [Vector3(0.0, 0.0, 16.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.attackers.size(), 2, "both rushers count")
	assert_eq(r.numbers, AIRushRead.Numbers.DOWN_ONE,
			"two coming at one back is DOWN_ONE")


func test_numbers_down_two_on_a_three_on_one() -> void:
	var theirs := {
		11: [Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 6.0)],
		12: [Vector3(-5.0, 0.0, 2.0), Vector3(0.0, 0.0, 6.0)],
		13: [Vector3(5.0, 0.0, 2.0), Vector3(0.0, 0.0, 6.0)],
	}
	var ours := {1: [Vector3(0.0, 0.0, 16.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.numbers, AIRushRead.Numbers.DOWN_TWO_PLUS,
			"three coming at one back is DOWN_TWO_PLUS")


func test_beaten_peer_does_not_count_as_back() -> void:
	# A peer stranded deep in the offensive zone can't be counted on. He still
	# sprints home (tracking mode), but the numbers read must not pretend he's
	# a defender — that's how a 2-on-1 gets defended as if it were a 2-on-2.
	var theirs := {
		11: [Vector3(0.0, 0.0, 14.0), Vector3(0.0, 0.0, 8.0)],
		12: [Vector3(4.0, 0.0, 14.0), Vector3(0.0, 0.0, 8.0)],
	}
	var ours := {
		1: [Vector3(0.0, 0.0, 20.0), Vector3.ZERO],
		2: [Vector3(0.0, 0.0, -26.0), Vector3.ZERO],   # stranded in their end
	}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.recovery_by_peer.get(2), AIRushRead.Recovery.BEATEN,
			"a peer stranded in the offensive zone is BEATEN")
	assert_eq(r.numbers, AIRushRead.Numbers.DOWN_ONE,
			"a beaten peer is not counted as back")


# ── Mode ─────────────────────────────────────────────────────────────────────

func test_regroup_when_they_turn_back() -> void:
	# They hold it in the neutral zone but are skating AWAY from us. The answer
	# is to stand up at our line, not to retreat — so this must not read RUSH.
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -5.0)]}
	var ours := {1: [Vector3(0.0, 0.0, 16.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.mode, AIRushRead.Mode.REGROUP,
			"a carrier skating away from our net is a regroup")


func test_rush_when_they_come_at_us() -> void:
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 7.0)]}
	var ours := {1: [Vector3(0.0, 0.0, 16.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.mode, AIRushRead.Mode.RUSH, "a carrier closing on us is a rush")


func test_our_possession_reads_no_rush_but_still_prices_the_counter() -> void:
	# We have the puck, so there is no rush to defend — but the pinch stations
	# still need to know who would burn us on a turnover here. That hypothesis
	# is exactly a turnover at the puck, so `attackers` stays populated while
	# everything about defending a live rush stays inert.
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3.ZERO]}
	var ours := {1: [Vector3(0.0, 0.0, 16.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 1)
	assert_eq(r.mode, AIRushRead.Mode.NONE, "no rush to read when we have it")
	assert_true(r.is_live, "the read still ran — consumers must not see it as unwired")
	assert_true(11 in r.attackers, "a turnover here would be countered by him")
	assert_eq(r.numbers, AIRushRead.Numbers.EVEN_OR_UP,
			"numbers are inert while we possess")
	assert_eq(r.backpressure_s, INF, "backpressure is inert while we possess")


func test_unwired_read_is_not_mistaken_for_a_clear_coast() -> void:
	# The inert instance every brainless context gets must report is_live false,
	# so collect_counter_threats falls back to all opponents instead of silently
	# disabling every race-home bound in the game.
	assert_false(AIRushRead.new().is_live)


func test_in_our_zone_is_a_rush_even_when_stalled() -> void:
	# A cycle in our own end is an attack, not a regroup — instantaneous closing
	# speed must not downgrade it.
	var theirs := {11: [Vector3(6.0, 0.0, 20.0), Vector3.ZERO]}
	var ours := {1: [Vector3(2.0, 0.0, 23.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.mode, AIRushRead.Mode.RUSH,
			"possession in our zone is an attack regardless of pace")


# ── Backpressure ─────────────────────────────────────────────────────────────

func test_backpressure_infinite_with_nobody_behind() -> void:
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0)]}
	var ours := {1: [Vector3(0.0, 0.0, 18.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_eq(r.backpressure_s, INF,
			"a lone defender in front of the rush has no backpressure")


func test_backpressure_measured_from_a_trailing_teammate() -> void:
	# A backchecker right on the carrier's hip is the doctrine trigger that lets
	# the D stand up. It must read as a small, finite number.
	var theirs := {11: [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0)]}
	var ours := {
		1: [Vector3(0.0, 0.0, 18.0), Vector3.ZERO],
		2: [Vector3(0.0, 0.0, -2.5), Vector3(0.0, 0.0, 7.0)],   # on his hip
	}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_lt(r.backpressure_s, 1.5,
			"a backchecker on the carrier's hip is live backpressure")


# ── Coverage accounting (the DZONE gate — plan §9) ───────────────────────────

func test_coverage_not_accounted_mid_backcheck() -> void:
	# The puck has just crossed into our zone with three of ours still up-ice.
	# This is exactly the moment the old code switched everyone into zone posts.
	var theirs := {
		11: [Vector3(0.0, 0.0, 10.0), Vector3(0.0, 0.0, 6.0)],
		12: [Vector3(-6.0, 0.0, 9.0), Vector3(0.0, 0.0, 6.0)],
	}
	var ours := {
		1: [Vector3(0.0, 0.0, 22.0), Vector3.ZERO],
		2: [Vector3(0.0, 0.0, -8.0), Vector3(0.0, 0.0, 6.0)],
		3: [Vector3(4.0, 0.0, -10.0), Vector3(0.0, 0.0, 6.0)],
	}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_false(r.coverage_accounted,
			"coverage is not set while men are unaccounted for")


func test_coverage_accounted_when_everyone_is_picked_up() -> void:
	# Set structure: a body on the puck, and the second attacker fronted
	# goal-side inside the cover envelope.
	var theirs := {
		11: [Vector3(0.0, 0.0, 20.0), Vector3.ZERO],
		12: [Vector3(-6.0, 0.0, 22.0), Vector3.ZERO],
	}
	var ours := {
		1: [Vector3(0.0, 0.0, 21.2), Vector3.ZERO],           # on the puck
		2: [Vector3(-5.0, 0.0, 23.5), Vector3.ZERO],          # goal-side of 12
	}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_true(r.coverage_accounted,
			"every man owned and somebody on the puck is set coverage")


func test_coverage_not_accounted_with_nobody_on_the_puck() -> void:
	var theirs := {11: [Vector3(0.0, 0.0, 20.0), Vector3.ZERO]}
	var ours := {1: [Vector3(-10.0, 0.0, 24.0), Vector3.ZERO]}
	var r: AIRushRead = _read(ours, theirs, 11)
	assert_false(r.coverage_accounted,
			"an unpressured carrier means coverage is not set")


# ── Hysteresis ───────────────────────────────────────────────────────────────

func test_tracking_is_sticky_across_the_boundary() -> void:
	# A peer sitting right on the recovery-race boundary must not flip the whole
	# team's posture tick to tick. Held as TRACKING last tick, he keeps counting
	# under the looser hold bar.
	var theirs := {
		11: [Vector3(0.0, 0.0, 6.0), Vector3(0.0, 0.0, 7.0)],
		12: [Vector3(4.0, 0.0, 6.0), Vector3(0.0, 0.0, 7.0)],
	}
	var ours := {
		1: [Vector3(0.0, 0.0, 20.0), Vector3.ZERO],
		2: [Vector3(0.0, 0.0, 3.0), Vector3(0.0, 0.0, 6.0)],
	}
	var cold: AIRushRead = _read(ours, theirs, 11, Vector3.INF, {})
	var warm: AIRushRead = _read(ours, theirs, 11, Vector3.INF,
			{2: AIRushRead.Recovery.TRACKING})
	# The incumbent bar is strictly looser, so a peer counted last tick can
	# never be dropped while a cold read would have kept him.
	var cold_back: bool = cold.recovery_by_peer.get(2) != AIRushRead.Recovery.BEATEN
	var warm_back: bool = warm.recovery_by_peer.get(2) != AIRushRead.Recovery.BEATEN
	assert_true(warm_back or not cold_back,
			"the hold bar is never stricter than the enter bar")


func test_empty_snapshot_is_inert() -> void:
	var r := AIRushRead.new()
	r.fill(null, 0, OUR_NET_Z, {}, {}, {})
	assert_eq(r.mode, AIRushRead.Mode.NONE)
	assert_true(r.attackers.is_empty())
	assert_true(r.coverage_accounted == false)
