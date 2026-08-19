class_name PlayerAttributes
extends RefCounted

# PlayerAttributes
# ----------------
# Per-skater build on the v4 BODY + GEAR model (docs/attributes-v4-plan.md).
# A build is:
#
#   • HEIGHT — a free CONTINUOUS dial in inches (every inch 5'7"..6'8"). Tables
#     are authored at 5 anchor heights and interpolate. Height decides reach,
#     the speed↔agility baseline fork (speed hump peaks at 6'1", agility
#     small-favored) and the shot-power baseline (big-favored).
#   • WEIGHT — a free CONTINUOUS dial in pounds, bounded per height by an
#     authored BMI band (22.5 LEAN .. 29.0 HEAVY, neutral 26.5) floored by an
#     absolute playable mass (160 lb): together they generate a plausible
#     pounds range at every inch, so implausible bodies (6'6"/160) are
#     unrepresentable by construction. Weight decides mass (linearly — mass IS
#     the physical/checking system now), the
#     accel↔momentum fork (lean = first-step burst; momentum is mass-emergent),
#     an agility bite (F = mv²/r — heavy turns wide and stops long, the
#     counterweight that makes the dial a real seesaw; glide is exempt so the
#     tank still coasts), hitbox width (tracks the visual frame bulk) and the
#     stamina metabolism fork (lean = shallow pool / fast regen).
#   • GEAR — four discrete slots, three options each, ALL LIVE and all
#     LATERAL (no net power): SKATE PROFILE (top-end/glide ↔ first-step/
#     cornering incl. grip), BLADE CURVE (loft-ladder steepness ↔
#     backhand honesty, + runway lean), STICK FLEX (shot ceiling ↔ load
#     time + runway), STICK LENGTH (reach/sweep ↔ snap/inner-circle — the
#     blade-cap lever).
#
# There is NO power economy: no tiers, no strong/weak shape, no legality
# beyond range coercion. Body dials are lateral; gear is lateral; validation
# is a clamp (coerce_height / coerce_weight / gear clamps), never a rejection.
#
# THE CONSTITUTION (see the plan doc §1) — categories a lever may scale:
#   outputs (body physics) and geometry (reach/lever/workspace) — fair game;
#   FIDELITY (how faithfully the blade tracks the cursor) — never. There is
#   deliberately no hands table of any kind: hands_blade_mult() is 1.0 for
#   every build. Hands differentiation arrives as lever GEOMETRY (stick
#   length → tip speed vs inertia) in a later stage, never as a multiplier.
#
# Neutral reference is 6'1" / 201 lbs / all-balanced gear: every gameplay
# multiplier is 1.0 there, so a neutral build plays and looks identical to
# the shipped @export defaults. (201 lbs = BMI 26.5 at 73" — the real
# NHL-average frame.)
#
# All tuning tables live in this file as private consts, consumed via the
# named accessors below — never index a `_*` table outside this file.
#
# To add a new "height/weight X scales Y" rule:
#   1. Add a table: `_FOO_H: Array[float]` (5-vec, height anchors) or
#      `_FOO_F: Array[float]` (5-vec, frame anchors lean→heavy).
#   2. Add an accessor `func foo_mult() -> float` returning `_h(...)`/`_f(...)`.
#   3. Multiply a captured base in SkaterController.apply_attributes /
#      SkaterAppearanceCoordinator.apply.
#
# Persistence: PlayerPrefs (attr_scale_version 5; older saves migrate via
# migrate_tiers / migrate_legacy), BotIdentityRegistry (bot picks),
# NetworkManager peer table (6 ints replicated at join, PROTOCOL v36).

# Height is stored in INCHES and is a free CONTINUOUS dial: every inch from
# 5'7" (67) to 6'8" (80) is playable. Tables are authored at 5 anchor heights
# (ANCHOR_INCHES); heights in between linearly interpolate the adjacent rows.
const HEIGHT_MIN: int = 67     # 5'7"
const HEIGHT_MEDIUM: int = 73  # 6'1"  (neutral)
const HEIGHT_MAX: int = 80     # 6'8"

# The 5 height table rows sit at these heights (inches). 5'10" (row 1) is the
# mesh-native anchor where the reach/height multiplier is exactly 1.0.
#
# BOTH END ANCHORS MOVED when the range was extended (6'7"→6'8" at the top,
# 5'8"→5'7" at the bottom) rather than adding sixth/seventh rows, which would
# have left anchors one inch apart at the ends. Each end row was rebalanced so
# the outermost segment's line still passes through the OLD end value — i.e.
# that segment's per-inch slope simply continues for one more inch:
#
#     V80 = V79 + (V79 − V76)/3        V67 = V68 − (V70 − V68)/2
#
# So every previously-playable height (5'8"–6'7") keeps the values it had (the
# bottom end exactly; the top end within 0.00025, pure constant-rounding), and
# the two new heights are real extensions of each curve rather than copies of
# their neighbours. The four 4-decimal constants below are the bottom-row
# halvings — carried to 4 places precisely so 5'8" and 5'9" stay bit-exact.
const ANCHOR_INCHES: Array[int] = [67, 70, 73, 76, 80]  # 5'7"..6'8"

# The legacy 1..5 height STEP mapping is frozen at the v3 height set, which
# ran 5'8"–6'7". It deliberately does NOT track ANCHOR_INCHES: a saved tier-era
# build should keep the body it had, not gain or lose an inch because the range
# was extended later.
const LEGACY_HEIGHT_STEPS: Array[int] = [68, 70, 73, 76, 79]

