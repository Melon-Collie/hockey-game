extends GutTest

# ── WHERE DOES THE REBOUND GO? ───────────────────────────────────────────────
# The beatability sweep classifies saves as "live" or "deadened", which turns
# out to be the wrong question. Live does not mean dangerous:
#
#   * a hard shot off a TOED-OUT PAD is live AND safe — the pose angle
#     (pad_toe_out_standing / _butterfly) sends it to the corner, which is
#     exactly what those angles exist for;
#   * a CHEST save is dead by construction — he smothers it and puts it down for
#     the crease sweep, so the puck never becomes a rebound at all;
#   * a STICK save is the dangerous one, and not because of its restitution: the
#     blade has no lateral cant, so it sends the puck back where it came from —
#     and seating it flat on the ice made that WORSE, not better (56% back at the
#     shooter against 53%), because a square flat face is a mirror. Pitch and
#     cant are separate levers and only the second one steers.
#
# So the measurement is DESTINATION, not restitution. This applies the real save
# response (GoalieSaveRules.resolve_contact + the flush eject, the same pair
# Puck._physics_process runs) and tracks the rebound until it LEAVES the danger
# area or comes to rest in it.
#
# ── WHAT IT MEASURES, AND WHAT IT CANNOT ─────────────────────────────────────
#   surface | saves | rebound STAYS in the slot
#   PAD     |    95 |    50  (53%)
#   STICK   |   111 |    47  (42%)
#   BLOCK   |    15 |     5  (33%)
#   CHEST   |     4 |     4  (100%)
#   GLOVE   |    28 |    28  (100%)
#   TOTAL   |   253 |   134  (53%)     goals 35/288
#
# ONE SPOT ON THE CENTRE LINE, which bounds every conclusion drawn from it. A
# square keeper takes a centred puck on the pads and the stick, so the sample is
# dominated by those two and the chest is n=4 — too thin to rank. An earlier
# reading of this table concluded the STICK was what drove net-front scrambles,
# on the strength of it taking more saves than everything else combined and
# clearing worse than the pads. Swept across the whole shot map
# (test_report_rebound_baseline_across_the_shot_map, below) that inverts: the
# stick clears BEST of any surface, and the surfaces resolved by script keep the
# puck in the slot. The spot was doing the work, not the surface.
#
# Kept as the in-tight centre-line slice, and read only as that.
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
	_h.danger_radius_m = SLOT_RADIUS_M


func _in_danger(p: Vector3) -> bool:
	if not p.is_finite():
		return false
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	# In FRONT of the goal line. The radius alone counts a puck behind the net as
	# a slot chance, and behind the net there is no shot to take.
	if absf(p.z) > GameRules.GOAL_LINE_Z:
		return false
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
				var k: String = _part_names[_h.last_part] if _h.last_part >= 0 else "?"
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


