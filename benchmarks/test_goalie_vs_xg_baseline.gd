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
# It also gives the distance gradient its sign. Against a STANDING shooter his
# depth is ~1.46-1.55 m from 3 m out to 15 m — nearly fixed — so as the shooter
# closes, the goalie (the nearer object) grows in angular terms FASTER than the
# net does, and coverage climbs from 99% at the point to 177% at the doorstep.
#
# THAT FLATNESS IS AN ARTIFACT OF THE STANDING SHOOTER, not the depth model.
# `_fill_rush_constraint` needs closing >= rush_min_closing_speed and
# `lateral_tracking_cap` returns INF at zero lateral speed, so a stationary
# shooter binds neither and the solve falls through to the ceiling. Skate him in
# and the retreat is textbook — see the closing-rush reports at the bottom.
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
#      5    40 |    READY          8.7%    | BUTTERFLY        11.1%
#      5    50 |    READY          8.1%    | BUTTERFLY         8.1%
#      5    60 |    READY         10.0%    |   READY           9.2%
#      5    70 |    READY          8.2%    |   READY           5.0%
#      5    75 |    READY         21.5%    |   READY          14.7%
#      5    80 |     VH_L          0.0%    |    VH_L           0.0%
#      8    40 |    READY          7.3%    |   READY           3.6%
#      8    60 |    READY          6.7%    |   READY           3.1%
#      8    70 |    READY          8.7%    |   READY           3.1%
#      8    75 |    READY         16.0%    |   READY           7.6%
#      8    80 |     VH_L          0.0%    |    VH_L           0.0%
#
# The slapper column is POST-FIX (see the slide note below); before it those
# three 5 m cells read SLIDING at 30.2 / 22.8 / 17.5%.
#
# ON THE WRISTER the angle axis is now FLAT from 40-70 deg (8.7 / 8.1 / 10.0 /
# 8.2) where it used to climb 2x, and what remains is a spike at 75 deg alone —
# the last step before post integration, where the arc solve already has him at
# the seal spot but he is STANDING there instead of in VH's vertical pad. That
# residual is the pose, not the position.
#
# ON THE SLAPPER the angle axis runs the RIGHT way — 11.1% at 40 deg falling to
# 5.0% at 70 deg, which is xG's direction. Before the slide fix that column read
# 30.2% at 40 deg and was the most dangerous cell in the whole grid.
#
# ── AND THAT WORST CELL WAS SELF-INFLICTED: read the STANCE column ───────────
# BEFORE THE FIX, at 5 m / 40-60 deg against a full slapper charge he was SLIDING
# at the release.
# Nothing moved: the shooter is stationary and only charging. He reads the loaded
# slapper, `_should_block` decides to drop, and from the butterfly he commits a
# slide — so by the time the puck leaves he is caught mid-translation, which is
# exactly the state the caught-moving model prices as most beatable. The keeper
# beats himself. Compare 70 deg on the same row: he stays READY and concedes 5%.
#
# This only became visible once the wind-up was modelled as the game produces it
# — 0.7 s of SLAPPER_CHARGE_WITH_PUCK in the slapper power band. A 0.125 s
# wrister hold never gives him time to make the decision.
#
# ── IT IS SLAPPER-ONLY: A HELD WRIST SHOT DOES NOT DO THIS ──────────────────
# A human wrister has no duration cap, so the obvious worry is that sitting on
# WRISTER_AIM walks him into the same trap on the shot players take most. It does
# not. Held out to 1.5 s (the hold sweep below) he stays READY at every duration
# and conversion is FLAT — 2.7% at 5 m centred, 6.8-8.1% at 5 m / 40 deg, 4.0% at
# 8 m centred, unchanged from 0.125 s to 1.5 s. The block decision distinguishes
# the two wind-ups deliberately: you block a loaded slapshot, you stay up and
# react to a wrister. So the exploit is not available on the wrister.
#
# ── WHY THE SLAPPER ENDS IN A SLIDE: THE DROP RELOCATES HIM ─────────────────
# At 5 m / 40 and 60 deg he is SLIDING on EVERY shot (225/225 and 217/217 — the
# instrument has no RNG, so the stance is deterministic per cell), and at 70 deg
# he never drops at all.
#
# The cause is a radius mismatch, not the slide logic. Standing, he holds the
# challenge radius (~1.75 m); `butterfly_radius` is 0.40. So the ACT OF DROPPING
# moves his arc target 1.35 m back along the ray, which at 40 deg swings his
# lateral target from ~0.88 to ~0.26 — and he then slides ~0.6 m to fix an angle
# that was correct until he dropped. The puck leaves while he is still travelling.
#
# Real goaltending does not work this way: a butterfly drop does not relocate
# you, you drop where you stand. Some settling back is honest; 1.35 m of it is
# what manufactures the slide.
#
# FIXED — but the cause was the SLIDE'S COVERAGE TEST, not the radius. It asked
# |puck.x - goalie.x|, which for a shooter out at an angle reads a 2.3 m breach
# against a keeper who is already square. Now measured off his angle instead.
# The radius mismatch above is real and still there; it just was not what fired
# the seal.
#
# ── RESIDUAL, UNRESOLVED: a drop <-> recover oscillation under shooter motion ─
# On post-fix code, holding a slapper charge while the shooter MOVES walks him
# into a stand-up/drop cycle. Stationary he drops once and stays down; add
# motion and he does not:
#
#   HARD, stationary        BUTTERFLY at 0.00 s, holds
#   HARD, 8 cm blade jitter BUTTERFLY 0.00 -> RECOVERING 1.09 -> READY 1.44 -> BUTTERFLY 1.69
#   HARD, 0.5 m/s drift     BUTTERFLY 0.00 -> RECOVERING 0.57 -> READY 0.92, stays up
#   EASY / NORMAL           no oscillation at either
#
# The mechanism is that `should_block` is knife-edge here — `answer_fraction`'s
# `available` term is about -0.02 s at this spot — and it has no hysteresis, so a
# few centimetres of jitter flips the verdict and the state machine turns each
# flip into a full recovery cycle. `_is_threat_pressing` already routes staying-
# down through the same `_should_block` ("going down and staying down are one
# question"), which is the right structure; what is missing is that abandoning a
# committed seal should need the verdict to HOLD, not to flicker — the file's own
# `lateral_commit_confirm_s` idiom.
#
# NOT FIXED, deliberately: `max_slapper_charge_time` is 0.7 s, so the jitter case
# (1.09 s) is out of reach of a real charge and only the drift case (0.57 s) is
# inside it — and a slapper PLANTS the shooter, which is what makes drift
# unlikely. Whether this is reachable in play is a question for the ice, not the
# instrument. Confirm it live before adding hysteresis for it.

