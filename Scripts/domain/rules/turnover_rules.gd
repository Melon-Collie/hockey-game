class_name TurnoverRules
## Pure classification of a possession change into takeaway / giveaway / nothing.
## Applied host-side by TurnoverTracker at each possession gain; kept pure + static
## so the branch logic unit-tests without a live game.
##
## Deterministic Mitts model of the (scorer-judgment) NHL definitions:
##   - No prior owner, or the same team recovers → nothing.
##   - Opponent recovers a puck the previous owner was STRIPPED of (a recent
##     poke / stick-lift) → takeaway to the recoverer: their team made the
##     defensive play. Being stripped is NOT a self-inflicted turnover, so no
##     giveaway is charged. (We credit the recoverer rather than the stripper
##     because the possession-change hook knows who gained the puck, not who
##     poked it — and NHL credits the player who takes possession.)
##   - Opponent recovers a puck the previous owner SHOT on goal (a rebound) →
##     nothing: a shot at the net isn't a giveaway.
##   - Opponent recovers a puck otherwise lost (fumble / intercepted pass) →
##     giveaway to the previous owner.

const NONE := "none"
const TAKEAWAY := "takeaway"
const GIVEAWAY := "giveaway"


# prev_team: team_id of the last owner (-1 if none). new_team: team_id gaining
# possession now. recent_strip: the puck was stripped off prev_team just before.
# recent_shot: prev_team put a shot on goal just before.
static func classify(prev_team: int, new_team: int,
		recent_strip: bool, recent_shot: bool) -> String:
	if prev_team < 0 or prev_team == new_team:
		return NONE
	if recent_strip:
		return TAKEAWAY
	if recent_shot:
		return NONE
	return GIVEAWAY
