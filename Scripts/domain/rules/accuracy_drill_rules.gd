class_name AccuracyDrillRules

# Pure target catalogue + sequencing for the Shot Accuracy drill: ten shots,
# each called at one randomly lit bullseye on the net. Engine-free so the pool
# geometry and the no-repeat pick are unit-testable headless;
# shot_accuracy_manager.gd owns the staging, in-flight detection, and scoring.
#
# Positions are net-plane (x = lateral, y = height) like the Shooting
# tutorial's target sets — x < 0 is the shooter's left. The pool is the
# classic shooter-tutor spread plus the mid-side holes:
#   - the four corners and the five-hole come straight from the tutorial's
#     calibrated sets (_LOW_TARGETS / _HIGH_TARGETS) — the drill's frozen
#     open-stance goalie leaves exactly those holes open;
#   - the two SIDE targets are placed so one notch of loft reaches them: LOW's
#     fixed vertical launch (SkaterController.loft_vertical_speed_low) peaks at
#     vy²/2g ≈ 0.25 m, so with the drill's hit tolerance a 0.50 m-high centre
#     is hittable by a saucer crossing near its apex — while a flat shot along
#     the ice stays out of range. (A HIGH shot passing through on its arc
#     works too; the calibration only guarantees LOW is enough.)

# Hit tolerance (m) around a target's centre — matched to the bullseye's drawn
# outer radius (TutorialTargets._BANDS) and the Shooting tutorial's own
# tolerance, so hitting the target you SEE gives credit.
const HIT_RADIUS: float = 0.34

# Parallel arrays: position and the called-spot name shown on the HUD.
const TARGET_POSITIONS: Array[Vector2] = [
	Vector2(-0.62, 0.30),  # bottom left, beside the pad
	Vector2(0.62, 0.30),   # bottom right
	Vector2(-0.62, 0.95),  # top left, over the shoulder
	Vector2(0.62, 0.95),   # top right
	Vector2(0.0, 0.24),    # five-hole
	Vector2(-0.62, 0.50),  # left side — the LOW-loft saucer height
	Vector2(0.62, 0.50),   # right side
]
const TARGET_NAMES: Array[String] = [
	"BOTTOM LEFT", "BOTTOM RIGHT", "TOP LEFT", "TOP RIGHT",
	"FIVE-HOLE", "LEFT SIDE", "RIGHT SIDE",
]


# Index of the next target to light. `roll` is any non-negative random int —
# the caller owns the RNG so sequencing stays deterministic under test. The
# previous index is excluded, so back-to-back repeats never happen and every
# shot reads as a fresh call; pass -1 (no previous) for a uniform first pick.
static func pick_next(previous: int, roll: int) -> int:
	var n: int = TARGET_POSITIONS.size()
	if previous < 0 or previous >= n:
		return roll % n
	var i: int = roll % (n - 1)
	return i if i < previous else i + 1
