class_name GameRules

# Pure game-rule constants. No engine concerns here — collision layers, masks,
# and physics tick rate live in Constants.gd (engine-facing autoload).
#
# This is a class_name const class, not an autoload — no registration needed.
# Access anywhere as `GameRules.BLUE_LINE_Z`.

# ── Game Flow Timings ─────────────────────────────────────────────────────────
const GOAL_PAUSE_DURATION: float        = 2.0  # fallback for GOAL_SCORED auto-advance if replay never starts
const GOAL_CELEBRATION_DURATION: float  = 1.5  # post-goal beat: movement allowed, puck pickup-locked,
												# banner + VFX play; auto-advances to GOAL_SCORED (replay)
const FACEOFF_PREP_DURATION: float = 2.0   # visible "2 → 1 → DROP!" countdown before puck unlocks
# Extra hold on the OPENING faceoff of a match (game start + rematch) so the
# pre-game intro can play: camera sweep, matchup card, crowd buzz. The normal
# countdown runs in the final FACEOFF_PREP_DURATION of the extended window.
const PREGAME_INTRO_DURATION: float = 4.0
const FACEOFF_TIMEOUT: float       = 10.0
const PERIOD_DURATION: float       = 4.0 * 60.0   # 240 s per period
const NUM_PERIODS: int             = 3
const END_OF_PERIOD_PAUSE: float   = 3.0           # pause before next-period faceoff prep
const OT_ENABLED: bool             = true
const OT_DURATION: float           = 4.0 * 60.0   # 240 s per OT period

# ── Rink Geometry ─────────────────────────────────────────────────────────────
const GOAL_LINE_Z: float = 26.65  # rink_length / 2 - distance_from_end (30 - 3.35)
const BLUE_LINE_Z: float = 7.29  # 64 ft from goal line to near edge + 0.15m to center
const NET_HALF_WIDTH: float = 0.915      # half of goal opening (post centerline) — must match HockeyGoal post positions
const NET_POST_RADIUS: float = 0.030     # goal-pipe radius — must match HockeyGoal.POST_RADIUS
const NET_DEPTH: float = 1.02            # goal depth from goal line to back frame
const NET_BACK_HALF_WIDTH: float = 1.02  # half-width at back of net (trapezoid wider end)
const NET_HEIGHT: float = 1.22           # crossbar height (pipe centerline) — must match HockeyGoal.NET_HEIGHT
const NET_PUCK_BUFFER: float = 0.10      # exclusion zone expansion beyond the physical net boundary

# Half the skater's body so the blue line keys off the body EDGE, not its
# centre — matching real hockey. You tag up the instant any part of your body
# reaches the line (centre still a body-width inside the zone), and you're only
# ruled offside once your whole body is over it. Shared by is_offside (entry) and
# has_tagged_up (clear) so the strict-< / ≥ split keeps a dead-band and the ghost
# never oscillates at the boundary. Tracks the medium collision-cylinder radius
# (Skater.tscn) — the canonical body half-width.
const OFFSIDE_LINE_SLACK: float = 0.35

# Rink dimensions (must match HockeyRink export values in the scene)
const RINK_HALF_WIDTH: float     = 13.0   # half of 26 m
const RINK_HALF_LENGTH: float    = 30.0   # half of 60 m
const CORNER_RADIUS: float       = 8.53  # 28 ft
const WALL_THICKNESS: float      = 0.3
# Must match HockeyRink.KICKPLATE_PROTRUSION — the kickplate's inward lip
# sticks 1 cm inside the boards' inner face, so the visible wall surface at
# ice level (and stick-blade level after a board-level dump) is 1 cm closer
# to rink center than the boards' face. The blade-clamp uses this innermost
# surface so the blade can't poke past the visible kickplate.
const KICKPLATE_INWARD_LIP: float = 0.01
# Inner wall boundary — the innermost visible wall surface (kickplate lip).
const INNER_HALF_WIDTH: float    = RINK_HALF_WIDTH  - WALL_THICKNESS * 0.5 - KICKPLATE_INWARD_LIP  # 12.84
const INNER_HALF_LENGTH: float   = RINK_HALF_LENGTH - WALL_THICKNESS * 0.5 - KICKPLATE_INWARD_LIP  # 29.84
const INNER_CORNER_RADIUS: float = CORNER_RADIUS    - WALL_THICKNESS * 0.5 - KICKPLATE_INWARD_LIP  # 8.37
const CORNER_CENTER_X: float     = INNER_HALF_WIDTH  - INNER_CORNER_RADIUS  # 4.47
const CORNER_CENTER_Z: float     = INNER_HALF_LENGTH - INNER_CORNER_RADIUS  # 21.47

