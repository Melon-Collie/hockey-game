class_name BuildArchetypeRules

# Scouting-label taxonomy for a v4 build — the pure decision table behind the
# pre-game matchup screen's archetype tags. Under the body+gear model a build
# is two lateral body dials plus gear leans, so the fun read is the archetype
# ("Waterbug", "Tank"), not the numbers: the body plane (height band × frame
# band) picks one of nine body labels, and a signature gear combo optionally
# adds one tell ("Quick Release"). Pure presentation taxonomy — the bands are
# display buckets, not an evaluator; nothing downstream reads them.
#
# Engine-free by the PingRules convention: this hands back stable translation
# keys and the display seam tr()'s them (localized copy in
# locale/translations.csv). GUT-tested: tests/unit/rules/test_build_archetype_rules.gd.

# Body-plane bands. Heights are inches on the 68..79 dial: short is 5'10" and
# under, tall 6'4" and up. Frame thirds split the BMI band's frame_t (0..1;
# the 73"/201 lbs neutral sits at exactly 0.5 → medium by construction).
const SHORT_MAX_INCHES: int = 70
const TALL_MIN_INCHES: int = 76
const LEAN_MAX_T: float = 1.0 / 3.0
const HEAVY_MIN_T: float = 2.0 / 3.0

# Nine body labels, indexed [height_band][frame_band] with bands ordered
# short/mid/tall × lean/medium/heavy.
const _BODY_KEYS: Array[Array] = [
	["ARCH_WATERBUG", "ARCH_SPARK_PLUG", "ARCH_FIRE_HYDRANT"],
	["ARCH_GREYHOUND", "ARCH_TWO_WAY", "ARCH_BRUISER"],
	["ARCH_RANGY", "ARCH_TOWER", "ARCH_TANK"],
]


# The body archetype key for a build — always resolves (every legal body
# lands in exactly one cell of the 3×3 grid).
static func body_key(attrs: PlayerAttributes) -> String:
	var height_band: int = 1
	if attrs.height <= SHORT_MAX_INCHES:
		height_band = 0
	elif attrs.height >= TALL_MIN_INCHES:
		height_band = 2
	var frame_band: int = 1
	var t: float = attrs.frame_t()
	if t <= LEAN_MAX_T:
		frame_band = 0
	elif t >= HEAVY_MIN_T:
		frame_band = 2
	return _BODY_KEYS[height_band][frame_band]


# The gear tell key for a build, or "" when the loadout has no signature
# combo. Only the stacked two-slot loadouts read as an identity worth calling
# out — a single leaned slot stays quiet. First match wins (a build stacking
# two signatures leads with the shot identity — that's the one the defense
# has to respect).
static func gear_tell_key(attrs: PlayerAttributes) -> String:
	if attrs.flex == PlayerAttributes.FLEX_LOW \
			and attrs.curve == PlayerAttributes.CURVE_OPEN:
		return "ARCH_TELL_QUICK_RELEASE"  # the stacked quick-release loadout
	if attrs.flex == PlayerAttributes.FLEX_HIGH \
			and attrs.length == PlayerAttributes.LENGTH_LONG:
		return "ARCH_TELL_HOWITZER"  # the point bomb: max ceiling, max reach
	if attrs.profile == PlayerAttributes.PROFILE_AGILITY \
			and attrs.length == PlayerAttributes.LENGTH_SHORT:
		return "ARCH_TELL_SHIFTY"  # the dangler setup: edges + close control
	return ""
