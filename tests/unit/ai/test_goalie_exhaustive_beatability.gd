extends GutTest

# ── CAN THE SET KEEPER BE BEATEN AT ALL? ─────────────────────────────────────
# Every other instrument here fires the shot the BOT chose. That answers "is the
# bot's pick good", never "is there a pick that works" — so a 0/24 could equally
# mean the keeper is a wall or the bot is aiming badly. This separates them by
# brute force: from a fixed spot against a set, squared keeper, fire the entire
# shot space with PERFECT execution (zero scatter) and count what gets in.
#
# aim x   — every 7 cm across the mouth, post to post
# loft    — FLAT / LOW / HIGH
# speed   — 65 / 70 / 75 mph (see SHOT_MPH)
#
# If nothing scores, the keeper is genuinely unbeatable when set and the bots
# refusing to shoot is correct play, not a modelling bug. If something scores,
# that cell IS the hole, and the planner should be finding it.
#
# ── SHOT SPACE COVERED (and what is NOT) ─────────────────────────────────────
# power_t 0.2/0.4/0.6/0.8/1.0 over the WRISTER band (GameRules 10-33 m/s):
#   14.6, 19.2, 23.8, 28.4, 33.0 m/s  =  32.7, 42.9, 53.2, 63.5, 73.8 mph
# Loft costs a little horizontal pace (HIGH's 4.65 m/s of vertical launch drops
# vh by ~0.3-0.8 m/s).
#
# NOT COVERED: the SLAPSHOT band (20-40 m/s, up to 89.5 mph). The top ~7 m/s of
# the game's shot power never appears in this sweep, and at 6 m a 40 m/s shot
# arrives in ~0.15 s — inside the keeper's arm read. Any conclusion here is
# about WRISTERS only.
#
# ── WHAT IT MEASURED (2026-07, at 65/70/75/80 mph) ───────────────────────────
# STANDARD SPOT: dead centre between the end-zone faceoff dots, 6.096 m out
# (GameRules.ICING_FACEOFF_DOT_Z — 20 ft, NHL spec). Picked because a human can
# stand there and replicate it by feel.
#
#   DOT LINE   FLAT |pppppppssssssssssssppppp|   0 goals
#   6.10 m     LOW  |Gppppssssssssssssspppppp|   1 goal
#              HIGH |GGsssssspppGGppppppppppG|  15 goals
#              -> 16/288 (5.6%)   LIVE rebounds 270 (93.8%)
#              first contact: PAD 147, STICK 123, CHEST 2, GLOVE 0
#
#   slot 3.0 m  all three rows solid stick -> 0/288 (0.0%)
#              LIVE rebounds 288 (100.0%), first contact STICK 288
#   slot 9.0 m  -> 38/288 (13.2%), LIVE rebounds 216 (75.0%)
#
# THREE THINGS, once the unrealistically slow shots are dropped:
#
#  1. ONLY HIGH WORKS from the dot line — 15 of the 16 goals. FLAT scores zero
#     and LOW scores once. At real pace the low game is completely shut.
#
#  2. 93.8% OF SHOTS LEAVE A LIVE PUCK, and from 3 m it is 100%. That is the
#     model working as designed rather than a defect: only a glove CATCH ends a
#     play, and the glove takes 2 of 288 shots from here. The keeper is a wall
#     to the first shot and a rebound machine on the same play, which is why he
#     plays differently than a save percentage reads. Where those rebounds GO is
#     the question this sweep cannot answer — see
#     test_goalie_rebound_destination.
#
#     (Read before the rebound model became material-based, this number was
#     evidence of something else: a speed threshold decided whether a pad save
#     was "controlled", and it sat at 28.0 m/s while real shots start at 65 —
#     so the controlled branch never once ran at a real shot speed. It only
#     fired on dumps and tricklers, where it invented a 5 m/s exit out of a puck
#     that arrived at one. That threshold is gone.)
#
#  3. From 3 m nothing goes in at all, at any legal speed, and all 288 first
#     contacts are STICK — but that is ANGLE COMPRESSION, not stick reach.
#     Measured contact positions show the blade covering a FIXED band of about
#     +/-0.22 m in the goalie's local x at BOTH 3 m and 6.1 m; it never widens.
#     From 3 m he stands 1.68 m out of a 3 m shot, so every aim from post to
#     post crosses his plane inside +/-0.20 m and funnels through that band. At
#     the dot line the same band only takes the middle half of the aim points
#     and the outer ones are PAD.
#
# ── THE HUMAN MECHANISM CHANGES THE ANSWER ───────────────────────────────────
# The sweeps above fire COLD: the puck appears already in flight, so the keeper
# gets no windup to read — no pre-lean, no pre-arm. That is not what a player
# executes. A human skates in, holds LMB (which freezes the blade and publishes
# predicted_shot_velocity for the goalie to lean on), then releases.
#
# Same grid through the real charge/release path, settled first so he is square
# before the trigger is pulled:
#
#   cold fire (no windup)   16/288  ( 5.6%)
#   held windup 0.25 s      28/288  ( 9.7%)
#   held windup 0.50 s      25/288  ( 8.7%)
#
# HOLDING THE WINDUP MAKES HIM EASIER TO BEAT, and it is not a settling
# artifact — he is fully set in both. The pre-lean COMMITS him, and on an honest
# shot that commitment costs more than the early read gains:
#
#   cold   FLAT |pppppppssssssssssssppppp|   0 goals
#   held   FLAT |ppsssssssssssssGGGGppppp|  13 goals
#
# Thirteen FLAT goals open at aim x +0.21..+0.42 — his GLOVE side, low (recall
# the 180 deg rotation: world +x is local -x, the glove). A low glove-side
# window exists against a held windup that does not exist against a cold shot.
#
# This is the honest-shot case. The disguise instrument
# (test_goalie_disguise_read.gd) covers what happens when the declared aim and
# the real one DISAGREE, which should widen the same seam further.
#
# ── THE SCOPE THAT MATTERED MOST: rebounds are TERMINAL here ─────────────────
# This instrument stops at FIRST goalie contact, so every rebound goal in a real
# game reads as a save. That is not a footnote — it inverts the conclusion:
#
#   slot 3.0 m        0.8% scored  |  LIVE rebounds 95.6% of all shots
#   slot 5.0 m        3.3%         |  63.1%
#   off-angle 5.3 m   4.2%         |  65.0%
#
# Only a glove catch ends a play; every other surface rebounds off its material.
# So the keeper who stops 99.2% of in-tight shots leaves the puck LOOSE on 95.6%
# of them. He is a wall to the first shot and a rebound machine on the same play,
# which is exactly why he plays differently than these numbers read.
#
# TWO CONSEQUENCES:
#   * "bots refusing to shoot at a set keeper is correct play" — stated earlier
#     in this branch — is WRONG. Shooting to generate a second chance is the
#     dominant in-tight play, and score_shoot prices only the FIRST shot, so it
#     under-values shooting by whatever the rebound is worth.
#   * Our stick is the inverse of a real one. Real goaltending uses the stick to
#     STEER rebounds to the corners and into the chest; ours stops everything and
#     controls nothing, because the rules exempt STICK from deadening entirely.
#
# Note the counterfactual inverts too: without the stick, live rebounds FALL to
# ~28-34%, because the pads deaden what the stick was kicking loose.
#
# ── COUNTERFACTUAL: how much of the wall IS the stick ────────────────────────
# Same sweep with all three stick colliders disabled:
#
#   with stick     30/1080   ( 2.8%)
#   without stick 226/1080   (20.9%)
#
# A 7.5x swing. The stick is not a garnish on this keeper, it is the majority of
# him. And note WHERE the goals appear without it: dead centre, every loft — the
# five-hole and the low middle. That part is realistic (guarding the slot IS the
# stick blade's job). What is not realistic is that with the stick ON, the low
# corners are shut too: at 3 m the FLAT and LOW rows are stick-saves at EVERY
# aim point out to both posts.
#
# Goalie.tscn carries THREE stick colliders — shaft (0.03 x 0.50), PADDLE
# (0.10 x 0.66) and blade (0.38 x 0.07). GoalieStickRules models only the blade,
# so the planner's "stick" is the smallest of the three; the paddle is the long
# surface doing much of this work. Disabling the blade alone still left 14.2%
# (STICK saves persisted) — it took all three to reach 20.9%.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SETTLE_TICKS: int = 90
# THE STANDARD SPOT: dead centre between the end-zone faceoff dots. Derived, not
# picked — the dots sit at GameRules.ICING_FACEOFF_DOT_Z, which is 6.096 m
# (20 ft, NHL spec) out from the goal line, so x = 0 on that line is the high
# slot. Chosen because it is a spot a human can stand on and replicate by feel,
# which is the only way to check these numbers against how he actually plays.
const SLOT_DIST_M: float = GameRules.GOAL_LINE_Z - GameRules.ICING_FACEOFF_DOT_Z
# Speeds people actually shoot at, in mph — the units the game reports back, so
# these can be matched by hand. The slow end of a normalized power band (a
# 33 mph wrister) is not a shot anybody takes and only pollutes the picture.
# 75 and 80 mph are above the NEUTRAL wrister ceiling (DEFAULT_WRISTER_POWER_MAX
# = 33.0 m/s = 73.8 mph) but are reachable on a wrister with height / weight /
# stick-flex modifiers, so the whole band is wrister-legal on some build. 69 mph
# is the reference build being played against.
#
# Worth knowing when reading LIVE rebound counts off this sweep: every speed here
# is a genuine shot, so nothing in it samples the soft contacts (dumps, passes,
# tricklers dying into the pads) where the rebound model's slow end lives.
const SHOT_MPH: Array[float] = [65.0, 70.0, 75.0, 80.0]
const MPH_TO_MS: float = 0.44704
const MAX_AIM: float = GameRules.NET_HALF_WIDTH \
		- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null
