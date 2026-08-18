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
# Extra hold on the OPENING faceoff of a match (game start + rematch): camera
# sweep, full-screen matchup rosters, crowd buzz. Longer than the period-start
# hold because the matchup screen lists all six players and needs the read
# time. The normal countdown runs in the final FACEOFF_PREP_DURATION of the
# extended window.
const PREGAME_INTRO_DURATION: float = 8.0
# Extra hold on each PERIOD-START faceoff (same sweep + bench skate-on with
# the "2ND PERIOD" card instead of the matchup rosters — a single line, so the
# original shorter beat).
const PERIOD_INTRO_DURATION: float = 4.0
# Skate-in glide durations (see SkaterController.begin_approach). Players skate
# from a start point to the faceoff dot instead of teleport-snapping. Each stays
# comfortably shorter than its prep window so everyone is set on the dot before
# the drop: a normal faceoff arrives with ~0.75 s of countdown to settle + aim;
# a period-start intro arrives just as the "2 → 1 → DROP" countdown begins, and
# the opening intro's longer matchup hold leaves the skaters set at the dot for
# its back half (the skate happens under the camera sweep + matchup screen).
const FACEOFF_APPROACH_DURATION: float = 1.25
const INTRO_APPROACH_DURATION: float   = 3.6
# Post-goal faceoffs stage the skate-in from this far behind the dot (toward the
# team's own end) instead of the player's scattered goal-moment position. The
# replay-to-live camera cut hides the reposition, so the visible result is a
# short, consistent skate into the dot no matter where the goal happened — the
# long "skate back" is elided into the replay's dead time. See
# PhaseCoordinator._approach_start_for / PlayerRules.faceoff_staging_position.
const FACEOFF_STAGING_SETBACK: float   = 6.0
# Stoppage faceoffs have no replay camera cut to hide a staging snap,
# so players skate in honestly from where play stopped. The prep window is
# extended by FACEOFF_SKATE_PREP_EXTRA (added before the "2 → 1 → DROP"
# countdown) so a far player covers the distance at ~FACEOFF_SKATE_IN_SPEED
# instead of a teleport-fast dash; per-player glide time scales with distance
# and is capped so everyone is set before the drop. Both host (prep timer) and
# client (cosmetic countdown) apply the same fixed extra, derived locally from
# the faceoff kind — no wire change. Icing (nearly the whole rink to cover)
# still skates briskly since the window can't stretch to the full length, but
# it reads as a hard skate rather than a snap.
const FACEOFF_SKATE_IN_SPEED: float    = 9.0   # m/s target skate pace
const FACEOFF_SKATE_PREP_EXTRA: float  = 1.5   # s added to the prep before the countdown
const FACEOFF_SKATE_SETTLE: float      = 0.4   # s a skater should be set before the drop
# Post-goal staged skate-ins all cover the same setback, so a fixed duration made
# everyone move in eerie lockstep. Vary each player's glide time by ±this
# fraction (deterministically, per player + goal count) so they arrive staggered
# at slightly different speeds. Kept small enough that the slowest still lands
# before the drop (base 1.25 s × 1.3 = 1.6 s < the 2 s post-goal prep).
const FACEOFF_STAGGER_FRACTION: float  = 0.3
const FACEOFF_TIMEOUT: float       = 10.0
const PERIOD_DURATION: float       = 4.0 * 60.0   # 240 s per period
const NUM_PERIODS: int             = 3
# Between-period break: END_OF_PERIOD runs the skate-off — every skater glides
# from where play stopped to their bench door (PhaseCoordinator.
# on_period_break_entered, hiding through the door on arrival) under the wide
# period-break camera hold, then the next prep runs the bench intro back onto
# the ice with the period card. Every break is a fixed INTERMISSION_DURATION:
# after the INTERMISSION_SETTLE beat the intermission band + countdown come
# up, with the period's goals looping behind them when there are any (replay
# mode freezes the phase timer; the host's intermission timer ends the break
# via GameStateMachine.finish_period_break) — a scoreless period holds the
# same band over the wide rink and rides the phase timer instead. A unanimous
# skip vote ends either break early. The worst skate-off trip (far corner →
# bench ≈ 44 m at FACEOFF_SKATE_IN_SPEED ≈ 4.9 s) fits well inside the break.
const PERIOD_BREAK_SETTLE: float   = 0.5   # s every skater should be set at the bench before the break ends
# Live beat between the period horn and the intermission band / reel taking
# over: lets the END-OF-PERIOD chyron + skate-off read first, and guarantees
# every client has received the END_OF_PERIOD phase byte (unreliable WS)
# before the reliable replay-mode RPC branches on it.
const INTERMISSION_SETTLE: float   = 2.0
# Total between-period break length (settle beat + band/reel window). The
# on-screen countdown counts the post-settle window down.
const INTERMISSION_DURATION: float = 20.0
const OT_ENABLED: bool             = true
const OT_DURATION: float           = 4.0 * 60.0   # 240 s per OT period

