extends GutTest
# ⚠️ NUMBERS BELOW WERE MEASURED WITH THE PLANNER WORK APPLIED, WHICH THIS
# BRANCH NO LONGER CARRIES. The stick/anatomy/arrival-height changes to
# AIActionScoring were split out to `claude/goalie-planner-calibration` because
# they broke 48 bot-side tests that cannot be re-pinned until the model settles.
# Re-run this instrument here and it will report the PRE-fix surface. The
# recorded findings stay because they are what the fix has to reproduce.
#

# ── score_shoot vs the live goalie, by BEARING ───────────────────────────────
# The companion to test_slot_shot_value_truth (which sweeps RANGE). Distance to
# goal is held constant and only the bearing varies, so angle is the single
# independent variable. That separation is what this instrument is for: the
# range sweep alone cannot tell a range defect from an angle defect, and the
# residuals turned out to be BOTH.
#
# ── WHAT IT FOUND (2026-07) ──────────────────────────────────────────────────
#  r   bearing  model  measured  delta | outcome
#  5.0    0 deg   1.00    0.19    +0.81 | STICK x12  <- aimed top corner, arrives LOW
#  5.0   15 deg   1.00    0.19    +0.81 | PAD x13
#  5.0   30 deg   0.65    0.00    +0.65 | PAD x16
#  5.0   45 deg   1.00    1.00    +0.00 | 16 goals
#  5.0   60 deg   1.00    0.94    +0.06 | 15 goals
#  7.0    0 deg   0.99    0.62    +0.36 | STICK x6
#  7.0   15 deg   1.00    1.00    +0.00 | 16 goals
#  7.0   30 deg   0.35    0.69    -0.33 | model UNDER-rates
#  7.0   45 deg   1.00    0.00    +1.00 | GLOVE x9 + 7 POSTS — aim misses the net
#  7.0   60 deg   0.00    1.00    -1.00 | no hole found; the FALLBACK scores 16/16
#
# The error is NOT one curve. It swings +0.81 head-on, through zero at 45 deg,
# to -1.00 at 60 deg, and the two ranges disagree about where. At least two
# distinct defects live in here:
#
#   1. ARRIVAL HEIGHT. The 5 m head-on cells are scored as top-corner looks but
#      the save part is STICK/PAD. The HIGH pace is solved so the arc clears the
#      0.86 m pad-top seam AT THE GOAL LINE, while the save happens at the
#      keeper's plane — where a still-rising arc is lower. Kinematics for the
#      5 m cell: ~0.88 m at the line but ~0.64 m at a keeper 1.68 m out, i.e.
#      pad height. The band a shot is CONTESTED in should follow its height
#      where it meets him, not the hole it was aimed at.
#
#      NOTE a naive fix fails: re-solving the pace against the goalie gap makes
#      the shot slow enough that his glove deploys, and the model then kills the
#      HIGH band everywhere — including the 45/60 deg cells that genuinely score
#      24/24. Measured and reverted; see the branch history. The fix has to
#      change which band CONTESTS the shot without slowing the shot down.
#
#   2. SHARP-ANGLE BLINDNESS. At 7 m / 60 deg the model finds no hole at all and
#      falls back to a dead-centre flat shot — which then scores 16/16. A keeper
#      challenging a sharp angle cannot cover both posts, and the far side is
#      open; the disc-tangent cover does not see that. Same signature at
#      7 m / 30 deg (-0.33).
#
# ── METHODOLOGY CORRECTION (2026-07, and it changed the answer) ───────────────
# The runs above scored through score_shoot's DEFAULTS — no post seal, no
# replicated pose, no measured five-hole. Gameplay does not: carrier.gd builds
# _shot_env_* off the live GoalieNetworkState and feeds all of it. So the first
# measurements compared a degraded model against the full live keeper, i.e. they
# measured a code path the bots never execute. Both instruments now score
# through Harness.shot_env(), which mirrors what carrier.gd assembles.
#
# Feeding the real read moves the result, and NOT in the flattering direction:
#
#   cell          loft  model  measured  saves
#   3.5 / 4.3 m     0    1.00    0.00    PAD x24
#   3.5 / 5.3 m     0    1.00    0.00    PAD x24
#   5.0 m           2    1.00    0.17    STICK x18
#   7.0 m           0    0.85    0.00    PAD x24
#
# The first two cells scored 24/24 GOALS on the default path, shooting HIGH.
# With the pose fed they pick FLAT and the pad eats all 24. So the pose-fed HIGH
# cover is OVER-STATED: READY hands parked at (0.42, 0.90) / (-0.44, 0.86) make
# the model read the top corners as guarded, the flat corner wins the hole
# compete by default, and the flat corner is exactly what this keeper is best at
# stopping. The band choice inverts for the second time, from the opposite cause.
#
# That is the live target. Note it is NOT the same defect as the stick (the
# in-tight cells stay 0.00/0.00 either way — that fix holds on both paths).

