class_name GameRules

# Pure game-rule constants. No engine concerns here — collision layers, masks,
# and physics tick rate live in Constants.gd (engine-facing autoload).
#
# This is a class_name const class, not an autoload — no registration needed.
# Access anywhere as `GameRules.BLUE_LINE_Z`.

# ── Game Flow Timings ─────────────────────────────────────────────────────────
const GOAL_PAUSE_DURATION: float   = 2.0
const FACEOFF_PREP_DURATION: float = 0.5
const FACEOFF_TIMEOUT: float       = 10.0
const PERIOD_DURATION: float       = 4.0 * 60.0   # 240 s per period
const NUM_PERIODS: int             = 3
const END_OF_PERIOD_PAUSE: float   = 3.0           # pause before next-period faceoff prep
const OT_ENABLED: bool             = true
const OT_DURATION: float           = 4.0 * 60.0   # 240 s per OT period

# ── Rink Geometry ─────────────────────────────────────────────────────────────
const GOAL_LINE_Z: float = 26.65  # rink_length / 2 - distance_from_end (30 - 3.35)
const BLUE_LINE_Z: float = 7.29  # 64 ft from goal line to near edge + 0.15m to center
const NET_HALF_WIDTH: float = 0.915      # half of goal opening — must match HockeyGoal post positions
const NET_DEPTH: float = 1.02            # goal depth from goal line to back frame
const NET_BACK_HALF_WIDTH: float = 1.02  # half-width at back of net (trapezoid wider end)
const NET_HEIGHT: float = 1.22           # crossbar height — must match HockeyGoal.NET_HEIGHT
const NET_PUCK_BUFFER: float = 0.10      # exclusion zone expansion beyond the physical net boundary

# Rink dimensions (must match HockeyRink export values in the scene)
const RINK_HALF_WIDTH: float     = 13.0   # half of 26 m
const RINK_HALF_LENGTH: float    = 30.0   # half of 60 m
const CORNER_RADIUS: float       = 8.53  # 28 ft
const WALL_THICKNESS: float      = 0.3
# Inner wall boundary — interior face of the boards
const INNER_HALF_WIDTH: float    = RINK_HALF_WIDTH  - WALL_THICKNESS * 0.5  # 12.85
const INNER_HALF_LENGTH: float   = RINK_HALF_LENGTH - WALL_THICKNESS * 0.5  # 29.85
const INNER_CORNER_RADIUS: float = CORNER_RADIUS    - WALL_THICKNESS * 0.5  # 8.35
const CORNER_CENTER_X: float     = INNER_HALF_WIDTH  - INNER_CORNER_RADIUS  # 4.5
const CORNER_CENTER_Z: float     = INNER_HALF_LENGTH - INNER_CORNER_RADIUS  # 21.5

# Returns world_xz projected onto the inner rink boundary (rounded rectangle).
# If the point is already inside, returns it unchanged.
static func clamp_to_rink_inner(world_xz: Vector2) -> Vector2:
	var ax: float = absf(world_xz.x)
	var az: float = absf(world_xz.y)
	if ax > CORNER_CENTER_X and az > CORNER_CENTER_Z:
		# Corner quadrant — clamp to the rounded arc
		var dx: float = ax - CORNER_CENTER_X
		var dz: float = az - CORNER_CENTER_Z
		var dist: float = sqrt(dx * dx + dz * dz)
		if dist > INNER_CORNER_RADIUS:
			var scale: float = INNER_CORNER_RADIUS / dist
			return Vector2(
				sign(world_xz.x) * (CORNER_CENTER_X + dx * scale),
				sign(world_xz.y) * (CORNER_CENTER_Z + dz * scale)
			)
	else:
		if ax > INNER_HALF_WIDTH:
			return Vector2(sign(world_xz.x) * INNER_HALF_WIDTH, world_xz.y)
		if az > INNER_HALF_LENGTH:
			return Vector2(world_xz.x, sign(world_xz.y) * INNER_HALF_LENGTH)
	return world_xz

# ── Puck ──────────────────────────────────────────────────────────────────────
const PUCK_START_POS: Vector3 = Vector3(0, 0.05, 0)
const ICE_FRICTION: float = 0.01
# Standard gravity. Used by AI trajectory prediction to convert the
# dimensionless ICE_FRICTION coefficient into a deceleration: a puck
# on ice decelerates at roughly μ × g via Coulomb friction.
const GRAVITY_M_S2: float = 9.81
# Puck deceleration on ice — Coulomb model. Matches the physics
# material's friction × gravity. Single source of truth so AI
# trajectory math and any future analytic puck simulation stay in
# sync with the actual rink physics.
const PUCK_ICE_DECEL_M_S2: float = ICE_FRICTION * GRAVITY_M_S2
# Board restitution coefficient. Mirrors Physics/boards.tres bounce
# value so AI prediction models post-bounce trajectories the same
# way Jolt resolves them.
const PUCK_BOARD_BOUNCE: float = 0.4
# Seconds puck must remain fully outside the rink boundary before a faceoff is forced.
const PUCK_OOB_FACEOFF_TIMEOUT: float = 3.0