# ── Weight band (BMI interval + absolute floor — see plan doc §3.2) ───────────
# One authored band generates the per-height pounds range: lbs = BMI·in²/703.
#
# CALIBRATION (2026-07, against a 46-player listed-height/weight sample of the
# current NHL). Two things the sample settles:
#
#   • BMI IS the right normalizer. Regressing ln(weight) on ln(height) over the
#     sample gives an exponent of 2.01 — h² on the nose — and BMI itself has no
#     usable drift with height (+0.007 BMI/inch). So the band is a horizontal
#     interval, NOT a height-tilted one: mean BMI 26.05, SD 1.61.
#
#   • The LEAN edge was the bug, and it bit tall builds hardest. A flat 24.0
#     floor is set by what SHORT players can get away with, because their lower
#     tail is truncated by an ABSOLUTE mass floor (~160 lb — Lane Hutson at
#     5'9"/162 is the lightest body in the league) rather than by a ratio: you
#     have to survive contact against 200-lb bodies, and that bound is in
#     pounds, not in BMI. Tall players are nowhere near that floor, so their
#     real lower tail runs much leaner — and a flat 24.0 forbade it. At 6'4"
#     the old floor was 197 lb, which excludes two actual 6'4" NHL defensemen
#     (Noah Dobson 195, Sam Rinzel 194). The model now says the same thing the
#     bodies do: a RATIO ceiling (carrying fat costs skating) and an ABSOLUTE
#     floor (you cannot be too light to play), and the band is their overlap.
#
# WHERE THE TWO FLOORS SIT. They are independent levers covering different
# heights, and each is fitted to the tail it actually governs:
#
#   • The RATIO floor (23.0) governs 5'11" and up, and is set just under the
#     leanest real bodies there — Reichel (6'0"/170 = 23.05) and Ehlers
#     (6'0"/172 = 23.32) at the low end, then a dense 23.6–23.9 cluster
#     (Rinzel, Dobson, K. Johnson, Pettersson, Edvinsson). It puts 6'4" at
#     189, clearing Dobson 195 / Rinzel 194.
#   • The ABSOLUTE floor (162) governs 5'7"–5'10", where the ratio floor falls
#     to 147–160 and stops meaning anything. 162 IS the lightest player in the
#     NHL (Lane Hutson, 5'9"), i.e. "you cannot be lighter than the lightest
#     man who has ever held the job." The lightest bodies at the neighbouring
#     short heights — Stankoven 5'8"/165, Garland 5'10"/165 — clear it by 3.
#
# The band edge landing exactly on one player is the shape of a fitted edge,
# not a defect: the 29.0 ceiling lands exactly on Kaprizov (5'10"/202) the
# same way.
#
# Two earlier passes got the lean edge wrong in the same direction. 22.5 was
# chasing a stale card — Elias Pettersson's 6'2"/176 (BMI 22.59) looked like a
# lone outlier, but that is his draft era (he measured 164 lb at the 2017
# combine) and he is listed 185 today, BMI 23.75, comfortably inside. 23.5
# then over-corrected past Reichel and Ehlers. The lesson both times: fit the
# edge to the tail's SHAPE, and when the short heights misbehave reach for the
# absolute floor rather than bending the ratio, because the thing that bounds
# a small player is pounds, not a ratio.
#
# The band is deliberately ASYMMETRIC about MEDIUM (3.0 BMI lean-side vs 2.5
# heavy-side): the empirical center sits at 26.05, but MEDIUM is pinned to the
# canonical 6'1"/201 NHL-average frame because that is the game's neutral
# identity — every @export default is authored there. frame_t() is piecewise
# about MEDIUM so the neutral still lands on exactly 0.5 and the frame anchors
# stay evenly spaced in frame-t (which is the axis the _f() tables index).
#
# Calibration namechecks: neutral = 6'1"/201 (NHL-average build); McDavid
# (6'1"/194) lean-mid; Dobson/Rinzel (6'4"/195, 194) ≈ 6'4"-LEAN; DeBrincat
# (5'8"/180) ≈ SOLID; Kaprizov (5'10"/202) = 5'10"-HEAVY exactly; Tage Thompson
# (6'6"/218) lean-mid; Oleksiak (6'7"/252) ≈ 6'7"-HEAVY.
const BMI_LEAN: float = 23.0
const BMI_MEDIUM: float = 26.5   # neutral frame
const BMI_HEAVY: float = 29.0

# Absolute lower bound on a playable body, in pounds — the floor that the BMI
# ratio cannot express. Binds at 5'7"–5'10", where the 23.0 ratio floor falls
# to 147–160 and would allow bodies lighter than anyone who has ever held an
# NHL job; from 5'11" up the ratio floor is the higher of the two. See the
# band block above for why 162 and not 160.
const MIN_PLAYABLE_LBS: int = 162

# Neutral mass reference (lbs): BMI 26.5 at 73" → round(26.5·73²/703) = 201.
# mass_mult is LINEAR in displayed weight — deliberately wider than v3's
# minor height edge (0.79..1.28, a 1.63× spread): with no Checking stat, mass
# is the physical system, feeding delivery and brace through the collision
# resolver's reduced-mass math. Escape hatch if too swingy: compress with an
# exponent ((lbs/201)^p, p ≤ 1) — physics gives the shape, playtest the
# magnitude.
const NEUTRAL_WEIGHT_LBS: float = 201.0

# ── Gear slots (step 1: stored + replicated, ZERO gameplay effect) ───────────
# Every slot is 0/1/2 with 1 = the balanced/neutral option. Options are
# discrete and chunky by design (the loft-level pattern) — never sliders.
const GEAR_BALANCED: int = 1

const PROFILE_AGILITY: int = 0   # +accel / first step / cornering, −top speed
const PROFILE_BALANCED: int = 1
const PROFILE_POWER: int = 2     # +top speed / glide, −agility

const CURVE_CLOSED: int = 0      # hardest to elevate, best backhand
const CURVE_BALANCED: int = 1
const CURVE_OPEN: int = 2        # easier elevation (FLAT/LOW), quick release, worst backhand

const FLEX_LOW: int = 0          # whippy: −power ceiling, shortest runway/wind-up
const FLEX_MEDIUM: int = 1
const FLEX_HIGH: int = 2         # stiff: +power ceiling, longest runway/wind-up

