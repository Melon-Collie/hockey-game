class_name TurnoverRules
## Pure classification of a possession change into takeaway / giveaway / nothing.
## Applied host-side by TurnoverTracker at each possession gain; kept pure + static
## so the branch logic unit-tests without a live game.
##
## Deterministic Mitts model of the (scorer-judgment) NHL definitions:
##   - No prior owner, or the same team recovers → nothing.
##   - Opponent recovers a puck the previous owner deliberately SURRENDERED —
##     a SHOT (saved, missed, or blocked) or a DUMP/CLEAR/RIM (fired to open ice
##     with no receiver) → nothing: conceding the puck to space is neither a
##     giveaway by the shooter/dumper nor a takeaway by whoever collects it.
##     Checked FIRST so a rebound or a retrieved dump is never scored as a
##     turnover. The dump/pass split is `is_dump_release` below — an intercepted
##     PASS (a teammate was the target) still charges a giveaway.
##   - Opponent recovers a puck the previous owner was STRIPPED of (a recent
##     poke / stick-lift / body-check) → takeaway. The credit goes to the
##     STRIPPER — the defender who made the play — not whoever recovers the loose
##     puck (TurnoverTracker carries the stripper's id alongside the strip). Being
##     stripped is NOT a self-inflicted turnover, so no giveaway is charged.
##   - Opponent recovers a puck otherwise cleanly lost (fumble / intercepted
##     pass) → giveaway to the previous owner. The one further exclusion —
##     losing a CONTESTED loose puck (a board battle the losing team fought for
##     and lost) — is vetoed by TurnoverTracker at establishment, since it is
##     only fully known once the scramble resolves.

const NONE := "none"
const TAKEAWAY := "takeaway"
const GIVEAWAY := "giveaway"

# A non-shot release counts as a DUMP/CLEAR (not a pass) when no teammate sits
# in its flight corridor: within RECEIVER_CORRIDOR_M of the launch line and
# ahead of the puck out to RECEIVER_MAX_DIST_M. A real pass is aimed AT a
# teammate (one lands inside the corridor even when an opponent picks it off —
# that stays a giveaway); a dump/clear/rim is fired to open ice.
const RECEIVER_CORRIDOR_M: float = 3.5
const RECEIVER_MAX_DIST_M: float = 30.0


# prev_team: team_id of the last owner (-1 if none). new_team: team_id gaining
# possession now. recent_strip: the puck was stripped off prev_team just before.
# recent_shot: prev_team put a shot on goal just before. recent_dump: prev_team
# dumped/cleared it to open ice just before.
static func classify(prev_team: int, new_team: int,
		recent_strip: bool, recent_shot: bool, recent_dump: bool) -> String:
	if prev_team < 0 or prev_team == new_team:
		return NONE
	# A deliberate surrender (shot or dump/clear) is never a turnover — checked
	# before the strip so a puck both surrendered and (rarely) grazed still reads
	# as a rebound, not a takeaway.
	if recent_shot or recent_dump:
		return NONE
	if recent_strip:
		return TAKEAWAY
	return GIVEAWAY


# True when a non-shot release is a DUMP/CLEAR/RIM — no teammate is positioned to
# receive it. `launch` and `launch_dir` are the horizontal (xz) release point and
# velocity direction; `teammate_positions` are the releaser's teammates' xz spots
# (self and goalies excluded). A teammate counts as a pass target when it lies
# ahead of the puck along the launch line, within RECEIVER_MAX_DIST_M, and within
# RECEIVER_CORRIDOR_M of that line — i.e., the release is aimed roughly at them.
static func is_dump_release(launch: Vector2, launch_dir: Vector2,
		teammate_positions: Array[Vector2]) -> bool:
	var dir: Vector2 = launch_dir
	if dir.length() < 0.001:
		return false  # no meaningful launch (e.g. a whistle drop) — not a dump
	dir = dir.normalized()
	for mate: Vector2 in teammate_positions:
		var to_mate: Vector2 = mate - launch
		var along: float = to_mate.dot(dir)
		if along <= 0.0 or along > RECEIVER_MAX_DIST_M:
			continue  # behind the puck, or beyond any plausible pass
		var perp: float = (to_mate - dir * along).length()
		if perp <= RECEIVER_CORRIDOR_M:
			return false  # a teammate is in the flight corridor — this is a pass
	return true
