class_name TurnoverRules
## Pure classification of a possession change into takeaway / giveaway / nothing.
## Applied host-side by TurnoverTracker at each possession gain; kept pure + static
## so the branch logic unit-tests without a live game.
##
## Deterministic Mitts model of the (scorer-judgment) NHL definitions:
##   - No prior owner, or the same team recovers → nothing.
##   - Opponent recovers a puck the previous owner just SHOT (saved, missed, or
##     blocked) → nothing: putting the puck at the net is neither a giveaway by
##     the shooter nor a takeaway by whoever collects the loose puck. Checked
##     FIRST so a rebound is never scored as a turnover.
##   - Opponent recovers a puck the previous owner was STRIPPED of (a recent
##     poke / stick-lift / body-check) → takeaway. The credit goes to the
##     STRIPPER — the defender who made the play — not whoever recovers the loose
##     puck (TurnoverTracker carries the stripper's id alongside the strip). Being
##     stripped is NOT a self-inflicted turnover, so no giveaway is charged.
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
	# A shot recovery is never a turnover — checked before the strip so a puck
	# both shot and (rarely) grazed still reads as a rebound, not a takeaway.
	if recent_shot:
		return NONE
	if recent_strip:
		return TAKEAWAY
	return GIVEAWAY