# Report-only: every cell above is a live disagreement, so there is nothing here
# worth freezing yet. This is the map, not the guard.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SAMPLES: int = 16
const SEED: int = 0x5EED

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null
var _parts: Dictionary = {}
var _out: Dictionary = {}
const PART := ["STICK", "PAD", "BLOCK", "CHEST", "GLOVE"]


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_h = Harness.new()
	_h.setup(_goalie, _puck, _ctrl, _shooter)


func _cell(spot: Vector3, spread: float) -> Dictionary:
	_ctrl.reset_to_crease()
	_h.settle(spot, 120)
	var g: Vector3 = _goalie.global_position
	var speed: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S
	# THE REPLICATED READ, exactly as gameplay assembles it (carrier.gd's
	# _shot_env_*): post seal, stance family, five-hole and pose all come off the
	# live GoalieNetworkState. Scoring against the defaults instead measures the
	# model in a degraded configuration — no seal, no pose, no five-hole — while
	# the puck meets the full keeper, which manufactures disagreements that are
	# instrument error rather than model error.
	var env: Dictionary = _h.shot_env()
	var down: bool = env["down"]
	var five: float = env["five"]
	var seal_x: float = env["seal_x"]
	var seal_tall: bool = env["seal_tall"]
	var hands: Vector4 = env["hands"]
	var pads: Vector4 = env["pads"]
	var model: float = AIActionScoring.score_shoot(
			spot, _goal, g, GameRules.NET_HALF_WIDTH, [], speed, 0.0, [],
			five, down, seal_x, seal_tall, spread, [], hands, pads)
	var aim: Vector3 = AIActionScoring.best_shot_aim(spot, _goal, g,
			GameRules.NET_HALF_WIDTH, speed, 0.0, five, down, spread,
			seal_x, seal_tall, 0.0, hands, pads)
	var loft: int = AIActionScoring.best_shot_loft(spot, _goal, g,
			GameRules.NET_HALF_WIDTH, speed, 0.0, five, down,
			seal_x, seal_tall, spread, 0.0, hands, pads)
	var pt: float = AIActionScoring.best_shot_power_t(spot, _goal, g,
			GameRules.NET_HALF_WIDTH, speed, 0.0, five, down,
			seal_x, seal_tall, spread, 0.0, hands, pads)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var goals: int = 0
	_parts = {}
	_out = {Harness.GOAL: 0, Harness.SAVE: 0, Harness.POST: 0, Harness.WIDE: 0}
	for _i: int in SAMPLES:
		_ctrl.reset_to_crease()
		_h.settle(spot, 120)
		var o: int = _h.fire(spot, aim, loft, pt, rng.randf_range(-spread, spread))
		_out[o] = int(_out.get(o, 0)) + 1
		if o == Harness.GOAL:
			goals += 1
		elif o == Harness.SAVE:
			var k: String = PART[_h.last_part] if _h.last_part >= 0 else "?"
			_parts[k] = int(_parts.get(k, 0)) + 1
	return {
		"model": model, "measured": float(goals) / float(SAMPLES),
		"gap": Vector2(g.x - spot.x, g.z - spot.z).length(),
		"gx": g.x, "gz": g.z, "depth": absf(g.z - GOAL_Z),
		"loft": loft, "pt": pt, "aim": aim, "seal": seal_x, "down": down,
		"hands": hands, "pads": pads, "five": five,
	}


func test_angle_sweep() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	gut.p("Distance to goal held constant; only BEARING varies.")
	gut.p(" r    bearing  model  measured   delta | G  S  P  W | keeper x/depth seal | aimx loft")
	for r: float in [5.0, 7.0]:
		for deg: float in [0.0, 15.0, 30.0, 45.0, 60.0]:
			var t: float = deg_to_rad(deg)
			var spot := Vector3(r * sin(t), 0.0, GOAL_Z + r * cos(t))
			var c: Dictionary = _cell(spot, spread)
			if deg == 0.0:
				gut.p("      pose: hands=%s pads=%s five=%.3f down=%s"
						% [str(c["hands"]), str(c["pads"]), c["five"], str(c["down"])])
			var a: Vector3 = c["aim"]
			gut.p("%4.1f  %5.0f deg  %5.2f   %5.2f   %+5.2f |%2d %2d %2d %2d | %+5.2f / %4.2f  | %+5.2f  %d  %s"
					% [r, deg, c["model"], c["measured"], c["model"] - c["measured"],
					_out[Harness.GOAL], _out[Harness.SAVE], _out[Harness.POST],
					_out[Harness.WIDE], c["gx"], c["depth"], a.x, c["loft"], str(_parts)])
	assert_true(true)