# ── Infractions ───────────────────────────────────────────────────────────────
const ICING_GHOST_DURATION: float = 3.0  # seconds team stays ghosted after icing
# End-zone faceoff dot Z offset from center (≈ 15 ft inside goal line).
# Hybrid icing race measures which team's player is closer to this dot.
const ICING_FACEOFF_DOT_Z: float = 22.1

# Rule preset that gates which infractions are detected and how they're punished.
#   OFF    — no offsides, no icing (free-for-all).
#   ARCADE — offsides ghost the offending player; icing is ignored.
#   NHL    — offsides + icing both detected; today they fall back to the ghost
#            penalty as a stub for the future stoppage + faceoff implementation.
enum RuleSet { OFF, ARCADE, NHL }
const DEFAULT_RULE_SET: int = RuleSet.ARCADE
const RULE_SET_NAMES: Array[String] = ["Off", "Arcade", "NHL"]

# Slot depth — distance from goal line to the faceoff-hash "hard slot"
# in front of the net. Real-rink geometry; matches the spot a hockey
# player reads as the prime scoring area. Used by AI role behaviors
# (anchor, carrier, finisher) as the "where the slot is" reference.
const SLOT_DIST_M: float = 5.0

# ── Skater Defaults ───────────────────────────────────────────────────────────
# Defaults shared between the live SkaterController @export and AI scoring /
# state-machine references. Single source of truth so the AI never reasons
# about a different "league average" than the controllers actually run.
#
# TODO(per-player attrs): when SkaterAttributes lands, the AI should query
# `attribute_resolver.call(peer_id).max_speed` (or .stick_length, etc.)
# instead of these defaults. They become "league average" fallbacks only
# used when an attribute isn't resolvable.
const DEFAULT_SKATER_MAX_SPEED_M_S: float = 10.5
const DEFAULT_STICK_LENGTH_M: float = 1.30
const DEFAULT_BLADE_LENGTH_M: float = 0.30

# Wrister/slapper/quick-shot puck release speeds. The puck consumes
# `direction × power` directly as linear velocity (see Puck.release),
# so "power" IS m/s. Min and max bracket the charge curve.
const DEFAULT_WRISTER_POWER_MIN_M_S: float = 14.0
const DEFAULT_WRISTER_POWER_MAX_M_S: float = 24.0
const DEFAULT_SLAPPER_POWER_MIN_M_S: float = 17.0
const DEFAULT_SLAPPER_POWER_MAX_M_S: float = 34.0
# Quick-shot is the no-charge release — also used by AI as the typical
# pass speed (passes are quick-shots in this codebase).
const DEFAULT_QUICK_SHOT_POWER_M_S: float = 14.0

# ── Goalie Defaults ───────────────────────────────────────────────────────────
# Shared between GoalieController @export and AIActionScoring's goalie
# react-then-slide model. Calibrate together — the AI's prediction must
# match the live goalie's reflex.
const DEFAULT_GOALIE_REACTION_DELAY_S: float = 0.13
# Goalie's max committed lateral movement speed. Mirrors GoalieController
# .t_push_speed — the actual translation speed when the goalie commits to
# a slide (lateral_threshold = 0.3 m). NOT tracking_speed (that's the
# mental-target lerp speed, not body movement) and NOT shuffle_speed
# (that's small adjustments, not a recovery slide).
const DEFAULT_GOALIE_T_PUSH_SPEED_M_S: float = 3.8

# ── Players ───────────────────────────────────────────────────────────────────
const MAX_PLAYERS: int = 6  # 3v3
const MAX_SPECTATORS: int = 4
# Sentinel team_id for spectators; players use 0 (home) or 1 (away). The lobby
# slot encoding, assign_player_slot RPC, and GameManager spectator branches all
# compare against this. -1 because it falls cleanly outside the 0..1 player
# team range and is naturally invalid for any team-indexed array.
const SPECTATOR_TEAM_ID: int = -1
# ENet connection cap = playable roster + spectator slots. Player count
# (3v3 roster) is still gated separately by PlayerRules.MAX_PER_TEAM.
const MAX_CONNECTIONS: int = MAX_PLAYERS + MAX_SPECTATORS

# ── Faceoff Positions ─────────────────────────────────────────────────────────
# Indexed by [team_id][team_slot]. Team 0 occupies the +Z half; Team 1 the -Z half.
const CENTER_FACEOFF_POSITIONS: Array = [
	[Vector3( 0.0, 1.0,  1.5), Vector3(-5.0, 1.0,  3.0), Vector3( 5.0, 1.0,  3.0)],  # team 0
	[Vector3( 0.0, 1.0, -1.5), Vector3(-5.0, 1.0, -3.0), Vector3( 5.0, 1.0, -3.0)],  # team 1
]