# ══════════════════════════════════════════════════════════════════════════════
# ── GROUND TRUTH: 233 LOGGED SHOTS FROM REAL GAMES (2026-07) ────────────────
# Supplied from the `shot_events` table — 7 games, 233 attempts, 117 on net, 39
# goals, mixed bot and human shooters. Small, one human, but it is the only
# measurement here taken from the game actually being played, and it settles two
# of this file's claims in opposite directions.
#
# ── THE DISTANCE FINDING ABOVE IS WRONG. Do not act on it. ──────────────────
#   band     onNet goals   rate
#   0-3 m       43    22   0.512
#   3-5 m       21     6   0.286
#   5-7 m       31     6   0.194
#   15+ m        5     0   0.000
#
# In play the doorstep is the MOST dangerous place on the ice and the surface
# rises monotonically as the shooter closes — xG's shape, and the exact opposite
# of the 0.000 this instrument reports at 3 m across the static grid, the rush
# sweep and the deke sweep alike.
#
# The instrument is what is wrong, and the caveat that does it is REBOUNDS ARE
# TERMINAL. A rebound is logged as its own shot event at its own close-range
# position, so the 0-3 m band is largely second chances — while here, first
# goalie contact ends the trial and every one of those scores as a save.
# test_goalie_exhaustive_beatability already measured the other half of this:
# 95.6% of in-tight shots leave a LIVE rebound. He is a wall to the first shot
# and a rebound machine on the same play, and the rebounds are what go in.
#
# So "he is too big in tight" was an artifact of excluding the mechanism that
# actually scores there. The in-tight problem is REBOUND CONTROL, not coverage —
# which also joins up with the no-stick counterfactual below: the stick is what
# shuts the low corners at 3 m, and GoalieSaveRules.is_controlled_save returns
# FALSE for STICK unconditionally, so the surface doing the covering is the one
# surface that never deadens anything.
#
# ── THE ANGLE FINDING IS CONFIRMED, and it is the one worth acting on. ──────
#   0-20 deg   44 onNet   7 goals  0.159
#   20-40 deg  26 onNet   9 goals  0.346
#   40-60 deg  36 onNet  17 goals  0.472
#   60-91 deg  11 onNet   6 goals  0.545
#
# Danger RISES 3.4x with angle in real games, and it holds inside 5 m on its own
# (0.286 / 0.370 / 0.609 across the same bands). Real hockey runs the other way:
# cutting the angle down is supposed to leave the shooter nothing. This is not an
# instrument artifact — the live sweeps and the logged games agree.
#
# ── Two smaller things the data says ────────────────────────────────────────
# The game's own stored `xg` tracks well in tight (0.479 vs 0.512 actual at
# 0-3 m; 0.283 vs 0.286 at 3-5 m) and UNDER-predicts badly from mid-range
# (0.084 vs 0.308 at 7-10 m, 0.085 vs 0.250 at 10-15 m, n=13 and n=4). Same
# direction as the band-instrument divergence flagged on
# test_shot_value_calibration.
#
# Overall save percentage is 0.667. Arcade by design, but it is the number any
# future "is the goalie too strong" question should be measured against, not the
# aim-space fractions in this file.
# ══════════════════════════════════════════════════════════════════════════════

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
func _shooter_ref() -> Skater:
	return _shooter