# Save-surface labels, DERIVED from the enum. A hand-kept copy goes stale the
# moment a part is added — MASK split from CHEST and every such list started
# reporting "?" for it.
static var _part_names: Array = GoalieSaveRules.SavePart.keys()


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


func _sweep(spot: Vector3, label: String) -> int:
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_HIGH,
	]
	var loft_names: Array[String] = ["FLAT", "LOW ", "HIGH"]
	var shots: int = 0
	var goals: int = 0
	var live: int = 0     # saves that leave the puck LOOSE (a second chance)
	var parts: Dictionary = {}
	# Per-loft goal map, so a hole shows up as a REGION rather than a count.
	for li: int in lofts.size():
		var row: String = ""
		var row_goals: int = 0
		var a: float = -MAX_AIM
		while a <= MAX_AIM + 0.001:
			var best: String = "."
			for mph: float in SHOT_MPH:
				_ctrl.reset_to_crease()
				_h.settle(spot, SETTLE_TICKS)
				var o: int = _h.fire_at(
						spot, Vector3(a, 0.0, GOAL_Z), lofts[li], mph * MPH_TO_MS, 0.0)
				shots += 1
				if o == Harness.GOAL:
					goals += 1
					row_goals += 1
					best = "G"
				elif o == Harness.SAVE:
					var k: String = _part_names[_h.last_part] if _h.last_part >= 0 else "?"
					parts[k] = int(parts.get(k, 0)) + 1
					# Did that save leave a LIVE puck? A glove catch ends the play and a
					# chest smother kills the shot dead for the sweep; every other
					# surface is a material rebound, so the slot is a scramble.
					if not _h.last_caught and not _h.last_trapped:
						live += 1
					if best == ".":
						best = k.substr(0, 1).to_lower()
				elif best == ".":
					best = "x"   # post / wide
			row += best
			a += 0.07
		gut.p("   %s |%s| %d goals" % [loft_names[li], row, row_goals])
	gut.p("%s: %d/%d scored (%.1f%%)   LIVE rebounds %d (%.1f%% of all shots)   saves:%s"
			% [label, goals, shots, 100.0 * float(goals) / float(maxi(shots, 1)),
			live, 100.0 * float(live) / float(maxi(shots, 1)), str(parts)])
	gut.p("        legend: G=goal  s=stick  p=pad  b=blocker  c=chest  g=glove  x=post/wide")
	gut.p("        FIRST-CONTACT parts above are what TOUCHES the puck first — the")
	gut.p("        instrument stops there, so a live rebound still reads as a save.")
	return goals


