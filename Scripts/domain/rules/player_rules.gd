class_name PlayerRules

# Pure rules about players — team balance and faceoff position lookup. No
# engine or GameManager access; callers do the data gathering (counting team
# members, etc.) and pass the numbers in. Color presets live in
# TeamColorRegistry.

# CAPACITY, not the live roster size: the largest team either mode can field
# (5v5). Sizes every per-slot structure (lobby grid, slot-key stride, faceoff
# offsets) so a lobby can flip 3v3 ↔ 5v5 without re-keying. The ACTIVE size for
# a match is GameStateMachine.team_size (latched at puck drop, like rule_set);
# roster gates must read that, never this constant.
const MAX_PER_TEAM: int = 5

# team_slot IS the position: the lobby grid's slot index doubles as the
# player's position identity (drives faceoff alignment, lobby/scoreboard
# labels, bot identity casting, and — in 5v5 — the AI's F/D group split).
# Slots 3/4 exist only when the latched team size is 5.
const POSITION_NAMES: Array[String] = ["C", "LW", "RW", "LD", "RD"]
# The F/D group split (5v5): defensemen are slots 3/4.
const FIRST_DEFENSE_SLOT: int = 3


static func position_name(team_slot: int) -> String:
	if team_slot >= 0 and team_slot < POSITION_NAMES.size():
		return POSITION_NAMES[team_slot]
	return ""


static func is_defense_slot(team_slot: int) -> bool:
	return team_slot >= FIRST_DEFENSE_SLOT

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
	# End-zone draws break the one-table symmetry for the D pair: their jobs
	# there are positional (net-front / retriever / points — see the
	# FACEOFF_END_* doc in GameRules), not dot-relative. C and wingers keep
	# the table everywhere (the hash-mark line-up IS the real alignment at
	# every dot), so 3v3 — which has no D slots — is untouched by construction.
	if team_slot >= FIRST_DEFENSE_SLOT \
			and absf(dot_xz.y) > GameRules.BLUE_LINE_Z:
		return _end_zone_d_position(team_id, team_slot, dot_xz)
	var off: Vector2 = GameRules.FACEOFF_OFFSETS[team_id][team_slot]
	if team_slot == 0 and center_reach > 0.0:
		off.y = signf(off.y) * center_reach
	# Depth cap (FACEOFF_MAX_ABS_Z): a defensive-zone end-zone draw puts the D
	# slots' raw offsets behind the goal line — clamp them net-side instead.
	var z: float = clampf(dot_xz.y + off.y,
			-GameRules.FACEOFF_MAX_ABS_Z, GameRules.FACEOFF_MAX_ABS_Z)
	return Vector3(dot_xz.x + off.x, GameRules.FACEOFF_SPAWN_HEIGHT, z)


# The D pair's end-zone draw placement (see the FACEOFF_END_* doc in
# GameRules). "Strong" is the D whose identity side (the sign of his legacy
# table offset — LD −x, RD +x, both teams) matches the dot's side of the ice,
# so the pair never crosses over: DEFENDING, the strong D retrieves directly
# behind the C (goal-side, boards shade) and the weak D fronts the net at the
# near post; ATTACKING, the strong D points up directly above the dot just
# inside the blue line and the weak D takes the middle of the line.
static func _end_zone_d_position(team_id: int, team_slot: int,
		dot_xz: Vector2) -> Vector3:
	# Own-net direction: team 0 defends +Z, team 1 −Z (the team-side
	# convention faceoff_facing documents).
	var own_dir: float = 1.0 if team_id == 0 else -1.0
	var boards: float = signf(dot_xz.x)
	var identity: float = signf(GameRules.FACEOFF_OFFSETS[team_id][team_slot].x)
	var strong: bool = identity == boards
	if signf(dot_xz.y) == own_dir:
		# Defensive-zone draw: goal-side stack.
		if strong:
			return Vector3(
					dot_xz.x + boards * GameRules.FACEOFF_END_RETRIEVER_SHADE_M,
					GameRules.FACEOFF_SPAWN_HEIGHT,
					dot_xz.y + own_dir * GameRules.FACEOFF_END_RETRIEVER_BEHIND_M)
		return Vector3(
				boards * GameRules.FACEOFF_END_NETFRONT_X_M,
				GameRules.FACEOFF_SPAWN_HEIGHT,
				own_dir * (GameRules.GOAL_LINE_Z
						- GameRules.FACEOFF_END_NETFRONT_OFF_LINE_M))
	# Offensive-zone draw: points at the blue line, inside the zone.
	var z: float = signf(dot_xz.y) \
			* (GameRules.BLUE_LINE_Z + GameRules.FACEOFF_END_POINT_INSIDE_M)
	if strong:
		return Vector3(dot_xz.x, GameRules.FACEOFF_SPAWN_HEIGHT, z)
	return Vector3(-boards * GameRules.FACEOFF_END_WEAK_POINT_X_M,
			GameRules.FACEOFF_SPAWN_HEIGHT, z)


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


# Post-goal skate-in start: the final faceoff slot pushed radially OUTWARD from
# the dot by FACEOFF_STAGING_SETBACK, so the skate-in runs back along the ray
# toward the dot — every player converging on the circle instead of skating in
# parallel. Derived from the already-resolved target (inherits the center's reach
# offset). A player sitting on the dot has no radial direction, so it falls back
# to a straight push toward the team's own end (team 0 defends +Z, team 1 -Z).
# Only used post-goal, whose replay camera cut hides the jump to this point.
static func faceoff_staging_position(target: Vector3, dot_xz: Vector2, team_id: int) -> Vector3:
	var staged: Vector3
	var radial: Vector2 = Vector2(target.x - dot_xz.x, target.z - dot_xz.y)
	if radial.length() < 0.01:
		var own_side_sign: float = -1.0 if team_id == 1 else 1.0
		staged = Vector3(target.x, target.y,
				target.z + own_side_sign * GameRules.FACEOFF_STAGING_SETBACK)
	else:
		var dir: Vector2 = radial.normalized()
		staged = Vector3(
				target.x + dir.x * GameRules.FACEOFF_STAGING_SETBACK,
				target.y,
				target.z + dir.y * GameRules.FACEOFF_STAGING_SETBACK)
	# Keep the staging point on the ice: a slot already near the end boards
	# (the 5v5 D pair on a defensive-zone draw) pushed radially outward would
	# otherwise stage inside the boards.
	var clamped: Vector2 = GameRules.clamp_to_rink_inner(
			Vector2(staged.x, staged.z), 0.6)
	return Vector3(clamped.x, staged.y, clamped.y)


# Glide time for a skater covering `distance` metres to its dot at the target
# skate pace, clamped to [min_dur, max_dur]. A close player skates in briefly
# and settles; a far one takes the full window. max_dur is set by the caller
# from the extended prep window so everyone arrives before the drop.
static func skate_in_duration(distance: float, min_dur: float, max_dur: float) -> float:
	var raw: float = distance / maxf(GameRules.FACEOFF_SKATE_IN_SPEED, 0.01)
	return clampf(raw, min_dur, max_dur)


# Deterministic pseudo-random value in [0, 1) from two int seeds — a spatial-hash
# mix, so the same (a, b) yields the same value on every machine (no RNG state to
# sync). Used to stagger the post-goal skate-in per player without the arrivals
# looking machine-generated: seed with (peer_id, goals-so-far) and they vary by
# player and by faceoff while host and clients agree.
static func stagger01(a: int, b: int) -> float:
	var h: int = ((a + 1) * 73856093) ^ ((b + 1) * 19349663)
	return float(absi(h) % 100003) / 100003.0