# ── Rink Geometry ─────────────────────────────────────────────────────────────
const GOAL_LINE_Z: float = 26.65  # rink_length / 2 - distance_from_end (30 - 3.35)
const BLUE_LINE_Z: float = 7.29  # 64 ft from goal line to near edge + 0.15m to center
const NET_HALF_WIDTH: float = 0.915      # half of goal opening (post centerline) — must match HockeyGoal post positions
const NET_POST_RADIUS: float = 0.030     # goal-pipe radius — must match HockeyGoal.POST_RADIUS
const NET_DEPTH: float = 1.016           # 40" goal-line-to-back-frame depth (NHL rulebook).
                                         # HockeyGoal.BASE_DEPTH reads this — see
                                         # test_net_geometry_mirrors.
const NET_BACK_HALF_WIDTH: float = 1.02  # half-width at back of net (trapezoid wider end)
const NET_HEIGHT: float = 1.22           # crossbar height (pipe centerline) — must match HockeyGoal.NET_HEIGHT
const NET_CROWN_HALF_WIDTH: float = 0.815  # half-span of the crossbar / top net panel — must match HockeyGoal.CROWN_HALF_WIDTH
# Radius of the post-to-crossbar bend — must match HockeyGoal.MOUTH_CORNER_RADIUS.
# The frame is continuous by construction: the post stands to
# NET_HEIGHT − this, the bend sweeps a quarter circle from there to the crossbar
# end, and NET_CROWN_HALF_WIDTH is NET_HALF_WIDTH − this (which is how HockeyGoal
# derives it). NetGeometry relies on that tiling — a puck leaving one surface
# must be picked up by the next with no seam.
const NET_MOUTH_CORNER_RADIUS: float = 0.10
const NET_TOP_DEPTH: float = 0.559       # depth of the top net panel from the goal line — must match HockeyGoal.TOP_DEPTH
# Coarse padding for the "is this over/near the net" footprint query below. NOT a
# collision surface: the blade and the puck both collide with the real cage
# (NetGeometry), where an invisible 10 cm apron is exactly the lie that made the
# area feel broken. Do not reintroduce it into a collider.
const NET_PUCK_BUFFER: float = 0.10

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
# Top of the opaque board stack (kickplate + white board + cap rail); the
# transparent glass starts here. Single-sourced: HockeyRink.wall_height reads
# this as its export default (don't override it in the scene). Used by the
# HUD's puck-behind-boards check — a camera sightline crossing the boundary
# below this height is blocked by opaque boards; above it, only glass.
const BOARD_TOP_HEIGHT: float = 1.07
# Inner wall boundary — the innermost visible wall surface (kickplate lip).
# This is also the puck's COLLISION surface (HockeyRink builds the perimeter
# collision at the kickplate lip), so physics, blade clamp, AI trajectory
# reflection, and the OOB check all share one boundary.
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

# Distance from an interior point to the inner rink boundary along `dir_xz` (a
# unit world-XZ direction) — how much room the point has before it runs into the
# boards on that heading. Shares the boundary clamp_to_rink_inner projects onto,
# so a reach limited by this result stops exactly where that clamp would have
# caught it.
#
# Exact rather than iterative, which the 120 Hz blade IK needs. The straight
# walls give an axis-aligned box exit; the true boundary in a corner quadrant is
# the arc, which is always nearer than the box corner, so an exit landing there
# is re-solved against that corner's circle. The ray is inside the disc wherever
# it is inside the rink's corner region, so the disc's FAR root is the rink exit
# whether or not the origin itself started inside that disc.
#
# Returns INF for a degenerate direction, and 0.0 for an origin already outside.
static func ray_to_rink_inner(
		origin_xz: Vector2, dir_xz: Vector2, margin: float = 0.0) -> float:
	if dir_xz.length_squared() < 0.000001:
		return INF
	var half_w: float = INNER_HALF_WIDTH - margin
	var half_l: float = INNER_HALF_LENGTH - margin
	var corner_r: float = INNER_CORNER_RADIUS - margin
	var t: float = INF
	if absf(dir_xz.x) > 0.000001:
		var wall_x: float = half_w if dir_xz.x > 0.0 else -half_w
		t = (wall_x - origin_xz.x) / dir_xz.x
	if absf(dir_xz.y) > 0.000001:
		var wall_z: float = half_l if dir_xz.y > 0.0 else -half_l
		t = minf(t, (wall_z - origin_xz.y) / dir_xz.y)
	if is_inf(t):
		return INF
	var hit: Vector2 = origin_xz + dir_xz * t
	if absf(hit.x) > CORNER_CENTER_X and absf(hit.y) > CORNER_CENTER_Z:
		var center := Vector2(
				signf(hit.x) * CORNER_CENTER_X, signf(hit.y) * CORNER_CENTER_Z)
		var m: Vector2 = origin_xz - center
		var b: float = m.dot(dir_xz)
		var c: float = m.length_squared() - corner_r * corner_r
		var disc: float = b * b - c
		if disc > 0.0:
			t = minf(t, -b + sqrt(disc))
	return maxf(t, 0.0)

