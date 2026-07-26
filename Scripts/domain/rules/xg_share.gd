class_name XGShare
## Cumulative expected-goals SHARE over the game clock — the "who deserved to
## win" curve behind the post-game analytics screen.
##
## At any moment t the home share is
##
##     home_xg(t) / (home_xg(t) + away_xg(t))
##
## the fraction of all the chance quality created so far that belongs to the
## home team. 0.5 is a dead-even game; 1.0 is one team playing alone.
##
## CUMULATIVE, deliberately. The question this answers — "who deserved it" — is
## a claim about the whole game, so it has to be settled by everything that has
## happened. A rolling window answers the different question of who is pushing
## RIGHT NOW, which is a run-of-play read, not a deserved-result one.
##
## Blocked attempts carry no xG (the Fenwick convention the xGF counter already
## uses), so they move neither the numerator nor the denominator.
##
## Before either team has generated a chance the ratio is 0/0 — undefined — and
## reported as 0.5: nothing has happened, so nobody deserves it more. The curve
## is genuinely volatile in the opening minutes, because one good look really is
## 100% of the danger created so far. That swing is information about a thin
## sample, not noise to be smoothed away, so it is left alone; the flat 0.5 lead-in
## and the widening event spacing are what show the reader the sample filling in.
##
## This is NOT a win probability. Turning a share into P(win) needs a model
## calibrated against real outcomes, which is a different (and later) thing —
## see the note on final_share.

# Row shape of series(): three parallel arrays, one entry per unblocked shot, in
# chronological order. Parallel packed arrays rather than an Array of rows so the
# whole series is three allocations instead of one per event, and so the fields
# stay typed.
#   t          — elapsed seconds since the opening faceoff
#   share      — home xG share AFTER that shot, 0..1
#   goal_team  — 0/1 when the shot was a goal, -1 otherwise

const EVEN: float = 0.5


# Absolute elapsed seconds for an event. `period` is 1-based and `clock_s` counts
# DOWN from the period length, so a shot at 4:00 remaining in P2 of 5-minute
# periods sits at 5*60 + (300 - 240) = 360 s.
static func elapsed_seconds(e: ShotEvent, period_s: float) -> float:
	return float(maxi(e.period - 1, 0)) * period_s + (period_s - e.clock_s)


static func series(events: Array[ShotEvent], period_s: float) -> Dictionary:
	var span: float = maxf(period_s, 1.0)
	var order: Array[ShotEvent] = events.duplicate()
	order.sort_custom(func(a: ShotEvent, b: ShotEvent) -> bool:
			return elapsed_seconds(a, span) < elapsed_seconds(b, span))

	# Filled as LOCALS and stored at the end. Packed arrays are value types, so
	# reading one back out of a Dictionary hands you a copy — appending through
	# `out["t"].append(...)` would silently write to a temporary and leave the
	# stored array empty.
	var ts := PackedFloat32Array()
	var shares := PackedFloat32Array()
	var goal_team := PackedInt32Array()

	var acc: Array[float] = [0.0, 0.0]
	for e: ShotEvent in order:
		if e.outcome == ShotEvent.Outcome.BLOCKED:
			continue
		var team: int = clampi(e.team_id, 0, 1)
		acc[team] += maxf(e.xg, 0.0)
		ts.append(elapsed_seconds(e, span))
		shares.append(_ratio(acc[0], acc[1]))
		goal_team.append(team if e.outcome == ShotEvent.Outcome.GOAL else -1)
	return {"t": ts, "share": shares, "goal_team": goal_team}


# The end-of-game share — the single number the curve is building toward, and the
# one worth putting in words ("you earned 63% of the danger"). Reported for the
# HOME side; the away side is 1 − this.
#
# A future win probability would be a function OF this, fitted to how often a
# given share actually won — every finished match already stores its team xG and
# its result, so the fit is a query away rather than a guess. Until that fit
# exists this stays a share, which is a measurement rather than a claim.
static func final_share(events: Array[ShotEvent]) -> float:
	var acc: Array[float] = [0.0, 0.0]
	for e: ShotEvent in events:
		if e.outcome == ShotEvent.Outcome.BLOCKED:
			continue
		acc[clampi(e.team_id, 0, 1)] += maxf(e.xg, 0.0)
	return _ratio(acc[0], acc[1])


static func _ratio(home: float, away: float) -> float:
	var total: float = home + away
	return EVEN if total <= 0.0 else clampf(home / total, 0.0, 1.0)
