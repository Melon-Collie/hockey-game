class_name AISkaterCaps
extends RefCounted

# One skater's attribute-scaled physical capabilities, as the bot AI models them.
# Built from the SAME scaled controller/skater values the physics body actually
# uses (SkaterController.build_ai_caps), so the AI plans with what a body can
# really do instead of league-default constants.
#
# Two uses, one class:
#   - SELF: a bot's model of its OWN body, pushed into its state machine via
#     apply_capabilities (AIController.apply_attributes → the RoleContext.self_*
#     mirror).
#   - PER-PEER: PlayerRegistry memoizes one of these per player in caps_by_peer
#     (rebuilt only on spawn / picker — never per tick), so a bot can model every
#     OTHER player — a teammate receiver's speed, an opponent's reach — with that
#     player's ACTUAL build. Threaded to roles via RoleContext.caps_by_peer.
#
# Every field defaults to the league baseline, so an unset caps (unit tests, the
# perfect-bot path before any attributes apply) plans like a league-average
# body — the consumers seed their values from these defaults.

# Top skating speed (height-derived, leaned by the skate profile). Drives
# chase-intercept reach, momentum-aware ETA,
# and the post-engagement blade-reset cooldown scaling.
var max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

# Sprint ceiling multiplier over max_speed (Speed — the attribute's HEADLINE
# lever: cruise is near-uniform by design, separation lives in this gear).
# Race-class reads (loose-puck election, race-lost, retrieval margins) fold it
# in via BotSprintRules.race_speed, stamina-gated per peer, so a race is priced
# at the pace the body will actually skate it. LEAGUE_* is the controller's
# league export default — also the capless fallback, so an unset caps races like
# a league body (which sprints).
const LEAGUE_SPRINT_SPEED_MULT: float = 1.14
var sprint_speed_mult: float = LEAGUE_SPRINT_SPEED_MULT

# All-direction acceleration / thrust (Acceleration). The reachable-set tests ask
# "how far off its momentum line can this skater pull a stick?" — that ceiling is
# this value. Default mirrors SkaterController.thrust's league default.
var max_accel: float = GameRules.DEFAULT_SKATER_THRUST_M_S2

# Hand-to-toe blade span = stick + blade (Size, via stick length). The state
# machine derives its reach gates (blade reach, pass-reception offset, poke reach)
# by adding its own ± buffers to this.
var blade_span: float = GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M

# Stick length ALONE (height + the stick-length gear slot). The lane-interception
# model uses stick reach (not the
# full stick+blade span) for a defender's blade in a pass/shot lane.
var stick_reach: float = GameRules.DEFAULT_STICK_LENGTH_M

# Maximum distance from the body origin to a legal blade-contact point — the
# fully-extended arm + stick + blade span (arm ROM displacement + stick + blade).
# NOT a bot-planning input: the host uses it as the structural anti-cheat ceiling
# for client-authoritative blade claims (pickup / poke / stick-lift). A claim
# carries the client's own blade geometry (its "aim"), and the host pins that
# geometry to within this reach of the SERVER-authoritative body so a modified
# client can't teleport its blade onto a distant puck. A real measurement built
# from the same scaled geometry the body uses (SkaterController.build_ai_caps),
# not a tuned margin. Default = league stick + blade + baseline backhand ROM reach.
var max_blade_reach: float = GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M + 0.46

# Charged wrister release speed (height-derived, leaned by stick flex and blade
# curve). Feeds shot-quality eval (score_shoot) — a hard-shooting player's shot
# reaches the net faster, leaving defenders less reaction time. Also the upper
# clamp on the player's distance-adaptive pass launch speed (its hardest possible
# pass) — see AIActionScoring.pass_launch_speed.
var wrister_shot_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S

# How fast the blade traverses its ROM to chase the aim cursor (Hands, =
# SkaterController.max_blade_speed). This is the REAL rotation/aim speed the body
# is clamped to, so a bot slews its synthesized aim cursor at exactly this rate —
# its aiming looks as fast as its hands actually are, no artificial per-difficulty
# override. Default mirrors the controller's 10.0.
var blade_speed: float = 10.0