# True if world_xz sits over a goal-net footprint — within the posts laterally
# (widened to the trapezoid back + puck buffer) and between the goal line and the
# back frame. Used to spot a puck stuck on the net frame.
static func is_over_net_footprint(world_xz: Vector2) -> bool:
	if absf(world_xz.x) > NET_BACK_HALF_WIDTH + NET_PUCK_BUFFER:
		return false
	var az: float = absf(world_xz.y)
	return az >= GOAL_LINE_Z - NET_PUCK_BUFFER and az <= GOAL_LINE_Z + NET_DEPTH + NET_PUCK_BUFFER

# Projects a skater's XZ clear of the goal-net exclusion box — a smooth stand-in
# for the concave net pocket (back + side panels), mirroring what
# clamp_to_rink_inner does for the boards. Returns world_xz unchanged when the center is
# already outside the box. Handles both net ends (|z|). Pure value-type math — no
# allocation, hot-path safe at 120 Hz × actors.
#
# The box spans the net footprint: laterally |x| <= NET_BACK_HALF_WIDTH (the wider
# trapezoid end), in depth |z| in [GOAL_LINE_Z, GOAL_LINE_Z + NET_DEPTH]. The back
# and both side faces inset by `radius` so the body EDGE stops at the panel. The
# FRONT face — the open goal mouth at the goal-line plane — is deliberately NOT
# inset: a skater can still jam with their center right up to the goal line and
# reach into the mouth, so crease / net-front play is untouched; they're only
# stopped from putting their center past the line into the cage. Ejects along the
# least-penetrated face.
static func push_out_of_net(world_xz: Vector2, radius: float = 0.0) -> Vector2:
	var az: float = absf(world_xz.y)
	var min_z: float = GOAL_LINE_Z                       # front (open mouth) — no inset
	var max_z: float = GOAL_LINE_Z + NET_DEPTH + radius  # back panel (body edge stops here)
	if az <= min_z or az >= max_z:
		return world_xz
	var max_x: float = NET_BACK_HALF_WIDTH + radius
	var x: float = world_xz.x
	if absf(x) >= max_x:
		return world_xz
	# Center is inside the exclusion box — eject along the least-penetrated face.
	var pen_front: float = az - min_z    # toward center ice (reduce |z|)
	var pen_back: float = max_z - az     # behind the net (increase |z|)
	var pen_left: float = x + max_x      # toward -x
	var pen_right: float = max_x - x     # toward +x
	var min_pen: float = minf(minf(pen_front, pen_back), minf(pen_left, pen_right))
	var end_sign: float = signf(world_xz.y)
	if min_pen == pen_front:
		return Vector2(x, end_sign * min_z)
	if min_pen == pen_back:
		return Vector2(x, end_sign * max_z)
	if min_pen == pen_left:
		return Vector2(-max_x, world_xz.y)
	return Vector2(max_x, world_xz.y)

