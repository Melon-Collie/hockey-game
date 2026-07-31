class_name GoalieSaveSelection

# BLOCK or REACT — the goalie's save selection, as one question.
#
# ── The rule (real goaltending, not invented here) ───────────────────────────
# Every save is a BLOCKING save or a REACTION save.
#   * REACTING is preferred. Stay patient, let the shooter's body and stick
#     declare the puck's path, then respond.
#   * BLOCKING is for when reacting is IMPOSSIBLE — the puck is too close to
#     answer, the goalie is screened, a deflection is live, or the play is an
#     unpredictable scramble. Put the body where the puck must hit it.
# The coaching rule of thumb is "beyond about two stick lengths, use the
# reaction butterfly", but distance is a PROXY. The real quantity is time: can
# I still complete an answer before the puck is on me?
#
# ── The model ────────────────────────────────────────────────────────────────
# An "answer" is: SEE the puck, DECIDE, then MOVE the pads to the floor. So the
# time an answer costs is
#
#     sight_delay + reaction_delay + drop_time
#
# and the time available is measured from the LAST MOMENT the puck's path
# becomes knowable. Two things can delay that: not being able to SEE it, and
# something still being able to CHANGE it.
#
#     available = time_to_arrival - max(sight_delay, contest) - reaction_delay
#
# A contest does NOT shorten the flight — a tipped puck does not arrive sooner.
# It RESTARTS the read: the direction he had been tracking is gone and he must
# answer a new one from the moment of the touch. That is why a net-front tip is
# lethal on a shot he can otherwise see comfortably, and it is the doctrine's
# third block trigger (proximity, screens, DEFLECTION RISK) falling out of the
# model rather than being added to it.
#
# `answer_fraction` is how much of the answer fits in the time available, and it
# needs NO THRESHOLD:
#
#     <= 0  reacting buys literally nothing — the read cannot even start, so
#           pre-commit: BLOCK.
#      0..1 he begins the drop and the puck arrives mid-rotation. This is not a
#           modelling gap, it is REAL and measured — the pads sweeping from
#           vertical to flat neither block the standing lane nor seal the ice,
#           which is the seam a human beats him through
#           (tests/unit/ai/test_goalie_mid_drop_gap.gd). The model reproduces it
#           instead of pretending the drop is instant.
#     >= 1  a full reaction fits: stay up and READ.
#
# The one case that is not about time is coverage: if the lateral race is
# already lost, no amount of reacting covers the far side and only the seal
# does. That stays an explicit input because it is a different question.
#
# ── Time-to-contest, not "is there a carrier" ────────────────────────────────
# Possession does not make a play readable. A controlled puck in traffic is
# still unpredictable, which is exactly when blocking is correct — and a slow
# loose rebound at his feet is no more answerable for having no carrier. So the
# input is TIME-TO-CONTEST: how soon can any stick that is not his reach the
# puck and change it. One quantity covers a loose rebound, a teammate corralling
# under pressure, and a 5v5 net-front crowd, on the same clock as everything
# else. Gating on carrier proximity instead stands him up into scrambles.
#
# ── Scope: in front of the net only ──────────────────────────────────────────
# A puck BEHIND the goal line is not a block-or-react question, it is a STANCE
# question — RVH seals at/below the goal line, VH takes the in-front sharp
# angle. That stays in `_is_puck_in_defensive_zone` → VH/RVH and is deliberately
# not folded in here. One model per question: this one answers "can I still
# answer this puck from my feet", post integration answers "which post stance
# covers this angle".
#
# Pure/static and engine-free. Callers own the Situation (rebuilt in place each
# tick) so the hot path allocates nothing.

class Situation:
	# Seconds until the puck could be ON his body BY ANY ROUTE — including via a
	# redirect. For a shot in flight this is the real flight time; for a carrier
	# it is the worst case, they shoot this instant; for a loose puck in the
	# crease it is the touch plus the (tiny) flight from there. The caller owns
	# that geometry, and getting it wrong here is what makes a scramble read as
	# safe.
	var time_to_arrival: float = INF
	# Seconds until any stick that is not his can reach the puck and change it.
	# INF when nobody is close enough to matter. This is the readability term:
	# a puck something can touch before he can answer is unpredictable no matter
	# who nominally possesses it.
	var time_to_contest: float = INF
	# His read delay for the low band (legs), and how long the pads take to
	# reach the floor once committed.
	var reaction_delay: float = 0.0
	var drop_time: float = 0.0
	# Extra seconds before he can even SEE the release — screen occlusion. A
	# full screen makes this large, which is what turns a screened release into
	# a blocking save without a bespoke timer.
	var sight_delay: float = 0.0
	# Coverage, not timing: the carrier's lateral drive has already won the race
	# to the post, so standing tracking cannot cover it and only the seal can.
	var lateral_race_lost: bool = false


