extends GutTest

# ── SHAPE CHECK: the live goalie vs the public-style xG baseline ─────────────
# REPORT ONLY. Nothing here asserts a level, and deliberately so: XGBaseline is
# NHL-calibrated and Mitts is arcade, so the absolute numbers are not expected to
# agree (that file says as much). What IS comparable is the SHAPE — how danger
# moves with distance and with angle — because a shape disagreement is a
# statement about the goalie's model, not about the game's scoring rate.
#
# Both columns are normalised to their own value at the mid-slot reference cell,
# so the report reads as "relative to a mid-slot shot" on both sides and the
# arcade-vs-NHL level cancels out.
#
# ── What is measured ─────────────────────────────────────────────────────────
# For each (distance, angle) cell: a settled, squared goalie, a real held windup
# (the human mechanism — cold fires read differently, see
# test_goalie_exhaustive_beatability.gd), then the whole aim x AIM x loft space
# fired with perfect execution. The cell's number is the FRACTION OF THE AIM
# SPACE THAT SCORES — "how much of the net is actually available from here".
#
# That is not a goal probability and must not be read as one. It is a measure of
# available net, which is the quantity xG's location term is a proxy for, and it
# has the properties this comparison needs: deterministic, no RNG, no assumption
# about how well the shooter aims. A shooter who picks well converts far above
# it; one who picks badly, far below.
#
# ── Known asymmetries, NOT bugs, do not "correct" for them ───────────────────
#  * NO SCREEN. This is the clear-sighted case throughout; real xG averages over
#    screened shots, which are far more dangerous. Our column is biased LOW
#    against xG everywhere by a roughly constant factor, which is exactly why the
#    comparison is normalised.
#  * REBOUNDS ARE TERMINAL (first goalie contact ends the shot). This is CORRECT
#    for a per-shot comparison — a real xG model scores the rebound as its own
#    separate shot event — but see the rebound note in the exhaustive sweep for
#    why it flatters this keeper in tight.
#  * THE SHAPE GRID IS WRISTER-ONLY. The boundary sweep below covers both
#    mechanisms at their real durations; the distance x angle grid above does not.
#  * STATIONARY SHOOTER, SET GOALIE. The single most goalie-flattering choice
#    here: nothing in this grid gets him moving, and xG's fitted average very
#    much includes plays that do.
#
# ── WHAT IT MEASURED (2026-07, 225 shots/cell) ───────────────────────────────
#   dist angle | goals   live  liveN |     xG   xgN |  rel
#      3     0 |    27  0.120   1.49 |  0.398  3.37 | 0.44
#      3    30 |    17  0.076   0.94 |  0.303  2.56 | 0.36
#      3    50 |     7  0.031   0.39 |  0.248  2.09 | 0.18
#      5     0 |    27  0.120   1.49 |  0.222  1.87 | 0.79
#      5    30 |    31  0.138   1.71 |  0.158  1.33 | 1.28
#      5    50 |    37  0.164   2.04 |  0.124  1.05 | 1.94
#      8     0 |     7  0.031   0.39 |  0.116  0.98 | 0.39
#      8    30 |    21  0.093   1.16 |  0.079  0.67 | 1.72
#      8    50 |    25  0.111   1.38 |  0.061  0.52 | 2.66
#     11     0 |     6  0.027   0.33 |  0.072  0.61 | 0.54
#     11    30 |    29  0.129   1.60 |  0.049  0.41 | 3.89
#     11    50 |    24  0.107   1.32 |  0.037  0.31 | 4.20
#     15     0 |     0  0.000   0.00 |  0.044  0.38 | 0.00
#     15    30 |    19  0.084   1.05 |  0.030  0.25 | 4.17
#     15    50 |    12  0.053   0.66 |  0.023  0.19 | 3.45
#     20     0 |     6  0.027   0.33 |  0.028  0.24 | 1.39
#     20    30 |    14  0.062   0.77 |  0.019  0.16 | 4.88
#
# THREE SHAPE DISAGREEMENTS:
#
#  1. THE ANGLE AXIS IS INVERTED BEYOND ~4 m. xG falls monotonically with angle
#     at every range. Ours falls correctly at 3 m and then RISES at every range
#     from 5 m out — 3.6x from 0 to 50 deg at 8 m, 4.8x at 11 m, and from
#     literally zero at 15 m. A sharp-angle shot is the easiest way to beat this
#     keeper, which is backwards from the model AND from the doctrine that
#     cutting the angle down leaves the shooter nothing.
#
#  2. THE PEAK IS IN THE WRONG PLACE. xG's most dangerous cell is 3 m straight
#     on (3.37x the grid mean). Ours is 5 m at 50 deg off-angle (2.04x), and the
#     doorstep reads 1.49x — no more dangerous than 5 m, and LESS than a sharp
#     5 m look. In tight we are 2-5x harder than the shape says.
#
#  3. THE CENTRE LINE HAS A HOLE FROM 8 m OUT, and at 15 m it is exactly zero:
#     no aim, loft, or wrister pace beats him dead centre from the top of the
#     circles. xG still prices that shot at 0.044.
#
# ── THE MECHANISM: he covers >=100% of the net from EVERYWHERE ───────────────
# The coverage report below is the cause. Comparing the angle the goal mouth
# subtends from the shooter against the angle the goalie's own blocking width
# subtends from the same eye:
#
#   dist angle | goalie x  depth | net subt  goalie subt | ratio
#      3     0 |     0.00   1.55 |    0.592        1.051 |  177%
#      5     0 |     0.01   1.52 |    0.362        0.474 |  131%
#      8     0 |     0.10   1.47 |    0.228        0.256 |  112%
#     11     0 |     0.11   1.46 |    0.166        0.176 |  106%
#     15     0 |     0.11   1.46 |    0.122        0.124 |  102%
#     20     0 |     0.12   1.46 |    0.091        0.091 |   99%
#
# ON THE CENTRE LINE THIS IS EXACT — he is on that sightline — and it explains
# findings 2 and 3 outright. There is no open net to shoot at from anywhere in
# the slot: goals are won purely by DYNAMICS (beating the read, the drop timing,
# the arm), never by finding net he is not standing in front of. A location-based
# xG model is a statement about GEOMETRY, so its shape cannot be reproduced by a
# keeper whose geometry is effectively constant.
#
# It also gives the distance gradient its sign. His depth is ~1.46-1.55 m from
# 3 m out to 15 m — nearly FIXED in absolute terms — so as the shooter closes,
# the goalie (the nearer object) grows in angular terms FASTER than the net does,
# and coverage climbs from 99% at the point to 177% at the doorstep. Distance
# then only changes flight TIME, which helps him. Hence a danger surface that
# falls too steeply with range and bottoms out at exactly zero.
#
# THE SHARP-ANGLE ROWS DO NOT EXPLAIN FINDING 1, and the ratio is misleading
# there — read it as an upper bound. It assumes he is centred on the sightline,
# which is true straight on and false once the arc solver pins him to the post
# (goalie x 0.92). Nominal coverage RISES with angle while measured beatability
# rises too, so the two disagree. The boundary sweep below resolves it.
#
# ── FINDING 1: the angled hole survives, isolated to 75 deg ─────────────────
# Conversion (goals / shots that reached him) from the REFERENCE POSE
# (Harness.settle_ready), with the wind-ups the GAME produces rather than
# hand-picked hold lengths — see the WIND-UPS block below for why that matters.
#
#   dist angle |   quick wrister (0.125 s) |   full slapper (0.70 s)
#      5    40 |    READY          8.7%    |   SLIDING        30.2%
#      5    50 |    READY          8.1%    |   SLIDING        22.8%
#      5    60 |    READY         10.0%    |   SLIDING        17.5%
#      5    70 |    READY          8.2%    |   READY           5.0%
#      5    75 |    READY         21.5%    |   READY          14.7%
#      5    80 |     VH_L          0.0%    |    VH_L           0.0%
#      8    40 |    READY          7.3%    |   READY           3.6%
#      8    60 |    READY          6.7%    |   READY           3.1%
#      8    70 |    READY          8.7%    |   READY           3.1%
#      8    75 |    READY         16.0%    |   READY           7.6%
#      8    80 |     VH_L          0.0%    |    VH_L           0.0%
#
# ON THE WRISTER the angle axis is now FLAT from 40-70 deg (8.7 / 8.1 / 10.0 /
# 8.2) where it used to climb 2x, and what remains is a spike at 75 deg alone —
# the last step before post integration, where the arc solve already has him at
# the seal spot but he is STANDING there instead of in VH's vertical pad. That
# residual is the pose, not the position.
#
# ON THE SLAPPER the angle axis runs the RIGHT way — 30.2% at 40 deg falling to
# 5.0% at 70 deg, which is xG's direction — and the most dangerous cell in the
# whole grid is a full slapper from 5 m nearly straight on.
#
# ── AND THAT WORST CELL IS SELF-INFLICTED: read the STANCE column ────────────
# At 5 m / 40-60 deg against a full slapper charge he is SLIDING at the release.
# Nothing moved: the shooter is stationary and only charging. He reads the loaded
# slapper, `_should_block` decides to drop, and from the butterfly he commits a
# slide — so by the time the puck leaves he is caught mid-translation, which is
# exactly the state the caught-moving model prices as most beatable. The keeper
# beats himself. Compare 70 deg on the same row: he stays READY and concedes 5%.
#
# This only became visible once the wind-up was modelled as the game produces it
# — 0.7 s of SLAPPER_CHARGE_WITH_PUCK in the slapper power band. A 0.125 s
# wrister hold never gives him time to make the decision.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z

