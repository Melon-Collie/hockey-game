class_name AISelfCapabilities
extends RefCounted

# A bot's model of its OWN physical capabilities, built once from the
# attribute-scaled values on its SkaterController (in
# AIController.apply_attributes) and pushed into the agent so the AI plans with
# what its body can actually do — top speed, acceleration, blade reach, shot /
# pass speed — instead of league-default constants.
#
# Scope: SELF only. The AI still models OTHER players (teammates' shots,
# opponents' reach and ETA, the loose-puck-chase election) at league defaults,
# because the snapshot doesn't carry per-skater attributes — that's a separate
# follow-up (opponent modeling). This fixes the bug where a fast/big/high-shot
# bot plans as if it were average.
#
# Built on apply_attributes (spawn + free-play picker changes — rare), never per
# tick, so it adds no hot-path allocation.
#
# Every field defaults to the league baseline, so a null/unset caps (unit tests,
# the perfect-bot path before any attributes apply) reproduces the prior
# behaviour exactly — the consumers seed their values from these defaults.

# Top skating speed (Speed). Drives chase-intercept reach, momentum-aware ETA,
# and the post-engagement blade-reset cooldown scaling.
var max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

# All-direction acceleration / thrust (Agility). The chase reachability test
# asks "can I pull the acceleration needed to land on this intercept?" — that
# ceiling is this value. Default mirrors SkaterController.thrust's 12.0 default.
var max_accel: float = 12.0

# Hand-to-toe blade span = stick + blade (Size, via stick length). The state
# machine derives its reach gates (blade reach, pass-reception offset, poke
# reach) by adding its own ± buffers to this — exactly as the old constants
# did off the league defaults.
var blade_span: float = GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M

# Charged wrister release speed (Shot). Feeds the bot's own shot-quality eval
# (score_shoot) — a high-Shot bot's shot reaches the net faster, leaving
# defenders less reaction time, so it correctly rates more shots as on. Also the
# upper clamp on the bot's distance-adaptive pass launch speed (its hardest
# possible pass) — see AIActionScoring.pass_launch_speed.
var wrister_shot_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S

# Body-check delivery (Size + Physical), used by AIBodyCheck to predict how hard
# a hit this bot would land before committing to it — the victim impulse is
# `approach × (self_weight / victim_weight) × self_body_check_transfer` (see
# Skater._resolve_player_collisions). A high-Size/Physical bot predicts harder
# hits and so commits to checks more readily; a light/low-Physical bot rarely
# clears the "real hit" bar and won't run around whiffing checks. Defaults are
# the league baseline (Skater.weight / body_check_transfer defaults) so an
# unwired caps reproduces an average checker.
var self_weight: float = 1.0
var self_body_check_transfer: float = 0.45
