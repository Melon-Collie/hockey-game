class_name PlayerRules

# Pure rules about players — team balance and faceoff position lookup. No
# engine or GameManager access; callers do the data gathering (counting team
# members, etc.) and pass the numbers in. Color presets live in
# TeamColorRegistry.

const MAX_PER_TEAM: int = 3

# Returns team_id (0 or 1). Balances by count; ties are broken randomly.
static func assign_team(team0_count: int, team1_count: int) -> int:
	if team0_count < team1_count:
		return 0
	if team1_count < team0_count:
		return 1
	return randi() % 2

# Looks up the faceoff start position for a team and within-team slot.
static func faceoff_position(team_id: int, team_slot: int) -> Vector3:
	return GameRules.CENTER_FACEOFF_POSITIONS[team_id][team_slot]


# Facing each team should adopt on a faceoff teleport. Team 0 starts on the
# +Z half and attacks -Z; team 1 mirrors. Without this, a teleport carries
# whatever facing the skater had last frame, which is why players sometimes
# spawn backwards after a faceoff or a slot swap. (-1) team_id returns
# Vector2.ZERO so callers that don't want to flip facing (tutorial / tests)
# can pass it through unchanged.
static func faceoff_facing(team_id: int) -> Vector2:
	if team_id == 0:
		return Vector2(0.0, -1.0)
	if team_id == 1:
		return Vector2(0.0, 1.0)
	return Vector2.ZERO