const WINDUP_TICKS: int = 24
# Power fractions over the wrister band (GameRules 10-33 m/s): 23.8 / 28.4 /
# 33.0 m/s = 53 / 64 / 74 mph. Pace is swept rather than fixed because the long
# cells live or die on it.
const POWERS: Array[float] = [0.6, 0.8, 1.0]
# Aim points across the mouth, post to post, and the three lofts.
const AIM_STEPS: int = 25
const LOFTS: Array[int] = [0, 1, 2]

# Polar grid off the goal mouth's centre. Distances span doorstep -> point.
const DISTANCES: Array[float] = [3.0, 5.0, 8.0, 11.0, 15.0, 20.0]
const ANGLES_DEG: Array[float] = [0.0, 30.0, 50.0]
# The cell both columns are normalised against: 8 m straight on, the mid-slot
# shot XGBaseline's own provenance note calibrates at ~0.12.
const REF_DIST: float = 8.0
const REF_ANGLE_DEG: float = 0.0

var _h: RefCounted = null
var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null


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


# Shooter world position at `dist` from the goal mouth's centre, `angle_deg` off
# the centre line. Positive angle puts him to +x.
func _spot(dist: float, angle_deg: float) -> Vector3:
	var a: float = deg_to_rad(angle_deg)
	return Vector3(dist * sin(a), 0.0, GOAL_Z + dist * cos(a))