# Away-from-net normal scaled by closeness, for a skater at `pos_xz` — the
# net-box analog of BoardPlayRules.board_proximity (same 0 → 1 closeness
# semantics: zero at `probe` away, 1 against the panel). Computed as the
# Euclidean closest point on the net footprint box rather than through
# push_out_of_net's face-eject — the eject picks the least-penetrated face of a
# probe-EXPANDED box, and at a body-length probe that is routinely the un-inset
# open-mouth face even for a skater standing beside the post, which would report
# the net as pushing toward center ice. The closest-point form is exact at the
# corners as a bonus. A point whose closest feature is the front face reports
# ZERO: the mouth is open, so nothing deflects off it — the side and back panels
# are the solid geometry this serves. Handles both net ends (|z|).
static func net_proximity(pos_xz: Vector2, probe: float) -> Vector2:
	if probe <= 0.0:
		return Vector2.ZERO
	var az: float = absf(pos_xz.y)
	var x: float = pos_xz.x
	if az <= GOAL_LINE_Z and absf(x) < NET_BACK_HALF_WIDTH:
		return Vector2.ZERO
	var d := Vector2(
			x - clampf(x, -NET_BACK_HALF_WIDTH, NET_BACK_HALF_WIDTH),
			az - clampf(az, GOAL_LINE_Z, GOAL_LINE_Z + NET_DEPTH))
	var dist: float = d.length()
	# Inside the footprint is degenerate (movement clamps keep body centers out
	# of the cage) — report nothing rather than a garbage direction.
	if dist >= probe or dist < 0.0001:
		return Vector2.ZERO
	var away: Vector2 = d / dist
	away.y *= signf(pos_xz.y)
	return away * ((probe - dist) / probe)

# ── Goalie body containment (analytic skater block) ─────────────────────────
# Base goalie footprint for the analytic skater body-block, like the boards/net.
# Two footprints by stance: a cylinder while standing/RVH, a wide-
# but-shallow oriented box in the butterfly (the leg pads spread laterally).
# These mirror the blade clamp's goalie_block_radius / butterfly_pad_half_* on
# SkaterController — the goalie is beatable-realism furniture here, not a precise
# collision hull. The skater's own collision radius is added on top at the call
# site (Skater.clamp_body_to_goalies) so the body EDGE stops at the goalie
# surface; kept here (not on the actor) so the live tick and the reconcile replay
# read one shared value.
const GOALIE_BLOCK_RADIUS: float = 0.50
const GOALIE_BUTTERFLY_HALF_X: float = 0.84
const GOALIE_BUTTERFLY_HALF_Z: float = 0.25

# Projects a skater's XZ clear of a goalie's body footprint so the skater can't
# walk through the goalie now that skater-vs-goalie is analytic. Mirrors
# push_out_of_net: standing/RVH uses a cylinder of `radius` around the goalie
# center; the butterfly uses an oriented box (half_x × half_z rotated by the
# goalie's yaw) covering the spread leg pads. `radius` / half-extents should
# already include the skater's own collision radius so the body EDGE stops at the
# goalie surface. Returns world_xz unchanged when the center is already clear.
# Pure value-type math — no allocation, hot-path safe at 120 Hz × actors.
static func push_out_of_goalie(world_xz: Vector2, gpos: Vector2, rot_y: float,
		is_butterfly: bool, radius: float, half_x: float, half_z: float) -> Vector2:
	if is_butterfly:
		return _push_out_of_goalie_box(world_xz, gpos, rot_y, half_x, half_z)
	# Standing / RVH — cylinder push-out around the goalie center.
	var to_body: Vector2 = world_xz - gpos
	var dist: float = to_body.length()
	if dist >= radius:
		return world_xz
	var dir: Vector2
	if dist > 0.001:
		dir = to_body / dist
	else:
		# Coincident centers — eject toward center ice (away from the goal line).
		dir = Vector2(0.0, -signf(gpos.y)) if gpos.y != 0.0 else Vector2(0.0, 1.0)
	return gpos + dir * radius

# Oriented-box push-out for the butterfly stance: transform world_xz into the
# goalie's local frame (yaw rot_y), eject along the least-penetrated local axis,
# then rotate the escape back to world. Mirrors the blade clamp's
# _clamp_blade_butterfly_box so the body and blade agree on the pad box.
static func _push_out_of_goalie_box(world_xz: Vector2, gpos: Vector2, rot_y: float,
		half_x: float, half_z: float) -> Vector2:
	var d: Vector2 = world_xz - gpos
	var c: float = cos(rot_y)
	var s: float = sin(rot_y)
	var local_x: float = d.x * c + d.y * s
	var local_z: float = -d.x * s + d.y * c
	if absf(local_x) >= half_x or absf(local_z) >= half_z:
		return world_xz
	# Inside the box — eject along the least-penetrated axis (goalie-local).
	var ox: float = half_x - absf(local_x)
	var oz: float = half_z - absf(local_z)
	var ex: float = local_x
	var ez: float = local_z
	if ox < oz:
		ex = half_x * signf(local_x) if local_x != 0.0 else half_x
	else:
		ez = half_z * signf(local_z) if local_z != 0.0 else half_z
	var world_dx: float = ex * c - ez * s
	var world_dz: float = ex * s + ez * c
	return Vector2(gpos.x + world_dx, gpos.y + world_dz)

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
# Widest |x| a puck's CENTER can cross the goal line at without clipping the
# post: post centerline (NET_HALF_WIDTH) minus the pipe radius minus the puck's
# own radius. Pure physical derivation — any aim beyond this line is a
# guaranteed post ricochet, so shot-aim clamps to it.
const NET_ENTRY_HALF_WIDTH: float = (
		NET_HALF_WIDTH - NET_POST_RADIUS - PUCK_COLLISION_RADIUS)
