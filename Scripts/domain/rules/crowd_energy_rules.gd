class_name CrowdEnergyRules

## How loud the building should be right now, from what the crowd can see: how
## good a look the puck is sitting on, who has it, and how long it has been
## camped in one end.
##
## The danger term is XGBaseline — the same public-style expected-goals model the
## post-game screen uses — read at the PUCK's position instead of at a release.
## "How good a chance is this" is the question a crowd answers with its volume,
## so the read is that model rather than a curve shaped to feel right.
##
## Taken in LOG-ODDS, not probability. xG is compressed at the quiet end: a point
## shot and a mid-slot look are 0.09 apart as probabilities and 1.5 apart as
## log-odds. The crowd hears the second scale — the logit is linear in
## ln(distance), so equal steps toward the net are equal steps in noise.
##
## Stateless and engine-free: the caller owns `energy` and `pressure` and hands
## them back each frame.

# The scale's ends, both straight-on shots: silence from the point, full roar
# from the top of the crease. Values are XGBaseline's logit at those distances,
# pinned by test_crowd_energy_rules.gd so a recalibration of the xG model fails
# there instead of quietly rescaling the building.
const QUIET_DISTANCE_M: float = 20.0
const ROAR_DISTANCE_M: float = 3.0
const QUIET_LOGIT: float = -3.5430
const ROAR_LOGIT: float = -0.4127

# What fraction of that look is a live chance, by who has the puck. The xG term
# prices the SPOT; these price whether anyone is in a position to use it. Feel
# values — the grounded half is the danger model.
const WEIGHT_ATTACKING: float = 1.0   # the team shooting at this net has it
const WEIGHT_LOOSE: float = 0.85      # a scramble in tight is the loudest thing in hockey
const WEIGHT_DEFENDING: float = 0.15  # a breakout, not a chance — but one bad pass from one

# Behind the goal line there is no shot at the mouth at all, so the log-odds
# form (which measures distance to the line, blind to which side of it you are
# on) does not apply: a puck a metre behind the net would read as a tap-in. A
# wraparound or a cycle start is real anticipation and well short of a chance,
# and it is its own flat regime rather than a discount on the front-of-net one.
const BEHIND_NET_CHANCE: float = 0.35

# Zone time. A shift spent cycling never produces a slot look, and the building
# still rises through it, so sustained attacking-zone possession is a second
# source of energy — slower to build than a chance and slower to leave.
const PRESSURE_BUILD_TAU_S: float = 6.0
const PRESSURE_FADE_TAU_S: float = 3.0
const PRESSURE_CEILING: float = 0.55  # a long cycle is loud; only a real look is louder

# The crowd's envelope: up on a held breath, down over a settle. Same asymmetry
# (and the same 2.5 s tail) as the whistle swell the ambient bed already rides.
const RISE_TAU_S: float = 0.25
const FALL_TAU_S: float = 2.5


# The team whose shot the crowd is watching for: the one attacking the net the
# puck is nearer. Team 0 attacks -Z, so the -Z half is team 0's to threaten.
static func threatening_team(puck_z: float) -> int:
	return 0 if puck_z < 0.0 else 1


# Danger at the puck's spot, 0..1, discounted by who controls it.
# `carrier_team` is -1 for a loose puck.
static func chance(puck_x: float, puck_z: float, carrier_team: int) -> float:
	var attacker: int = threatening_team(puck_z)
	var weight: float = live_chance_weight(carrier_team, attacker)
	if absf(puck_z) > GameRules.GOAL_LINE_Z:
		return BEHIND_NET_CHANCE * weight
	var logit: float = XGBaseline.logit_for_shot(
			puck_x, puck_z, attacker, ShotEvent.ShotType.SHOT)
	var look: float = clampf(inverse_lerp(QUIET_LOGIT, ROAR_LOGIT, logit), 0.0, 1.0)
	return look * weight


static func live_chance_weight(carrier_team: int, attacking_team: int) -> float:
	if carrier_team < 0:
		return WEIGHT_LOOSE
	return WEIGHT_ATTACKING if carrier_team == attacking_team else WEIGHT_DEFENDING


# Whether the puck is being held in the attacking zone by the team attacking it
# — the zone time the pressure term integrates.
static func is_sustaining_pressure(puck_z: float, carrier_team: int) -> bool:
	return carrier_team == threatening_team(puck_z) \
			and absf(puck_z) > GameRules.BLUE_LINE_Z


static func advance_pressure(pressure: float, sustained: bool, dt: float) -> float:
	if sustained:
		return approach(pressure, 1.0, PRESSURE_BUILD_TAU_S, dt)
	return approach(pressure, 0.0, PRESSURE_FADE_TAU_S, dt)


static func advance_energy(energy: float, target: float, dt: float) -> float:
	var tau: float = RISE_TAU_S if target > energy else FALL_TAU_S
	return approach(energy, target, tau, dt)


# The louder of the two sources. Not a sum: a slot chance during a long cycle is
# one moment the crowd reacts to, not two stacked, and summing would peg the bed
# at full for any sustained shift.
static func target_energy(chance_now: float, pressure: float) -> float:
	return clampf(maxf(chance_now, PRESSURE_CEILING * pressure), 0.0, 1.0)


# Frame-rate-independent exponential approach: `tau_s` is the time to close
# 63% of the remaining gap, whatever the frame length. A plain lerp by a
# constant would make the crowd's timing a function of the viewer's fps.
static func approach(current: float, target: float, tau_s: float, dt: float) -> float:
	return lerpf(current, target, 1.0 - exp(-dt / maxf(tau_s, 0.0001)))