func _puck_ref() -> Node:
	return _puck


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


# ── DOES A HELD WRIST SHOT SELF-DEFEAT THE SAME WAY? ─────────────────────────
# The slapper result above is driven by the goalie's own block-and-slide response
# to a wind-up he has read for 0.7 s. A wrister publishes a DIFFERENT state
# (WRISTER_AIM, not SLAPPER_CHARGE_WITH_PUCK) but `_should_block` reads both, and
# a human wrister has NO duration cap — power comes from cursor-stroke speed, not
# a timer, so a player can sit on WRISTER_AIM as long as they like. The bots' own
# 0.125 s charge is the short end of that range, not the whole of it.
#
# So: sweep the hold and watch the stance. If holding a wrister walks him into
# the same drop-then-slide, the exploit is available on the shot players take
# most, not just on the slapper.
const HOLD_SWEEP_TICKS: Array[int] = [15, 36, 60, 84, 120, 180]
const HOLD_SWEEP_SPOTS: Array[Vector2] = [
	Vector2(5.0, 0.0), Vector2(5.0, 40.0), Vector2(8.0, 0.0),
]
const HOLD_SWEEP_POWER: float = 0.9


func test_report_held_wrister_hold_sweep() -> void:
	var hw: float = GameRules.NET_HALF_WIDTH - GameRules.NET_POST_RADIUS \
			- GameRules.PUCK_COLLISION_RADIUS
	gut.p("Held WRISTER_AIM, wrister band, power_t %.2f. Stance is at release."
			% [HOLD_SWEEP_POWER])
	gut.p("%5s %6s %7s | %10s | %5s %5s | %6s"
			% ["dist", "angle", "hold s", "stance", "goal", "save", "conv%"])
	for spot2: Vector2 in HOLD_SWEEP_SPOTS:
		for hold: int in HOLD_SWEEP_TICKS:
			var shooter: Vector3 = _spot(spot2.x, spot2.y)
			var goals: int = 0
			var saves: int = 0
			var stance: int = -1
			for loft: int in LOFTS:
				for i: int in AIM_STEPS:
					var t: float = float(i) / float(AIM_STEPS - 1)
					var aim := Vector3(lerpf(-hw, hw, t), 0.0, GOAL_Z)
					_h.settle_ready(shooter)
					_h.publish_windup(shooter, aim, loft, HOLD_SWEEP_POWER, hold,
							SkaterStateMachine.State.WRISTER_AIM)
					stance = _ctrl._sm.current as int
					match _h.fire_release(shooter, aim, loft, HOLD_SWEEP_POWER, 0.0):
						Harness.GOAL:
							goals += 1
						Harness.SAVE:
							saves += 1
						_:
							pass
			gut.p("%5.0f %6.0f %7.3f | %10s | %5d %5d | %5.1f%%"
					% [spot2.x, spot2.y, float(hold) / 120.0, _STANCE_NAME[stance],
					goals, saves, 100.0 * float(goals) / float(maxi(goals + saves, 1))])
	assert_true(true, "report")


