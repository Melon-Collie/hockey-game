extends GutTest

# Reachable-set (pursuit-evasion) possession safety. Whether a defender threatens
# the puck is "can he get a stick to it given his momentum + reaction," not raw
# proximity. These pin the behaviours the old proximity model couldn't express:
# a hard charger is evadable (he overshoots), a contained/jockeying defender can't
# strip a careful carrier, a stick on the puck is a real threat, and handling
# (how far the carrier holds the puck off his body) threads tighter seams.

const HANDLE: float = 0.9   # base puck-protect reach (Hands scales this)


# Carrier's evadability [0,1]: safety at the best seam in his handling envelope.
func _evade(car: Vector3, car_v: Vector3, opps: Array[Vector3],
		vels: Array[Vector3], handle: float = HANDLE) -> float:
	var seam: Vector3 = AIActionScoring.best_evade_point(car, car_v, opps, vels, handle)
	var clear: float = AIActionScoring.reach_clearance(
			seam, AIActionScoring.EVADE_HORIZON_S, opps, vels)
	return AIActionScoring.clearance_to_safety(clear)


func test_no_defenders_is_fully_safe() -> void:
	assert_eq(_evade(Vector3.ZERO, Vector3(5, 0, 0), [], []), 1.0)


func test_angled_hard_charger_is_evadable() -> void:
	# Defender charging in from front-left at ~8 m/s. His momentum carries his
	# reach downrange past the carrier, so the space he vacates is open — beat him
	# by letting him overshoot.
	var opps: Array[Vector3] = [Vector3(2.5, 0, 2.5)]
	var vels: Array[Vector3] = [Vector3(-5.66, 0, -5.66)]
	assert_gt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.8,
			"a committed angled charger is beaten, not a strip threat")


func test_straight_on_charger_is_evadable() -> void:
	var opps: Array[Vector3] = [Vector3(3, 0, 0)]
	var vels: Array[Vector3] = [Vector3(-8, 0, 0)]
	assert_gt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.8,
			"a head-on charger at 8 m/s blows past — evadable")


func test_stick_on_the_puck_is_a_real_threat() -> void:
	# Defender's stick right on the puck, no momentum — the carrier can't just
	# skate out of it in one cut.
	var opps: Array[Vector3] = [Vector3(0.8, 0, 0.3)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	assert_lt(_evade(Vector3.ZERO, Vector3(3, 0, 0), opps, vels), 0.35,
			"a stick on the puck is genuine pressure")


func test_stationary_wall_ahead_is_tight() -> void:
	var opps: Array[Vector3] = [Vector3(1.5, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	assert_lt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.35,
			"skating into a stationary defender 1.5 m ahead is tight")


func test_jockey_cannot_strip_a_careful_carrier() -> void:
	# A gap-control defender pacing the carrier can CONTAIN (cap progress) but not
	# strip — the carrier is safe from a poke (he can retreat/hold). Containment is
	# the offense model's problem (no lane past him), not a safety one.
	var opps: Array[Vector3] = [Vector3(2.2, 0, 0.2)]
	var vels: Array[Vector3] = [Vector3(5, 0, 0)]
	assert_gt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.8,
			"gap-control contains but doesn't strip — safe from the poke")


func test_handling_threads_a_tighter_seam() -> void:
	# In a tight spot (stationary wall), a better handler holds the puck further
	# off his body and finds room a plodder can't. Skill expression, grounded in
	# the handling envelope — not a magic deke chance.
	var opps: Array[Vector3] = [Vector3(1.5, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var low: float = _evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels, 0.6)
	var high: float = _evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels, 1.4)
	assert_gt(high, low, "better hands thread a tighter seam")


func test_seam_points_into_open_space() -> void:
	# The seam is a usable carry target: with a defender to the left, it resolves
	# to the right of the carrier's line.
	var opps: Array[Vector3] = [Vector3(1.0, 0, 2.0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var seam: Vector3 = AIActionScoring.best_evade_point(
			Vector3.ZERO, Vector3(4, 0, 0), opps, vels, HANDLE)
	assert_lt(seam.z, 0.5, "seam leans away from the defender on the +Z side")