# How much of a full answer fits in the time available, in [0, 1].
#   0   -> the read cannot even begin; reacting buys nothing
#   1   -> a complete reaction fits, pads sealed before arrival
# Values between are the goalie genuinely caught mid-drop, which is a real
# state, not a rounding error — see the class doc.
static func answer_fraction(s: Situation) -> float:
	if s.drop_time <= 0.0:
		# Degenerate config: an instantaneous drop always "fits".
		return 1.0
	# A contest that lands after the puck does never happens, so it delays
	# nothing. Otherwise the read restarts at the touch.
	var contest: float = s.time_to_contest if s.time_to_contest < s.time_to_arrival \
			else 0.0
	var known_at: float = maxf(s.sight_delay, contest)
	var available: float = s.time_to_arrival - known_at - s.reaction_delay
	return clampf(available / s.drop_time, 0.0, 1.0)


# True once the drop can no longer be deferred.
#
# This is the second half of the decision and it is easy to miss. "Reacting is
# impossible" is a statement about the WHOLE play; it says nothing about whether
# NOW is the moment to go, and standing is not free to give up — a goalie on his
# feet can still push, track and cut angles, and a sealed one cannot. Without
# this, a puck sitting in his lap with an opponent FOUR SECONDS away read as a
# block: perfectly true that he could never react to the eventual whack, and
# absurd as an instruction to lie down for four seconds.
#
# The drop must START by `time_to_arrival - drop_time` or the pads are still
# rotating when the puck lands. So there are two ways it can be time to go:
#
#   1. THE DEADLINE IS HERE. `arrival - drop_time <= 0`.
#   2. HE CANNOT SEE THE DEADLINE COMING. Deferring means counting down to a
#      moment, and you cannot count down to a puck you cannot see. If the screen
#      outlasts the deadline he has to commit blind and early rather than
#      discover he is late. This is the screened blocking save, and it is why a
#      screen is a different kind of block trigger from a tip: a tipper does not
#      stop him TIMING the seal, only knowing where it goes — and the timing is
#      the only thing deferral needs.
#
# No new constant — the drop time and the sight delay are both already inputs.
# "Start the drop no earlier than you must, unless you cannot tell when that is."
static func must_commit_now(s: Situation) -> bool:
	var deadline: float = s.time_to_arrival - s.drop_time
	return deadline <= 0.0 or s.sight_delay > deadline


# STAYING down, as opposed to going down. Same model and the same inputs — a
# goalie has no business standing into a situation he would have dropped for —
# but deliberately NOT the same threshold, because the two are not equally
# expensive to get wrong. Entering the seal is free; leaving it costs a full
# `recovery_duration` and then the climb back out to challenge depth, most of a
# second during which he is neither down nor set.
#
# WITHOUT THE ASYMMETRY THIS OSCILLATES, and not because of noisy inputs. The
# goalie's own depth feeds `time_to_arrival` (the puck's flight to WHERE HE IS),
# so the decision's input depends on the decision's output: at challenge depth
# the gap is inside the block threshold, he drops, recovering retreats him toward
# his goal line, the longer gap says he can react after all, he stands, the climb
# back out shortens the gap, and he drops again. Measured in play against a
# completely stationary puck — the gap cycling 4.87 / 4.92 / 5.62 / 4.86 m across
# a threshold at 4.884 m while the puck sat at one spot the entire time.
#
# So he abandons the seal only when the react response is FULLY available again
# (a whole drop's worth of time on top of the read), never on the hair's breadth
# that his own retreat just bought him. No tuned constant: `answer_fraction` is
# already normalised by the drop, so "fully answerable" is its own ceiling.
#
# One release the fraction cannot see, and it is the far end of the same
# asymmetry: `stand_up_time` is the COST of leaving — the vulnerable window
# during which he can neither drop nor react. If no stick can reach the puck and
# its own flight cannot arrive inside that window, standing exposes nothing:
# whatever eventually comes meets a SET goalie making this same block-or-react
# choice from his feet. Without it, the loose-puck arrival term (next touch plus
# a worst-case flight) reads "not fully answerable" for any dead puck within
# ~11 m — an instruction to lie sealed while the nearest opponent is seconds
# away, the exact absurdity `must_commit_now` exists to prevent on the way down.
# Coaching consensus agrees from the other side: a rebound beyond a couple of
# stick lengths is answered by recovering to the feet, not by holding the ice.
static func should_hold_seal(s: Situation, stand_up_time: float) -> bool:
	if s.lateral_race_lost:
		return true
	if answer_fraction(s) >= 1.0:
		return false
	return minf(s.time_to_contest, s.time_to_arrival) <= stand_up_time


# THE decision. Block when reacting cannot cover the threat at all, or when it
# cannot complete AND the drop can no longer wait.
static func should_block(s: Situation) -> bool:
	# Coverage, not timing: a lost lateral race is not answered by waiting, so it
	# does not get the deferral. Only the seal covers it, and late is worse.
	if s.lateral_race_lost:
		return true
	return answer_fraction(s) <= 0.0 and must_commit_now(s)


# Seconds until a body `dist` metres from the puck, whose stick reaches
# `stick_reach`, can touch it — closing at `close_speed`. INF when it is already
# out of reach and not closing. The readability input, expressed as a race like
# everything else in the goalie.
static func contest_time(dist: float, stick_reach: float,
		close_speed: float) -> float:
	var gap: float = dist - stick_reach
	if gap <= 0.0:
		return 0.0          # already within a stick of it
	if close_speed <= 0.001:
		return INF
	return gap / close_speed