# ── THE CLOSING RUSH — and why this, not the grid above, is the real read ────
# Everything above fires from a STANDSTILL. Players almost never do: barring a
# one-timer, a shot comes off a moving body. That makes the static grid an edge
# case being used as a reference, and it never exercises half the depth model —
# `_fill_rush_constraint` needs closing >= rush_min_closing_speed, and
# `lateral_tracking_cap` returns INF at zero lateral speed, so against a standing
# shooter neither binds and the solve falls through to the depth ceiling.
#
# It also explains the static grid's doorstep result (exactly 0.000 at 3 m). NHL
# shots from 3 m are overwhelmingly rebounds, deflections and scrambles, so xG's
# 0.40 there is fitted on chaos this instrument deliberately excludes. A clean,
# unscreened, stationary 3 m shot at a set goalie SHOULD be stopped nearly
# always; that cell is not evidence of a defect.
#
# So: skate him in and shoot on the move.

# ── WHAT THE RUSH MEASURED (2026-07) ─────────────────────────────────────────
# DEPTH TRACKS DOCTRINE, at every closing speed. `taught` is
# GoalieBehaviorRules.rush_retreat_depth; the live radius sits on it within a
# couple of centimetres from 12 m all the way to the crease:
#
#   dist |  taught |  4 m/s  6 m/s  8 m/s
#   12.0 |    1.75 |   1.75   1.74   1.74
#    8.0 |    1.75 |   1.75   1.75   1.74
#    6.0 |    1.49 |   1.49   1.49   1.48
#    4.5 |    1.30 |   1.29   1.30   1.29     <- crease top at the hash marks
#    3.0 |    0.70 |   0.69   0.70   0.67
#    2.0 |    0.30 |   0.29   0.30   0.27     <- goal line at the crease
#
# So the depth model is NOT the problem, and any claim that he "never backs in"
# is a claim about the static grid only.
#
# BUT THE DISTANCE AXIS IS STILL INVERTED, now with the confound removed.
# Shooting on the move off a 6 m/s rush, quick wrister:
#
#   relD lane |   live  liveN |     xG   xgN |  rel
#     10    0 |  0.000   0.00 |  0.083  0.45 | 0.00
#      8    0 |  0.026   0.71 |  0.116  0.63 | 1.13
#      6    0 |  0.077   2.14 |  0.174  0.95 | 2.26   <- our peak
#      4    0 |  0.026   0.71 |  0.292  1.59 | 0.45
#      3    0 |  0.000   0.00 |  0.398  2.17 | 0.00   <- xG's peak, our zero
#     10   30 |  0.051   1.43 |  0.056  0.31 | 4.66
#      3   30 |  0.026   0.71 |  0.303  1.65 | 0.43
#
# xG rises monotonically as the shooter closes; ours peaks at 6 m and FALLS to
# zero at 3 m. Closing in makes him harder, not easier.
#
# AND IT IS NO LONGER DEPTH. The retreat does its job — coverage at the doorstep
# drops from 177% (standing shooter, parked at 1.55 m) to ~118% (rush, retreated
# to 0.70 m). It simply never drops BELOW 100%: his blocking body still subtends
# more than the mouth at every range on the rush, so proximity never buys the
# shooter any angle. The remaining inversion is a SIZE relationship between the
# goalie's blocking geometry and the goal mouth, not a positioning error, which
# makes it a much larger question than anything the depth chart can answer.
#
# Caveats that still apply and are load-bearing in tight: no screens, no dekes,
# and rebounds terminal. Real 3 m chances are largely those three things, so
# xG's 0.40 there is fitted on a population this instrument excludes by
# construction — the gap is real but it is not 5x real.