# The retail stiffness ladder — the flex numbers sticks actually ship in. The
# workbench shows the build's real number (see flex_number); the gameplay leans
# never read it, they stay on the relative pick.
const FLEX_LADDER: Array[int] = [65, 75, 85, 100, 110]

# Shaft stiffness per pound of body at a matched fit. The half-bodyweight rule
# of thumb overshoots what players actually shoot (big NHL forwards routinely
# sit well under it — release beats ceiling); 0.42 puts the 201 lb neutral on
# an 85, the most-shipped number, and leaves exactly one rung of headroom at
# both ends of the ladder for the gear pick to shift into.
const _MATCHED_FLEX_PER_LB: float = 0.42

const LENGTH_SHORT: int = 0      # −reach, snappiest reversal, finest close control
const LENGTH_STANDARD: int = 1
const LENGTH_LONG: int = 2       # +reach / tip speed / contest momentum, +inertia

# ── Gameplay tables — height-indexed (5 rows at ANCHOR_INCHES) ────────────────
# Values are the v3 average-tier column: the v4 body plane is authored around
# the old no-strength-no-weakness builds, so a v4 body reproduces the exact
# behavior a v3 all-average build of the same height had. Gear (later stages)
# re-widens the spread laterally.

# Speed baseline (max_speed). The hump: top speed peaks at medium height.
const _SPEED_H: Array[float] = [0.9875, 0.995, 1.000, 0.995, 0.988]

# Agility baseline (turn rate / brake / facing / lateral). Small-favored.
const _AGILITY_H: Array[float] = [1.065, 1.020, 1.000, 0.960, 0.920]

# Shot-power baseline (charged wrister/slapper ceiling). Big-favored — the
# leverage a long frame loads into a shot. Wind-up derives inversely.
const _SHOT_H: Array[float] = [0.880, 0.940, 1.000, 1.050, 1.103]

# Hitbox cylinder radius — girth_mult(), the same grounded lateral width the
# silhouette wears (hitbox tracks the visual body exactly): bigger poke
# target and net-front screen for the wide build, slimmer profile for the
# lean one. See girth_mult() for the model.

# Body height (mesh Y-scale, arm/ROM length, hand heights). Mesh-native 5'10"
# is row 1, so the 1.0 identity sits there (NOT the 6'1" gameplay neutral).
const _HEIGHT: Array[float] = [0.9565, 1.000, 1.043, 1.086, 1.143]

# Stick length — equipment, ~0.65× the height deviation from mesh-native 5'10".
# Height sets the BAND CENTER (real sticks are cut to the body)…
const _STICK_LEN: Array[float] = [0.9715, 1.000, 1.028, 1.056, 1.093]
# …and the LENGTH gear slot leans it — THE FIRST LIVE GEAR SLOT. A lean on
# your height's stick, not an absolute pick, so max-height + LONG can't stack
# reach beyond the tuned corner. Symmetric ±4% to start (whether LONG should
# lean more conservatively than SHORT is an open tuning call — reach is the
# closest thing the game has to raw power, but the lever-derived inertia and
# tip-speed tradeoffs are what price it honestly). Everything downstream of
# stick_len_mult follows automatically: stick/blade mesh, poke + claim reach,
# blade-cap lever derivation, wrister full-stroke rescale.
const _LENGTH_LEAN: Array[float] = [0.960, 1.000, 1.040]  # SHORT / STANDARD / LONG

# ── Gear-lean tables — 3-vec, indexed by the slot option (0/1/2) ─────────────
# SKATE PROFILE — top-end ↔ burst (the last slot to land). POWER (long flat
# grind) = +top speed and +glide, −agility (turn/brake/grip — it multiplies
# the full agility lever, lateral_grip included); AGILITY (rockered) = +first
# step and +cornering, −top speed. The speed lean is what re-widens the
# sprint band the body plane deliberately compressed (~20.5–24 mph across
# profiles, approaching the v3 20–25 target). STACKED AGILITY CORNERS
# (body × gear, pinned by test): best 5'7"-lean-agility ≈ 1.15, worst
# 6'8"-heavy-power ≈ 0.84 — a self-chosen extreme, deliberately outside the
# involuntary body floor/ceiling (~0.88 / ~1.10).
const _PROFILE_SPEED_LEAN: Array[float] = [0.96, 1.00, 1.04]    # agility / balanced / power
const _PROFILE_AGILITY_LEAN: Array[float] = [1.05, 1.00, 0.95]
const _PROFILE_ACCEL_LEAN: Array[float] = [1.04, 1.00, 0.98]
const _PROFILE_GLIDE_LEAN: Array[float] = [1.03, 1.00, 0.96]    # drag mult: lower = coasts better

# STICK FLEX — power ↔ release, a true seesaw: stiff loads a bigger shot but
# pays a slower load (longer slapper wind-up AND longer wrister runway);
# whippy is the snap release at a softer ceiling. NOTE the charge lean goes
# WITH the power lean, deliberately breaking from the height coupling
# (2 − power, where a harder shooter also threatens sooner — a double
# benefit the v3 tier price policed): a lateral slot must trade, never
# stack. Real-hockey sign convention: high flex number = stiffer.
const _FLEX_SHOT_LEAN: Array[float] = [0.94, 1.00, 1.06]    # whippy / medium / stiff
const _FLEX_CHARGE_LEAN: Array[float] = [0.92, 1.00, 1.10]  # wind-up time, with power
const _FLEX_RUNWAY_LEAN: Array[float] = [0.90, 1.00, 1.12]  # wrister full-stroke travel