# Returns world_xz projected onto the inner rink boundary (rounded rectangle).
# If the point is already inside, returns it unchanged.
#
# `margin` insets the boundary uniformly — pass a body's collision radius to keep
# its CENTER that far from the boards, so the body's edge (not its center) stops
# at the surface. The corner CENTERS are invariant under the inset (half-width
# and corner-radius shrink by the same margin), so the straight/corner split is
# unchanged. Default 0.0 leaves point callers (puck-OOB, blade clamp, trajectory)
# exactly as before.
static func clamp_to_rink_inner(world_xz: Vector2, margin: float = 0.0) -> Vector2:
	var half_w: float = INNER_HALF_WIDTH - margin
	var half_l: float = INNER_HALF_LENGTH - margin
	var corner_r: float = INNER_CORNER_RADIUS - margin
	var ax: float = absf(world_xz.x)
	var az: float = absf(world_xz.y)
	if ax > CORNER_CENTER_X and az > CORNER_CENTER_Z:
		# Corner quadrant — clamp to the rounded arc
		var dx: float = ax - CORNER_CENTER_X
		var dz: float = az - CORNER_CENTER_Z
		var dist: float = sqrt(dx * dx + dz * dz)
		if dist > corner_r:
			var scale: float = corner_r / dist
			return Vector2(
				sign(world_xz.x) * (CORNER_CENTER_X + dx * scale),
				sign(world_xz.y) * (CORNER_CENTER_Z + dz * scale)
			)
	else:
		if ax > half_w:
			return Vector2(sign(world_xz.x) * half_w, world_xz.y)
		if az > half_l:
			return Vector2(world_xz.x, sign(world_xz.y) * half_l)
	return world_xz

# True if world_xz sits over a goal-net footprint — within the posts laterally
# (widened to the trapezoid back + puck buffer) and between the goal line and the
# back frame. Used to spot a puck stuck on the net frame.
static func is_over_net_footprint(world_xz: Vector2) -> bool:
	if absf(world_xz.x) > NET_BACK_HALF_WIDTH + NET_PUCK_BUFFER:
		return false
	var az: float = absf(world_xz.y)
	return az >= GOAL_LINE_Z - NET_PUCK_BUFFER and az <= GOAL_LINE_Z + NET_DEPTH + NET_PUCK_BUFFER