const RUSH_START_DIST: float = 14.0
const RUSH_SPEEDS: Array[float] = [4.0, 6.0, 8.0]
const RUSH_RELEASE_DISTS: Array[float] = [10.0, 8.0, 6.0, 4.0, 3.0]
const RUSH_LANES_DEG: Array[float] = [0.0, 30.0]
const RUSH_AIMS: int = 13


# Drive the shooter from RUSH_START_DIST down the `lane_deg` bearing toward the
# goal mouth at `speed`, carrying, until he reaches `until_dist`. Returns his
# final world position. The goalie is settled against the START of the lane
# first, so what follows is a genuine approach rather than a spawn.
func _skate_in(lane_deg: float, speed: float, until_dist: float, seed_settle: bool) -> Vector3:
	var a: float = deg_to_rad(lane_deg)
	var dir := Vector3(sin(a), 0.0, cos(a))
	var start: Vector3 = Vector3(0.0, 0.0, GOAL_Z) + dir * RUSH_START_DIST
	if seed_settle:
		_h.settle_ready(start)
	_shooter_ref().current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter_ref().predicted_shot_velocity = Vector3.ZERO
	_puck_ref().set_carrier(_shooter_ref())
	var d: float = RUSH_START_DIST
	var dt: float = 1.0 / 120.0
	# Closing straight at the mouth, so |velocity| is the closing speed the rush
	# constraint reads, and its x component is what the lateral cap reads.
	var vel: Vector3 = -dir * speed
	var guard: int = 0
	while d > until_dist and guard < 2000:
		d -= speed * dt
		var pos: Vector3 = Vector3(0.0, 0.0, GOAL_Z) + dir * d
		_shooter_ref().global_position = pos
		_shooter_ref().velocity = vel
		_puck_ref().global_position = pos
		_puck_ref().linear_velocity = Vector3.ZERO
		_ctrl._physics_process(dt)
		guard += 1
	return Vector3(0.0, 0.0, GOAL_Z) + dir * until_dist


func test_report_rush_depth_vs_doctrine() -> void:
	var cfg := GoalieBehaviorRules.RushRetreatConfig.new()
	cfg.engage_distance = _ctrl.rush_engage_distance
	cfg.mid_distance = _ctrl.rush_mid_distance
	cfg.arrive_distance = _ctrl.rush_arrive_distance
	cfg.depth_engage = _ctrl.depth_aggressive
	cfg.depth_mid = _ctrl.depth_base
	cfg.depth_arrive = _ctrl.depth_defensive
	gut.p("Goalie challenge radius through a closing rush, straight-on lane.")
	gut.p("`taught` is GoalieBehaviorRules.rush_retreat_depth — crease-top depth")
	gut.p("at the hash marks (%.1f m), goal-line depth at the crease (%.1f m)."
			% [_ctrl.rush_mid_distance, _ctrl.rush_arrive_distance])
	gut.p("%6s | %8s | %8s %8s %8s" % ["dist", "taught", "4 m/s", "6 m/s", "8 m/s"])
	var rows := {}
	for speed: float in RUSH_SPEEDS:
		for d: float in [12.0, 10.0, 8.0, 6.0, 4.5, 3.0, 2.0]:
			_skate_in(0.0, speed, d, true)
			var key: String = "%.1f" % d
			if not rows.has(key):
				rows[key] = []
			(rows[key] as Array).append(_ctrl._current_depth)
	for d: float in [12.0, 10.0, 8.0, 6.0, 4.5, 3.0, 2.0]:
		var got: Array = rows["%.1f" % d]
		gut.p("%6.1f | %8.2f | %8.2f %8.2f %8.2f"
				% [d, GoalieBehaviorRules.rush_retreat_depth(d, cfg),
				got[0], got[1], got[2]])
	assert_true(true, "report")


