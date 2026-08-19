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


static func butterfly_pad_edge_half_width() -> float:
	return PAD_LOCAL_OFFSET_M + BUTTERFLY_PAD_HALF_WIDTH_M


# Half-width of the torso alone — the part of the high band that is covered no
# matter what the hands are doing.
static func torso_half_width() -> float:
	return TORSO_BOX_WIDTH_M * 0.5


const HEAD_BOX_M: float = 0.26

const PAD_CENTER_Y_STANDING_M: float = 0.44
const TORSO_CENTER_Y_STANDING_M: float = 1.22
const HEAD_CENTER_Y_STANDING_M: float = 1.79

const PAD_CENTER_Y_BUTTERFLY_M: float = 0.14
const TORSO_CENTER_Y_BUTTERFLY_M: float = 0.40
const HEAD_CENTER_Y_BUTTERFLY_M: float = 0.97


# Vertical extent (bottom, top) of a part, as a Vector2 so callers can test a
# height against it without allocating.
static func _span(center_y: float, height: float) -> Vector2:
	return Vector2(center_y - height * 0.5, center_y + height * 0.5)


# The leg pads. Standing they are a 0.84 m column bottoming at the ice and
# topping out at the pad-top seam (GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M);
# rolled flat in the butterfly they are only their own box WIDTH tall — 0.28 m,
# which is 11 inches, the real NHL pad width. That collapse is the whole reason
# the over-the-pad shot exists: going down trades 0.58 m of vertical coverage
# for 0.48 m of lateral splay.
static func pad_span(down: bool) -> Vector2:
	if down:
		return _span(PAD_CENTER_Y_BUTTERFLY_M, PAD_BOX_WIDTH_M)
	return _span(PAD_CENTER_Y_STANDING_M, PAD_BOX_HEIGHT_M)


# The trunk. Standing it is glued to the pad-top seam (0.86–1.58); in the save
# stances it drops with the body so the same box spans 0.04–0.76 — which is
# what leaves a gap above it once the pads are flat.
static func torso_span(down: bool) -> Vector2:
	if down:
		return _span(TORSO_CENTER_Y_BUTTERFLY_M, TORSO_BOX_HEIGHT_M)
	return _span(TORSO_CENTER_Y_STANDING_M, TORSO_BOX_HEIGHT_M)


# The height at which GOING DOWN STOPS COVERING THE SHOT — the top of the trunk
# in the save stances, above which the butterfly silhouette holds nothing until
# the mask. This is the anatomical line coaching states as "drop for shots below
# the belly button": below it the seal is the wider answer, above it dropping
# concedes the very band it was meant to take away. Derived from the stance so a
# resize moves the fork with it (GoalieController.elevated_threshold).
static func butterfly_cover_ceiling() -> float:
	return torso_span(true).y


static func head_span(down: bool) -> Vector2:
	if down:
		return _span(HEAD_CENTER_Y_BUTTERFLY_M, HEAD_BOX_M)
	return _span(HEAD_CENTER_Y_STANDING_M, HEAD_BOX_M)


# Half the vertical reach of a hand about its own centre — how far off a hand's
# height a puck can arrive and still meet it.
static func hand_vertical_half_extent() -> float:
	return GLOVE_BOX_WIDTH_M * 0.5


# Does a hand centred at `hand_y` meet a puck arriving at `arrival_y`?
static func hand_covers_height(arrival_y: float, hand_y: float) -> bool:
	return absf(arrival_y - hand_y) <= hand_vertical_half_extent()


# Half-width the keeper's STRUCTURE covers at arrival height `y` — pads, trunk
# and head only. The HANDS are deliberately absent: they move, they are raced
# against the shot's flight in the planner's reaction model, and their live
# positions arrive as replicated pose. This answers the part of the question
# that is pure shape, and the caller adds whatever the hands win.
#
# The result is symmetric because every structural part is centred on the
# midline; only the hands are sided.
static func structural_cover_half_width_at(y: float, down: bool) -> float:
	var cover: float = 0.0
	var pads: Vector2 = pad_span(down)
	if y >= pads.x and y <= pads.y:
		cover = maxf(cover, butterfly_pad_edge_half_width() if down
				else GoalieBehaviorRules.STANDING_PAD_CENTER_X_M + PAD_BOX_WIDTH_M * 0.5)
	var torso: Vector2 = torso_span(down)
	if y >= torso.x and y <= torso.y:
		cover = maxf(cover, torso_half_width())
	var head: Vector2 = head_span(down)
	if y >= head.x and y <= head.y:
		cover = maxf(cover, HEAD_BOX_M * 0.5)
	return cover