# BLADE CURVE — three house patterns modeled on hockey's most-played real
# blades: M88 (closed slot — the P88-like mid curve), M92 (balanced — the
# P92-like mid-toe all-rounder, the neutral row), M28 (open — the P28-like
# open toe hook). The ANGLE LADDER is the elevation lever (the manual
# contact-point model — docs/elevation-rework-plan.md v3): each loft level is
# a set launch angle from this pattern's ladder, steeper on the open blade at
# every rung.
#
# THE LEVEL NAMES THE SHOT; THE GEAR NAMES THE RANGE. Each level targets a
# GOALIE-POSTURE landmark — absolute heights off the ice, not fractions of the
# net — and each gear places those same three shots at its own HOME RANGE:
#
#   level        target        what it beats
#   LOW  (35%)   0.41 m        over the butterfly pad (0.28), UNDER his hands
#   MID  (60%)   0.70 m        the armpit — OVER his committed hands (0.49)
#   HIGH (85%)   0.99 m        upstairs — over the standing pad seam (0.86)
#
#   gear   home    ladder
#   M88    8.5 m   the range blade — peaks in the high slot / long range
#   M92    6.0 m   the all-rounder — 3 shots from the slot out to long range
#   M28    4.5 m   the close blade — peaks in the slot, owns the crease
#
# (Percentages are of the 1.17 m scoring cavity, a naming convenience only —
# what the rungs actually clear is the goalie's equipment, whose heights are
# absolute. See GoalieAnatomy for the pad/hand/torso boxes those come from.)
#
# Away from home the menu slides rather than breaking: one zone out a gear
# keeps two shots, two zones out one. Nobody gets the full menu at the point,
# which is deliberate — a point shot only has to reach the net, not pick a
# corner (the whole net is a 3.4° window at 19 m, so no ladder could).
#
# Two properties fall out of anchoring the fans close in rather than at range,
# and both are load-bearing:
#   · BUILD TOLERANCE. Build variance lives entirely in the gravity drop
#     (~d²/v²), so the ±17% shot-power spread moves arrival by only ±3–12 cm
#     at these home ranges instead of the ±60 cm it moved when bands sat at
#     15–22 m. Every build keeps its full menu at home; the lone casualty is a
#     weak build's M88 LOW, which lands under the pad. No normalization needed
#     — the anchoring dissolved the problem.
#   · THE SLAPPER NEEDS NO SEPARATE LADDER. Its extra pace costs ~5 cm of drop
#     at home range, so the same rungs ride about one notch higher. Real, and
#     small enough that the level still means what it means.
# NO rung sails on a wrister, and no LOW rung sails even off a max slapper
# (apexes 0.62 / 0.75 / 1.01 m by gear) — the flat bottom of every ladder is
# the universally safe shot.
#
# The rest of the identity triangle, all lateral trades about the M92:
#   M88 — the playmaker/point blade: best backhand, +3% slapper (a flatter
#         face stays square through the heel-contact sweep), and catches the
#         hardest feeds (+7% reception ceiling — the flat blade cradles).
#   M28 — the in-tight blade: the open toe is its whole (large) upside;
#         it pays the deepest backhand penalty, −3% slapper, and hard feeds
#         bounce off (−7% reception). Its stored quick-release runway lean
#         goes live when the wrister travel gate unfreezes.
# Backhand relief approaches but never reaches forehand parity
# (0.75 base × 1.08 = 0.81). Reception lean scales the deflect ceiling +
# alignment bonus at the decision sites (PuckReceptionRules callers) — never
# pickup_max_speed, so soft passes settle on every blade and the client's
# provisional-pickup gate stays build-independent.
const _CURVE_LOFT_LOW_DEG: Array[float] = [5.0, 5.5, 6.4]      # M88 / M92 / M28
const _CURVE_LOFT_MID_DEG: Array[float] = [6.9, 8.2, 10.0]
const _CURVE_LOFT_HIGH_DEG: Array[float] = [8.9, 11.0, 13.6]
const _CURVE_RUNWAY_LEAN: Array[float] = [1.00, 1.00, 0.90]
const _CURVE_BACKHAND_LEAN: Array[float] = [1.08, 1.00, 0.90]
const _CURVE_SLAP_LEAN: Array[float] = [1.03, 1.00, 0.97]
const _CURVE_RECEPTION_LEAN: Array[float] = [1.07, 1.00, 0.93]

# ── Gameplay tables — frame-indexed (5 rows lean→heavy at the BMI anchors) ────

# Acceleration (thrust / forward burst). Lean = first-step quickness; heavy
# trades the first step for mass-emergent momentum (no separate table — the
# collision/inertia math already carries it).
const _ACCEL_F: Array[float] = [1.080, 1.040, 1.000, 0.980, 0.970]

# Agility (turn / brake / facing) frame term — multiplies the height baseline.
# Grounded in F = mv²/r: at fixed leg strength more mass means a wider arc and
# a longer stop. This is the counterweight that makes the weight dial a real
# seesaw (mass 1.28 is a big buy; without this its only tax was mild accel).
# CORNER BUDGET (body-only): best 5'7"-lean 1.065·1.03 ≈ 1.10, worst 6'8"-heavy
# 0.92·0.96 ≈ 0.88 — pinned just under the v3 "feels bad but playable" floor;
# the skate-profile gear lean stacks on top later, so re-check the stacked
# corners when that slot lands. Deliberately NOT applied to edge glide — see
# agility_glide_mult.
const _AGILITY_F: Array[float] = [1.030, 1.015, 1.000, 0.980, 0.960]

# Stamina drain scale (sprint DURATION / pool depth). Lean = fast metabolism =
# higher drain; heavy = deep pool = drains slower.
const _STAMINA_DRAIN_F: Array[float] = [1.15, 1.07, 1.00, 0.92, 0.85]

# Stamina regen scale (RECOVERY). Lean tops up fast; heavy recovers slowly.
# The pair: lean = short repeatable bursts, heavy = one long drive, slow refill.
const _STAMINA_REGEN_F: Array[float] = [1.25, 1.12, 1.00, 0.90, 0.82]

