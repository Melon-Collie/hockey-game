class_name GoalieAnatomy

# The goalie's BODY, as one source of truth.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# The bot planner contained a hand-built replica of the goalie: a set of loose
# numbers in action_scoring.gd describing how wide his pads splay, how far his
# glove reaches, how big his torso is. None of them were WRONG on purpose —
# they were copied from the real body at some point and then left to drift,
# because nothing connects a literal to the collider it was copied from.
#
# Every confirmed defect in the goalie audit is an instance of that: the depth
# chart (planner kept its own copy), the band harness (a third copy), the stick
# (no copy at all). The fix that keeps working is not "correct the number", it
# is "delete the copy" — derive the planner's read from the same geometry the
# live goalie is built out of, so changing the body moves the planner for free.
#
# This file is the goalie's dimensions. GoalieStickRules is his stick (same
# pattern, split out because the blade also owns an aim solve). Between them,
# anything the planner believes about the keeper's SHAPE should come from here.
#
# ── Scope: shape, not skill ──────────────────────────────────────────────────
# Physical CAPABILITY (reaction delays, push speed, butterfly drop time) is not
# here — it is tier-varied and already shared through GoalieSkillProfile /
# set_goalie_profile, which is the correct mechanism. And the BOT's own decision
# knobs (action hysteresis, settle references) are not claims about the goalie
# at all, so they are not anatomy either. This file answers exactly one
# question: how big is he, and where.
#
# Values mirror Scenes/Goalie.tscn's collision shapes and GoalieController's
# pose exports; the controller and pose builder default FROM these so there is
# one place to change.

# ── Collider boxes (Scenes/Goalie.tscn) ──────────────────────────────────────
# Leg pad: 0.28 x 0.84 x 0.2 (LeftPad / RightPad).
const PAD_BOX_WIDTH_M: float = 0.28
const PAD_BOX_HEIGHT_M: float = 0.84
# Torso: 0.52 x 0.72 x 0.28 (Body).
const TORSO_BOX_WIDTH_M: float = 0.52
const TORSO_BOX_HEIGHT_M: float = 0.72
# Glove: 0.25 x 0.25 x 0.2 (Glove).
const GLOVE_BOX_WIDTH_M: float = 0.25

# ── Pose (GoalieController exports / GoalieBodyConfigBuilder stance) ─────────
# Lateral offset of each pad's centre from the body midline.
const PAD_LOCAL_OFFSET_M: float = 0.42
# Half-width a pad presents once ROTATED FLAT in the butterfly — the pad's long
# axis goes lateral, so this is the splayed span, not PAD_BOX_WIDTH_M * 0.5.
const BUTTERFLY_PAD_HALF_WIDTH_M: float = 0.42
# Furthest the glove hand travels outboard on a full reach
# (GoalieBodyConfigBuilder.glove_max_x_outward, sign-stripped).
const GLOVE_MAX_X_OUTWARD_M: float = 0.85
# Resting hand lateral offsets in the READY stance (that builder's
# c.glove_pos.x / c.blocker_pos.x).
const GLOVE_REST_X_M: float = 0.42
const BLOCKER_REST_X_M: float = 0.44


# Half-width the STANDING pad column covers along the ice, before any reaction:
# a pad centred at PAD_LOCAL_OFFSET_M presenting half its box.
static func standing_pad_column_half_width() -> float:
	return PAD_LOCAL_OFFSET_M + PAD_BOX_WIDTH_M * 0.5


# Half-width the pads cover once the BUTTERFLY has landed — the splayed edge.
# This is the widest the legs ever get, and the LOW band's fully-deployed core.
static func butterfly_pad_edge_half_width() -> float:
	return PAD_LOCAL_OFFSET_M + BUTTERFLY_PAD_HALF_WIDTH_M


# Half-width of the torso alone — the part of the high band that is covered no
# matter what the hands are doing.
static func torso_half_width() -> float:
	return TORSO_BOX_WIDTH_M * 0.5


# Outer edge of a RESTING glove hand: the hand's stance offset plus half its
# box. What the high band covers laterally with zero reaction, assuming the
# shot arrives inside the hand's vertical extent.
static func resting_hand_outer_half_width() -> float:
	return maxf(GLOVE_REST_X_M, BLOCKER_REST_X_M) + GLOVE_BOX_WIDTH_M * 0.5


# Furthest the high band can ever cover — a fully deployed glove.
static func deployed_hand_half_width() -> float:
	return GLOVE_MAX_X_OUTWARD_M