# Fraction of the (aim x, loft) space that scores from `shooter`, through the
# real windup/release path against a re-settled goalie each shot.
func _available_net(shooter: Vector3) -> Vector2:
	var hw: float = GameRules.NET_HALF_WIDTH - GameRules.NET_POST_RADIUS \
			- GameRules.PUCK_COLLISION_RADIUS
	var goals: int = 0
	var shots: int = 0
	for power: float in POWERS:
		for loft: int in LOFTS:
			for i: int in AIM_STEPS:
				var t: float = float(i) / float(AIM_STEPS - 1)
				var aim := Vector3(lerpf(-hw, hw, t), 0.0, GOAL_Z)
				_h.settle_ready(shooter)
				_h.publish_windup(shooter, aim, loft, power, WINDUP_TICKS)
				if _h.fire_release(shooter, aim, loft, power, 0.0) == Harness.GOAL:
					goals += 1
				shots += 1
	return Vector2(float(goals) / float(maxi(shots, 1)), float(goals))


func test_report_goalie_shape_vs_xg_baseline() -> void:
	var keys: Array[String] = []
	var measured := {}
	var counts := {}
	var baseline := {}
	for dist: float in DISTANCES:
		for angle: float in ANGLES_DEG:
			var shooter: Vector3 = _spot(dist, angle)
			# Off-ice spots are not shots. Skip rather than score them zero.
			if absf(shooter.x) > GameRules.INNER_HALF_WIDTH:
				continue
			var key: String = "%.0f|%.0f" % [dist, angle]
			keys.append(key)
			var m: Vector2 = _available_net(shooter)
			measured[key] = m.x
			counts[key] = int(m.y)
			# Team 0 attacks -Z, which is the net this harness defends.
			baseline[key] = XGBaseline.for_shot(
					shooter.x, shooter.z, 0, ShotEvent.ShotType.SHOT)
	# Normalise each column by its OWN mean over the grid. A single reference cell
	# is too noisy at this resolution to anchor on.
	var m_sum: float = 0.0
	var b_sum: float = 0.0
	for key: String in keys:
		m_sum += measured[key]
		b_sum += baseline[key]
	var m_avg: float = maxf(m_sum / float(maxi(keys.size(), 1)), 0.0001)
	var b_avg: float = maxf(b_sum / float(maxi(keys.size(), 1)), 0.0001)

	var per_spot: int = AIM_STEPS * LOFTS.size() * POWERS.size()
	gut.p("live = fraction of the aim x loft x pace space that scores (%d/spot)" % per_spot)
	gut.p("xG   = XGBaseline.for_shot at the same spot")
	gut.p("Each column normalised by its own grid mean, so levels cancel and only")
	gut.p("the SHAPE is compared. rel > 1 = our goalie is soft here relative to xG.")
	gut.p("%5s %6s | %5s %7s %7s | %7s %7s | %6s"
			% ["dist", "angle", "goals", "live", "liveN", "xG", "xgN", "rel"])
	for key: String in keys:
		var parts: PackedStringArray = key.split("|")
		var m: float = measured[key]
		var b: float = baseline[key]
		gut.p("%5s %6s | %5d %7.3f %7.2f | %7.3f %7.2f | %6.2f"
				% [parts[0], parts[1], counts[key], m, m / m_avg, b, b / b_avg,
				(m / m_avg) / maxf(b / b_avg, 0.0001)])
	assert_true(true, "report")