# Puck-on-ice kinetic friction coefficient (realistic μ ~0.05–0.10). SINGLE SOURCE
# OF TRUTH: the analytic puck step applies it directly (through PUCK_ICE_DECEL_M_S2
# below), and the AI/client-prediction model reads the same constant — host drive and
# model are literally the same number, so they cannot drift. (An earlier hand-synced
# mirror once ran the model at 0.1 against live ice at 0.01 → pucks modelled ~10× too
# draggy. There is no ice .tres.)
const ICE_FRICTION: float = 0.05
# Gravity used for the Coulomb conversion below. Matches Godot's engine default
# (physics/3d/default_gravity = 9.8, un-overridden) rather than textbook 9.81;
# tests/unit/rules/test_physics_constant_mirrors.gd pins the pair.
const GRAVITY_M_S2: float = 9.8
# Puck deceleration on ice — constant Coulomb model. The puck slides flat
# (Puck.tscn locks angular X/Z), so friction force = μ·m·g and a = μ·g ≈ 0.49 m/s²,
# independent of speed and mass. Single source of truth for the host's real glide
# so AI trajectory prediction and client puck extrapolation decelerate exactly as
# the host's drive does — all three read this one derivation from ICE_FRICTION.
const PUCK_ICE_DECEL_M_S2: float = ICE_FRICTION * GRAVITY_M_S2
# Height above the ice at which a puck counts as AIRBORNE — the blade-plane
# gate: a grounded blade only plays pucks below this plane, a lifted blade
# only above it (Puck.is_airborne / PuckReceptionRules.blade_can_interact).
# Single source so the AI's saucer flight model (when a lofted pass is over
# a grounded stick, and where it must land to be receivable) agrees with
# the live interaction gate.
const PUCK_AIRBORNE_HEIGHT_M: float = 0.05
# Board restitution coefficient — sole authority, applied by the analytic carom.
# Tune the rim's liveliness here; nothing else describes the boards.
const PUCK_BOARD_BOUNCE: float = 0.4
# Board kinetic friction coefficient. On a carom the boards bleed tangential speed
# via Coulomb friction proportional to the normal impulse — this is what stops a
# hard rim-around from circling the rink forever (ice friction alone is far too
# weak to kill it). Applied by AITrajectory's carom, which is the host drive and
# the client prediction alike.
const PUCK_BOARD_FRICTION: float = 0.25
# Silent grace before an out-of-play puck is whistled dead. Short enough that
# the stoppage feels responsive, long enough that a transient penetration spike
# (a slapshot buried into the boards for a tick or two before the carom
# pushes it back) never false-flags — the timer resets the moment the puck
# reads inside again.
const PUCK_OOB_GRACE_DURATION: float = 1.0
# XZ distance past the inner (kickplate-lip) boundary before the OOB timer
# runs. The puck COLLIDES at that boundary, so a loose puck's own radius keeps
# its center ≥6 cm inside — a center sustained even 1 cm past the lip means the
# puck escaped into or through the wall (tunnelled at speed, squeezed through
# by a board pin, or over the glass). The previous 0.2 m tolerance plus a
# height branch left a dead zone: a puck trapped INSIDE the 0.3 m wall band at
# ice level tripped neither and soft-locked play, invisible behind the boards.
const PUCK_OOB_XZ_TOLERANCE: float = 0.01

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
# Per-bot builds resolve through AISkaterCaps; these are the league-average
# fallback for an unresolvable peer.
# Base (Speed-2) skater top speed. 9.0 m/s ≈ 20 mph ≈ 32 km/h — a solid NHL
# stride. This is the *cruising* cap; the Sprint burst (sprint_max_speed_multiplier
# on SkaterController) lifts it to ~25 mph, the real elite top speed. Tuned so
# base + sprint both stay anchored to plausible skating speeds rather than
# stacking into superhuman territory.
const DEFAULT_SKATER_MAX_SPEED_M_S: float = 9.0
# Maneuvering acceleration — the skate's thrust (SkaterController.thrust). Mirrors
# that @export so the AI's pursuit/evasion reachable-set model (AIActionScoring
# reach_clearance) uses the same accel the bodies actually have. It's what bounds
# how far a skater can deviate from their momentum line in a short window.
const DEFAULT_SKATER_THRUST_M_S2: float = 10.5
const DEFAULT_STICK_LENGTH_M: float = 1.30
const DEFAULT_BLADE_LENGTH_M: float = 0.30

