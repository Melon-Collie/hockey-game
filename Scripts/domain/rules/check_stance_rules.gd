class_name CheckStanceRules

# The check-commit load-up: which shoulder a committing checker throws, how far
# that shoulder's cap and arm root travel while he throws it, and where the
# elbow on that side tucks to.
#
# A load-up is ASYMMETRIC. A trunk roll is not — it raises the trailing shoulder
# by exactly what it drops the leading one, so the silhouette reads as a skater
# tipping over rather than one coiling into a hit. Everything here is per-side:
# the trailing shoulder stays where it was.
#
# Pure and stateless, off replicated inputs only (move intent, facing,
# handedness), so a wire-fed remote reproduces the pose identically. The ease
# that feeds it runs at physics rate in Skater._update_commit_stance, not at
# render rate — the loaded blade position reads the lead, and the blade is
# gameplay geometry on the wire.


# LEAD SIDE, in [−1, +1]: +1 means the skater's RIGHT shoulder leads. Magnitude
# doubles as the load depth, so the two sides cross through a square-shouldered
# pose instead of the load teleporting from one to the other.
#
# Two terms, and neither is lateral velocity: a skater closing straight on his
# target has none, so the pose degenerated to lean-and-crouch in the ordinary
# case, and its sign flipped hard across zero mid-approach.
#
#   - the STICK bias, which is what a straight-on hit reads. The stick occupies
#     the forehand side and the checker wants it out of the collision, so the
#     off-stick shoulder is the one he throws by default.
#   - the STEER term. Angling across into someone turns that shoulder in. Signed
#     by the body-local lateral component of the move INTENT, which is what the
#     player is asking for a beat before velocity answers.
#
# Neither term dominates outright: a straight-on commit is decisively off-stick,
# and a hard angle across into the target carries the lead all the way over to
# the stick-side shoulder, which is what angling that way physically does. That
# a crossing is REACHABLE is why the sum is continuous and clamped rather than a
# sign — it slides through a square-shouldered pose instead of teleporting the
# load from one shoulder to the other.
const LEAD_STICK_BIAS: float = 0.55
const LEAD_STEER_GAIN: float = 0.65

# Where the LEADING shoulder's cap and arm root travel at full load, in
# upper-body-local metres. Forward and across the chest is the load; the drop is
# the smallest of the three, because a shoulder driven forward barely descends —
# the old pose spent its whole budget on a drop and none on the protraction that
# actually reads as loading up.
#
# Scapular protraction swings the acromion through an arc set by the clavicle,
# which is about half the shoulder width, so these are fractions of the shoulder
# HALF-WIDTH (Skater.shoulder_offset) and a bigger frame loads bigger for free.
const LOAD_FORWARD: float = 0.45
const LOAD_ACROSS: float = 0.30
const LOAD_DOWN: float = 0.22

# The leading arm tucks: the elbow leaves its outboard hang to sit against the
# ribs and a touch behind, so the near arm folds into the check instead of
# flaring out of it. Applied to the IK POLE (where the elbow wants to go), never
# to the hand — the hand belongs to the stick, and moving it would move the
# blade. Upper-body-local, |x| outboard and +z behind.
const TUCK_ELBOW_OUT: float = 0.12
const TUCK_ELBOW_BACK: float = 0.55


# `body_right_xz` is the skater's local +X in the world XZ plane;
# `stick_side` is +1 when the forehand is on his right (a right-handed shot).
static func lead_target(move_intent: Vector2, body_right_xz: Vector2,
		stick_side: float) -> float:
	return clampf(
			-stick_side * LEAD_STICK_BIAS
					+ move_intent.dot(body_right_xz) * LEAD_STEER_GAIN,
			-1.0, 1.0)


# How hard the shoulder on `side_sign` (+1 = the skater's right) is loaded: zero
# on the trailing side, which is the whole asymmetry.
static func side_load(lead: float, side_sign: float) -> float:
	return maxf(lead * side_sign, 0.0)


# Displacement of one shoulder's cap AND its arm root — the two travel together
# or the pad walks off the arm it grows from (see Skater._textured_shoulder).
static func load_offset(load: float, side_sign: float,
		half_width: float) -> Vector3:
	if load <= 0.0:
		return Vector3.ZERO
	var reach: float = half_width * minf(load, 1.0)
	return Vector3(
			-side_sign * LOAD_ACROSS * reach,
			-LOAD_DOWN * reach,
			-LOAD_FORWARD * reach)


# `pole` is already mirrored onto this arm's side; the tuck keeps it there.
static func tucked_pole(pole: Vector3, load: float) -> Vector3:
	if load <= 0.0:
		return pole
	return pole.lerp(
			Vector3(signf(pole.x) * TUCK_ELBOW_OUT, pole.y, TUCK_ELBOW_BACK),
			minf(load, 1.0))
