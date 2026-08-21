extends GutTest

# ── HOW WIDE IS THE FIVE-HOLE, REALLY? ───────────────────────────────────────
# The exhaustive sweep steps aim in 7 cm increments, and the standing five-hole
# clearance is about 7 cm (a ~0.20 m slot less the 0.13 m puck). So the sweep can
# step straight over the window and report it closed — which is what it did
# (FLAT 0 goals, LOW 1 from the dot line) while a human reports beating him
# five-hole cold, rarely but repeatably.
#
# This walks the middle of the net in 1 cm steps to find the window's real edges,
# at the reference build's actual shot speed. Reported as WORLD aim x at the goal
# line, which is the number a player can aim at.
#
# NOTE the goalie is rotated ~180 deg: world +x is his GLOVE side, world -x is
# his blocker/stick side.
#
# ── WHAT IT MEASURED (dot line, 78 mph, the reference build) ─────────────────
#   COLD      FLAT   no scoring aim anywhere in +/-0.40 m
#             LOW    no scoring aim anywhere in +/-0.40 m
#   HELD .25s FLAT   window +0.30 .. +0.40 m   (GLOVE side, >=11 cm — runs to
#                    the edge of the span, so the true window is wider)
#             LOW    window -0.15 .. -0.01 m   (15 cm — the FIVE-HOLE, just
#                    blocker-side of centre)
#
# Both windows were independently reported from real play before this ran
# ("glove side low, and hard through his 5 hole"), which is the first external
# confirmation any of these instruments have had.
#
# The COLD result is the interesting one. At 1 cm steps nothing scores, so the
# sweep was NOT stepping over the five-hole — against a FULLY SET keeper it is
# genuinely shut. Yet a human reports beating him five-hole cold, rarely. The
# likely reconciliation is that this harness always grants a full 0.75 s settle
# and a real keeper almost never gets one: mid-shuffle, mid-recovery, still
# tracking. If so the rare cold five-hole is an UNSETTLED-goalie window rather
# than a set-goalie one, which would explain both its rarity and why it cannot
# be produced on demand. Testable by varying SETTLE_TICKS — not yet done.
#
# Mechanism behind the held-windup windows: the pre-lean swings the blocker
# assembly (and the stick with it) toward the predicted impact, vacating the
# centre band the blade was guarding. Committing him is what opens both.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SLOT_DIST_M: float = GameRules.GOAL_LINE_Z - GameRules.ICING_FACEOFF_DOT_Z
const MPH_TO_MS: float = 0.44704
# The build under test shoots ~78 mph; measure at what the player actually has.
const SHOT_MPH: float = 78.0
const SETTLE_TICKS: int = 90
const STEP_M: float = 0.01
const SPAN_M: float = 0.40   # walk +/- this either side of dead centre

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


# Walk the centre of the net and report every aim that scores, plus the widest
# contiguous run of scoring aims (the window a human has to hit).
func _walk(spot: Vector3, loft: int, label: String, hold_ticks: int) -> void:
	var row: String = ""
	var goals: Array[float] = []
	var a: float = -SPAN_M
	while a <= SPAN_M + 0.0001:
		var aim := Vector3(a, 0.0, GOAL_Z)
		_ctrl.reset_to_crease()
		_h.settle(spot, SETTLE_TICKS)
		var o: int
		if hold_ticks > 0:
			_h.hold_windup_at(spot, aim, loft, SHOT_MPH * MPH_TO_MS, hold_ticks)
			o = _h.fire_release_at(spot, aim, loft, SHOT_MPH * MPH_TO_MS, 0.0)
		else:
			o = _h.fire_at(spot, aim, loft, SHOT_MPH * MPH_TO_MS, 0.0)
		if o == Harness.GOAL:
			row += "G"
			goals.append(a)
		elif o == Harness.SAVE:
			row += _part_names[_h.last_part].substr(0, 1).to_lower() \
					if _h.last_part >= 0 else "?"
		else:
			row += "x"
		a += STEP_M
	# Widest contiguous scoring run.
	var best_lo: float = 0.0
	var best_w: int = 0
	var run_lo: float = 0.0
	var run: int = 0
	var prev: float = -999.0
	for g: float in goals:
		if run > 0 and absf(g - prev - STEP_M) < 0.0005:
			run += 1
		else:
			run = 1
			run_lo = g
		if run > best_w:
			best_w = run
			best_lo = run_lo
		prev = g
	gut.p("  %-14s |%s|" % [label, row])
	if best_w > 0:
		gut.p("      widest window: %.2f .. %.2f m  (%d cm wide), %d scoring aims"
				% [best_lo, best_lo + float(best_w - 1) * STEP_M, best_w, goals.size()])
	else:
		gut.p("      no scoring aim anywhere in +/-%.2f m" % SPAN_M)


func test_report_the_five_hole_window() -> void:
	var spot := Vector3(0.0, 0.0, GOAL_Z + SLOT_DIST_M)
	gut.p("Dot line %.2f m, %.0f mph, 1 cm aim steps across +/-%.2f m of centre."
			% [SLOT_DIST_M, SHOT_MPH, SPAN_M])
	gut.p("World +x = GLOVE side. Row runs -%.2f (blocker) .. +%.2f (glove)."
			% [SPAN_M, SPAN_M])
	gut.p("COLD (no windup held) — the rarer shot:")
	_walk(spot, ShotMechanics.ELEVATION_FLAT, "FLAT", 0)
	_walk(spot, ShotMechanics.ELEVATION_LOW, "LOW", 0)
	gut.p("HELD 0.25 s windup — the telegraphed shot:")
	_walk(spot, ShotMechanics.ELEVATION_FLAT, "FLAT", 30)
	_walk(spot, ShotMechanics.ELEVATION_LOW, "LOW", 30)
	assert_true(true, "report")