# Swept-segment hit radius for poke checks (puck-segment vs blade-segment).
# Lives in the domain so AI scoring can derive poke-threat geometry without
# reaching into PuckController. PuckController.POKE_RADIUS is the single
# consumer at the infrastructure side and aliases this value.
const POKE_RADIUS_M: float = 0.5

# Wrister/slapper/quick-shot puck release speeds. The puck consumes
# `direction × power` directly as linear velocity (see Puck.release),
# so "power" IS m/s. Min and max bracket the wrister power model
# (ShotMechanics.wrister_power_t — pure cursor speed, feel-curve shaped, with
# the blade-travel-gated ceiling). The min sits BELOW the quick-shot/pass
# speed on purpose: a slow deliberate sweep is a soft touch pass, softer than
# the fixed snap pass.
# The maxes are the LEAGUE-AVERAGE (Shot L3) anchors, calibrated so the
# _SHOT_POWER_MULTS spread (+/-18%, see PlayerAttributes) puts Shot L5 at an
# elite top-of-the-NHL release:
#   wrister 33 m/s ≈ 74 mph  (L5 ~38.9 ≈ 87 mph, L1 ~27.4 ≈ 61 mph)
#   slapper 40 m/s ≈ 89 mph  (L5 ~47.2 ≈ 106 mph, L1 ~33.2 ≈ 74 mph)
# Reception already gates hard shots (above deflect_min_speed ~22 m/s
# receiver-relative needs a squared blade), so most of the wrister band is
# catch-with-care territory.
# The slapper min is a hurried, barely-wound release — still a heavy shot
# (~45 mph); one-timers always fire at max regardless of charge.
const DEFAULT_WRISTER_POWER_MIN_M_S: float = 10.0
const DEFAULT_WRISTER_POWER_MAX_M_S: float = 33.0
const DEFAULT_SLAPPER_POWER_MIN_M_S: float = 20.0
const DEFAULT_SLAPPER_POWER_MAX_M_S: float = 40.0
# Quick-shot is the no-charge release — also used by AI as the typical
# pass speed (passes are quick-shots in this codebase).
const DEFAULT_QUICK_PASS_POWER_M_S: float = 14.0

# ── Loft (ShotMechanics loft levels — the manual angle ladder) ────────────────
# Design: docs/elevation-rework-plan.md v3. Charged shots use SET LAUNCH
# ANGLES per level, from the blade curve's per-gear ladder
# (PlayerAttributes._CURVE_LOFT_*_DEG); these are the M92 (league-neutral)
# rungs as tan(angle) — the defaults everywhere a build isn't known (AI
# league-average reads, unwired configs). Arrival height is emergent from
# angle × charge × range; missing high is a real outcome.
const DEFAULT_LOFT_TAN_LOW: float = 0.0963   # tan 5.5°  — over the butterfly pad
const DEFAULT_LOFT_TAN_MID: float = 0.1441   # tan 8.2°  — the armpit
const DEFAULT_LOFT_TAN_HIGH: float = 0.1944  # tan 11°   — upstairs
#
# QUICK PASSES keep the fixed vertical-speed table (ShotMechanics.loft_y —
# pass mechanics must not solve toward a net that isn't their target):
#   LOW  2.2  → ~0.26 m apex (saucer pass: clears stick blades, lands, slides)
#   HIGH 4.65 → ~1.10 m apex (the flip pass / chip)
const DEFAULT_LOFT_VY_LOW_M_S: float = 2.2
const DEFAULT_LOFT_VY_HIGH_M_S: float = 4.65