# ── Puck ──────────────────────────────────────────────────────────────────────
# Rest height = puck collision half-height (Puck.tscn cylinder height / 2 = 0.035/2),
# so the disc sits with its bottom face on the ice plane (y=0). Keep in sync with
# Puck.gd `ice_height` and the Puck.tscn mesh/shape height.
const PUCK_START_POS: Vector3 = Vector3(0, 0.0175, 0)
# Puck collision cylinder extents (Puck.tscn CylinderShape3D: radius 0.065,
# height 0.035). The puck is angular-locked flat (axis_lock_angular_x/z), so its
# horizontal reach is the radius and its vertical reach the half-height — the two
# differ and GoalDetectionRules needs both to size the goal mouth to the whole
# disc. Keep in sync with Puck.tscn.
const PUCK_COLLISION_RADIUS: float = 0.065
const PUCK_COLLISION_HALF_HEIGHT: float = 0.0175
# Puck-on-ice kinetic friction coefficient (realistic μ ~0.05–0.10). SINGLE
# SOURCE OF TRUTH: HockeyRink._add_ice() builds the live ice PhysicsMaterial
# directly from this constant, and the AI/client-prediction model below reads it
# too — so the sim and the model can't drift. (This replaces the old hand-synced
# mirror that once ran the model at 0.1 while the live ice was 0.01 → pucks
# modelled ~10× too draggy. There is no ice .tres.)
#
# Why the puck feels EXACTLY the surface friction (not a blend with its own):
# Godot's PhysicsMaterial combine (per godot-proposals #11715, documenting current
# behavior) keys off the `rough` flag — when both bodies are smooth (rough=false)
# it takes the MINIMUM of the two frictions. The puck has no material → engine
# default friction 1.0 (rough=false); every surface here is < 1.0 and smooth, so
# min(1.0, surface) = the surface value. Hence ICE_FRICTION (and boards' 0.3) is
# the effective μ the puck actually experiences. Holds while the puck's friction
# stays ≥ every surface's.
const ICE_FRICTION: float = 0.05
# Gravity used for the Coulomb conversion below. Matches Godot's engine default
# (physics/3d/default_gravity = 9.8, un-overridden) rather than textbook 9.81, so
# the modelled decel equals what Jolt's contact solver actually applies.
const GRAVITY_M_S2: float = 9.8
# Puck deceleration on ice — constant Coulomb model. The puck slides flat
# (Puck.tscn locks angular X/Z), so friction force = μ·m·g and a = μ·g ≈ 0.49 m/s²,
# independent of speed and mass. Single source of truth for the host's real glide
# so AI trajectory prediction and client puck extrapolation decelerate the same
# way Jolt does — derived from ICE_FRICTION, which the live ice is also built from.
const PUCK_ICE_DECEL_M_S2: float = ICE_FRICTION * GRAVITY_M_S2
# Board restitution coefficient. Mirrors Physics/boards.tres `bounce` so AI
# prediction models post-bounce trajectories the way Jolt resolves them. Unlike
# ICE_FRICTION this can't be single-sourced — boards.tres is a static resource a
# const can't reach — so tests/unit/rules/test_physics_material_mirrors.gd guards
# the pair: change one, CI fails until the other matches. (Restitution is safe
# whatever the combine does: Godot's non-absorbent bounce combine ADDS the two,
# and the puck's side is 0, so 0 + 0.4 = 0.4 regardless.)
const PUCK_BOARD_BOUNCE: float = 0.4
# Silent grace before an out-of-play puck is whistled dead. Short enough that
# the stoppage feels responsive, long enough that pucks bouncing back in off
# the boards don't get false-flagged.
const PUCK_OOB_GRACE_DURATION: float = 1.0
# Defense-in-depth height term for the OOB check: a puck this far above the ice
# while at/beyond the rink boundary has gone over the glass or perched on the
# boards — the flat XZ check tolerates 0.2 m and would miss it, soft-locking play.
# Above the boards (~1.07 m) but below any legitimate in-rink deflection apex
# (those are INSIDE, so their XZ distance-to-boundary is ~0 and they don't trip
# this). The raised perimeter collision should prevent the escape outright; this
# is the backstop if a puck gets outside some other way.
const PUCK_OVER_BOARDS_HEIGHT: float = 1.2

# Puck-stuck-on-net detection. A puck that settles motionless on the net frame
# never touches the ice, so the normal on-ice/airborne logic leaves it
# unplayable forever. We catch it: stationary (< NET_STUCK_MAX_SPEED) and
# airborne over a net footprint for NET_STUCK_GRACE_DURATION. Resolution splits
# on height — if it's only sitting on the low back/skirt frame (within
# NET_STUCK_PLAYABLE_HEIGHT of the ice) it's realistically playable, so we drop
# it straight to the ice; if it's perched up on the crossbar/crown it's genuinely
# unplayable and gets whistled dead like an out-of-play puck.
const NET_STUCK_GRACE_DURATION: float = 1.0
const NET_STUCK_MAX_SPEED: float = 0.6       # m/s — below this the puck counts as settled
const NET_STUCK_PLAYABLE_HEIGHT: float = 0.30  # m above ice; at/under → drop to ice, over → whistle