func test_can_anything_beat_the_set_keeper_from_the_slot() -> void:
	gut.p("Exhaustive shot space, PERFECT execution, set + squared keeper.")
	gut.p("Columns are aim x from -0.84 to +0.84 in 7 cm steps; each cell is the")
	gut.p("best outcome over 65/70/75/80 mph.")
	gut.p("STANDARD SPOT: dead centre between the faceoff dots, %.3f m out." % SLOT_DIST_M)
	_sweep(Vector3(0.0, 0.0, GOAL_Z + SLOT_DIST_M), "DOT LINE %.2f m" % SLOT_DIST_M)
	# Kept either side of it for context on how fast the picture changes.
	_sweep(Vector3(0.0, 0.0, GOAL_Z + 3.0), "slot 3.0 m")
	_sweep(Vector3(0.0, 0.0, GOAL_Z + 9.0), "slot 9.0 m")
	assert_true(true, "report")


# THE HUMAN MECHANISM: skate in, hold LMB (goalie pre-leans off the declared
# aim and builds his pre-arm read), release at the target without deceiving.
# The sweeps above fire cold — no windup, so no pre-arm — which is NOT what a
# player executes. This runs the identical grid through the real charge/release
# path so the keeper gets everything he gets against a human.
func test_report_the_sweep_a_human_can_actually_execute() -> void:
	var spot := Vector3(0.0, 0.0, GOAL_Z + SLOT_DIST_M)
	var max_aim: float = GameRules.NET_HALF_WIDTH \
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_HIGH,
	]
	var names: Array[String] = ["FLAT", "LOW ", "HIGH"]
	gut.p("HELD WINDUP -> honest release (declared aim == real aim), dot line.")
	for hold_ticks: int in [30, 60]:
		gut.p("  hold %.2f s:" % (float(hold_ticks) / 120.0))
		var total: int = 0
		var shots: int = 0
		var parts: Dictionary = {}
		for li: int in lofts.size():
			var row: String = ""
			var g: int = 0
			var a: float = -max_aim
			while a <= max_aim + 0.001:
				var best: String = "."
				for mph: float in SHOT_MPH:
					var aim := Vector3(a, 0.0, GOAL_Z)
					# Set up FIRST, exactly as a player does, then hold.
					_ctrl.reset_to_crease()
					_h.settle(spot, SETTLE_TICKS)
					_h.hold_windup_at(spot, aim, lofts[li], mph * MPH_TO_MS, hold_ticks)
					var o: int = _h.fire_release_at(
							spot, aim, lofts[li], mph * MPH_TO_MS, 0.0)
					shots += 1
					if o == Harness.GOAL:
						g += 1
						total += 1
						best = "G"
					elif o == Harness.SAVE:
						var k: String = _part_names[_h.last_part] if _h.last_part >= 0 else "?"
						parts[k] = int(parts.get(k, 0)) + 1
						if best == ".":
							best = k.substr(0, 1).to_lower()
					elif best == ".":
						best = "x"
				row += best
				a += 0.07
			gut.p("     %s |%s| %d goals" % [names[li], row, g])
		gut.p("     -> %d/%d (%.1f%%)   %s"
				% [total, shots, 100.0 * float(total) / float(maxi(shots, 1)), str(parts)])
	assert_true(true, "report")