# The blade curve's angle ladder as tan per elevated loft level
# (x = LOW, y = MID, z = HIGH — SkaterController.loft_tan_low/mid/high). The
# HIGH-hole rung-picker reads it so a bot prices (and fires) the rungs its
# own blade actually has. Default = the M92 league-neutral ladder.
var loft_tans: Vector3 = Vector3(
		GameRules.DEFAULT_LOFT_TAN_LOW,
		GameRules.DEFAULT_LOFT_TAN_MID,
		GameRules.DEFAULT_LOFT_TAN_HIGH)

# Lateral grip multiplier (= SkaterController.lateral_grip — agility × the
# skate-profile lean). Scales the PERPENDICULAR thrust authority in the real
# movement core, so planning reads it wherever it models a direction change:
# the cross-momentum shed in time_to_arrive / reach_clearance, and the deke's
# bite/unwind budgets. Straight-line phases (ramp, race-home) stay pure accel
# — grip never limits parallel drive, in planning or in physics.
var lateral_grip: float = 1.0

# Reception ceiling lean (= Skater.reception_ceiling_mult, from the blade
# curve): scales the deflect ceiling + squared bonus this receiver's blade can
# soak. Carried per-peer so pass pricing CAN read a teammate's real catchable
# ceiling; the pass-speed solver still prices the league constant today
# (conservative — see the GitHub issue on pricing reception per receiver).
var reception_ceiling_mult: float = 1.0

# Backhand power coefficient (= SkaterController.backhand_power_coefficient — a
# flat mechanic: backhand technique is the human, leaned only by the blade-curve
# gear). The release-offset sampler prices a backhand-side release at this
# fraction of the wrister pace. Default mirrors the controller's 0.75.
var backhand_power_coefficient: float = 0.75

# Body-check delivery: the attacker impulse coefficient. The victim impulse is
# `approach × (attacker_weight / victim_weight) × transfer` (see
# Skater._resolve_player_collisions), so delivery is mass-emergent — a heavier
# player predicts harder hits and commits to checks more readily.
var weight: float = 1.0
var body_check_transfer: float = 0.45

# Active brace against being put down. The live collision multiplies a
# braced victim's absorbed transfer by this; the AI reads it to model how hard a
# specific OPPONENT is to knock off the puck.
var body_check_brace: float = 0.4

# How far the carrier holds/protects the puck off its body while HANDLING it —
# the reach that sets how tight an evasion seam it can thread (best_evade_point).
# Scaled by Hands via the real dangle lever (max_blade_speed): a faster blade
# moves the puck further within the evasion window. (This is puck HANDLING, not
# pass reception — reception has no Hands term in the physics.) Default is the
# league carry-handle reach (AIActionScoring.EVADE_CARRY_HANDLE_M).
var handle_reach: float = 0.9

# Half-angle of the blade's reach cone: how far off its FACING the body can
# place the blade WITHOUT turning — arm ROM plus torso twist
# (SkaterController.rom_backhand_angle_max_deg + upper_body_max_twist_deg, the
# exact gate SkaterPoseCoordinator.apply_facing enforces on the IK). A bot can
# fire a shot/pass anywhere inside this cone from its current facing, so only aims
# BEYOND it (the narrow back wedge) cost a body rotation. Fixed equipment/anatomy
# geometry — not attribute-scaled — but read from the real exports so the bot's
# model tracks the body's actual reach. Default = deg_to_rad(90 + 67) = ~157°.
var reach_cone_half_angle: float = deg_to_rad(157.0)

# Effective body-facing turn rate (rad/s) used to price the rotation an out-of-cone
# aim costs. The real facing is an exponential lerp at facing_drag_speed (Agility-
# scaled); this is a constant-rate approximation of it whose BASELINE is the
# long-standing 6.0 rad/s and whose per-bot value scales with the skater's real
# Agility (a nimbler bot prices a back-wedge turn cheaper). Default = the baseline.
var facing_turn_rate: float = 6.0