func test_report_rush_beatability_vs_xg() -> void:
	var hw: float = GameRules.NET_HALF_WIDTH - GameRules.NET_POST_RADIUS \
			- GameRules.PUCK_COLLISION_RADIUS
	var keys: Array[String] = []
	var measured := {}
	var baseline := {}
	for lane: float in RUSH_LANES_DEG:
		for rel: float in RUSH_RELEASE_DISTS:
			var goals: int = 0
			var shots: int = 0
			var spot := Vector3.ZERO
			for loft: int in LOFTS:
				for i: int in RUSH_AIMS:
					var t: float = float(i) / float(RUSH_AIMS - 1)
					var aim := Vector3(lerpf(-hw, hw, t), 0.0, GOAL_Z)
					spot = _skate_in(lane, 6.0, rel, true)
					# Quick wrister off the rush — the bots' own charge length.
					_h.publish_windup(spot, aim, loft, 0.9, WRISTER_WINDUP_TICKS)
					if _h.fire_release(spot, aim, loft, 0.9, 0.0) == Harness.GOAL:
						goals += 1
					shots += 1
			var key: String = "%.0f|%.0f" % [rel, lane]
			keys.append(key)
			measured[key] = float(goals) / float(maxi(shots, 1))
			baseline[key] = XGBaseline.for_shot(
					spot.x, spot.z, 0, ShotEvent.ShotType.SHOT)
	var m_sum: float = 0.0
	var b_sum: float = 0.0
	for key: String in keys:
		m_sum += measured[key]
		b_sum += baseline[key]
	var m_avg: float = maxf(m_sum / float(maxi(keys.size(), 1)), 0.0001)
	var b_avg: float = maxf(b_sum / float(maxi(keys.size(), 1)), 0.0001)
	gut.p("Shooting ON THE MOVE off a 6 m/s rush, quick wrister. Columns match the")
	gut.p("static grid's: each normalised by its own mean, so only shape compares.")
	gut.p("%6s %6s | %7s %7s | %7s %7s | %6s"
			% ["relD", "lane", "live", "liveN", "xG", "xgN", "rel"])
	for key: String in keys:
		var parts: PackedStringArray = key.split("|")
		var m: float = measured[key]
		var b: float = baseline[key]
		gut.p("%6s %6s | %7.3f %7.2f | %7.3f %7.2f | %6.2f"
				% [parts[0], parts[1], m, m / m_avg, b, b / b_avg,
				(m / m_avg) / maxf(b / b_avg, 0.0001)])
	assert_true(true, "report")


# ── THE DEKE — the mechanism that actually beats a goalie in tight ───────────
# The rush sweep leaves one question standing: our keeper reads 0.000 at 3 m
# where xG peaks, and the coverage geometry says he is simply bigger than the
# mouth from there. But a real 3 m chance is almost never a clean shot — it is a
# lateral MOVE. So before concluding "he is too big", measure the thing that is
# supposed to beat him and see whether it does.
#
# The comparison is deliberately paired: the SAME release point and the SAME
# aim x loft space, reached two ways.
#   STATIC — settled there, goalie settled with him. The static grid's case.
#   DEKE   — arrives there via a lateral cut at `speed`, goalie tracking the
#            whole way, so `lateral_tracking_cap` and `is_beaten_wide` are live.
# The difference between the two columns IS what the move bought. If the deke
# column is also ~0, he is too big and no amount of playmaking opens him. If it
# converts, then 0.000 on a stationary 3 m shot is a statement about a shot
# nobody takes, not about the keeper.
const DEKE_APPROACH_DIST: float = 8.0
const DEKE_CUT_FROM_DIST: float = 4.0
const DEKE_RELEASE_DIST: float = 3.0
const DEKE_LATERAL_M: float = 1.5
const DEKE_SPEEDS: Array[float] = [2.0, 4.0, 6.0]
const DEKE_AIMS: int = 13


