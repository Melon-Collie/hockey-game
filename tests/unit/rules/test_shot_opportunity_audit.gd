extends GutTest

# Shot-opportunity audit — a distribution tripwire against shot-starvation.
#
# The per-geometry calibration table (test_ai_action_scoring.gd) pins WHICH
# looks score; this audit pins HOW OFTEN a bot has a committable shot across a
# broad grid of realistic offensive-zone situations, split by the goalie state
# that produced them. A SET, SQUARED keeper concedes only the MODEST
# quick-release band (the puck reaches his body before the drop / glove
# deploy widens his standing cover — mid-range straight-ish looks), never a
# strong chance — so the honesty line is that the set column stays capped and
# strong-free, while the states TEAM PLAY CREATES (displaced keepers off
# passes/cuts, down keepers, deep-holding keepers) stay committable at
# healthy rates. If a future model change collapses (or inflates) a column,
# this file fails before playtest does.
#
# Grid: shooters across the OZ fan (lateral x ±6, range 3–14 m), no defenders
# (the lane/pressure terms are audited elsewhere) — pure keeper-vs-shooter.

const NET := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
const FIRE_FLOOR: float = 0.02   # AIRoleCarrier.FIRE_MIN_VALUE — the commit gate

var _shooters: Array[Vector3] = []


func before_each() -> void:
	_shooters.clear()
	for x: float in [-6.0, -4.0, -2.0, 0.0, 2.0, 4.0, 6.0]:
		for dist: float in [3.0, 5.0, 7.0, 9.0, 11.0, 14.0]:
			var z: float = NET.z + dist
			# Keep the sample inside the zone fan (skip degenerate sharp
			# angles tighter than the goal line buffer allows).
			if absf(x) < dist * 1.2:
				_shooters.append(Vector3(x, 0.0, z))


# Goalie squared to `target` at `depth` out from the net centre.
func _squared_at(target: Vector3, depth: float) -> Vector3:
	var dir: Vector3 = target - NET
	dir.y = 0.0
	return NET + dir.normalized() * depth


# Fraction of the shooter grid whose direct shot clears the fire floor, for a
# goalie-state generator. `strong_out` (optional 1-element array) receives the
# fraction clearing 0.3 (a genuine chance, not a floor-scraper).
func _committable_fraction(state: Callable, strong_out: Array = []) -> float:
	var committable: int = 0
	var strong: int = 0
	var none: Array[Vector3] = []
	for shooter: Vector3 in _shooters:
		var args: Array = state.call(shooter)  # [goalie_pos, unsettled, five_gap, down]
		var s: float = AIActionScoring.score_shoot(
				shooter, NET, args[0], GameRules.NET_HALF_WIDTH, none, 33.0,
				args[1], [], args[2], args[3])
		if s > FIRE_FLOOR:
			committable += 1
		if s > 0.3:
			strong += 1
	if not strong_out.is_empty():
		strong_out[0] = float(strong) / float(_shooters.size())
	return float(committable) / float(_shooters.size())


func test_shot_opportunity_distribution() -> void:
	# SET + SQUARED at challenge depth: the modest quick-release band — real
	# looks across the mid-range slice of the fan, but never a strong chance;
	# a set keeper still has to be MOVED (pass / carry / cut) for those.
	var set_strong: Array = [0.0]
	var set_frac: float = _committable_fraction(func(sh: Vector3) -> Array:
		return [_squared_at(sh, 1.3), 0.0, -1.0, false],
		set_strong)

	# DISPLACED: keeper still square to a spot 3 m lateral of the shooter (the
	# stale square a cross-seam catch / lateral cut leaves behind).
	var displaced_strong: Array = [0.0]
	var displaced_frac: float = _committable_fraction(func(sh: Vector3) -> Array:
		var stale := Vector3(sh.x + (3.0 if sh.x <= 0.0 else -3.0), 0.0, sh.z)
		return [_squared_at(stale, 1.3), 1.0, -1.0, false],
		displaced_strong)

	# DOWN: butterflied keeper, squared, mid-slide leak on the pads.
	var down_strong: Array = [0.0]
	var down_frac: float = _committable_fraction(func(sh: Vector3) -> Array:
		return [_squared_at(sh, 1.0), 0.0,
				GoalieBehaviorRules.five_hole_gap_m(true, 0.12), true],
		down_strong)

	# DEEP: keeper holding passive depth (0.6 m — on his line), squared.
	var deep_frac: float = _committable_fraction(func(sh: Vector3) -> Array:
		return [_squared_at(sh, 0.6), 0.0, -1.0, false])

	print("[shot-audit] committable fractions over %d OZ looks:" % _shooters.size())
	print("[shot-audit]   set+squared @1.3:  %.0f%%  (strong %.0f%% — intended 0)"
			% [set_frac * 100.0, set_strong[0] * 100.0])
	print("[shot-audit]   displaced 3m:      %.0f%%  (strong %.0f%%)"
			% [displaced_frac * 100.0, displaced_strong[0] * 100.0])
	print("[shot-audit]   down (leak 0.24m): %.0f%%  (strong %.0f%%)"
			% [down_frac * 100.0, down_strong[0] * 100.0])
	print("[shot-audit]   deep @0.6:         %.0f%%" % (deep_frac * 100.0))

	# The honesty invariants on the set keeper: the quick-release band keeps a
	# healthy floor (shot-starvation guard — a carrier with space always has a
	# committable, if modest, look through the mid-range) under a ceiling (so a
	# future tweak can't quietly re-open firing into set keepers everywhere) —
	# and NO look at a set squared keeper is ever a strong chance (observed max
	# ≈ 0.19 over the grid): strong chances require moving him.
	assert_between(set_frac, 0.2, 0.7,
			"a set squared keeper concedes the modest mid-range band, no more")
	assert_lt(set_strong[0], 0.03,
			"…and never a strong chance — those require moving him")
	# The keep-shooting invariants: the states team play creates must stay
	# richly committable, or bots go shot-starved in live games.
	assert_gt(displaced_frac, 0.5,
			"a keeper caught 3 m off his square is a shot most of the time")
	# Strong chances concentrate in the in-range slice of the fan (observed
	# ~17% of ALL looks including 11–14 m samples), so the tripwire sits just
	# under that: if it drops toward zero, displacement stopped paying.
	assert_gt(displaced_strong[0], 0.1,
			"…and a solid slice are genuine chances, not floor-scrapes")
	assert_gt(down_frac, 0.4,
			"a down keeper concedes real targets across much of the zone")
	assert_gt(deep_frac, 0.15,
			"a keeper parked on his line concedes angle even when set")