# ── Visual tables ─────────────────────────────────────────────────────────────
# Silhouette = body (v4): height drives overall Y scale; every LATERAL body
# multiplier (torso, shoulders, limbs — and the hitbox radius, which tracks
# the silhouette) is the single grounded girth_mult() below, so there are no
# authored width curves left to drift. The head is the one part that keeps a
# (mild) authored table — real adult heads are nearly constant across
# statures, so it moves a few percent, not with the body.
const _HEAD_BULK: Array[float] = [0.935, 0.98, 1.00, 1.03, 1.07]   # height

# ── Sprint / carry constants ──────────────────────────────────────────────────
# The normalization span is the FULL v3 speed-lever span (weak-small .. strong-
# medium), retained so v4 body-only builds land on the same sprint ceilings
# their v3 all-average counterparts had (neutral identity at every height).
# Body-only speed occupies the middle of the span; the skate-profile gear slot
# re-widens it laterally in a later stage.
const _SPEED_MULT_MIN: float = 0.955
const _SPEED_MULT_MAX: float = 1.060
# Sprint top-speed multiplier, interpolated across the speed span — grounded
# to the NHL EDGE 20–25 mph burst band.
const SPRINT_CEIL_MIN: float = 1.07
const SPRINT_CEIL_MAX: float = 1.164
# Carry speed = how much of your speed survives carrying (higher = less
# penalty). v3 eased this by Hands (primary) + Speed; v4 has no hands lever
# (constitution), so the v3 neutral hands contribution is folded into the
# base — CARRY_BASE = 0.92 + 0.07·(0.15/0.39), exactly the v3 H3-average
# value — leaving Speed as the only easing term.
const CARRY_BASE: float = 0.92 + 0.07 * (0.15 / 0.39)
const CARRY_SPEED_GAIN: float = 0.025
const CARRY_FLOOR: float = 0.85
const CARRY_CEIL: float = 0.99

# ── State ─────────────────────────────────────────────────────────────────────
var height: int = HEIGHT_MEDIUM
var weight: int = int(NEUTRAL_WEIGHT_LBS)
var profile: int = GEAR_BALANCED
var curve: int = GEAR_BALANCED
var flex: int = GEAR_BALANCED
var length: int = GEAR_BALANCED


func _init(p_height: int = HEIGHT_MEDIUM, p_weight: int = 0,
		p_profile: int = GEAR_BALANCED, p_curve: int = GEAR_BALANCED,
		p_flex: int = GEAR_BALANCED, p_length: int = GEAR_BALANCED) -> void:
	height = coerce_height(p_height)
	weight = coerce_weight(height, p_weight)
	profile = _clamp_gear(p_profile)
	curve = _clamp_gear(p_curve)
	flex = _clamp_gear(p_flex)
	length = _clamp_gear(p_length)


# The neutral build (6'1"/201, all-balanced). Name kept from the tier era —
# every "give me a default build" call site reads it.
static func all_average() -> PlayerAttributes:
	return PlayerAttributes.new()


# Direct construction from raw levels in canonical wire order:
# [height_in, weight_lbs, profile, curve, flex, length].
static func from_levels(p_height: int, p_weight: int,
		p_profile: int = GEAR_BALANCED, p_curve: int = GEAR_BALANCED,
		p_flex: int = GEAR_BALANCED, p_length: int = GEAR_BALANCED) -> PlayerAttributes:
	return PlayerAttributes.new(p_height, p_weight, p_profile, p_curve, p_flex, p_length)


# ── Weight band helpers ───────────────────────────────────────────────────────
# Displayed pounds for a BMI at a height: lbs = BMI·in²/703 (the BMI formula
# inverted). All band math routes through here so the interval stays single-
# sourced.
static func weight_for_bmi(inches: int, bmi: float) -> int:
	var h: int = clampi(inches, HEIGHT_MIN, HEIGHT_MAX)
	return int(roundf(bmi * float(h * h) / 703.0))


# The leaner of the two bounds never wins: the ratio floor and the absolute
# playable-mass floor are both real, so the band starts at whichever is higher.
static func weight_min(inches: int) -> int:
	return maxi(weight_for_bmi(inches, BMI_LEAN), MIN_PLAYABLE_LBS)


static func weight_max(inches: int) -> int:
	return weight_for_bmi(inches, BMI_HEAVY)


static func weight_neutral(inches: int) -> int:
	return weight_for_bmi(inches, BMI_MEDIUM)


# Clamp a pounds value into the height's band. Zero/negative means "no stored
# weight" (a pre-v5 save or a defaulted wire arg) and coerces to the height's
# neutral frame, so legacy identities keep their silhouette.
static func coerce_weight(inches: int, lbs: int) -> int:
	if lbs <= 0:
		return weight_neutral(inches)
	return clampi(lbs, weight_min(inches), weight_max(inches))


# Frame position 0..1 across the band (0 = LEAN, 0.5 = MEDIUM, 1 = HEAVY) —
# the height-independent "how heavy for my frame" quantity the frame tables
# index by, and what the picker preserves when the height slider moves.
# Measured in the INTEGER pounds band the player actually sees (not raw BMI):
# the band edges land exactly on 0/1 and the neutral 73"/201 lands exactly on
# 0.5, so the rounded display weight can't nudge a neutral build off the 1.0
# multipliers (raw BMI of 201 lbs is 26.515, a ~0.3% lerp leak).
func frame_t() -> float:
	return frame_t_for(height, weight)