# COUNTERFACTUAL: the same sweep with the blade collider switched off. Not a
# proposal — a measurement of how much of the wall the stick actually is, which
# is the number that says whether a weak side is a tweak or a rewrite.
func test_report_how_much_of_the_wall_is_the_stick() -> void:
	# ALL THREE stick colliders — Goalie.tscn carries a shaft (0.03 x 0.50), a
	# PADDLE (0.10 x 0.66) and the blade (0.38 x 0.07). GoalieStickRules models
	# only the blade, so "stick" in the planner is the smallest of the three; the
	# paddle is the long surface that lies across the ice.
	var parts: Array[CollisionShape3D] = []
	for n: String in ["StickShaftCollider", "StickPaddleCollier", "StickBladeCollider"]:
		var cs: CollisionShape3D = _goalie.find_child(n, true, false) as CollisionShape3D
		assert_not_null(cs, "found %s" % n)
		if cs != null:
			cs.disabled = true
			parts.append(cs)
	gut.p("SAME sweep, STICK BLADE REMOVED (counterfactual, not a proposal).")
	var a: int = _sweep(Vector3(0.0, 0.0, GOAL_Z + SLOT_DIST_M),
			"no-stick DOT LINE %.2f m" % SLOT_DIST_M)
	var n: int = 24 * 3 * SHOT_MPH.size()
	gut.p("NO-STICK at the dot line: %d/%d (%.1f%%)" % [a, n, 100.0 * float(a) / float(n)])
	for cs: CollisionShape3D in parts:
		cs.disabled = false