# The mechanism behind the table above: how much of the net the goalie's body
# actually occludes from each spot. Cheap (settle only, no shots), and the number
# that explains why a location-based xG shape cannot be reproduced.
#
# `net subt` is the angle the goal mouth subtends from the shooter's eye;
# `goalie subt` is the angle his blocking half-width subtends from the same eye
# at wherever the depth chart has parked him. Ratio > 100% means he is wider than
# the net looks — there is no open net to aim at, at any height.
func test_report_goalie_angular_coverage() -> void:
	gut.p("%5s %6s | %8s %7s | %9s %11s | %6s" % [
			"dist", "angle", "goalie x", "depth", "net subt", "goalie subt", "ratio"])
	for dist: float in DISTANCES:
		for angle: float in ANGLES_DEG:
			var spot: Vector3 = _spot(dist, angle)
			if absf(spot.x) > GameRules.INNER_HALF_WIDTH:
				continue
			_ctrl.reset_to_crease()
			_h.settle(spot, 90)
			var gx: float = _goalie.global_position.x
			var gz: float = _goalie.global_position.z
			var hw: float = GameRules.NET_HALF_WIDTH
			var eye := Vector2(spot.x, spot.z)
			var left: Vector2 = Vector2(-hw, GOAL_Z) - eye
			var right: Vector2 = Vector2(hw, GOAL_Z) - eye
			var net_subt: float = absf(left.angle_to(right))
			# He squares to the puck, so he presents his blocking half-width
			# perpendicular to the sightline from any bearing — the same disc
			# assumption AIActionScoring.open_net_danger occludes with.
			var body_hw: float = _ctrl.pad_local_offset + _ctrl.butterfly_pad_half_width
			var g_dist: float = maxf((Vector2(gx, gz) - eye).length(), 0.01)
			var g_subt: float = 2.0 * atan2(body_hw, g_dist)
			gut.p("%5.0f %6.0f | %8.2f %7.2f | %9.3f %11.3f | %5.0f%%" % [
					dist, angle, gx, absf(gz - GOAL_Z), net_subt, g_subt,
					100.0 * g_subt / maxf(net_subt, 0.0001)])
	assert_true(true, "report")