# PIECEWISE about MEDIUM — each half of the band maps onto half of frame-t. The
# band is asymmetric (the lean side is wider, see the band block above), so a
# single lerp across [min, max] would slide the neutral build off 0.5 and cost
# it its 1.0 multipliers. Splitting at MEDIUM pins all three anchors exactly
# (min → 0, neutral → 0.5, max → 1) at every height, including the heights
# where MIN_PLAYABLE_LBS truncates the lean half.
static func frame_t_for(inches: int, lbs: int) -> float:
	var mid: float = float(weight_neutral(inches))
	var w: float = float(lbs)
	if w <= mid:
		var lo: float = float(weight_min(inches))
		return clampf(0.5 * (w - lo) / maxf(mid - lo, 1.0), 0.0, 0.5)
	var hi: float = float(weight_max(inches))
	return clampf(0.5 + 0.5 * (w - mid) / maxf(hi - mid, 1.0), 0.5, 1.0)


# Inverse of frame_t_for: the displayed pounds at a frame position. This is the
# frame-anchor constructor — LEAN/LIGHT/MEDIUM/SOLID/HEAVY are t = 0/.25/.5/
# .75/1 — and what the picker rides when the height slider moves, so a lean
# build stays lean as it grows.
static func weight_for_frame_t(inches: int, t: float) -> int:
	var mid: float = float(weight_neutral(inches))
	var f: float = clampf(t, 0.0, 1.0)
	if f <= 0.5:
		return int(roundf(lerpf(float(weight_min(inches)), mid, f / 0.5)))
	return int(roundf(lerpf(mid, float(weight_max(inches)), (f - 0.5) / 0.5)))


func weight_label() -> String:
	return "%d lbs" % weight


# Format an inches value as feet'inches" (e.g. 73 → 6'1").
static func inches_label(inches: int) -> String:
	return "%d'%d\"" % [inches / 12, inches % 12]


# ── Named multiplier accessors ────────────────────────────────────────────────
# Body — height (× the skate-profile gear lean where the profile owns a share)
func speed_mult() -> float:
	return _h(_SPEED_H, height) * _PROFILE_SPEED_LEAN[profile]
# Agility = height baseline × frame term (F = mv²/r — mass widens the arc and
# lengthens the stop) × profile lean. Feeds turn / brake / facing / grip.
func agility_mult() -> float:
	return _h(_AGILITY_H, height) * _f(_AGILITY_F) * _PROFILE_AGILITY_LEAN[profile]
# Edge glide is the inverse of the HEIGHT-ONLY agility component — deliberately
# NOT the full agility_mult: routing the frame term in would make a heavy build
# bleed speed while coasting, the opposite of the momentum identity the
# accel↔momentum fork promises (the tank turns wide but coasts like his mass
# says he should). The PROFILE lean does apply — blade contact length is
# literally the glide surface (the long flat coasts, the rocker scrubs).
func agility_glide_mult() -> float:
	return (2.0 - _h(_AGILITY_H, height)) * _PROFILE_GLIDE_LEAN[profile]
# Shot ceiling = height baseline × flex lean (stiff loads more).
func shot_power_mult() -> float:    return _h(_SHOT_H, height) * _FLEX_SHOT_LEAN[flex]
# Slapper wind-up: the HEIGHT part keeps the inherited inverse coupling
# (2 − power — a big frame's harder shot also threatens sooner); the FLEX
# part goes WITH the power lean (stiff = slower load) so the gear slot is a
# lateral trade, not a stacked buff. See the _FLEX_CHARGE_LEAN doc.
func shot_charge_mult() -> float:
	return (2.0 - _h(_SHOT_H, height)) * _FLEX_CHARGE_LEAN[flex]

# Body — frame (× the profile's first-step lean)
func accel_mult() -> float:         return _f(_ACCEL_F) * _PROFILE_ACCEL_LEAN[profile]
func stamina_drain_mult() -> float: return _f(_STAMINA_DRAIN_F)
func stamina_regen_mult() -> float: return _f(_STAMINA_REGEN_F)
# Mass is linear in displayed weight — see NEUTRAL_WEIGHT_LBS.
func mass_mult() -> float:          return float(weight) / NEUTRAL_WEIGHT_LBS

# Hands — CONSTITUTION: no fidelity scaling, ever. The blade tracks every
# player's cursor identically; hands differentiation arrives as lever geometry
# (stick length → tip speed vs inertia) in a later stage. Accessors kept so
# apply_attributes stays table-agnostic.
func hands_blade_mult() -> float:    return 1.0
func hands_backhand_mult() -> float: return 1.0

# Checking — body-emergent: mass (above) feeds delivery and brace through the
# collision resolver's reduced-mass math; there is no attribute term. Accessors
# kept at neutral so apply_attributes stays table-agnostic.
func check_delivery_mult() -> float: return 1.0
func brace_mult() -> float:          return 1.0

# Geometry
# Lateral body girth — a grounded model, not an authored curve: body density
# is ~constant, so cross-section area is mass/height and lateral girth is
# sqrt(mass / height), normalized to the 6'1"/201 neutral. What falls out for
# free: at a fixed BMI mass rides height², so a taller body is absolutely
# broader yet RELATIVELY narrower than its height (the elongated tall
# silhouette); a short max-frame build carries near-neutral absolute width on
# a shorter body (the hydrant). BMI band + mass floor bound it to ~[0.93, 1.10].
func girth_mult() -> float:
	return sqrt(mass_mult() / (float(height) / float(HEIGHT_MEDIUM)))


# Hitbox radius = the same girth the silhouette wears (hitbox tracks the
# visual body exactly).
func radius_mult() -> float:    return girth_mult()
func height_mult() -> float:    return _h(_HEIGHT, height)
# Height band center × the length gear lean (see _LENGTH_LEAN; `length` is
# constructor-clamped to 0..2, so the direct index is safe).
func stick_len_mult() -> float: return _h(_STICK_LEN, height) * _LENGTH_LEAN[length]

# ── Gear-lean accessors (flex + curve) ───────────────────────────────────────
# Wrister runway: fraction of the full-stroke travel this loadout needs for a
# max-power release ("max power with less real estate consumed"). Flex and
# curve stack; the floor across the stacked extremes (0.90 × 0.90 = 0.81) is
# the runway-floor constraint — a max-power release must still emit a
# readable wind-up tell (pinned by the calibration test).
func wrister_runway_mult() -> float:
	return _FLEX_RUNWAY_LEAN[flex] * _CURVE_RUNWAY_LEAN[curve]

