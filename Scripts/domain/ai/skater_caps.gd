class_name AISkaterCaps
extends RefCounted

# One skater's attribute-scaled physical capabilities, as the bot AI models them.
# Built from the SAME scaled controller/skater values the physics body actually
# uses (SkaterController.build_ai_caps), so the AI plans with what a body can
# really do — top speed, acceleration, blade reach, shot speed, check delivery —
# instead of league-default constants.
#
# Two uses, one class:
#   - SELF: a bot's model of its OWN body, pushed into its state machine via
#     apply_capabilities (AIController.apply_attributes → the RoleContext.self_*
#     mirror). This is the long-standing self path.
#   - PER-PEER: PlayerRegistry memoizes one of these per player in caps_by_peer
#     (rebuilt only on spawn / picker — never per tick), so a bot can model every
#     OTHER player — a teammate receiver's speed, an opponent's reach — with that
#     player's ACTUAL build instead of the league average. Threaded to roles via
#     RoleContext.caps_by_peer.
#
# Every field defaults to the league baseline, so an unset caps (unit tests, the
# perfect-bot path before any attributes apply) reproduces the prior behaviour
# exactly — the consumers seed their values from these defaults.

# Top skating speed (Speed). Drives chase-intercept reach, momentum-aware ETA,
# and the post-engagement blade-reset cooldown scaling.
var max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

# All-direction acceleration / thrust (Agility). The reachable-set tests ask
# "how far off its momentum line can this skater pull a stick?" — that ceiling is
# this value. Default mirrors SkaterController.thrust's 12.0 default.
var max_accel: float = 12.0

# Hand-to-toe blade span = stick + blade (Size, via stick length). The state
# machine derives its reach gates (blade reach, pass-reception offset, poke reach)
# by adding its own ± buffers to this.
var blade_span: float = GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M

# Stick length ALONE (Size). The lane-interception model uses stick reach (not the
# full stick+blade span) for a defender's blade in a pass/shot lane.
var stick_reach: float = GameRules.DEFAULT_STICK_LENGTH_M

# Charged wrister release speed (Shot). Feeds shot-quality eval (score_shoot) — a
# high-Shot player's shot reaches the net faster, leaving defenders less reaction
# time. Also the upper clamp on the player's distance-adaptive pass launch speed
# (its hardest possible pass) — see AIActionScoring.pass_launch_speed.
var wrister_shot_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S

# Body-check delivery (Size + Physical): the attacker impulse coefficient. The
# victim impulse is `approach × (attacker_weight / victim_weight) × transfer` (see
# Skater._resolve_player_collisions) — a high-Size/Physical player predicts harder
# hits and commits to checks more readily.
var weight: float = 1.0
var body_check_transfer: float = 0.45

# Active brace against being put down (Physical). The live collision multiplies a
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
