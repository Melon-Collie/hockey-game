class_name DangleDrillRules

# Pure geometry + scoring for the Dangle Gauntlet drill: a single timed run
# where you carry a loose puck through a fixed serpentine of gates in order,
# racing the clock. Engine-free so the course layout, the gate-crossing test,
# and the par/medal math are all unit-testable headless; the manager
# (dangle_gauntlet_manager.gd) owns the puck staging, the gate visuals, the
# live clock, and the results card.
#
# Coordinates are on-ice (x = lateral, z = down the length; team 0 attacks -Z,
# so the course runs from the +Z end toward -Z). A gate is a checkpoint segment,
# not a collider — the posts are purely visual and the puck passes freely; a
# gate "clears" when the puck's path crosses the gate plane inside the gap while
# the player has control (the manager owns the control gate). The gate plane is
# oriented to the APPROACH direction (previous gate → this gate), so it tilts
# with the weave and always faces the line you're skating.

# One checkpoint on the course. RefCounted so the manager can hold the built
# list; the fields are read straight through (no accessors — this is a plain
# geometry record).
class Gate extends RefCounted:
	var center: Vector2 = Vector2.ZERO      # on-ice (x, z) of the gap centre
	var axis: Vector2 = Vector2(0.0, -1.0)  # unit "through" direction (approach line)
	var half_width: float = 0.75            # half the gap, along the lateral axis

	func _init(c: Vector2, a: Vector2, hw: float) -> void:
		center = c
		axis = a.normalized() if a.length() > 0.0001 else Vector2(0.0, -1.0)
		half_width = hw

	# Lateral (horizontal, perpendicular to the through-axis) unit vector — the
	# line the two posts sit on. Used by the visuals to place the posts and by
	# the crossing test to measure gap offset.
	func lateral() -> Vector2:
		return Vector2(-axis.y, axis.x)


# Where the player is staged, facing -Z (down-course toward the first gate). The
# puck is handed a stride ahead of here; grabbing it starts the clock.
const SPAWN: Vector2 = Vector2(0.0, 19.0)

# Half the gap for every gate (m). Feel tunable — a 1.5 m gap threads with the
# puck on your stick but punishes a lazy line through the weave.
const GATE_HALF_WIDTH: float = 0.75

# The fixed serpentine, first to last (x, z). Hand-laid, not random, so a run is
# a fair race against your own previous time. Kept well inside the inner boards
# (|x| ≤ ~5.5 vs INNER_HALF_WIDTH 12.84) and clear of both nets (z in
# [-16, 16] vs GOAL_LINE_Z 26.65). The lateral flips force a real weave; the
# final gate centres up for a clean finishing lane.
const _GATE_CENTERS: Array[Vector2] = [
	Vector2(5.5, 16.0),
	Vector2(-5.5, 10.0),
	Vector2(5.0, 3.0),
	Vector2(-5.0, -4.0),
	Vector2(4.0, -10.0),
	Vector2(0.0, -16.0),
]

# Grounded par: the course path length divided by a controlled dangling pace.
# A clean carry through a weave runs well under a flat-out sprint (carrying
# slows you and the lateral cuts bleed speed), so ~6.5 m/s is an honest "good
# but not perfect" line. Par itself is physical (metres ÷ m/s); the medal
# multipliers below are the difficulty feel-knobs layered on top.
const REFERENCE_DANGLE_SPEED: float = 6.5   # m/s

# Medal windows as multiples of par (difficulty feel tunables). Gold rewards a
# near-par line, bronze is "you finished cleanly".
const GOLD_PAR_MULT: float = 1.15
const SILVER_PAR_MULT: float = 1.50
const BRONZE_PAR_MULT: float = 2.10

# Medal tiers, high to low. NONE means finished slower than bronze (or bailed
# gates); the manager maps these to HUD strings.
enum Medal { NONE, BRONZE, SILVER, GOLD }


# Builds the ordered gate list. Each gate's plane faces the direction you skate
# INTO it (previous centre → this centre); the first gate faces the line from
# the spawn, so it reads as "skate straight in and turn".
static func build_course() -> Array:
	var gates: Array = []
	var prev: Vector2 = SPAWN
	for c: Vector2 in _GATE_CENTERS:
		var approach: Vector2 = c - prev
		gates.append(Gate.new(c, approach, GATE_HALF_WIDTH))
		prev = c
	return gates


static func gate_count() -> int:
	return _GATE_CENTERS.size()


# True when the puck's movement from prev_xz to cur_xz this tick crosses the
# gate plane in the forward (through) direction AND the crossing point lies
# inside the gap. Segment-based, so a fast puck can't tunnel the plane between
# ticks. Both args are on-ice (x, z).
static func crossed_gate(prev_xz: Vector2, cur_xz: Vector2, gate: Gate) -> bool:
	var n: Vector2 = gate.axis
	var prev_rel: float = (prev_xz - gate.center).dot(n)
	var cur_rel: float = (cur_xz - gate.center).dot(n)
	# Must pass from the near side to the far side this tick (forward crossing).
	if prev_rel >= 0.0 or cur_rel < 0.0:
		return false
	var denom: float = prev_rel - cur_rel
	if absf(denom) < 0.000001:
		return false
	var f: float = prev_rel / denom  # in [0, 1]: fraction of the segment at the plane
	var crossing: Vector2 = prev_xz + (cur_xz - prev_xz) * f
	var lat: float = (crossing - gate.center).dot(gate.lateral())
	return absf(lat) <= gate.half_width


# Total on-ice path length from the spawn through every gate centre in order —
# the distance a perfect line covers. Drives par.
static func course_length() -> float:
	var total: float = 0.0
	var prev: Vector2 = SPAWN
	for c: Vector2 in _GATE_CENTERS:
		total += prev.distance_to(c)
		prev = c
	return total


# Grounded par time (s): the ideal path length at a controlled dangling pace.
static func par_time() -> float:
	return course_length() / REFERENCE_DANGLE_SPEED


# Medal earned for finishing all gates in `elapsed` seconds. A run that bailed
# any gate (cleared < total) never medals, however fast — the medal is for a
# clean weave. NONE otherwise if slower than the bronze window.
static func medal(elapsed: float, gates_cleared: int, gates_total: int) -> Medal:
	if gates_cleared < gates_total:
		return Medal.NONE
	var par: float = par_time()
	if elapsed <= par * GOLD_PAR_MULT:
		return Medal.GOLD
	if elapsed <= par * SILVER_PAR_MULT:
		return Medal.SILVER
	if elapsed <= par * BRONZE_PAR_MULT:
		return Medal.BRONZE
	return Medal.NONE
