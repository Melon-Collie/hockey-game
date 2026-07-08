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

# Computes the faceoff start position for a team and within-team slot around
# the given dot. Defaults to center ice when no dot is supplied — covers
# default-arg callers (tests, tutorial) without forcing them to know the dot.
#
# center_reach: the CENTER slot's distance from the dot, in metres. The static
# FACEOFF_OFFSETS distance (1.5 m) predates attribute-scaled reach — a Size-1
# center's maximum blade radius (~1.3 m) physically cannot touch the puck from
# there. Callers that know the player pass their reach-derived distance
# (SkaterController.faceoff_center_distance: rest blade radius × fraction) so
# every build can play the drop; ≤ 0 keeps the legacy offset (tests, tutorial,
# callers without a controller). Wingers are unaffected.
static func faceoff_position(team_id: int, team_slot: int,
		dot_xz: Vector2 = GameRules.CENTER_ICE_DOT,
		center_reach: float = -1.0) -> Vector3:
	var off: Vector2 = GameRules.FACEOFF_OFFSETS[team_id][team_slot]
	if team_slot == 0 and center_reach > 0.0:
		off.y = signf(off.y) * center_reach
	return Vector3(dot_xz.x + off.x, GameRules.FACEOFF_SPAWN_HEIGHT, dot_xz.y + off.y)


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


# Bench-door start point for the pre-game intro skate-in. Both benches are on
# the +X boards; team 0 (the +Z-half team) uses the +Z bench, team 1 the -Z
# bench, with a per-slot stagger along the bench so the three skaters don't
# stack. Y matches FACEOFF_SPAWN_HEIGHT so the intro path stays level with the
# dot placement. Unknown team_id (-1, tests) falls back to the +Z bench.
static func bench_start_position(team_id: int, team_slot: int) -> Vector3:
	var side: float = -1.0 if team_id == 1 else 1.0
	var center_z: float = side * GameRules.BENCH_DOOR_CENTER_Z
	var dz: float = 0.0
	if team_slot >= 0 and team_slot < GameRules.BENCH_DOOR_SLOT_DZ.size():
		# Mirror the stagger with the team side so both benches fan toward
		# center ice rather than toward the end boards.
		dz = side * GameRules.BENCH_DOOR_SLOT_DZ[team_slot]
	return Vector3(GameRules.BENCH_DOOR_X, GameRules.FACEOFF_SPAWN_HEIGHT, center_z + dz)