# ── THE POST-STANCE BOUNDARY: where does the angled softness actually live? ──
# The grid above stops at 50 deg, which is entirely inside the SQUARED stance —
# RVH/VH needs `rvh_early_angle` (80 deg) AND the puck within `zone_post_z` (2 m)
# of the goal line, so nothing above was ever post-integrated. This sweeps the
# angle axis THROUGH that boundary at fixed range and reports the stance the
# goalie is actually holding at release, so the softness can be located relative
# to it rather than inferred.
#
# Two rates, because they answer different questions at sharp angles:
#   aim%   goals as a fraction of the whole aim space — deflated at high angles
#          because the near post geometrically eats aim points (they read POST,
#          not SAVE), so it understates how open he is.
#   conv%  goals / (goals + saves) — conversion among shots that actually reached
#          him. Post-blocking drops out, so this is the comparable number across
#          the angle axis and the one to read.
const BOUNDARY_DISTANCES: Array[float] = [5.0, 8.0]
const BOUNDARY_ANGLES_DEG: Array[float] = [40.0, 50.0, 60.0, 70.0, 75.0, 80.0, 85.0]
const BOUNDARY_POWERS: Array[float] = [0.8, 1.0]

# ── THE WIND-UPS ARE THE GAME'S, NOT HAND-PICKED ─────────────────────────────
# Wind-up length is the deciding variable for what the goalie has read by the
# release, so it must not be a free parameter of the instrument. Both arms below
# are the mechanisms the game actually produces, at their real durations and in
# their real states — a wrister and a slapper are DIFFERENT reads for the goalie
# (WRISTER_AIM vs SLAPPER_CHARGE_WITH_PUCK gates the pre-lean, the pinned-windup
# squaring override and the slapper aim shade), not one knob with two settings.
#
#   QUICK WRISTER — SkaterAgentStateMachine.BOT_WRISTER_CHARGE_TICKS, the charge
#   every bot in the game actually holds. 15 ticks / 125 ms, which is SHORTER
#   than either length an earlier pass swept by hand, so the quick-release case
#   was never actually measured.
#
#   FULL SLAPPER — SkaterController.max_slapper_charge_time, the full charge at
#   0.7 s, fired in the SLAPPER power band. This is also the only place
#   slapshots enter this instrument at all; everything else here is wrister pace,
#   and the top ~7 m/s of the game's shot power is exactly what the long cells
#   live on.
#
# A human wrister has no canonical duration — power comes from cursor-stroke
# speed, not a timer — so the bot charge stands in for the quick release and the
# slapper covers the long-hold end.
const WRISTER_WINDUP_TICKS: int = 15          # bot wrister charge, ~0.125 s
const SLAPPER_WINDUP_TICKS: int = 84          # max_slapper_charge_time 0.7 s
const SLAPPER_SPEEDS_M_S: Array[float] = [
	GameRules.DEFAULT_SLAPPER_POWER_MIN_M_S,
	0.5 * (GameRules.DEFAULT_SLAPPER_POWER_MIN_M_S + GameRules.DEFAULT_SLAPPER_POWER_MAX_M_S),
	GameRules.DEFAULT_SLAPPER_POWER_MAX_M_S,
]

