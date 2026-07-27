extends GutTest

# ── WHERE DOES THE REBOUND GO? ───────────────────────────────────────────────
# The beatability sweep classifies saves as "live" or "deadened", which turns
# out to be the wrong question. Live does not mean dangerous:
#
#   * a hard shot off a TOED-OUT PAD is live AND safe — the pose angle
#     (pad_toe_out_standing / _butterfly) sends it to the corner, which is
#     exactly what those angles exist for;
#   * a CHEST save is deadened and DANGEROUS — GoalieSaveRules zeroes its
#     goalward and vertical motion so the puck "settles dead in front", i.e.
#     in the blue paint, which is the drop-then-scramble sequence;
#   * a STICK save is never deadened by rule, but the blade angle plus the
#     stick's restitution still throws most of them clear.
#
# So the measurement is DESTINATION, not restitution. This applies the real save
# response (GoalieSaveRules.resolve_contact + the flush eject, the same pair
# Puck._physics_process runs) and keeps marching until the puck is slow enough
# for a skater to play, then asks where that happened.
#
# ── WHAT IT MEASURED (2026-07, dot line, 65-80 mph) ──────────────────────────
#   surface | saves | rebound STAYS in the slot
#   PAD     |    94 |    38  (40%)
#   STICK   |   177 |    99  (56%)
#   CHEST   |     2 |     2  (100%)
#   TOTAL   |   273 |   139  (51%)     goals 15/288
#
# The pads DO clear: 60% of pad rebounds leave the danger area, which is the
# toe-out angle doing its job. And the chest is the worst surface per save —
# 100% stay in the paint, exactly the drop-then-scramble the deadened_velocity
# doc-block describes ("settles dead in front"). But n=2: from this range the
# chest almost never sees the puck, so it is not what drives the scrambles.
#
# THE STICK IS. It takes 177 of 273 saves — more than everything else combined —
# and clears WORSE than the pads (56% stay vs 40%). It supplies 99 of the 139
# dangerous rebounds. It is never deadened by rule, and unlike the pads it has
# no toe-out equivalent steering it cornerward, so it stops the most and
# controls the least. Real goaltending uses the stick to steer rebounds to the
# corners or into the chest; this one does neither.
#
# Also note GLOVE is absent entirely — zero catches from the dot line. The one
# surface that actually ends the play never gets the puck at this range.
#
# DANGER AREA is the home-plate slot in front of the net: within SLOT_RADIUS_M
# of the goal and inside the faceoff dots laterally. A rebound that settles
# there is a second chance; one that reaches the corner or the perimeter is a
# save that did its job.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SLOT_DIST_M: float = GameRules.GOAL_LINE_Z - GameRules.ICING_FACEOFF_DOT_Z
const SHOT_MPH: Array[float] = [65.0, 70.0, 75.0, 80.0]
const MPH_TO_MS: float = 0.44704
const SETTLE_TICKS: int = 90
# Danger area: inside the dots laterally, and no further out than the dot line.
const SLOT_HALF_WIDTH_M: float = GameRules.END_ZONE_FACEOFF_DOT_X
const SLOT_RADIUS_M: float = GameRules.GOAL_LINE_Z - GameRules.ICING_FACEOFF_DOT_Z

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


func _in_danger(p: Vector3) -> bool:
	if not p.is_finite():
		return false
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	return absf(p.x) <= SLOT_HALF_WIDTH_M \
			and Vector2(p.x - goal.x, p.z - goal.z).length() <= SLOT_RADIUS_M


func test_report_rebound_destination_by_save_surface() -> void:
	var spot := Vector3(0.0, 0.0, GOAL_Z + SLOT_DIST_M)
	var max_aim: float = GameRules.NET_HALF_WIDTH \
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_HIGH,
	]
	# Per first-contact surface: [saves, rebounds that stayed in the danger area]
	var by_part: Dictionary = {}
	var goals: int = 0
	var shots: int = 0
	for li: int in lofts.size():
		var a: float = -max_aim
		while a <= max_aim + 0.001:
			for mph: float in SHOT_MPH:
				_ctrl.reset_to_crease()
				_h.settle(spot, SETTLE_TICKS)
				var o: int = _h.fire_tracking_rebound(
						spot, Vector3(a, 0.0, GOAL_Z), lofts[li], mph * MPH_TO_MS, 0.0)
				shots += 1
				if o == Harness.GOAL or _h.rebound_goal:
					goals += 1
					continue
				if o != Harness.SAVE:
					continue
				var k: String = PART[_h.last_part] if _h.last_part >= 0 else "?"
				if not by_part.has(k):
					by_part[k] = [0, 0]
				var row: Array = by_part[k]
				row[0] += 1
				if _in_danger(_h.rebound_pos):
					row[1] += 1
			a += 0.07
	gut.p("Dot line %.2f m, 65-80 mph, perfect execution. Danger area = inside the"
			% SLOT_DIST_M)
	gut.p("faceoff dots laterally and within %.2f m of the goal." % SLOT_RADIUS_M)
	gut.p("  surface | saves | rebound STAYS in the slot")
	var total_saves: int = 0
	var total_danger: int = 0
	for k: String in by_part.keys():
		var row: Array = by_part[k]
		total_saves += row[0]
		total_danger += row[1]
		gut.p("  %-7s | %5d | %5d  (%.0f%%)"
				% [k, row[0], row[1], 100.0 * float(row[1]) / float(maxi(row[0], 1))])
	gut.p("  TOTAL   | %5d | %5d  (%.0f%%)     goals %d/%d"
			% [total_saves, total_danger,
			100.0 * float(total_danger) / float(maxi(total_saves, 1)), goals, shots])
	assert_true(true, "report")