# ── Wrister power-model default (ShotMechanics.wrister_power_t) ──────────────
# Feel tunable — live editor tuning isn't the workflow, but it's an @export on
# SkaterController; this is the shared default so the bot AI stays calibrated to
# the live shot. Wrister power is now the pure mouse-speed model: power is a
# curve over the raw cursor speed (scaled by the player's Shot Power
# Sensitivity), distance-independent. The full-power cursor-speed reference is a
# per-setup export (wrister_mouse_speed_full), not shared here.
# Feel-curve exponent on the 0..1 power parameter. Slightly above linear
# (low-end compressive): the catchable touch-pass window spans a comfortable
# slice of gesture space instead of rounding up toward the middle, and the
# raised 33 m/s ceiling supplies the top-end pop that a sub-1.0 exponent
# used to fake. (< 1.0 inflates the low end — it made soft passes HARDER.)
const DEFAULT_WRISTER_POWER_CURVE: float = 1.1

# ── Goalie Defaults ───────────────────────────────────────────────────────────
# Shared between GoalieController @export and AIActionScoring's goalie
# react-then-slide model. Calibrate together — the AI's prediction must
# match the live goalie's reflex.
const DEFAULT_GOALIE_REACTION_DELAY_S: float = 0.13
# Arms (glove/blocker) read a shot slower than legs — legs drop reflexively on a
# low read, arms need "where in the upper net" placement math first. Mirrors
# GoalieController.arm_reaction_delay. AIActionScoring.open_net_danger gates the
# goalie's glove/blocker REACH (lateral arm extension + over-the-shoulder cover)
# on this, while the lateral SLIDE prediction still uses the leg reaction above.
const DEFAULT_GOALIE_ARM_REACTION_DELAY_S: float = 0.18
# Goalie's max committed lateral movement speed. Mirrors GoalieController
# .t_push_speed — the actual translation speed when the goalie commits to
# a slide (lateral_threshold = 0.3 m). NOT tracking_speed (that's the
# mental-target lerp speed, not body movement) and NOT shuffle_speed
# (that's small adjustments, not a recovery slide).
const DEFAULT_GOALIE_T_PUSH_SPEED_M_S: float = 3.8
# How fast a lateral push ramps toward t_push_speed — pushes accelerate onto
# the edge, they are not instant. Mirrors the Hard/default GoalieController
# .lateral_accel (the tiered GoalieSkillProfile values ease it downward; the
# AI predicts against the top-tier keeper like every other goalie constant
# here). The ramp is the window a hard lateral cut in tight genuinely beats.
const DEFAULT_GOALIE_LATERAL_ACCEL_M_S2: float = 14.0
# The pad-top seam: the height where the goalie's coverage changes hands from
# the leg pads to the torso + arms. Mirrors the stance anatomy in
# GoalieBodyConfigBuilder (torso bottom "glued to the pad-top seam at 0.86" —
# body centre 1.22 minus the 0.72 Goalie.tscn torso box's half-height; keep in
# sync if that anatomy resizes). AIActionScoring's hole model uses it as the
# HIGH band's arrival floor: a lofted shot is only an over-the-pads target if
# its arc physically crosses the net line above this seam.
const DEFAULT_GOALIE_PAD_TOP_SEAM_M: float = 0.86

# ── Players ───────────────────────────────────────────────────────────────────
# Team size is a per-match config latched at puck drop (GameStateMachine.
# team_size, applied via apply_config — the exact rule_set rail). The lobby
# picks it from TEAM_SIZE_OPTIONS; everything sized per-slot uses the CAPACITY
# (PlayerRules.MAX_PER_TEAM = 5) so a live lobby can flip modes without
# re-keying.
const DEFAULT_TEAM_SIZE: int = 3
const TEAM_SIZE_OPTIONS: Array[int] = [3, 5]
const TEAM_SIZE_NAMES: Array[String] = ["3v3", "5v5"]

