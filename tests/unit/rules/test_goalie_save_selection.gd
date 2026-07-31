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


# The same play, `dt` seconds later. Every clock on a Situation is measured from
# NOW, so advancing time shrinks them together — moving `time_to_arrival` alone
# silently turns a tip into a non-tip (a contest that lands after the puck cannot
# happen, so it stops counting).
func _advance(s: GoalieSaveSelection.Situation,
		dt: float) -> GoalieSaveSelection.Situation:
	var out := GoalieSaveSelection.Situation.new()
	out.time_to_arrival = s.time_to_arrival - dt
	out.time_to_contest = s.time_to_contest - dt if is_finite(s.time_to_contest) \
			else INF
	out.reaction_delay = s.reaction_delay
	out.drop_time = s.drop_time
	out.sight_delay = maxf(s.sight_delay - dt, 0.0)
	out.lateral_race_lost = s.lateral_race_lost
	return out


# The same play at the last instant the drop can still start and finish in time.
func _at_deadline(s: GoalieSaveSelection.Situation) -> GoalieSaveSelection.Situation:
	return _advance(s, s.time_to_arrival - s.drop_time)

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
	assert_gt(GoalieSaveSelection.answer_fraction(_s(flight)), 0.0,
			"unobstructed, he has a read to work with")
	assert_eq(GoalieSaveSelection.answer_fraction(_s(flight, tip_at)), 0.0,
			"a stick that can touch it in flight makes the read worthless")
	# ...but "no read" is not "go now". He can still SEE the puck, so he can time
	# the seal, and standing is worth keeping until the deadline. He blocks once
	# the drop can no longer wait — same sealed posture, later, with the extra
	# tenth spent on his feet. See must_commit_now.
	assert_false(GoalieSaveSelection.should_block(_s(flight, tip_at)),
			"he does not flop at the release — he can time this one")
	assert_true(GoalieSaveSelection.should_block(_at_deadline(_s(flight, tip_at))),
			"and he seals when the drop can no longer be deferred")


func test_a_net_front_tip_leaves_him_nothing() -> void:
	# "You cannot react to a tip" — and the arithmetic says how true that is.
	# Answering costs reaction + drop = 0.33 s, so a tip would have to happen
	# more than 0.33 s of flight away to leave a FULL answer. At 30 m/s that is
	# ~9.9 m, which is not a tip, it is a different play.
	#
	# Inside genuine net-front range he has literally nothing. Further out he
	# gets a sliver — enough to begin moving, not enough to be a save — which
	# matches the fact that mid-slot deflections occasionally get a piece of a
	# goalie while doorstep tips never do. The model is left to say exactly how
	# much rather than being forced to a verdict.
	var shot_speed: float = 30.0
	var shooter_dist: float = 15.0
	var arrival: float = shooter_dist / shot_speed
	for tip_dist: float in [1.0, 2.0, 3.0]:
		var tip_at: float = (shooter_dist - tip_dist) / shot_speed
		var s := _s(arrival, tip_at)
		assert_eq(GoalieSaveSelection.answer_fraction(s), 0.0,
				"a tip %.0f m out leaves no answer at all" % tip_dist)
		# No answer, so when he goes down he is BLOCKING, not reacting — but the
		# moment is set by the deadline, not by the tip. Unscreened he can time it.
		assert_true(GoalieSaveSelection.should_block(_at_deadline(s)),
				"so the save he makes is a block, taken at the deadline")
	# The fade, not a cliff: a deflection out at mid-slot leaves a fraction of a
	# drop. Still not a save, but he is moving, and pretending otherwise would be
	# the same binary thinking the pad model already suffers from.
	for tip_dist: float in [4.0, 5.0]:
		var tip_at: float = (shooter_dist - tip_dist) / shot_speed
		var f: float = GoalieSaveSelection.answer_fraction(_s(arrival, tip_at))
		assert_true(f > 0.0 and f < 0.25,
				"a %.0f m deflection leaves a sliver, not a save (got %.2f)"
				% [tip_dist, f])


func test_a_tip_threat_blocks_him_before_the_shot_is_taken() -> void:
	# The consequence that matters in 5v5: because time_to_arrival is the worst
	# case — the point man shoots this instant — a live tip threat in the lane
	# drops him while the puck is still on the blue line. That is what a real
	# goalie does against a screen-and-tip look, and it falls out of the same
	# inequality rather than needing a "there is traffic" rule.
	var arrival: float = 15.0 / 30.0        # if he shoots right now
	var tip_at: float = 12.0 / 30.0         # tipper 3 m off the goalie
	assert_eq(GoalieSaveSelection.answer_fraction(_s(arrival, tip_at)), 0.0,
			"a live tip threat voids the read before the puck is even released")
	# ⚠️ DOCTRINE, CHANGED DELIBERATELY. This used to assert that he goes DOWN
	# here — pre-committed while the puck is still on the blue line. He does not
	# any more, and the reason is that "cannot react" and "must go now" turned out
	# to be two questions (must_commit_now). A tip ruins his read of DIRECTION; it
	# does nothing to his read of TIMING, and deferring costs him nothing because
	# he ends up sealed at the same instant either way.
	#
	# The 5v5 argument is what settled it: in net-front traffic "a stick can reach
	# the puck first" is close to always true, so blocking on it alone means
	# pre-dropping through most of a shift. That is the same failure the
	# WRISTER_AIM experiment measured — a goalie who pre-commits stops being
	# readable, and deception stops paying.
	#
	# A SCREEN still commits him early, because you cannot count down to a puck
	# you cannot see (test_a_screened_point_shot_is_blocked_but_a_clean_one_is_read).
	# To restore the old behaviour, drop the `must_commit_now` conjunct from
	# should_block; the answer_fraction assertions above are the part that is not
	# a judgment call.
	assert_false(GoalieSaveSelection.should_block(_s(arrival, tip_at)),
			"but an unscreened tip does not put him down early — he can time it")
	assert_true(GoalieSaveSelection.should_block(_s(arrival, tip_at, arrival)),
			"add a screen and he must commit blind, because now he cannot time it")