# ── THE BASELINE INSTRUMENT ──────────────────────────────────────────────────
# The report above fires every shot from ONE spot on the centre line, which is
# why it sees n=2 chest saves and zero glove: a square keeper takes a centred
# puck on the pads and the stick, and the hands never enter it. Half the save
# surfaces are therefore unmeasured by it, and a rebound model cannot be judged
# on the half that happens to be sampled.
#
# This one sweeps SPOTS as well as aims — real looks at real ranges and angles,
# so every surface gets the pucks it would actually see — and reports four
# numbers per surface rather than one:
#
# A SAVE IS A SEQUENCE, and the columns follow it. The goalie's next beat is part
# of the save: a puck that dies in front of him is one he SWEEPS to the corner,
# and a puck he gets a hand on is one he HOLDS. Only what survives both is a
# second chance.
#
#   HELD    he ended the play with it — a glove catch, or a cover smother.
#   SWEPT   he played it away with the stick. Both are the goalie dealing with
#           his own rebound, and both are excluded from STAYS below.
#   STAYS   nobody dealt with it and it never left the danger area — it came to
#           rest in there. THIS is the scramble number.
#   DWELL   seconds the rebound spent inside the danger area on its way out. A
#           puck crossing the slot and a puck sitting in it are different
#           problems, and STAYS alone cannot tell them apart.
#   ->SHOOTER  it came back within a stick of the man who just shot it. The
#           DIRECTION number, and the one the pose actually controls: a rebound
#           to the corner and a rebound straight back up the slot can settle the
#           same distance from the net.
#   OWN     it went into his own net.
#
# Attribution is to the FIRST surface struck, so a pad save gloved on the way
# down is a HELD row under PAD; that is the sequence, not a misclassification.
#
# READ STAYS AS THE DANGER, not OWN. There is no second shooter in this harness,
# so OWN can only catch the goalie beating himself — a rebound that finds the net
# off his own body with nobody touching it. Rare by construction, and a zero
# there says nothing about whether the crease is a scramble.
const SPOTS: Array[Vector3] = [
	Vector3(0.0, 0.0, 3.0),     # doorstep, centre
	Vector3(0.0, 0.0, 6.4),     # slot / dot line
	Vector3(0.0, 0.0, 10.0),    # high slot
	Vector3(0.0, 0.0, 16.0),    # point
	Vector3(5.5, 0.0, 8.0),     # strong-side circle
	Vector3(-5.5, 0.0, 8.0),    # weak-side circle
	Vector3(8.5, 0.0, 4.0),     # sharp angle, off the goal line
]
const BASELINE_MPH: Array[float] = [65.0, 75.0, 85.0]
const AIM_FRACTIONS: Array[float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
# Within a stick of the shooter counts as "it came back to him".
const BACK_AT_SHOOTER_M: float = 1.8


func test_report_rebound_baseline_across_the_shot_map() -> void:
	var max_aim: float = GameRules.NET_HALF_WIDTH \
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_MID,
		ShotMechanics.ELEVATION_HIGH,
	]
	# Per surface: [saves, held, swept, stayed, own, dwell sum, back-at-shooter].
	var by_part: Dictionary = {}
	var shots: int = 0
	var first_goals: int = 0
	var own_goals: int = 0
	for spot: Vector3 in SPOTS:
		var from := Vector3(spot.x, 0.0, GOAL_Z + spot.z)
		for loft: int in lofts:
			for frac: float in AIM_FRACTIONS:
				for mph: float in BASELINE_MPH:
					_ctrl.reset_to_crease()
					_h.settle(from, SETTLE_TICKS)
					var o: int = _h.fire_tracking_rebound(
							from, Vector3(frac * max_aim, 0.0, GOAL_Z), loft,
							mph * MPH_TO_MS, 0.0)
					shots += 1
					if o != Harness.SAVE:
						if o == Harness.GOAL:
							first_goals += 1
						continue
					var k: String = _part_names[_h.last_part] if _h.last_part >= 0 else "?"
					if not by_part.has(k):
						by_part[k] = [0, 0, 0, 0, 0, 0.0, 0]
					var row: Array = by_part[k]
					row[0] += 1
					if _h.rebound_caught or _h.rebound_held:
						row[1] += 1
						continue
					if _h.rebound_swept:
						row[2] += 1
						continue
					if _in_danger(_h.rebound_pos):
						row[3] += 1
					if _h.rebound_goal:
						row[4] += 1
						own_goals += 1
					row[5] += _h.rebound_danger_dwell_s
					if _h.rebound_min_dist_to_shooter <= BACK_AT_SHOOTER_M:
						row[6] += 1
	gut.p("%d spots x %d lofts x %d aims x %d speeds (65-85 mph), perfect execution."
			% [SPOTS.size(), lofts.size(), AIM_FRACTIONS.size(), BASELINE_MPH.size()])
	gut.p("  surface | saves | HELD | SWEPT | loose | STAYS | DWELL | ->SHOOTER | OWN")
	var totals := [0, 0, 0, 0, 0, 0.0, 0]
	for k: String in _part_names:
		if not by_part.has(k):
			gut.p("  %-7s |     0 |    0 |     0 |     0 |    -- |    -- |        -- |  --" % k)
			continue
		var row: Array = by_part[k]
		for i: int in 7:
			totals[i] += row[i]
		var loose: int = row[0] - row[1] - row[2]
		gut.p("  %-7s | %5d | %4d | %5d | %5d | %5d | %5.2fs | %4d (%3.0f%%) | %3d" % [
			k, row[0], row[1], row[2], loose, row[3],
			row[5] / float(maxi(loose, 1)),
			row[6], 100.0 * float(row[6]) / float(maxi(loose, 1)), row[4]])
	var all_loose: int = totals[0] - totals[1] - totals[2]
	gut.p("  TOTAL   | %5d | %4d | %5d | %5d | %5d | %5.2fs | %4d (%3.0f%%) | %3d" % [
		totals[0], totals[1], totals[2], all_loose, totals[3],
		totals[5] / float(maxi(all_loose, 1)),
		totals[6], 100.0 * float(totals[6]) / float(maxi(all_loose, 1)), totals[4]])
	gut.p("  shots %d | beaten clean %d | own-net rebounds %d"
			% [shots, first_goals, own_goals])
	assert_true(true, "report")