const MAX_PLAYERS: int = 10  # capacity: 5v5 roster (3v3 uses 6 of these)
const MAX_SPECTATORS: int = 4
# Sentinel team_id for spectators; players use 0 (home) or 1 (away). The lobby
# slot encoding, assign_player_slot RPC, and GameManager spectator branches all
# compare against this. -1 because it falls cleanly outside the 0..1 player
# team range and is naturally invalid for any team-indexed array.
const SPECTATOR_TEAM_ID: int = -1
# Connection cap = playable roster capacity + spectator slots. The live
# roster is gated separately by the latched GameStateMachine.team_size.
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
# Indexed by [team_id][team_slot]. Center on the dot line (slot 0); wingers
# stand ON THE CIRCLE'S EDGE at the hash marks, nearly level with the dot
# (±4.7 wide, 0.9 back — just outside the 4.57 m circle), so opposing wingers
# line up nose-to-nose ~1.8 m apart across the dot, the real alignment.
# Slots 3/4 (LD/RD, 5v5 only) stand behind everyone outside the circle — the
# real alignment puts D behind the hash marks; near an end-zone dot the raw
# offset can land past the goal line, which faceoff_position clamps back in.
# END-ZONE draws override this table for the D pair only (the FACEOFF_END_*
# constants below + PlayerRules.faceoff_position): the one dot-relative shape
# is the real alignment at center/neutral dots, but an end-zone draw's D jobs
# are positional, not dot-relative (plan §10, landed).
const FACEOFF_OFFSETS: Array = [
	[Vector2( 0.0,  1.5), Vector2(-4.7,  0.9), Vector2( 4.7,  0.9),
			Vector2(-2.4,  7.0), Vector2( 2.4,  7.0)],  # team 0
	[Vector2( 0.0, -1.5), Vector2(-4.7, -0.9), Vector2( 4.7, -0.9),
			Vector2(-2.4, -7.0), Vector2( 2.4, -7.0)],  # team 1
]

# ── End-zone draw alignment (5v5; see PlayerRules.faceoff_position) ──────────
# The real positional jobs at an end-zone dot, replacing the dot-relative
# offsets above for the players whose jobs there aren't dot-relative.
# DEFENDING side plays the NHL wall-and-stack: the strong-side D (identity
# side == the dot's side of the ice) holds the WALL — at the boards, level
# with the dot (a hair on-side) — for the boards battle and the rim; the
# weak-side D and the boards-side WINGER form the shoulder-to-shoulder STACK
# on the goal-side arc of the circle (just outside it — the on-side rule) —
# a won draw comes straight back to the stack for the breakout, and on a
# loss the stack D boxes out to the net-front while the stack W releases up
# to the strong point. The net-front itself is the goalie's at the drop —
# the old near-post D spawn double-covered it while leaving the wall empty.
# The inside winger keeps the table's hash-mark spot (the checking matchup).
# ATTACKING side plays the points at the blue line: strong point directly
# above the dot (the boards-side lane + draw-back target), weak point toward
# the middle of the line (the middle-ice valve).
const FACEOFF_END_WALL_INSET_M: float = 1.2       # wall D: in from the boards
const FACEOFF_END_WALL_ONSIDE_M: float = 0.3      # ...level with the dot, a hair on-side
const FACEOFF_END_STACK_BEHIND_M: float = 4.8     # stack: goal-side, outside the 4.57 m circle
const FACEOFF_END_STACK_HALF_SEP_M: float = 0.9   # shoulder-to-shoulder half split
const FACEOFF_END_POINT_INSIDE_M: float = 1.0     # points: inside the blue line
const FACEOFF_END_WEAK_POINT_X_M: float = 1.2     # weak point: past mid, off-dot side
# Depth cap for faceoff placements: no slot spawns closer to the end boards
# than this far in front of the goal line, so a defensive-zone draw's D pair
# (raw offset ~7 m behind an end-zone dot) stands net-side instead of inside
# the netting.
const FACEOFF_MAX_ABS_Z: float = GOAL_LINE_Z - 1.0

# ── Bench-Door Start Points (pre-game intro skate-in) ─────────────────────────
# Where each skater begins the opening/rematch intro before skating out to its
# faceoff slot. Both team benches sit on the +X boards (see arena_stands.gd:
# BENCH_CENTER_Z = 4.4); team 0 (the +Z-half team) takes the +Z bench, team 1
# the -Z bench. Skaters emerge just off the boards and fan out from a small
# per-slot stagger along the bench span. Only used for the center-ice opening
# faceoff — every other faceoff skates in from the player's current position.
# BENCH_DOOR_X is pulled a little in from the inner boards (INNER_HALF_WIDTH
# 12.84) so skaters start on the ice, not clipping the kickplate.
const BENCH_DOOR_X: float          = 11.5
const BENCH_DOOR_CENTER_Z: float   = 4.4   # mirrors arena_stands.gd BENCH_CENTER_Z
# Per-slot fan-out along the bench span (index = team_slot). Center leaves from
# the middle of the bench; wingers from either side, D from the outer edges,
# so the five don't stack (3v3 uses the first three).
const BENCH_DOOR_SLOT_DZ: Array[float] = [0.0, 2.4, -2.4, 4.8, -4.8]

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