func test_a_pass_he_can_see_resets_the_read_but_leaves_him_time() -> void:
	# D-to-D at the blue line. A pass is a CONTEST — the puck's path changes, so
	# the read he had is void and restarts at the reception. Same mechanism as a
	# tip; the difference is that it happens far out and he sees it coming, so
	# the restarted read still has a full flight to work with.
	#
	# Passes and deflections are therefore one concept in this model, separated
	# only by where they happen and whether sight is blocked.
	var pass_at: float = 0.35                 # reception, well out
	var arrival: float = pass_at + 0.50       # then a shot from the far point
	assert_false(GoalieSaveSelection.should_block(_s(arrival, pass_at)),
			"a pass he sees resets the read and he still has time to answer")
	# The same pass with his eyes blocked is a different play: the read cannot
	# restart until he picks the puck up again.
	assert_true(GoalieSaveSelection.should_block(_s(arrival, pass_at, arrival - 0.10)),
			"screened through the reception, the reset never happens in time")


func test_a_loose_rebound_with_bodies_converging_stays_sealed() -> void:
	# UNVALIDATED — recorded as the model's answer, not as a known-good one.
	# Nobody has confirmed by play what he SHOULD do here, and it is a hard
	# read even for a person.
	#
	# What the model says: a rebound at his feet with sticks converging has a
	# contest time near zero and an arrival right behind it, so there is no
	# answer to be had and he stays sealed. That direction is at least
	# consistent with the reported complaint — he currently pops UP into this
	# situation and concedes through the five-hole — so the model moving the
	# other way is a point in its favour, but it is not evidence.
	#
	# If play shows him staying down too long here and getting beaten high
	# instead, that is the signal, and it would mean the arrival term needs to
	# distinguish "a stick can touch it" from "a stick can SHOOT it".
	var contest: float = GoalieSaveSelection.contest_time(0.4, STICK, 4.0)
	assert_true(GoalieSaveSelection.should_block(_s(contest + 0.03, contest)),
			"a converging scramble at his feet reads as unanswerable")


# ── Staying down: the seal releases when standing is safe ────────────────────

const STAND_UP: float = 0.35        # recovery_duration — the cost of leaving


func test_a_rebound_cleared_to_the_corner_lets_him_recover() -> void:
	# THE STUCK-IN-BUTTERFLY BUG. He kicks the rebound 8 m to the corner; the
	# nearest opponent is a second of skating from reaching it. The arrival term
	# still prices the worst case — next touch plus a 33 m/s whack back at him —
	# so a full from-the-feet answer never fits and the fraction alone held him
	# sealed indefinitely. But nothing can touch the puck before he is back on
	# his feet, so standing exposes nothing: the eventual shot meets a set
	# goalie. Coaching consensus: beyond a couple of stick lengths, recover.
	var contest: float = GoalieSaveSelection.contest_time(
			STICK + 9.0, STICK, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S)
	var s := _s(contest + 8.0 / 33.0, contest)
	assert_lt(GoalieSaveSelection.answer_fraction(s), 1.0,
			"the worst-case relaunch still reads as not fully answerable")
	assert_false(GoalieSaveSelection.should_hold_seal(s, STAND_UP),
			"but he can beat any touch to his feet, so he recovers")


func test_a_loose_rebound_at_his_feet_still_holds_the_seal() -> void:
	# The bug the hold was built for, re-pinned against the stand-up race: a
	# stick already on the puck contests it long before he could be upright, so
	# standing up is standing into the whack — five-hole. He stays sealed.
	var contest: float = GoalieSaveSelection.contest_time(0.5, STICK, 3.0)
	assert_true(GoalieSaveSelection.should_hold_seal(
			_s(contest + 0.02, contest), STAND_UP),
			"a puck a stick can already touch keeps him down")


func test_a_shot_arriving_mid_recovery_holds_the_seal() -> void:
	# A puck in flight lands on him before he could finish standing — getting
	# up opens the five-hole exactly as it arrives. Contest is irrelevant;
	# the flight itself beats the stand-up.
	assert_true(GoalieSaveSelection.should_hold_seal(_s(0.25), STAND_UP),
			"a flight shorter than the stand-up keeps him sealed")


func test_a_lost_lateral_race_holds_regardless_of_time() -> void:
	# Coverage, not timing — same precedence as should_block.
	assert_true(GoalieSaveSelection.should_hold_seal(
			_s(5.0, INF, 0.0, true), STAND_UP),
			"only the seal covers a lost lateral race")


func test_a_fully_answerable_situation_releases_the_seal() -> void:
	# The original asymmetric release: a whole answer fits from his feet again.
	assert_false(GoalieSaveSelection.should_hold_seal(_s(2.0), STAND_UP),
			"with a full answer available he has no business on the ice")


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