# Cut laterally from the centre line to (side * DEKE_LATERAL_M, DEKE_RELEASE_DIST)
# at `speed`, closing as it goes. Returns the release position.
func _deke_to(side: float, speed: float) -> Vector3:
	_skate_in(0.0, 6.0, DEKE_CUT_FROM_DIST, true)
	var from := Vector3(0.0, 0.0, GOAL_Z + DEKE_CUT_FROM_DIST)
	var to := Vector3(side * DEKE_LATERAL_M, 0.0, GOAL_Z + DEKE_RELEASE_DIST)
	var span: float = from.distance_to(to)
	var dir: Vector3 = (to - from) / maxf(span, 0.0001)
	var vel: Vector3 = dir * speed
	var dt: float = 1.0 / 120.0
	var travelled: float = 0.0
	var guard: int = 0
	while travelled < span and guard < 2000:
		travelled += speed * dt
		var pos: Vector3 = from + dir * minf(travelled, span)
		_shooter_ref().global_position = pos
		_shooter_ref().velocity = vel
		_puck_ref().global_position = pos
		_puck_ref().linear_velocity = Vector3.ZERO
		_ctrl._physics_process(dt)
		guard += 1
	return to


# Fire the whole aim x loft space from `spot` and return the scoring fraction.
# `deke_speed` <= 0 means the static arm (settle there instead of cutting to it).
func _release_fraction(spot: Vector3, side: float, deke_speed: float,
		stick: bool = true) -> float:
	var hw: float = GameRules.NET_HALF_WIDTH - GameRules.NET_POST_RADIUS \
			- GameRules.PUCK_COLLISION_RADIUS
	var goals: int = 0
	var shots: int = 0
	for loft: int in LOFTS:
		for i: int in DEKE_AIMS:
			var t: float = float(i) / float(DEKE_AIMS - 1)
			var aim := Vector3(lerpf(-hw, hw, t), 0.0, GOAL_Z)
			var release: Vector3 = spot
			if deke_speed > 0.0:
				release = _deke_to(side, deke_speed)
			else:
				_h.settle_ready(spot)
			_h.publish_windup(release, aim, loft, 0.9, WRISTER_WINDUP_TICKS)
			_goalie.set_stick_collision_enabled(stick)
			if _h.fire_release(release, aim, loft, 0.9, 0.0) == Harness.GOAL:
				goals += 1
			_goalie.set_stick_collision_enabled(true)
			shots += 1
	return float(goals) / float(maxi(shots, 1))


func test_report_deke_vs_static_in_tight() -> void:
	var spot_l := Vector3(-DEKE_LATERAL_M, 0.0, GOAL_Z + DEKE_RELEASE_DIST)
	var spot_r := Vector3(DEKE_LATERAL_M, 0.0, GOAL_Z + DEKE_RELEASE_DIST)
	gut.p("Paired at the SAME release point (%.1f m lateral, %.1f m out)."
			% [DEKE_LATERAL_M, DEKE_RELEASE_DIST])
	gut.p("static = settled there. deke = arrived via a lateral cut from %.1f m."
			% [DEKE_CUT_FROM_DIST])
	gut.p("no-stick repeats the 6 m/s cut with the three stick colliders off —")
	gut.p("the counterfactual test_goalie_exhaustive_beatability already uses.")
	gut.p("%6s | %8s | %8s %8s %8s | %10s"
			% ["side", "static", "cut 2", "cut 4", "cut 6", "cut 6 no-stick"])
	for pair: Array in [["left", -1.0, spot_l], ["right", 1.0, spot_r]]:
		var side: float = pair[1]
		var spot: Vector3 = pair[2]
		var stat: float = _release_fraction(spot, side, -1.0)
		var got: Array[float] = []
		for sp: float in DEKE_SPEEDS:
			got.append(_release_fraction(spot, side, sp))
		var nostick: float = _release_fraction(spot, side, 6.0, false)
		gut.p("%6s | %7.1f%% | %7.1f%% %7.1f%% %7.1f%% | %9.1f%%"
				% [pair[0], 100.0 * stat, 100.0 * got[0], 100.0 * got[1],
				100.0 * got[2], 100.0 * nostick])
	assert_true(true, "report")
