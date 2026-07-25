extends GutTest

# Situations the save selection has to get right, written as hockey rather than
# as numbers. Each one names the play, states what a goalie should do, and why.
#
# This is the file to grow. Adding a situation is four lines: build a Situation,
# say what he should do, say why. If a scenario we care about cannot be
# expressed with the inputs on Situation, that is the signal the model is
# missing a perception — which is exactly how the stick and the drop phase were
# found.

const REACT_DELAY: float = 0.13     # legs, Hard tier
const DROP: float = 0.20            # pads to floor
const STICK: float = GameRules.DEFAULT_STICK_LENGTH_M


func _s(arrival: float, contest: float = INF, sight: float = 0.0,
		beaten: bool = false) -> GoalieSaveSelection.Situation:
	var s := GoalieSaveSelection.Situation.new()
	s.time_to_arrival = arrival
	s.time_to_contest = contest
	s.reaction_delay = REACT_DELAY
	s.drop_time = DROP
	s.sight_delay = sight
	s.lateral_race_lost = beaten
	return s


# ── Patience: the half that is easy to lose in a refactor ────────────────────

func test_a_dangler_in_space_does_not_get_a_free_drop() -> void:
	# The penalty-shot 1v1. He has time, nobody else can touch the puck, and
	# dropping early is exactly what the dangle is fishing for. Stay up and make
	# the shooter declare — this is the patience the old code got right and any
	# model must keep.
	var s := _s(0.40)
	assert_false(GoalieSaveSelection.should_block(s),
			"a carrier with time and no traffic must not drop him")
	assert_eq(GoalieSaveSelection.answer_fraction(s), 1.0,
			"and a full reaction fits, so he is reading, not scrambling")


func test_a_point_shot_is_read_not_blocked() -> void:
	# Long flight, clear sight, no traffic. The textbook reaction save.
	assert_false(GoalieSaveSelection.should_block(_s(0.55)),
			"a clean point shot is reacted to")


# ── Blocking: reacting is impossible ─────────────────────────────────────────

func test_a_point_blank_windup_is_blocked() -> void:
	# Slapshot winding up at the doorstep. Flight is shorter than the read, so
	# the release beats him no matter what — the drop has to happen DURING the
	# windup or not at all.
	assert_true(GoalieSaveSelection.should_block(_s(0.05)),
			"a release he cannot even begin to read is pre-committed to")


func test_a_full_screen_turns_a_readable_shot_into_a_block() -> void:
	# Same shot, same distance — but he cannot see the release. Sight delay eats
	# the budget, so the reaction he would otherwise have does not exist. This is
	# what the bespoke `_screen_block_drop_timer` was doing by hand.
	var clear := _s(0.30)
	var screened := _s(0.30, INF, 0.25)
	assert_false(GoalieSaveSelection.should_block(clear),
			"unscreened, that shot is readable")
	assert_true(GoalieSaveSelection.should_block(screened),
			"screened, the same shot must be blocked instead")


func test_a_loose_rebound_at_his_feet_keeps_him_down() -> void:
	# THE REPORTED BUG. A slow loose puck in the crease with a stick on it. The
	# old rule held the butterfly only for a hostile CARRIER, so this fell
	# through and stood him up into the scramble — unearned rebounds through the
	# five-hole. Nobody possesses it; that is not the point. Something can change
	# it before he can answer, so it is unreadable, so he stays sealed.
	var contest: float = GoalieSaveSelection.contest_time(0.5, STICK, 3.0)
	# Arrival is the touch plus the flight from half a metre — effectively now.
	assert_true(GoalieSaveSelection.should_block(_s(contest + 0.02, contest)),
			"a puck a stick can already touch keeps him down regardless of possession")


func test_a_teammate_corralling_under_pressure_is_still_traffic() -> void:
	# His own defenceman has it, but an opponent is a stick away. Possession does
	# not make it readable — one poke and it is a shot from two metres.
	var contest: float = GoalieSaveSelection.contest_time(1.4, STICK, 4.0)
	assert_true(GoalieSaveSelection.should_block(_s(contest + 0.05, contest)),
			"a contested puck in the crease is a block regardless of who holds it")