# ── Infractions ───────────────────────────────────────────────────────────────
const ICING_GHOST_DURATION: float = 3.0  # seconds team stays ghosted after icing (ARCADE/legacy path)
# Crease protection — ARCADE-only anti-camp mechanic, not a real NHL rule. A
# field skater (carrier exempt — see compute_ghost_state) who lingers in a
# goalie crease this long is ghosted (loses puck/body interaction) until they
# leave the paint. Dwell-timed, not instant: aggressive net drives,
# wraparounds, and jam plays pass through untouched — only parking in the blue
# paint is punished. Active in ARCADE only (not OFF, not NHL — real
# goaltender interference is contact-based and screening is legal, so this
# has no NHL equivalent until a real contact-based system exists). Reuses the
# offside ghost mechanism; the crease itself is the "blue line" you tag up at
# (un-ghosts on exit).
const CREASE_DWELL_DURATION: float = 0.6  # seconds in the crease before ghosting
# End-zone faceoff dot offsets from centre ice — NHL spec. The rink renderer
# (hockey_rink.gd) paints the dots at the same positions, so puck reset and
# player teleport land on the painted dot. Z is 20' (6.096m) inside the goal
# line; X is 22' (6.7056m) from the centre line. The icing race re-uses the Z
# value as the dot players sprint toward in hybrid icing.
const END_ZONE_FACEOFF_DOT_X: float = 6.7056
const ICING_FACEOFF_DOT_Z: float = GOAL_LINE_Z - 6.096   # 20.554
# Neutral-zone faceoff dots — NHL spec. Painted 5' (1.524m) from each blue
# line on the neutral-zone side. Used as the faceoff spot when an offside is
# called and as candidates when the puck goes out of play in the neutral zone.
const NEUTRAL_ZONE_FACEOFF_DOT_Z: float = BLUE_LINE_Z - 1.524   # 5.766

# Rule preset that gates which infractions are detected and how they're punished.
#   OFF    — no offsides, no icing, no crease protection (free-for-all).
#   ARCADE — offsides ghost the offending player; icing is ignored; crease
#            camping (anti-cheese, not a real rule) ghosts after a dwell timer.
#   NHL    — full stoppage rules: icing blows the whistle after the hybrid race,
#            offsides run delayed (no ghost) and whistle on offending-team touch.
#            No crease protection — see CREASE_DWELL_DURATION for why.
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
# Base (Speed-2) skater top speed. 9.0 m/s ≈ 20 mph ≈ 32 km/h — a solid NHL
# stride. This is the *cruising* cap; the Sprint burst (sprint_max_speed_multiplier
# on SkaterController) lifts it to ~25 mph, the real elite top speed. Tuned so
# base + sprint both stay anchored to plausible skating speeds rather than
# stacking into superhuman territory.
const DEFAULT_SKATER_MAX_SPEED_M_S: float = 9.0
const DEFAULT_STICK_LENGTH_M: float = 1.30
const DEFAULT_BLADE_LENGTH_M: float = 0.30

# Swept-segment hit radius for poke checks (puck-segment vs blade-segment).
# Lives in the domain so AI scoring can derive poke-threat geometry without
# reaching into PuckController. PuckController.POKE_RADIUS is the single
# consumer at the infrastructure side and aliases this value.
const POKE_RADIUS_M: float = 0.5

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
# Spawn height for skaters at a faceoff. The dot itself sits on the ice (Y=0);
# this is added at teleport time so dots and per-team offsets stay 2D.
const FACEOFF_SPAWN_HEIGHT: float = 1.0

