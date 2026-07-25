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
# ── What this replaces ───────────────────────────────────────────────────────
# GoalieController had SIX independent paths into butterfly — a doorstep
# slapshot check, a crease-jam check, a beaten-wide race, a bespoke
# "Blocking-drop timer" for screened releases, a post-save rebound drop, and the
# reactive low read — plus a SEPARATE decision (`_is_threat_pressing`) for
# standing back up. Four hand-picked distance thresholds (1.2 / 1.5 / 2.0 /
# 2.5 m) all sat just under two stick lengths (2.6 m), which is what four
# approximations of one boundary look like.
#
# The screened-release timer is the tell: its own comment calls it a
# "Blocking-drop timer". The general rule was already in the codebase, filed as
# a special case beside its siblings.
#
# ── The model ────────────────────────────────────────────────────────────────
# An "answer" is: SEE the puck, DECIDE, then MOVE the pads to the floor. So the
# time an answer costs is
#
#     sight_delay + reaction_delay + drop_time
#
# and the time available is however long until the puck's state can change out
# from under him — the sooner of it ARRIVING and it being TOUCHED by someone who
# can redirect it:
#
#     available = min(time_to_arrival, time_to_contest)
#
# `answer_fraction` is how much of the answer fits in the time available. And
# the useful thing is that it needs NO THRESHOLD:
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
# already lost, no amount of reacting covers the far side, and only the seal
# does. That stays an explicit input because it is a different question.
#
# ── Why contest time, not "is there a carrier" ───────────────────────────────
# The old stand-up rule held the butterfly only for a HOSTILE CARRIER inside a
# proximity threshold, so a slow loose rebound at his feet — no carrier — fell
# through and stood him up into the scramble. Reported from play as "he gets up
# early and gives up unearned rebounds through his five-hole".
#
# Possession does not make a play readable. A controlled puck in traffic is
# still unpredictable, which is exactly when blocking is correct. So the input
# is TIME-TO-CONTEST: how soon can any stick that is not his reach the puck and
# change it. That covers a loose rebound, a teammate corralling under pressure,
# and a 5v5 net-front crowd with one quantity, and it uses the same clock as
# everything else.
#
# Pure/static and engine-free. Callers own the Situation (rebuilt in place each
# tick) so the hot path allocates nothing.

class Situation:
	# Seconds until the puck could be ON his body if it were released or
	# redirected right now. For a shot in flight this is the real flight time;
	# for a carrier it is the worst case — they shoot this instant.
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
	var available: float = minf(s.time_to_arrival, s.time_to_contest) \
			- s.sight_delay - s.reaction_delay
	return clampf(available / s.drop_time, 0.0, 1.0)


# THE decision. Block when reacting cannot buy anything, or when reacting
# cannot cover the threat at all.
static func should_block(s: Situation) -> bool:
	if s.lateral_race_lost:
		return true
	return answer_fraction(s) <= 0.0


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