func test_a_teammate_with_the_puck_and_no_pressure_lets_him_up() -> void:
	# The other half of that: uncontested possession in the crease is not a
	# scramble, and holding the butterfly forever would be wrong.
	var contest: float = GoalieSaveSelection.contest_time(6.0, STICK, 4.0)
	assert_false(GoalieSaveSelection.should_block(_s(contest + 0.40, contest)),
			"an uncontested puck lets him stand back up")


func test_beaten_laterally_is_a_block_even_with_all_the_time_in_the_world() -> void:
	# Coverage, not timing. The drive has won the race to the post; reacting
	# perfectly still does not cover the far side, only the seal does. Playtest
	# confirms the resulting lateral-beat-then-elevate goal is a fair chance, so
	# this stays.
	assert_true(GoalieSaveSelection.should_block(_s(1.0, INF, 0.0, true)),
			"a lost lateral race is sealed, not read")


func test_a_screened_point_shot_is_blocked_but_a_clean_one_is_read() -> void:
	# The 5v5 bread-and-butter. Point shot ~15 m, 30 m/s, so the puck is on him
	# in ~0.44 s and an answer costs 0.33 s. Clean, he reads it. With a wall in
	# front the puck only EMERGES about 3 m out, leaving ~0.10 s of sight — the
	# reaction no longer exists, so he blocks: drop, take the ice, concede the top
	# corner he could not have reacted to anyway.
	var flight: float = 0.44
	var clean := _s(flight)
	var walled := _s(flight, INF, flight - 0.10)
	assert_false(GoalieSaveSelection.should_block(clean),
			"a clean point shot is read")
	assert_true(GoalieSaveSelection.should_block(walled),
			"a screened point shot is blocked")


func test_a_tip_threat_blocks_a_shot_he_can_otherwise_see() -> void:
	# The third block trigger in the doctrine, alongside proximity and screens:
	# RISK OF A DEFLECTION. A net-front stick in the lane does not have to hide
	# the puck to ruin the read — it only has to be able to touch it in flight,
	# because a tip changes the puck's direction inside his answer time.
	#
	# This is why time_to_contest must be computed over bodies in the SHOT LANE,
	# not only bodies near the puck's current position: for a net-front tipper
	# the puck travels TO the stick, so the contest time is when the flight
	# reaches them.
	var flight: float = 0.44
	# A tipper 3 m off his body: the puck arrives at their stick well before it
	# arrives at him, and before he could complete an answer.
	var tip_at: float = 0.34
	assert_false(GoalieSaveSelection.should_block(_s(flight)),
			"unobstructed, he reads it")
	assert_true(GoalieSaveSelection.should_block(_s(flight, tip_at)),
			"a stick that can touch it in flight makes the read worthless")


# ── The middle: caught mid-drop is real, not a rounding error ────────────────

func test_the_mid_drop_state_is_represented() -> void:
	# Measured against the live goalie: a shot that arrives while the pads are
	# rotating goes through, because a half-rotated pad neither blocks the
	# standing lane nor seals the ice. The model must be able to SAY "partly
	# answered" — a binary up/down cannot express the seam a human scores on.
	var partial := _s(REACT_DELAY + DROP * 0.5)
	var f: float = GoalieSaveSelection.answer_fraction(partial)
	assert_almost_eq(f, 0.5, 0.01,
			"half the drop time available reads as half an answer")
	assert_false(GoalieSaveSelection.should_block(partial),
			"he still commits to reacting — being caught mid-drop is the cost")


func test_answer_fraction_is_monotonic_in_time() -> void:
	var prev: float = -1.0
	for t: float in [0.10, 0.20, 0.30, 0.40, 0.50]:
		var f: float = GoalieSaveSelection.answer_fraction(_s(t))
		assert_true(f >= prev, "more time never answers less (t=%.2f)" % t)
		prev = f


# ── Contest time ─────────────────────────────────────────────────────────────

func test_contest_time_is_a_stick_race() -> void:
	assert_eq(GoalieSaveSelection.contest_time(0.8, STICK, 5.0), 0.0,
			"a body already within a stick of the puck can touch it now")
	assert_almost_eq(GoalieSaveSelection.contest_time(STICK + 2.0, STICK, 4.0),
			0.5, 0.001, "otherwise it is the gap over the closing speed")
	assert_eq(GoalieSaveSelection.contest_time(5.0, STICK, 0.0), INF,
			"a body that is not closing never contests it")
