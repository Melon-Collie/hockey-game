class_name PassingDrillRules

# Pure scenario catalogue + sequencing for the Passing drill: ten passes, each
# onto a teammate staged (and often skating) somewhere new. Engine-free so the
# staging geometry and the no-repeat pick are unit-testable headless;
# passing_drill_manager.gd owns the puppet motion, wall, completion detection,
# and scoring.
#
# Each PassScenario is a hand-authored rep that varies the four dimensions the
# request asked for — depth (how deep down-ice the play sits), length (the gap
# the pass has to cover), width (lateral / cross-ice angle), and receiver speed
# (a route the puppet skates, so the player has to LEAD a moving target) — plus
# an occasional saucer board across the lane that forces a lofted pass. These
# are feel/staging offsets, chosen by hand (see CLAUDE.md → Grounded models:
# staging is legitimately hand-set); the only rule logic is the no-repeat
# sequencer, mirroring AccuracyDrillRules.pick_next.
#
# Coordinates are on-ice (x = lateral, x < 0 is the player's left; z = down-ice,
# and team 0 attacks -Z, so a receiver deeper in the offensive zone sits at more
# negative z). All spots stay well inside INNER_HALF_WIDTH (~12.8) /
# INNER_HALF_LENGTH (~29.8).

# One staged pass rep. `receiver_target` == `receiver` means the teammate holds
# still; otherwise he patrols the receiver→target line until the pass is thrown,
# so the player reads and leads a moving man. `wall` drops a knee-high board in
# the lane a few strides ahead of the passer — a flat pass clanks off it, only a
# LOW saucer gets through.
class PassScenario:
	var title: String
	var passer: Vector2          # player's staging spot (x, z)
	var receiver: Vector2        # teammate's start (x, z)
	var receiver_target: Vector2 # patrol endpoint; == receiver ⇒ stationary
	var wall: bool               # a saucer board sits across the lane

	func _init(t: String, p: Vector2, r: Vector2, rt: Vector2, w: bool = false) -> void:
		title = t
		passer = p
		receiver = r
		receiver_target = rt
		wall = w

	func receiver_moves() -> bool:
		return not receiver.is_equal_approx(receiver_target)


# Builds the scenario pool. Constructed on call (objects can't be const); the
# manager builds it once at _ready and caches — never a hot path.
static func scenarios() -> Array[PassScenario]:
	return [
		# Depth shallow, dead straight, stationary — the baseline tape-to-tape rep.
		PassScenario.new("SLOT — SHORT",
				Vector2(0.0, 8.0), Vector2(0.0, 0.0), Vector2(0.0, 0.0)),
		# Width: a wide, stationary cross-ice target off to the wing.
		PassScenario.new("CROSS-ICE",
				Vector2(0.0, 8.0), Vector2(-8.0, 2.0), Vector2(-8.0, 2.0)),
		# Length + receiver speed: a teammate streaking away down-ice — lead the stretch.
		PassScenario.new("STRETCH — LEAD IT",
				Vector2(0.0, 9.0), Vector2(3.0, 0.0), Vector2(3.0, -12.0)),
		# Receiver speed across the grain: he skates the slot side to side.
		PassScenario.new("GIVE & GO — ACROSS",
				Vector2(0.0, 7.0), Vector2(-7.0, 1.0), Vector2(7.0, 1.0)),
		# Saucer: deep straight lane with a board in front of the passer.
		PassScenario.new("SAUCER — OVER THE STICK",
				Vector2(0.0, 8.0), Vector2(0.0, -8.0), Vector2(0.0, -8.0), true),
		# Length + width: a long diagonal to a stationary man deep on the far wing.
		PassScenario.new("WIDE & DEEP",
				Vector2(-4.0, 9.0), Vector2(9.0, -6.0), Vector2(9.0, -6.0)),
		# Depth + receiver speed: a back-door drive to the far post, sliding across and deep.
		PassScenario.new("BACKDOOR — SLIDING",
				Vector2(-6.0, 2.0), Vector2(6.0, -2.0), Vector2(1.0, -10.0)),
		# Touch pass to a closing man — he skates back toward the passer, so the
		# lead is short and soft.
		PassScenario.new("TOUCH — CLOSING",
				Vector2(0.0, 8.0), Vector2(0.0, -2.0), Vector2(0.0, 4.0)),
		# Second saucer, deep on the wing — a straight lane so the axis-aligned
		# board squarely blocks a flat pass (see the wall note in the manager).
		PassScenario.new("SAUCER — FAR LANE",
				Vector2(5.0, 7.0), Vector2(5.0, -7.0), Vector2(5.0, -7.0), true),
	]


# Index of the next scenario to stage. `roll` is any non-negative random int —
# the caller owns the RNG so sequencing stays deterministic under test. The
# previous index is excluded, so back-to-back repeats never happen; pass -1 (no
# previous) for a uniform first pick. Mirrors AccuracyDrillRules.pick_next.
static func pick_next(previous: int, roll: int, count: int) -> int:
	if count <= 1:
		return 0
	if previous < 0 or previous >= count:
		return roll % count
	var i: int = roll % (count - 1)
	return i if i < previous else i + 1