# Backhand coefficient lean — the one place backhand varies (technique is the
# human; hands_backhand_mult stays 1.0 by constitution — this is the BLADE's
# shape, not the player's skill).
func curve_backhand_mult() -> float: return _CURVE_BACKHAND_LEAN[curve]

# Slapper-only power lean — how square the pattern keeps the blade through
# the heel-contact sweep (see the _CURVE_* doc). Multiplies with the flex
# shot lean on the slapper min/max; wristers deliberately stay flex-only.
func curve_slap_mult() -> float: return _CURVE_SLAP_LEAN[curve]

# The stick's real stiffness number, for display. Weight picks the matched
# rung of the retail ladder; the FLEX slot shifts it one rung either way. The
# numbers OVERLAP across bodies by construction — an 85 is the plank a 165 lb
# winger picks stiff and the noodle a 240 lb defenseman picks whippy — which is
# how stick fitting actually works, and is why the leans above ride the
# relative pick instead of this number: a number-driven lean would route weight
# into the shot-power axis, which is height's by design.
func flex_number() -> int:
	return flex_number_for(weight, flex)


static func flex_number_for(lbs: int, p_flex: int) -> int:
	# The matched rung is clamped off both ends of the ladder, so the gear
	# shift always lands on a real rung instead of saturating.
	var matched: int = clampi(_nearest_flex_rung(float(lbs) * _MATCHED_FLEX_PER_LB),
			1, FLEX_LADDER.size() - 2)
	return FLEX_LADDER[matched + _clamp_gear(p_flex) - GEAR_BALANCED]


# Reception ceiling lean — scales the deflect ceiling + squared-up bonus a
# receiver's blade can soak (PuckReceptionRules decision sites). Physical
# framing: the blown-open force limit of the blade shape, not a hands stat.
func reception_ceiling_mult() -> float: return _CURVE_RECEPTION_LEAN[curve]

# tan(launch angle) per loft level — this pattern's angle ladder (see the
# _CURVE_LOFT_*_DEG doc). Every rung sits under ShotMechanics.MAX_LOFT_RATIO.
func curve_loft_tan_low() -> float:
	return tan(deg_to_rad(_CURVE_LOFT_LOW_DEG[curve]))


func curve_loft_tan_mid() -> float:
	return tan(deg_to_rad(_CURVE_LOFT_MID_DEG[curve]))


func curve_loft_tan_high() -> float:
	return tan(deg_to_rad(_CURVE_LOFT_HIGH_DEG[curve]))


# Sprint ceiling — speed-normalized, grounded to the 20–25 mph burst band.
func sprint_ceiling_mult() -> float:
	var n: float = clampf((speed_mult() - _SPEED_MULT_MIN)
			/ (_SPEED_MULT_MAX - _SPEED_MULT_MIN), 0.0, 1.0)
	return lerpf(SPRINT_CEIL_MIN, SPRINT_CEIL_MAX, n)


# Carry speed retention — speed-eased (see CARRY_BASE for where the v3 hands
# term went). Higher = less penalty.
func carry_speed_mult() -> float:
	var sn: float = clampf((speed_mult() - _SPEED_MULT_MIN)
			/ (_SPEED_MULT_MAX - _SPEED_MULT_MIN), 0.0, 1.0)
	return clampf(CARRY_BASE + sn * CARRY_SPEED_GAIN, CARRY_FLOOR, CARRY_CEIL)


# Visual
# Every lateral body part wears the one grounded girth (see girth_mult) —
# the accessor seams stay so the appearance rig remains table-agnostic.
func torso_bulk_mult() -> float: return girth_mult()
func head_bulk_mult() -> float:  return _h(_HEAD_BULK, height)
func shoulder_bulk_mult() -> float:  return girth_mult()
func thigh_mult() -> float:          return girth_mult()
func calf_mult() -> float:           return girth_mult()
func forearm_bulk_mult() -> float:   return girth_mult()
func upper_arm_bulk_mult() -> float: return girth_mult()


# ── Serialization ─────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	return {
		"height": height, "weight": weight,
		"profile": profile, "curve": curve, "flex": flex, "length": length,
	}


# Rebuilds from a dict. Native v5 keys win; a v4 three-tier dict
# (height/skating/skill/checking) migrates via migrate_tiers; the oldest
# six-attribute dicts (speed/agility/hands/size/physical/shot, or the earlier
# skill/strength variants) migrate via migrate_legacy. Missing native keys
# default to neutral.
static func from_dict(d: Dictionary) -> PlayerAttributes:
	if d.has("weight") or d.has("profile"):
		return PlayerAttributes.new(
				int(d.get("height", HEIGHT_MEDIUM)),
				int(d.get("weight", 0)),
				int(d.get("profile", GEAR_BALANCED)),
				int(d.get("curve", GEAR_BALANCED)),
				int(d.get("flex", GEAR_BALANCED)),
				int(d.get("length", GEAR_BALANCED)))
	if d.has("skating") or d.has("checking"):
		return migrate_tiers(
				int(d.get("height", HEIGHT_MEDIUM)),
				int(d.get("skating", 2)), int(d.get("skill", 2)),
				int(d.get("checking", 2)))
	if d.has("speed") or d.has("agility") or d.has("size") or d.has("physical") \
			or d.has("shot") or d.has("strength"):
		# Legacy six-attribute (or four-attribute) dict.
		var legacy_skill: int = int(d.get("skill", d.get("strength", 3)))
		return migrate_legacy(
				int(d.get("speed", 3)), int(d.get("agility", 3)),
				int(d.get("hands", legacy_skill)), int(d.get("size", 3)),
				int(d.get("physical", 3)), int(d.get("shot", legacy_skill)))
	# No attribute keys at all (a name-only or height-only entry): neutral
	# frame at the given height — never the legacy migration's default shape.
	return PlayerAttributes.new(int(d.get("height", HEIGHT_MEDIUM)))