# 2D dot positions (XZ). Center ice plus four end-zone dots — one to each side
# of each goal, reusing the existing icing-race Z so the dots line up with the
# hybrid-icing geometry.
const CENTER_ICE_DOT: Vector2 = Vector2.ZERO
const END_ZONE_FACEOFF_DOTS: Array[Vector2] = [
	Vector2(-END_ZONE_FACEOFF_DOT_X,  ICING_FACEOFF_DOT_Z),  # team 0 defensive zone, left
	Vector2( END_ZONE_FACEOFF_DOT_X,  ICING_FACEOFF_DOT_Z),  # team 0 defensive zone, right
	Vector2(-END_ZONE_FACEOFF_DOT_X, -ICING_FACEOFF_DOT_Z),  # team 1 defensive zone, left
	Vector2( END_ZONE_FACEOFF_DOT_X, -ICING_FACEOFF_DOT_Z),  # team 1 defensive zone, right
]
# Neutral-zone dots — 5' from each blue line on the neutral-zone side. Index
# pairing: first two flank the +Z blue line (team 1's attacking blue line),
# last two flank the -Z blue line (team 0's attacking blue line).
const NEUTRAL_ZONE_FACEOFF_DOTS: Array[Vector2] = [
	Vector2(-END_ZONE_FACEOFF_DOT_X,  NEUTRAL_ZONE_FACEOFF_DOT_Z),
	Vector2( END_ZONE_FACEOFF_DOT_X,  NEUTRAL_ZONE_FACEOFF_DOT_Z),
	Vector2(-END_ZONE_FACEOFF_DOT_X, -NEUTRAL_ZONE_FACEOFF_DOT_Z),
	Vector2( END_ZONE_FACEOFF_DOT_X, -NEUTRAL_ZONE_FACEOFF_DOT_Z),
]

# Per-team, per-slot XZ offsets from whichever dot is active. Team 0 stands on
# the +Z side of the dot, team 1 on -Z (preserves team 0 = +Z half convention).
# Indexed by [team_id][team_slot].
const FACEOFF_OFFSETS: Array = [
	[Vector2( 0.0,  1.5), Vector2(-5.0,  3.0), Vector2( 5.0,  3.0)],  # team 0
	[Vector2( 0.0, -1.5), Vector2(-5.0, -3.0), Vector2( 5.0, -3.0)],  # team 1
]

# Returns the faceoff dot closest to the given XZ point — picks among centre
# ice, the four end-zone dots, and the four neutral-zone dots. Used to pick
# the spot where an out-of-play puck reconvenes.
static func nearest_faceoff_dot(world_xz: Vector2) -> Vector2:
	var best: Vector2 = CENTER_ICE_DOT
	var best_d2: float = world_xz.distance_squared_to(CENTER_ICE_DOT)
	for dot: Vector2 in END_ZONE_FACEOFF_DOTS:
		var d2: float = world_xz.distance_squared_to(dot)
		if d2 < best_d2:
			best_d2 = d2
			best = dot
	for dot: Vector2 in NEUTRAL_ZONE_FACEOFF_DOTS:
		var d2: float = world_xz.distance_squared_to(dot)
		if d2 < best_d2:
			best_d2 = d2
			best = dot
	return best

# NHL icing faceoff dot: in the offending team's defensive zone, on the side
# closest to where the puck was last touched by the offending team. Team 0
# defends +Z; team 1 defends -Z. Centerline release defaults to the +X side.
static func icing_faceoff_dot(offender_team_id: int, last_carrier_x: float) -> Vector2:
	var z: float = ICING_FACEOFF_DOT_Z if offender_team_id == 0 else -ICING_FACEOFF_DOT_Z
	var x: float = END_ZONE_FACEOFF_DOT_X if last_carrier_x >= 0.0 else -END_ZONE_FACEOFF_DOT_X
	return Vector2(x, z)

# NHL offside faceoff dot: the neutral-zone dot flanking the blue line the
# offending team crossed, on the side the puck entered. Team 0 attacks -Z
# (crosses the -Z blue line); team 1 attacks +Z.
static func offside_faceoff_dot(offender_team_id: int, puck_x: float) -> Vector2:
	var z: float = -NEUTRAL_ZONE_FACEOFF_DOT_Z if offender_team_id == 0 else NEUTRAL_ZONE_FACEOFF_DOT_Z
	var x: float = END_ZONE_FACEOFF_DOT_X if puck_x >= 0.0 else -END_ZONE_FACEOFF_DOT_X
	return Vector2(x, z)