const _STANCE_NAME: Array[String] = [
	"STANDING", "BUTTERFLY", "RECOVERING", "RVH_L", "RVH_R", "READY", "SLIDING",
	"COILING", "VH_L", "VH_R", "COVERING", "PLAY_PUCK", "CATCHING", "CATCH_DN",
]


func test_report_angled_softness_vs_post_stance() -> void:
	var hw: float = GameRules.NET_HALF_WIDTH - GameRules.NET_POST_RADIUS \
			- GameRules.PUCK_COLLISION_RADIUS
	gut.p("Stance is read AFTER the settle+windup, i.e. what he holds at release.")
	gut.p("conv%% = goals/(goals+saves) — the angle-comparable rate. See the note.")
	gut.p("%5s %6s | %10s | %5s %5s %5s %5s | %6s %6s"
			% ["dist", "angle", "stance", "goal", "save", "post", "wide", "aim%", "conv%"])
	gut.p("-- QUICK WRISTER: %d ticks (%.3f s), wrister band --"
			% [WRISTER_WINDUP_TICKS, float(WRISTER_WINDUP_TICKS) / 120.0])
	_boundary_pass(hw, false)
	gut.p("-- FULL SLAPPER: %d ticks (%.2f s), slapper band --"
			% [SLAPPER_WINDUP_TICKS, float(SLAPPER_WINDUP_TICKS) / 120.0])
	_boundary_pass(hw, true)
	assert_true(true, "report")


# `slapper` picks the whole mechanism, not just the hold: charge state, duration
# and power band all move together, because that is how the game produces them.
func _boundary_pass(hw: float, slapper: bool) -> void:
	var windup: int = SLAPPER_WINDUP_TICKS if slapper else WRISTER_WINDUP_TICKS
	var state: int = SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK if slapper \
			else SkaterStateMachine.State.WRISTER_AIM
	var paces: Array = SLAPPER_SPEEDS_M_S if slapper else BOUNDARY_POWERS
	for dist: float in BOUNDARY_DISTANCES:
		for angle: float in BOUNDARY_ANGLES_DEG:
			var shooter: Vector3 = _spot(dist, angle)
			if absf(shooter.x) > GameRules.INNER_HALF_WIDTH:
				continue
			var goals: int = 0
			var saves: int = 0
			var posts: int = 0
			var wides: int = 0
			var stance: int = -1
			var down_at_settle: int = 0
			for pace: float in paces:
				for loft: int in LOFTS:
					for i: int in AIM_STEPS:
						var t: float = float(i) / float(AIM_STEPS - 1)
						var aim := Vector3(lerpf(-hw, hw, t), 0.0, GOAL_Z)
						_h.settle_ready(shooter)
						if _h.last_settle_went_down:
							down_at_settle += 1
						var outcome: int
						if slapper:
							_h.publish_windup_at(shooter, aim, loft, pace, windup, state)
							outcome = _h.fire_release_at(shooter, aim, loft, pace, 0.0)
						else:
							_h.publish_windup(shooter, aim, loft, pace, windup, state)
							outcome = _h.fire_release(shooter, aim, loft, pace, 0.0)
						stance = _ctrl._sm.current as int
						match outcome:
							Harness.GOAL:
								goals += 1
							Harness.SAVE:
								saves += 1
							Harness.POST:
								posts += 1
							_:
								wides += 1
			var shots: int = goals + saves + posts + wides
			var reached: int = goals + saves
			gut.p("%5.0f %6.0f | %10s | %5d %5d %5d %5d | %5.1f%% %5.1f%% | down@settle %d"
					% [dist, angle, _STANCE_NAME[stance], goals, saves, posts, wides,
					100.0 * float(goals) / float(maxi(shots, 1)),
					100.0 * float(goals) / float(maxi(reached, 1)), down_at_settle])
