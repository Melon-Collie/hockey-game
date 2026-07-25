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
# power   — the full wrister band
#
# If nothing scores, the keeper is genuinely unbeatable when set and the bots
# refusing to shoot is correct play, not a modelling bug. If something scores,
# that cell IS the hole, and the planner should be finding it.
#
# ── WHAT IT MEASURED (2026-07) ───────────────────────────────────────────────
#                     aim x:  -0.84 ....... 0 ....... +0.84
# slot 3.0 m   FLAT |ssssssssssssssssssssssss|  0 goals
#              LOW  |ssssssssssssssssssssssss|  0 goals
#              HIGH |sssssssspppGGGpppppppppp|  3 goals   -> 3/360   (0.8%)
# slot 5.0 m   FLAT |ppppppsssssssssssssppppp|  0 goals
#              LOW  |ppppsssssspGGGppppsppppp|  4 goals
#              HIGH |GbbbbbbppppGGpppppgggggG|  8 goals   -> 12/360  (3.3%)
# off-angle    FLAT |ssssssssssssssssssGppppp|  1 goal
#   5.3 m      LOW  |ssssssspGGGGGppppspppppp|  9 goals
#              HIGH |bbpppppppGGppppppggggggG|  5 goals   -> 15/360  (4.2%)
#
# So he is NOT literally unbeatable — but only 0.8-4.2% of the shot space beats
# him with PERFECT execution, which a bot carrying ~0.05 rad of aim spread
# cannot reliably find. "The bots will not shoot at a set keeper" is therefore
# correct play, and matches what the calibrated shot surface says.
#
# THE MECHANISM IS THE STICK. 344 of 360 saves at 3 m are STICK. The derived
# paddle reach is 0.64 m half-width and the keeper stands 1.32 m away there, so
# projected to the goal line it spans 0.64 * 3/1.32 = 1.45 m against a 0.915 m
# net half-width: the stick ALONE covers the entire low net from the slot — and
# it does so on BOTH sides at once, because yaw_to_target swings the blade onto
# the puck line from either direction. A real goalie's paddle guards one side.
# That symmetry is the wall, and it is where the weak side goes.
#
# The windows that DO work are the honest ones: HIGH dead centre in tight (over
# the shoulder) and HIGH at both posts from range — the shots players actually
# score. Re-run this after any change to the keeper's coverage; the beatable
# fraction and WHERE it sits are the two numbers that matter.
#
# ── THE SCOPE THAT MATTERED MOST: rebounds are TERMINAL here ─────────────────
# This instrument stops at FIRST goalie contact, so every rebound goal in a real
# game reads as a save. That is not a footnote — it inverts the conclusion:
#
#   slot 3.0 m        0.8% scored  |  LIVE rebounds 95.6% of all shots
#   slot 5.0 m        3.3%         |  63.1%
#   off-angle 5.3 m   4.2%         |  65.0%
#
# GoalieSaveRules.is_controlled_save returns FALSE for STICK unconditionally — a
# stick save NEVER deadens — and PAD/BLOCKER only eat shots under the deaden
# threshold. So the keeper who stops 99.2% of in-tight shots leaves the puck
# LOOSE on 95.6% of them. He is a wall to the first shot and a rebound machine
# on the same play, which is exactly why he plays differently than these numbers
# read.
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
const MAX_AIM: float = GameRules.NET_HALF_WIDTH \
		- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null
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
	var cfg := GoalieSaveRules.DeadenConfig.new()
	cfg.pad_max_incoming_speed = _puck.save_deaden_pad_max_speed
	# Per-loft goal map, so a hole shows up as a REGION rather than a count.
	for li: int in lofts.size():
		var row: String = ""
		var row_goals: int = 0
		var a: float = -MAX_AIM
		while a <= MAX_AIM + 0.001:
			var best: String = "."
			for pt: float in [0.2, 0.4, 0.6, 0.8, 1.0]:
				_ctrl.reset_to_crease()
				_h.settle(spot, SETTLE_TICKS)
				var o: int = _h.fire(spot, Vector3(a, 0.0, GOAL_Z), lofts[li], pt, 0.0)
				shots += 1
				if o == Harness.GOAL:
					goals += 1
					row_goals += 1
					best = "G"
				elif o == Harness.SAVE:
					var k: String = PART[_h.last_part] if _h.last_part >= 0 else "?"
					parts[k] = int(parts.get(k, 0)) + 1
					# Did that save actually END the play? STICK never deadens, and
					# PAD/BLOCKER only eat shots under the deaden threshold — above
					# it the puck kicks out live and the slot is a scramble.
					if not GoalieSaveRules.is_controlled_save(
							_h.last_shot_speed, _h.last_part, cfg):
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
	return goals


func test_can_anything_beat_the_set_keeper_from_the_slot() -> void:
	gut.p("Exhaustive shot space, PERFECT execution, set + squared keeper.")
	gut.p("Columns are aim x from -0.84 to +0.84 in 7 cm steps; each cell is the")
	gut.p("best outcome over 5 power levels.")
	_sweep(Vector3(0.0, 0.0, GOAL_Z + 3.0), "slot 3.0 m")
	_sweep(Vector3(0.0, 0.0, GOAL_Z + 5.0), "slot 5.0 m")
	_sweep(Vector3(3.5, 0.0, GOAL_Z + 4.0), "off-angle 5.3 m")
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
	var a: int = _sweep(Vector3(0.0, 0.0, GOAL_Z + 3.0), "no-stick slot 3.0 m")
	var b: int = _sweep(Vector3(0.0, 0.0, GOAL_Z + 5.0), "no-stick slot 5.0 m")
	var c: int = _sweep(Vector3(3.5, 0.0, GOAL_Z + 4.0), "no-stick off-angle 5.3 m")
	gut.p("NO-STICK TOTAL: %d/1080 beat him (%.1f%%) — with the stick it was 30/1080 (2.8%%)"
			% [a + b + c, 100.0 * float(a + b + c) / 1080.0])
	for cs: CollisionShape3D in parts:
		cs.disabled = false