# Maps a v4 height + three-tier build (tiers 1=weak/2=average/3=strong) onto
# the body+gear model. Deterministic and documented (plan doc §9):
#   height   — carries over (coerce_height accepts 1..5 steps or inches).
#   weight   — frame anchor by the Checking tier: weak→LIGHT, avg→MEDIUM,
#              strong→SOLID (the physical identity lives in mass now).
#   profile  — strong Skating leans the skate profile the way height leaned
#              the tier: POWER at/above 6'1", AGILITY below.
#   curve    — strong Skill on a big frame was the bomber → OPEN.
#   length   — strong Checking ran the defenseman's stick → LONG; strong
#              Skill on a small frame was the dangler → SHORT.
#   flex     — always MEDIUM (no tier expressed release speed).
# Gear has no gameplay effect in step 1, so this mapping only shapes what the
# picker shows a migrated player — they lose nothing by re-picking.
static func migrate_tiers(p_height: int, skating: int, skill: int,
		checking: int) -> PlayerAttributes:
	var h: int = coerce_height(p_height)
	var frame: float = 0.5
	if checking >= 3:
		frame = 0.75
	elif checking <= 1:
		frame = 0.25
	var p_profile: int = GEAR_BALANCED
	if skating >= 3:
		p_profile = PROFILE_POWER if h >= HEIGHT_MEDIUM else PROFILE_AGILITY
	var p_curve: int = CURVE_OPEN if skill >= 3 and h >= HEIGHT_MEDIUM else GEAR_BALANCED
	var p_length: int = GEAR_BALANCED
	if checking >= 3:
		p_length = LENGTH_LONG
	elif skill >= 3 and h < HEIGHT_MEDIUM:
		p_length = LENGTH_SHORT
	return PlayerAttributes.new(h, weight_for_frame_t(h, frame),
			p_profile, p_curve, GEAR_BALANCED, p_length)


# Maps a legacy 1..5 six-attribute build to the body+gear model, through the
# same tier composite the v3→v4 migration used (Skating←speed+agility,
# Skill←hands+shot, Checking←physical; highest→strong, lowest→weak, stable
# ties by that order), then migrate_tiers. Height comes from the old Size axis.
static func migrate_legacy(speed: int, agility: int, hands: int, size: int,
		physical: int, shot: int) -> PlayerAttributes:
	var scores: Array = [
		{"idx": 0, "score": speed + agility},   # Skating
		{"idx": 1, "score": hands + shot},      # Skill
		{"idx": 2, "score": physical * 2},      # Checking
	]
	scores.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["score"] != b["score"]:
			return a["score"] > b["score"]
		return a["idx"] < b["idx"])
	var tiers: Array[int] = [2, 2, 2]
	tiers[scores[0]["idx"]] = 3
	tiers[scores[2]["idx"]] = 1
	return migrate_tiers(coerce_height(size), tiers[0], tiers[1], tiers[2])


func equals(other: PlayerAttributes) -> bool:
	if other == null:
		return false
	return height == other.height and weight == other.weight \
			and profile == other.profile and curve == other.curve \
			and flex == other.flex and length == other.length


# ── Internal ──────────────────────────────────────────────────────────────────
# Bracketing anchor rows for a height in inches: [lo_row, hi_row, t] where the
# interpolated value is lerp(row[lo], row[hi], t).
static func _anchor(inches: int) -> Array:
	var h: int = clampi(inches, HEIGHT_MIN, HEIGHT_MAX)
	for i: int in range(ANCHOR_INCHES.size() - 1):
		if h <= ANCHOR_INCHES[i + 1]:
			var span: float = float(ANCHOR_INCHES[i + 1] - ANCHOR_INCHES[i])
			var t: float = 0.0 if span <= 0.0 else float(h - ANCHOR_INCHES[i]) / span
			return [i, i + 1, t]
	var last: int = ANCHOR_INCHES.size() - 1
	return [last, last, 0.0]


# 5-vec lookup interpolated by height.
static func _h(table: Array[float], inches: int) -> float:
	var a: Array = _anchor(inches)
	return lerpf(table[a[0]], table[a[1]], a[2])


# 5-vec lookup interpolated by frame position. The anchors are evenly spaced in
# FRAME-T (0/.25/.5/.75/1) — not in BMI, which the asymmetric band leaves
# uneven — so frame_t maps linearly onto the row axis.
func _f(table: Array[float]) -> float:
	var pos: float = frame_t() * float(table.size() - 1)
	var lo: int = clampi(int(floorf(pos)), 0, table.size() - 2)
	return lerpf(table[lo], table[lo + 1], pos - float(lo))


# Accept a legacy 1..5 step (maps onto LEGACY_HEIGHT_STEPS, frozen at the v3
# heights so a migrated build keeps its body) OR a raw inches value. No real
# hockey height falls in 6..67, so the split is unambiguous.
static func coerce_height(v: int) -> int:
	if v <= LEGACY_HEIGHT_STEPS.size():
		return LEGACY_HEIGHT_STEPS[clampi(v, 1, LEGACY_HEIGHT_STEPS.size()) - 1]
	return clampi(v, HEIGHT_MIN, HEIGHT_MAX)


static func _clamp_gear(v: int) -> int:
	return clampi(v, 0, 2)


# Nearest rung of the retail flex ladder to a raw stiffness value.
static func _nearest_flex_rung(value: float) -> int:
	var best: int = 0
	for i: int in range(1, FLEX_LADDER.size()):
		if absf(value - float(FLEX_LADDER[i])) < absf(value - float(FLEX_LADDER[best])):
			best = i
	return best
