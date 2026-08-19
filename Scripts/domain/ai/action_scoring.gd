class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1]. `score_shoot` is xG-SHAPED
# (peak in the slot, fading with range and angle) but NOT magnitude-calibrated:
# read the outputs as RELATIVE shot quality, never as a goal probability.
#
# Top-level options compete uniformly, on one scale:
#
#   shoot:  score_shoot(self_pos)
#   pass:   score_at(receiver_lead) × lane_clear × time_factor
#   carry:  score_at(candidate)     × path_clearance × time_factor
#
# score_at(pos) = max(score_shoot(pos), carry_to_slot_from_pos), defined in the
# carrier. There is deliberately no leaf-pass term inside it: at depth 2 only
# the receiver's own shot and carry-to-slot are considered, which bounds the
# recursion and keeps two bots out of a mutual pass loop.
#
# Dumps do NOT compete on this scale — they are priced in their own currency (a
# concession, plus the race the dump-in earns a gain from) and meet the carry in
# AIRoleCarrier's commit compete.

# Shared read-only empty arrays for the optional opponent-context args below.
# Passing these instead of a fresh `[]` at the internal pass-through sites keeps
# the leaf scorers (score_shoot / score_pass / lane_clear), which fire tens of
# times per carrier compete × bots, from allocating an empty array per call.
#
# Two traps. They are for ARGUMENT sites only: a shared empty used as a
# *parameter default* trips a Godot type-binding error at call time, so the
# `= []` defaults below stay literals. And EMPTY_VEC3 must be a `static var`,
# not a `const`: a typed-`const` array loses its element type when passed as a
# typed-array argument (Godot rejects it — "does not have the same element
# type"), whereas a typed static var keeps it. EMPTY_CAPS is untyped, so a
# read-only `const` is fine there.
static var EMPTY_VEC3: Array[Vector3] = []
const EMPTY_CAPS: Array = []

static func _static_init() -> void:
	EMPTY_VEC3.make_read_only()

# SLOT_RADIUS_M is the platform width — positions within this distance
# of the goal are all peak-value. Tuning: up (8 m) makes the gradient
# pull bots from further out; down (4 m) tightens the sweet spot.
const SLOT_RADIUS_M: float = 6.0

# ── Shot danger: hole-based open-net model ───────────────────────────────────
# score_shoot rates a shot by evaluating the classic goalie "holes" as separate
# targets, taking the BEST one. The score is that hole's opening; which hole it
# is decides the LOFT the bot shoots (best_shot_loft). This is pure geometry
# from the shooter's eye — distance, angle, and coverage all EMERGE (see
# _hole_open_angle) — with the goalie a body that occludes part of the net.
#
#   1,2  top corners     -> HIGH loft (over the glove/blocker held up in stance)
#   3,4  bottom corners  -> FLAT      (beside the pads)
#   5    five-hole       -> FLAT      (between the legs — opens when he's moving)
#
# HIGH holes ride the manual angle ladder (docs/elevation-rework-plan.md v3):
# the release is FULL pace and the bot PICKS THE RUNG — the elevated level
# whose set-angle arc arrives highest in the top band without missing high
# (_best_high_rung), the same read a practiced human makes. From the point
# that rung is LOW (the mid-blade snipe); in tight it is the toe, and only a
# steep ladder has one that gets up in time — the roofing gradient. A DOWN
# goalie still concedes the top band's arm extension (the butterfly's
# defining trade); a SET goalie keeps the reaction race at full-pace flight
# times.
#
# The goalie FREEZES on the shot (he can't slide into it), so the only thing
# range buys him is REACTION time to extend the relevant body part to the
# placement. The reaction budget is the puck's travel time to the GOALIE'S BODY
# (t_reach — the shooter→goalie gap at the band's pace), NOT the flight to the
# goal line: the save happens where the puck crosses his reach envelope, which a
# challenging keeper puts a large fraction of the flight closer to the shooter.
# Never budget on the flight to the goal line: that hands him the whole flight
# to deploy, and from 4 m a top-band arc passes his body at 0.14 s — before his
# 0.18 s arm read even fires — while scoring against a 0.25 s flight.
#
# Each hole reads its own height BAND, and the bands differ in exactly the two
# ways a real goalie's do — a wider always-covered CORE and a slower REACTION —
# which is what makes the loft choice fall out of the same geometry:
#   cover = CORE + EXT × reaction ;  reaction = clamp((t_reach − DELAY)/DEPLOY,0,1)
#   openness = the net bearing interval the hole clears past the cover's BODY-DISC
#              tangent cone (he squares to the puck, so the cover half-width faces
#              every sightline — sharp angles are walled by his depth), minus the
#              puck's clean-entry fit inset and the shooter's execution spread
# Aggressive angle-challenging (the goalie playing OUT for a longer shot) is not
# a constant — it's just where the goalie actually is, fed in as goalie_pos.
#
# The band cores/reaches are grounded, not fitted:
#  · LOW  — legs/pads AND the stick. The pad column alone is only
#           LOW_CORE_STANDING_M standing; the wider butterfly core exists only
#           after the leg read + pads-to-floor drop (GOALIE_BUTTERFLY_DROP_S —
#           the same gate the five-hole seal runs), so an in-tight low shot
#           beats the DROP exactly as it does against the live keeper. What it
#           does not beat is the paddle already lying on the ice:
#           stick_low_cover() floors the band by the BLADE'S OWN WIDTH from the
#           first frame, un-raced, which is why the standing keeper's low net
#           measures shut in tight — where angle compression makes even that
#           narrow blade span most of the mouth. A DOWN goalie's splayed pads
#           exceed it.
#  · HIGH — glove/blocker, NARROWEST core (held up they leave the top corners)
#           but the longest reach (out to 0.85 m ≈ glove_max_x_outward) on a slow
#           ARM reaction. In tight the glove can't extend -> roof it; at range it
#           gets there -> top corners shut. This is the over-the-shoulder read.
# Total HIGH reach (CORE+EXT = 0.85) mirrors the live goalie's glove_max_x_outward.
#
# The model has no MID/armpit band and no STATIC body-side hole: that seam only
# opens when the goalie commits an arm elsewhere. The replicated pose
# (goalie_hands) makes that condition visible, so HIGH cover races from where
# each hand actually is (_band_cover's per-side hand read) and the seam emerges
# exactly when a hand is genuinely caught low or wide — never as a phantom the
# resting stance covers.
#
# [LOW, HIGH] half-width, fully deployed. LOW must track the live butterfly's
# real splayed pad edge — pad_local_offset 0.42 + butterfly_pad_half_width 0.42
# (GoalieController's pose), the exact span the shot-outcome sim measures saves
# with. Undersell the splay and the planning model invents low-corner windows
# the real keeper closes.
const HOLE_BAND_CORE: Array[float] = [0.84, 0.40]
# Standing LOW core: the pad column a standing goalie covers with NO reaction —
# stance pad center + half a pad box, mirrored from the live goalie's stance
# anatomy (GoalieBehaviorRules). Everything between this and HOLE_BAND_CORE[LOW]
# only exists once the butterfly drop lands.
const LOW_CORE_STANDING_M: float = (
		GoalieBehaviorRules.STANDING_PAD_CENTER_X_M
		+ GoalieBehaviorRules.PAD_BOX_WIDTH_M * 0.5)

# ── The keeper's STICK, the LOW band's primary surface while he is upright ───
# Every other `stick` in this file is LANE_DEFENDER_REACH_M, a SKATER's blade in
# a passing lane. This one is the goalie's paddle lying across the ice, and four
# properties decide how it enters:
#   · SYMMETRIC — the blade-aim solve yaws the paddle toward the threat, so both
#     sides measure identically. This keeper's stick is not the stick-side-only
#     asset a real goalie's is.
#   · NOT reaction-gated — it is already on the ice in the stance, which is why
#     it eats the in-tight shot the pads have no time to drop for. It floors the
#     CORE; the lateral push still adds on top.
#   · LOW BAND ONLY — the blade is GoalieStickRules.BLADE_HEIGHT_M (0.07 m)
#     tall, so an elevated puck clears it entirely. Entering it here and NOT in
#     HIGH is the whole point: it does not make every shot worse, it makes the
#     FLAT shot worse and leaves the roof alone, which is the band choice the
#     live keeper's save distribution rewards.
#   · ITS OWN WIDTH, NOT ITS REACH — do not feed standing_lateral_reach() here.
#     That is a PLACEMENT ENVELOPE, the furthest off centre the blade can be
#     swung; the band cover is consumed as a DISC half-width by the tangent-cone
#     occlusion, i.e. surface the keeper presents in every direction at once.
#     The envelope makes him a 0.64 m solid disc instead of a 0.38 m blade,
#     which projects over 84-100% of the mouth at every range and shuts the flat
#     net everywhere. The error is geometric, not temporal, so racing the
#     envelope does not fix it either (at 7.8 m the flight gives him 0.25 s
#     against a 0.09 s deploy — any ramp saturates back to 0.64). Pricing where
#     the blade can be PUT needs a per-hole placement race, not a wider floor.
#
# Read from the blade's own box in GoalieStickRules (the same source the POSED
# stick reads), so the planned stick and the posed stick cannot drift apart.
static func stick_low_cover() -> float:
	return GoalieStickRules.BLADE_WIDTH_M * 0.5
# Reaction-gated extension to the placement. LOW has none of its own: the pad
# column's widening IS the butterfly drop (core lerp), and everything beyond it
# is the lateral push (_goalie_lateral_reach in _band_cover).
const HOLE_BAND_EXT: Array[float] = [0.0, 0.45]
const GOALIE_ARM_DEPLOY_S: float = 0.09   # reaction ramp width — time to extend to the placement.
										  # Hard baseline: HIGH-band EXT (0.45) / glove_react_max_speed
										  # (5.0) ≈ 0.09 s to cover the reaction-gated reach. The live
										  # value tracks the tier via set_goalie_profile.


# Per-band reaction delay (legs fast, arms slow) — the difficulty-synced read
# latencies (see set_goalie_profile below).
static func _delay_at_height(arrival_y: float, goalie_down: bool) -> float:
	# Which limb has to answer decides the latency, and that is a question about
	# the puck's HEIGHT against his current pad top — not about a band index.
	# Standing, the pad column runs to the seam, so everything under it is legs
	# and everything over it is arms: exactly the LOW/HIGH split. Down, the
	# pads collapse to 0.28 m and the answer changes — an over-the-pad puck is
	# the HANDS' problem now, and it pays the slower arm read.
	if arrival_y <= GoalieAnatomy.pad_span(goalie_down).y:
		return goalie_leg_delay_s
	return goalie_arm_delay_s

# ── HIGH-band viability under the angle ladder ────────────────────────────────
# The four loft levels are SET ANGLES from the shooter's blade ladder
# (docs/elevation-rework-plan.md v3), so a top-band look is a RUNG CHOICE:
# the bot picks the elevated rung whose full-pace arc arrives highest inside
# the band at the net — top shelf, without missing high — which is the same
# read a practiced human makes. The band:
#   · floor — the PAD-TOP SEAM (GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M,
#     0.86 m): below it the shot is contested by the pad column the LOW band
#     already models. A flat ladder in tight arrives under the seam on every
#     rung — the roofing gradient.
#   · ceiling — the scoring cavity's top (HIGH_BAND_CEILING_M): above it the
#     puck misses high. A steep ladder at range sails on every rung — bots
#     never deliberately miss.
#   · a STANDING keeper's plane — the arc must cross him above his stick
#     assembly (GoalieStickRules.PADDLE_HEIGHT_M); a DOWN goalie's paddle is
#     on the ice (the LOW band's business) and bars nothing, which is what
#     leaves the doorstep roof over the butterfly live.
const GRAVITY_M_S2: float = 9.8   # engine default the airborne puck falls under
# Scoring cavity top: NET_HEIGHT − post radius − puck half-height, less a
# whisker — mirrors goal detection's under-the-bar bound.
const HIGH_BAND_CEILING_M: float = 1.17
# The M92 (league-neutral) ladder — the default wherever a build isn't known
# (defensive reads of opponents, unwired tests).
const DEFAULT_LOFT_TANS: Vector3 = Vector3(0.1405, 0.3153, 0.4452)


# Arrival height (m above launch) of a set-angle arc at `dist`:
#   h = d·tan − g·d²·(1 + tan²) / (2p²)
static func _arrival_height(dist: float, speed: float, tan_a: float) -> float:
	return dist * tan_a \
			- GRAVITY_M_S2 * dist * dist * (1.0 + tan_a * tan_a) / (2.0 * speed * speed)


# The elevated LEVEL (ELEVATION_LOW..HIGH) whose full-pace arc lands highest
# inside the band from `dist`, or 0 (ELEVATION_FLAT) when no rung does — the
# committed loft of a HIGH-band hole (best_shot_loft) and its viability.
static func _best_high_rung(dist: float, shot_speed_m_s: float,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS, goalie_dist: float = -1.0,
		goalie_down: bool = false) -> int:
	var best_level: int = ShotMechanics.ELEVATION_FLAT
	var best_cover: float = INF
	# The floor is HIS PAD TOP, not a fixed seam: a rung arriving under the
	# pads is the pad column's business, which the flat holes already model.
	# Standing that is the 0.86 m seam; once he is down the pads collapse to
	# 0.28 m and the rungs between become real targets. No puck inset here:
	# eligibility is "is he pad there", and
	# the cover model below charges whatever actually is at that height.
	var floor_y: float = GoalieAnatomy.pad_span(goalie_down).y
	for i: int in 3:
		var tan_a: float = loft_tans[i]
		var arrive: float = _arrival_height(dist, shot_speed_m_s, tan_a)
		if arrive <= floor_y or arrive > HIGH_BAND_CEILING_M:
			continue
		if goalie_dist > 0.0 and not goalie_down and _arrival_height(
				goalie_dist, shot_speed_m_s, tan_a) < GoalieStickRules.PADDLE_HEIGHT_M:
			continue
		# SHAPE picks the rung: the height where the least of him is in the
		# way. The race (hands, push, his read budget) is not consulted here —
		# it needs a pace that needs a rung, and resolving that circularity by
		# guessing would make the choice depend on its own answer. A shooter
		# reads posture; whether the shot beats him is _cover_at_height's
		# question. Ties keep the FLATTER rung — the easier contact, and the
		# same preference LOFT_TIE_FRAC applies between holes.
		var cover: float = GoalieAnatomy.structural_cover_half_width_at(
				arrive, goalie_down)
		if cover < best_cover:
			best_cover = cover
			best_level = ShotMechanics.ELEVATION_LOW + i
	return best_level


# Horizontal pace of the full-power release on the chosen rung from `dist`,
# or 0.0 when the band is structurally closed (no rung lands in it).
static func _high_band_pace(dist: float, shot_speed_m_s: float,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS, goalie_dist: float = -1.0,
		goalie_down: bool = false) -> float:
	var level: int = _best_high_rung(dist, shot_speed_m_s, loft_tans,
			goalie_dist, goalie_down)
	if level == ShotMechanics.ELEVATION_FLAT:
		return 0.0
	var tan_a: float = loft_tans[level - ShotMechanics.ELEVATION_LOW]
	return shot_speed_m_s / sqrt(1.0 + tan_a * tan_a)


# The rung a hole's shot flies: FLAT along the ice for the low bands, the
# posture-picked rung for a HIGH hole (ELEVATION_FLAT there means the band is
# structurally closed — no rung clears his pads without missing high). Callers
# read this ONCE and derive pace, arrival height and cover from it, so the
# score, the loft and the aim cannot describe different shots.
static func _hole_rung(band: int, dist: float, shot_speed_m_s: float,
		loft_tans: Vector3, goalie_dist: float, goalie_down: bool) -> int:
	if band != HOLE_BAND_HIGH:
		return ShotMechanics.ELEVATION_FLAT
	return _best_high_rung(dist, shot_speed_m_s, loft_tans, goalie_dist, goalie_down)


# Horizontal pace of a release on `level` — a lofted arc spends pace on the
# climb, a flat shot keeps all of it.
static func _rung_pace(level: int, shot_speed_m_s: float,
		loft_tans: Vector3) -> float:
	if level == ShotMechanics.ELEVATION_FLAT:
		return maxf(shot_speed_m_s, 1.0)
	var tan_a: float = loft_tans[level - ShotMechanics.ELEVATION_LOW]
	return shot_speed_m_s / sqrt(1.0 + tan_a * tan_a)


# Height that rung crosses the net line at. FLAT rides the ice.
static func _rung_arrival(level: int, dist: float, shot_speed_m_s: float,
		loft_tans: Vector3) -> float:
	if level == ShotMechanics.ELEVATION_FLAT:
		return 0.0
	return _arrival_height(dist, shot_speed_m_s,
			loft_tans[level - ShotMechanics.ELEVATION_LOW])


# Horizontal pace (m/s) of a shot at hole band `band` over `dist` to the net —
# HIGH holes fly the full-pace contact-point arc (0.0 when the band is
# structurally closed), FLAT bands the committed full pace. The five-hole rides
# the LOW band. Divides the shooter→goalie gap for the reach budget (t_reach).
static func _band_pace(band: int, dist: float, shot_speed_m_s: float,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS, goalie_dist: float = -1.0,
		goalie_down: bool = false) -> float:
	if band == HOLE_BAND_HIGH:
		return _high_band_pace(dist, shot_speed_m_s, loft_tans, goalie_dist,
				goalie_down)
	return maxf(shot_speed_m_s, 1.0)


# The goalie's covered half-width (m) for a band, given the READ budget
# `t_read` — the puck's travel time to HIS body minus everything that delays
# his read starting: screen occlusion and the caught-moving lateness (see
# _hole_open_angle's t_read). One implementation shared by _hole_open_angle
# and _hole_aim_x so aim and score always read the same edge.
#   HIGH: stance core + the reaction-gated arm extension; a DOWN goalie's glove
#         starts at pad height, so the extension is conceded entirely (the
#         butterfly's defining trade).
#   LOW:  standing pad column, widened to the live butterfly's splayed pad
#         edge by the drop gate (read + pads-to-floor time — the same gate
#         the five-hole seal runs). A DOWN goalie is already sealed there.
#   BOTH: plus the real lateral PUSH — the accel-limited T-push he lands
#         inside the read window (_goalie_lateral_reach, the live
#         controller's ramp). This is the recovery race the model was blind
#         to: a goalie left off the shot line (predict_goalie_pos mid-carry,
#         a cross-seam feed) physically pushes back toward the crossing, and
#         how much of that gap he closes is pure kinematics — honest range
#         windows shrink, honest in-tight and caught-moving windows stay
#         open because the flight beats his first stride.
# The splayed (butterfly) pad's half-LENGTH — the x-extent a 90°-rolled pad
# presents. HOLE_BAND_CORE[LOW] (0.84) = pad offset 0.42 + this, the same
# anatomy the declared constant was derived from.
const PAD_SPLAY_HALF_M: float = 0.42


# A pad's LOW-band x-extent from its replicated roll, consumed as
# SPLAYED-vs-STANDING (45° threshold): a standing pad — including the
# stance's cosmetic ~12° A-frame lean — presents its box width (exactly
# the declared stance column, calibration-checked), a rolled-flat pad its
# full splayed half-length. Fine roll interpolation is deliberately NOT
# modeled: the butterfly-drop race in _band_cover owns mid-transition
# growth, and no instrument calibrates the intermediate angles — an
# uncheckable curve would be shape-fitting, not measurement.
static func _pad_half_extent(roll: float) -> float:
	if absf(sin(roll)) > 0.707:
		return PAD_SPLAY_HALF_M
	return GoalieBehaviorRules.PAD_BOX_WIDTH_M * 0.5


static func _cover_at_height(arrival_y: float, t_read: float, goalie_down: bool,
		side: int = 0, goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF) -> float:
	# Height-resolved cover: which of his parts are actually AT the puck's
	# arrival height, each still raced against the read budget exactly as the
	# two-band model raced them. The shape comes from GoalieAnatomy; the race
	# is this function's job (see _best_high_rung for the other half of that
	# split — shape picks the rung, the race scores it).
	var t_move: float = maxf(0.0, t_read - _delay_at_height(arrival_y, goalie_down))
	var push: float = goalie_lateral_reach(t_move)
	var pads_top: float = GoalieAnatomy.pad_span(goalie_down).y
	var band: int = HOLE_BAND_LOW if arrival_y <= pads_top else HOLE_BAND_HIGH
	# The puck's own radius rides on the cover edge: a puck whose CENTER
	# passes within a radius of the pad/glove edge is clipped — the exact
	# mirror of the clean-entry inset the post side already charges. Without
	# it, sub-puck slivers past the edge read as real windows (the sharp-
	# angle phantom in miniature).
	var edge: float = GameRules.PUCK_COLLISION_RADIUS + push
	if band == HOLE_BAND_HIGH:
		# ── Above his pads: STRUCTURE plus whatever the hands win ────────
		# The structural floor is the trunk/head actually at this height
		# (GoalieAnatomy), not a single declared core — which is the whole
		# point of resolving height. Above the standing seam it is floored by
		# HOLE_BAND_CORE[HIGH]: 0.40 was measured for that band and the raw
		# box list under-represents it there (shoulders and arm roots are not
		# colliders). Below the seam — the over-the-pad and armpit heights —
		# the geometry stands on its own.
		var structural: float = GoalieAnatomy.structural_cover_half_width_at(
				arrival_y, goalie_down)
		if arrival_y >= GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M:
			structural = maxf(structural, HOLE_BAND_CORE[HOLE_BAND_HIGH])
		# With the replicated pose in scope (goalie_hands finite, a signed
		# hole side), the reaction race STARTS where the hand actually is
		# instead of at a declared stance core: a READY hand (parked at ~the
		# torso edge) deploys at the stance rate, a hand committed LOW
		# (butterfly, gloves at pad height) must LIFT to the puck's height
		# before its lateral coverage counts, and a hand caught on the wrong
		# side contributes nothing this side beyond the structure.
		if side != 0 and goalie_hands.is_finite():
			var arm_speed: float = HOLE_BAND_EXT[HOLE_BAND_HIGH] \
					/ maxf(goalie_arm_deploy_s, 0.001)
			var cap: float = HOLE_BAND_CORE[HOLE_BAND_HIGH] \
					+ HOLE_BAND_EXT[HOLE_BAND_HIGH]
			# The hand defending this side: the one with the larger
			# side-ward offset from the goalie's center.
			var dx_a: float = goalie_hands.x * float(side)
			var dx_b: float = goalie_hands.z * float(side)
			var hand_lat: float = dx_a
			var hand_y: float = goalie_hands.y
			if dx_b > dx_a:
				hand_lat = dx_b
				hand_y = goalie_hands.w
			var t_arm: float = t_move
			# A hand below the PUCK covers nothing until it has risen to it —
			# the lift spends read budget at the arm's pace. Racing to the
			# puck's own height rather than to a fixed seam is what makes the
			# armpit a real target: a keeper whose gloves are sealed at 0.49 m
			# has to travel to 0.70 m, and often cannot in the time given.
			var reach_y: float = arrival_y - GoalieAnatomy.hand_vertical_half_extent()
			if hand_y < reach_y:
				t_arm = maxf(0.0, t_arm - (reach_y - hand_y) / arm_speed)
				if t_arm <= 0.0:
					# Hand still below the puck at arrival — structure only.
					return structural + edge
			# A hand caught on the WRONG side (negative side-ward offset)
			# pays the cross-over distance — it starts from where it is.
			var start_lat: float = clampf(hand_lat, -cap, cap)
			var hand_cover: float = clampf(start_lat + arm_speed * t_arm, 0.0, cap)
			return maxf(structural, hand_cover) + edge
		var deploy: float = 0.0 if goalie_down \
				else clampf(t_move / goalie_arm_deploy_s, 0.0, 1.0)
		return structural + HOLE_BAND_EXT[HOLE_BAND_HIGH] * deploy + edge
	# ── Hole-model v3: the LOW cover reads the side's REAL pad ───────────
	# With the replicated pads in scope, the side's cover starts at the
	# MEASURED pad edge — the pad's rotated-box x-extent (box half-width
	# ·|cos roll| + splay half-length·|sin roll|: standing ~0.22 m tall
	# pads project narrow, the 90°-rolled butterfly pad its full splayed
	# length) at its actual lateral offset — and the butterfly drop RACE
	# grows it toward the committed splay edge at the same average pace
	# the declared-stance lerp implied. Mid-drop, mid-slide, and the
	# asymmetric post stances all read as the pads actually sit; a DOWN
	# goalie's measurement IS the truth (nothing left to drop).
	# The stick is on the ice from the first frame, so it FLOORS whatever the
	# pads have managed — it is not raced, and it applies down as well as up
	# (the splayed pads simply exceed it). See stick_low_cover.
	var stick: float = stick_low_cover()
	if side != 0 and goalie_pads.is_finite():
		var d_left: float = goalie_pads.x * float(side) + _pad_half_extent(goalie_pads.y)
		var d_right: float = goalie_pads.z * float(side) + _pad_half_extent(goalie_pads.w)
		var measured: float = maxf(maxf(d_left, d_right), 0.0)
		if goalie_down:
			return maxf(measured, stick) + edge
		var drop_rate: float = (HOLE_BAND_CORE[HOLE_BAND_LOW] - LOW_CORE_STANDING_M) \
				/ maxf(goalie_butterfly_drop_s, 0.001)
		return maxf(minf(measured + drop_rate * t_move,
				maxf(HOLE_BAND_CORE[HOLE_BAND_LOW], measured)), stick) + edge
	var core: float = HOLE_BAND_CORE[HOLE_BAND_LOW]
	if not goalie_down:
		var drop: float = clampf(t_move / goalie_butterfly_drop_s, 0.0, 1.0)
		core = lerpf(LOW_CORE_STANDING_M, HOLE_BAND_CORE[HOLE_BAND_LOW], drop)
	return maxf(core, stick) + edge

# Loft choice prefers the SIMPLER shot among comparable openings: a heel-flat
# release is the easier contact than riding the toe, and when a low hole and a
# high hole are both open there is nothing the roof buys. So best_shot_loft
# takes the flattest hole whose opening is within this fraction of the widest —
# committing to a roof only when the top is meaningfully the better way in.
# The SCORE is still the widest opening; this only picks the loft.
const LOFT_TIE_FRAC: float = 0.85
const HOLE_BAND_LOW: int = 0
const HOLE_BAND_HIGH: int = 1

# Hole kinds (how the opening is measured — see _hole_open_angle).
const HOLE_KIND_CORNER: int = 0   # net-relative post; opening = net cleared past the cover edge
const HOLE_KIND_FIVE: int = 1     # goalie-relative low-centre gap; opens when he's UNSETTLED

# The five holes as parallel arrays (indexed 0..4, no per-call allocation).
const HOLE_KIND: Array[int] = [
		HOLE_KIND_CORNER, HOLE_KIND_CORNER,   # 1,2 top corners
		HOLE_KIND_CORNER, HOLE_KIND_CORNER,   # 3,4 bottom corners
		HOLE_KIND_FIVE,                       # 5   five-hole
]
const HOLE_SIDE: Array[int] = [-1, 1, -1, 1, 0]   # net/goalie side; 0 = centred
const HOLE_BAND: Array[int] = [
		HOLE_BAND_HIGH, HOLE_BAND_HIGH,
		HOLE_BAND_LOW, HOLE_BAND_LOW,
		HOLE_BAND_LOW,
]
const HOLE_COUNT: int = 5

# Five-hole: a set goalie seals it; it opens as he's caught moving (the
# goalie_unsettled_factor delays his read — see UNSETTLE_READ_PENALTY_S). Modeled
# as a physical GAP between the splayed pads, so its angular size FORESHORTENS
# with range like any real target (gap / distance) — a five-hole from the point is
# a sliver, from in tight a real opening. Only a roughly head-on look can thread
# the legs (centrality falls off past FIVE_CENTER_REF_M of lateral offset).
const FIVE_GAP_M: float = 0.18
const FIVE_CENTER_REF_M: float = 1.6

# A goalie caught moving (goalie_unsettled_factor) reads the release LATE —
# this much added read delay at unsettled = 1, mirroring the live goalie /
# shot-outcome sim (UNSETTLE_REACT_PENALTY_S). Entering the model as a read
# delay (not a reaction-killing scalar) makes the recovery emergent: a long
# flight hands the delay back through the same reach race — the drop, the
# glove, and the lateral push all still land — while a quick release inside
# the delayed read meets a goalie who never moved. The race IS the fade; it
# needs no separate recovery constant.
const UNSETTLE_READ_PENALTY_S: float = 0.15

# The sharpest release scatter the game actually produces (the Hard bot hand;
# a human flick is no cleaner). Floors the make-probability division below so
# a zero-spread agent still reads window WIDTH as value gradient rather than
# collapsing every sliver to a certainty.
const MIN_RELEASE_SPREAD_RAD: float = 0.010

# ── The cover edge is not a knife-edge ───────────────────────────────────────
# 1σ of WHERE the goal/save boundary actually falls, measured laterally at the
# keeper's body. The hole geometry computes one exact edge from one predicted
# pose; the real edge is a distribution, and this is its width.
#
# Derived by ELIMINATION rather than picked, because most of what looks like
# edge uncertainty is already charged somewhere else:
#   · pose — a pad's x-extent swings ~0.20 m between the stance column and the
#     splayed butterfly edge, but the DROP RACE in _band_cover already resolves
#     where in that swing he is;
#   · the puck's own radius — a puck whose centre passes within a radius of the
#     edge is clipped, and _band_cover ALREADY adds PUCK_COLLISION_RADIUS to
#     the cover for exactly that. Charging it again here is a double-count;
#   · the lateral push — explicit and kinematic (_goalie_lateral_reach).
# What is left is the timing residual the push model cannot resolve: his
# position at arrival versus the prediction, within one read quantum. At the
# t-push speed that is about a tick's worth of travel, ~0.03 m.
#
# Consumed by goalie_edge_spread, which foreshortens it to an angle at the
# shooter's range. It sets how much range the decision currency has, so
# test_shot_currency_saturation.gd and the real-goalie calibration are the
# readouts whenever it moves.
const GOALIE_EDGE_SOFTNESS_M: float = 0.03

# 1σ of a well-aimed shot's arrival scatter BEYOND the shooter's aim error, in
# radians. ZERO, and that is a measurement rather than a default: the release
# applies exactly the aim angle plus the tier's error and the puck then flies
# deterministic analytic physics, so in THIS game a well-aimed shot goes
# exactly where it was aimed (real_goalie_shot_harness.shot_velocity_at is the
# same launch the bots execute).
#
# Do not raise it to buy the decision currency more range when the make ramp
# saturates: a nonzero scatter here charges every shot for dispersion the
# simulation does not produce, and it under-reads real chances by about a
# third. Range comes from real geometry (the goalie's stick shrinks the
# in-tight windows). Kept as a named zero so the seam is visible if the shot
# ever DOES gain dispersion (a wobbling puck, a contested release).
const PLACEMENT_DISPERSION_RAD: float = 0.0

# What _hole_margin returns for a hole that is not a target at all — behind the
# goal line, a band no legal power reaches, a deployed post seal, a release
# already inside his body. Structurally impossible rather than merely covered,
# so it must sit far below any softness width and never read as "nearly open".
const HOLE_STRUCTURALLY_CLOSED_RAD: float = -1.0

# Goalie position prediction. React-then-push: react delay first, then move
# toward the puck-at-release X — ACCELERATING onto the edge (the live keeper's
# lateral_accel ramp) up to max push speed, never snapping to it. The ramp is
# what a hard lateral cut in tight genuinely beats: over a sub-quarter-second
# release window an accelerating keeper covers centimetres, not the half metre
# a snap-to-speed model would. The reaction delay
# and accel ramp are difficulty-synced (set_goalie_profile); the top speed is a
# const because no tier varies GoalieController.t_push_speed.
const GOALIE_MAX_LATERAL_SPEED_MPS: float = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S

# Pads-to-floor time once the goalie commits the butterfly — the Hard baseline,
# mirroring GoalieController.butterfly_drop_speed (0.20 s, grounded on the
# measured pro drop velocity of 2.07 m/s — realism audit F2; the live value
# tracks the tier via set_goalie_profile below). With the legs reaction delay in
# front of it, this is how fast a STANDING goalie seals low after reading a
# release — gating both the five-hole slot and the LOW band's widening from the
# standing pad column to the butterfly core (_band_cover). Raced against the
# puck reaching HIS body (t_reach): releases inside the delay leave low fully
# open (the in-tight window), releases past delay + drop meet closed pads.
const GOALIE_BUTTERFLY_DROP_S: float = 0.20

# ── Difficulty-synced goalie read model ───────────────────────────────────────
# The scorer predicts the LIVE goalie, and the live goalie's reads vary with the
# match's GoalieSkillProfile — so the mirrored knobs are static vars, synced via
# set_goalie_profile wherever GameManager selects goalie_skill_profile. Defaults
# are the Hard/authored baselines, so unwired contexts (unit tests, threat
# surfaces) score exactly the ceiling goalie. Without the sync the bots would
# model a Hard goalie on every tier and pass up shots that genuinely beat a
# weaker one. Statics (not per-call params) because the model threads ~every
# scoring entry point; one goalie difficulty exists per match, set only at match
# config / free-play picker time — never per tick.
static var goalie_leg_delay_s: float = GameRules.DEFAULT_GOALIE_REACTION_DELAY_S
static var goalie_arm_delay_s: float = GameRules.DEFAULT_GOALIE_ARM_REACTION_DELAY_S
static var goalie_butterfly_drop_s: float = GOALIE_BUTTERFLY_DROP_S
static var goalie_lateral_accel_m_s2: float = GameRules.DEFAULT_GOALIE_LATERAL_ACCEL_M_S2
static var goalie_arm_deploy_s: float = GOALIE_ARM_DEPLOY_S

# ── Planning keeper DEPTH: the challenge chart + the rush backflow ───────────
# The keeper is not a fixed-depth turret. His radial distance out from the goal
# line is a function of where the puck is (GoalieBehaviorRules'
# target_depth_for_puck_distance — the Buckley chart the live goalie skates),
# and a CLOSING carrier retreats him along the speed-matched backflow curve
# (rush_retreat_depth) until he is at goal-line depth by the time the attacker
# reaches the crease. Both are the live GoalieController's behaviour.
#
# The planner reads this as a RETREAT-ONLY correction (see planned_goalie_depth):
# it gives ground as the play comes to him and never challenges out on its own.
#
# Never hold his depth frozen while the shooter closes. Coverage here is a
# TANGENT CONE off the keeper's body, so a keeper pinned out at challenge depth
# appears to GROW as the shooter approaches: a 3 m release against a keeper held
# at 1.75 m out is only 1.25 m from the puck and subtends a wider cone than the
# whole net, so open_net_danger reads ~0 from the most dangerous ice on the
# rink. The in-zone gradient then points AWAY from the goal, nothing out-scores
# standing still, and the compete falls through to the safest option — the back
# pass. With the backflow he has retreated to ~0.85 m by then, sits ~2.15 m off
# the release, and leaves honest corners open.
#
# Values mirror GoalieController's export defaults (cited per field); the two
# tier-varied depths ride set_goalie_profile like every other synced read.
static var _depth_cfg_planning: GoalieDepthSolver.Constraints = _build_planning_depth_cfg()
# The tier's challenge ceiling, held separately because the reused Constraints has
# its `ceiling_radius` overwritten per call by the in-zone gate.
static var _planning_ceiling: float = 1.75
static var _rush_cfg_planning: GoalieBehaviorRules.RushRetreatConfig = _build_planning_rush_cfg()
# Closing speed below which the live keeper keeps his challenge instead of
# backing in (`rush_min_closing_speed` export default) — a stalled or lateral
# carrier does not retreat him.
const GOALIE_RUSH_MIN_CLOSING_M_S: float = 1.5
# Skating speed in and out of the crease (`depth_max_speed` export default) —
# the rate cap on ordinary chart depth changes. A genuine rush retreat is
# speed-matched instead (rush_retreat_rate), which can legitimately exceed it.
const GOALIE_DEPTH_MAX_SPEED_M_S: float = 2.2


# The planner's copy of the live keeper's depth CONSTRAINTS. Reused in place (this
# is read from the per-tick planning path), and fed to the same
# GoalieDepthSolver.solve_target the live GoalieController integrates toward — so
# the planner cannot drift from the keeper it is predicting.
static func _build_planning_depth_cfg() -> GoalieDepthSolver.Constraints:
	var cfg := GoalieDepthSolver.Constraints.new()
	cfg.ceiling_radius = 1.75         # depth_aggressive export default (tier-varied)
	cfg.floor_radius = 0.10           # depth_defensive
	return cfg


# Resting depth (BPS "C", middle of the paint) held while the play has not entered
# the zone — `depth_conservative` export default.
const GOALIE_RESTING_DEPTH_M: float = 0.70
# Gap the keeper keeps between himself and the threat while challenging —
# `challenge_standoff` export default. Physical (body depth + stick clearance).
const GOALIE_CHALLENGE_STANDOFF_M: float = 0.60
# Depth of the offensive zone; beyond it the play has not entered and the keeper
# rests instead of challenging (GoalieController._threat_is_in_zone).
const GOALIE_ZONE_DEPTH_M: float = GameRules.GOAL_LINE_Z - GameRules.BLUE_LINE_Z


static func _build_planning_rush_cfg() -> GoalieBehaviorRules.RushRetreatConfig:
	var cfg := GoalieBehaviorRules.RushRetreatConfig.new()
	cfg.engage_distance = 8.0    # rush_engage_distance export default
	cfg.mid_distance = 4.5       # rush_mid_distance
	cfg.arrive_distance = 1.5    # rush_arrive_distance
	cfg.depth_engage = 1.75      # = depth_aggressive
	cfg.depth_mid = 1.30         # = depth_base
	cfg.depth_arrive = 0.40      # rush_arrive_depth export default
	return cfg


# Sync the goalie read model to the match's difficulty tier. Call with
# GoalieSkillProfile.hard() to restore the baseline (tests must restore).
static func set_goalie_profile(profile: GoalieSkillProfile) -> void:
	goalie_leg_delay_s = profile.reaction_delay_s
	goalie_arm_delay_s = profile.arm_reaction_delay_s
	goalie_butterfly_drop_s = profile.butterfly_drop_s
	goalie_lateral_accel_m_s2 = profile.lateral_accel_mps2
	# Deploy ramp = reaction-gated reach / arm speed (see GOALIE_ARM_DEPLOY_S).
	goalie_arm_deploy_s = HOLE_BAND_EXT[HOLE_BAND_HIGH] / profile.glove_react_max_speed_mps
	# Depth chart + backflow anchors — the tier's challenge depth (the live
	# controller feeds these same two profile fields into its own configs).
	_planning_ceiling = profile.depth_aggressive_m
	_rush_cfg_planning.depth_engage = profile.depth_aggressive_m
	_rush_cfg_planning.depth_mid = profile.depth_base_m


# Closing speed (m/s) of a body at `pos` moving at `vel` toward `goal`.
# Negative when it is backing off. The input the depth model needs to know
# whether the rush backflow engages.
static func closing_toward(pos: Vector3, vel: Vector3, goal: Vector3) -> float:
	var dx: float = goal.x - pos.x
	var dz: float = goal.z - pos.z
	var d: float = sqrt(dx * dx + dz * dz)
	if d < 0.001:
		return 0.0
	return (vel.x * dx + vel.z * dz) / d


# The keeper's radial depth (metres out from his goal line) when the puck is at
# `puck_pos_at_release`, `time_s` from now, with the shooter closing on the net
# at `closing_speed_m_s`. The chart target, pulled further IN by the rush
# backflow while a genuinely closing attacker is inside the engage range,
# approached from his current depth at the rate the budget allows — ordinary
# crease skating, or the speed-matched retreat rate when the backflow binds.
#
# RETREAT-ONLY, deliberately: the model may pull the keeper IN but never push
# him OUT. His live depth is replicated truth, and it is set by a lot this
# planner cannot see — an RVH/VH post seal, a backdoor cap, the lateral-pressure
# pull, a recovery, a slide. Snapping him out to the chart's challenge station
# would invent an aggressive challenge the real keeper may already have declined,
# and would silently re-price every settled look. The one depth change the play
# itself forces is the retreat — he gives ground as the puck comes to him — so a
# static read returns his current depth unchanged and only an approach moves
# him.
static func planned_goalie_depth(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		puck_pos_at_release: Vector3,
		time_s: float,
		closing_speed_m_s: float = 0.0) -> float:
	var now_depth: float = absf(goalie_now.z - attacking_goal.z)
	if time_s <= 0.0:
		return now_depth
	var dx: float = puck_pos_at_release.x - attacking_goal.x
	var dz: float = puck_pos_at_release.z - attacking_goal.z
	var dist: float = sqrt(dx * dx + dz * dz)
	# Same model the live keeper solves — ceiling gated on the play being in-zone,
	# floored, and bounded by the physical standoff. The caps the planner cannot
	# see (the lateral tracking cap, the backdoor re-square race) only ever pull
	# him DEEPER, and the retreat-only `minf` below already means this never
	# challenges him out, so omitting them stays on the conservative side.
	var c := _depth_cfg_planning
	c.ceiling_radius = _planning_ceiling if dist <= GOALIE_ZONE_DEPTH_M \
			else GOALIE_RESTING_DEPTH_M
	c.standoff_cap = dist - GOALIE_CHALLENGE_STANDOFF_M
	var target: float = minf(now_depth, GoalieDepthSolver.solve_target(c))
	var rate: float = GOALIE_DEPTH_MAX_SPEED_M_S
	if dist < _rush_cfg_planning.engage_distance \
			and closing_speed_m_s >= GOALIE_RUSH_MIN_CLOSING_M_S:
		var rush_target: float = GoalieBehaviorRules.rush_retreat_depth(
				dist, _rush_cfg_planning)
		if rush_target < target:
			target = rush_target
			# Speed-matched backflow: a fast rush backs him in fast, a slow one
			# SLOWLY. While the backflow retreats him it OWNS the motion and
			# bypasses the ordinary rate cap entirely (GoalieDepthSolver.solve),
			# so the rate is the backflow's own — never the max of the two, which
			# agrees with the live keeper only while the curve happens to be
			# steeper than `depth_max_speed`. Zero means the curve is flat here
			# (outside its sloped segments), and there the live solve falls back
			# to the settle — so does this.
			var rush_rate: float = GoalieBehaviorRules.rush_retreat_rate(
					dist, closing_speed_m_s, _rush_cfg_planning)
			if rush_rate > 0.0:
				rate = rush_rate
	if target >= now_depth:
		return now_depth
	return maxf(now_depth - rate * time_s, target)


# `goalie_now` relocated to `depth` metres out from the attacked goal line,
# keeping his lateral position. The rink side is the side the goal faces.
static func _at_depth(goalie_now: Vector3, attacking_goal: Vector3,
		depth: float) -> Vector3:
	return Vector3(goalie_now.x, goalie_now.y,
			attacking_goal.z - signf(attacking_goal.z) * depth)


# Lateral distance a goalie push covers in `move_time` (post-reaction), on the
# accelerate-then-cruise profile: ½·a·t² until the push reaches t_push speed,
# linear after. The inverse of _goalie_lateral_time.
static func goalie_lateral_reach(move_time: float) -> float:
	if move_time <= 0.0:
		return 0.0
	var t_ramp: float = GOALIE_MAX_LATERAL_SPEED_MPS / goalie_lateral_accel_m_s2
	if move_time <= t_ramp:
		return 0.5 * goalie_lateral_accel_m_s2 * move_time * move_time
	return 0.5 * goalie_lateral_accel_m_s2 * t_ramp * t_ramp \
			+ GOALIE_MAX_LATERAL_SPEED_MPS * (move_time - t_ramp)


# Time a goalie push needs to cover `dist` laterally (post-reaction) — the
# inverse of _goalie_lateral_reach.
static func _goalie_lateral_time(dist: float) -> float:
	if dist <= 0.0:
		return 0.0
	var t_ramp: float = GOALIE_MAX_LATERAL_SPEED_MPS / goalie_lateral_accel_m_s2
	var ramp_dist: float = 0.5 * goalie_lateral_accel_m_s2 * t_ramp * t_ramp
	if dist <= ramp_dist:
		return sqrt(2.0 * dist / goalie_lateral_accel_m_s2)
	return t_ramp + (dist - ramp_dist) / GOALIE_MAX_LATERAL_SPEED_MPS

# Shadow half-width used by AIShotAim.compute_open_net_aim for the lane-check
# aim point — picks a point past the goalie for the lane segment check.
const GOALIE_SHADOW_HALF_M: float = 0.3

# goalie_unsettled() settle reference: how long the goalie must sit stopped at
# its target before the model treats it as fully re-set. A recovering goalie
# reads the shot late, so score_shoot cuts his glove/blocker reaction by the
# unsettled fraction (he can't deploy the arms in time) — an off-angle
# one-timer that leaves him mid-slide beats him more.
const GOALIE_SETTLE_REF_S: float = 0.20

# ── Lane interception: closest-approach reachability model ───────────────────
# A fired puck (shot or pass) travels the straight segment from→to at
# `puck_speed`. A defender intercepts iff they can get a stick onto the
# puck's PATH at the moment the puck is there. We solve this per defender
# as a closest-approach problem between two moving points:
#
#   puck(τ)     = from + dir·speed·τ                 (τ ∈ [0, T], T = len/speed)
#   defender(τ) = D + V·τ                            (dead-reckoned momentum)
#   τ*          = argmin |puck(τ) − defender(τ)|     (closest approach, clamped)
#   miss        = |puck(τ*) − defender(τ*)|
#   reach(τ*)   = REACH + CLOSE_SPEED · max(0, τ* − REACTION)
#   block       = clamp((reach − miss) / REACH, 0, 1)
#
# Reachability, never a separable "how close to the line" × "how much flight
# time" product: that form scores a defender draped on the carrier (dead on the
# line, but near the release so the flight time is short) at block ≈ 0, reads
# the lane clear, and collapses the pass turnover cost to zero. Posed as
# reachability, a defender already within a stick of the path blocks fully
# regardless of timing, while one off the path must physically close the gap
# (CLOSE_SPEED × available time) before the puck passes. It is also
# VELOCITY-AWARE: a defender bearing down on the lane is dead-reckoned INTO it,
# one drifting away is credited less.
#
# Faster pucks still thread better for free: a shorter flight T leaves less
# time to close, shrinking reach. All three parameters are physical, not
# feel-tuned:
#   REACH       — blade reach of a lane defender (stick length).
#   REACTION    — competitive read delay before they start closing (~2 ticks
#                 at 30 Hz).
#   CLOSE_SPEED — a defender's lateral adjustment pace. About half top skating
#                 speed: they pivot / crossover into the lane, they do not
#                 straight-line sprint at it.
const LANE_DEFENDER_REACH_M: float = GameRules.DEFAULT_STICK_LENGTH_M
const LANE_REACTION_DELAY_S: float = 0.08
# Fraction of top skating speed a defender covers LATERALLY sliding into a lane
# (you close a passing lane sideways, not at full straight-line speed). Per-
# defender close speed is this × the defender's real max_speed.
const LANE_LATERAL_FRACTION: float = 0.5
const LANE_DEFENDER_CLOSE_SPEED_M_S: float = LANE_LATERAL_FRACTION * GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

# A saucer pass lifts over a grounded stick but NOT a body — it's hard to
# react a blade up into a puck flying overhead, but you can't fly it
# through a torso. So in the airborne stretch of a saucer's flight a
# defender's reach collapses to their BODY radius: no stick extension, no
# closing. A defender standing dead in the lane still blocks the saucer; a
# stick-poke-range defender no longer does. Matches the skater collision-
# cylinder radius (GameRules canonical body half-width).
const LANE_DEFENDER_BODY_RADIUS_M: float = GameRules.OFFSIDE_LINE_SLACK

# Puck release speed assumptions for lane-clear reaction-window math.
# `puck.release(direction, power)` consumes `direction × power` as
# linear velocity directly (see Puck.release), so "power" IS m/s.
# Sourced from GameRules so the AI's lane reaction window matches
# the live shot mechanics. score_shoot defaults to wrister speed;
# score_pass uses pass speed (which is quick_pass_power — short
# passes in this codebase are mechanically quick-shots, long ones
# get wrister-charged for more pace — see PASS_CHARGE_SPEED_M_S /
# expected_pass_speed).
const WRISTER_SHOT_SPEED_M_S: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
const SLAPPER_SHOT_SPEED_M_S: float = GameRules.DEFAULT_SLAPPER_POWER_MAX_M_S
const PASS_SPEED_M_S: float = GameRules.DEFAULT_QUICK_PASS_POWER_M_S

# Target CLOSING speed at reception — the puck's speed in the RECEIVER'S frame
# when it arrives, which is what PuckReceptionRules judges (#373). Under that
# model's ceilings (any-angle catch ≤ deflect_min 22, squared ≤ 30), 20 sits
# comfortably under the any-angle bar, so a magnet-pace feed catches at ANY
# blade angle with margin — the documented "~20 m/s, always catch" pass. Held
# constant across distance (friction-compensated below) and, when the receiver's
# velocity is supplied, across the receiver's motion too: pass_launch_speed
# solves the world launch so the puck lands on the tape at THIS closing speed
# whether the receiver is streaking onto a lead feed or curling back to it.
const PASS_TARGET_CLOSING_M_S: float = 20.0

# Hardest receiver-frame arrival we'll allow a pass to land at — the cap on how
# much the receiver-motion solve below may SOFTEN the world launch. Grounded on
# the reception ceilings (PuckReceptionRules: any-angle catch < deflect_min 22,
# fully-squared < 30). A bot receiver sets up SQUARE to the incoming feed
# (_pass_receive_aim_and_steer opens the blade face for the alignment bonus; the
# gate-park holds it square the whole way in), so its real ceiling sits well above
# the any-angle bar — 26 credits that squaring while leaving margin below 30 for
# an imperfect setup. Without this cap, a receiver curling back toward the puck
# drove the world launch down to the min-wrister floor (~10-12 m/s): a "super
# soft" floater that doubled its own flight time and got picked off. Lower toward
# 22 to assume no squaring (guaranteed any-angle catch, softer passes); raise
# toward 30 for crisper feeds that lean harder on the receiver squaring up.
const PASS_RECEIVE_CEILING_M_S: float = 26.0

# Reference charged-pass speed (~mid-ramp). Not a release target — a real pass
# is distance-adaptive via pass_launch_speed — but a representative pass speed
# for lane/threat tests and any caller that wants a single "typical charged
# pass" number.
const PASS_CHARGE_SPEED_M_S: float = (
		GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
		+ (GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
				- GameRules.DEFAULT_WRISTER_POWER_MIN_M_S) * 0.5)

# Pass LAUNCH speed backed out of the target CLOSING speed: fire hard enough that
# the puck arrives on the tape at PASS_TARGET_CLOSING_M_S in the receiver's frame
# after shedding ice friction over the pass distance.
#
# Two corrections stack:
#   1. Friction (always): v_world_arrival → v_launch = sqrt(v_arrival² + 2·a·d),
#      constant decel a = PUCK_ICE_DECEL_M_S2. Tiny (~0.5 m/s²), well under 1 m/s
#      even on a long pass.
#   2. Receiver motion (when receiver_vel/pass_dir supplied): reception judges the
#      puck's speed in the RECEIVER'S frame, so the WORLD arrival speed must be set
#      so |v_arrival·pass_dir − receiver_vel| = PASS_TARGET_CLOSING_M_S. Solving that
#      quadratic for the world arrival speed w:
#        w = (pass_dir·receiver_vel) + sqrt(max(0, closing² − |receiver_vel_⊥|²)),
#      i.e. cancel the receiver's along-pass motion (fire harder onto a streaking
#      receiver, softer to one curling back) and accept its unavoidable lateral
#      component. If the lateral speed alone exceeds the target, the discriminant
#      floors to 0 and w = the along component — the softest catchable feed
#      possible. With no receiver_vel this reduces to w = PASS_TARGET_CLOSING_M_S
#      (the static-receiver case), so distance-only callers are unchanged.
#
# Clamped to max_launch — the passer's own max wrister (its hardest possible
# pass), or the league default for opponent threat modeling.
#
# speed_scale is the difficulty pace knob (BotSkillProfile.pass_speed_scale). It
# scales the TARGET ARRIVAL pace — the closing speed this whole function solves a
# launch for — and everything downstream then runs on the softened target: the
# receiver-motion quadratic, the friction compensation, and the executable floor.
# So a lower tier throws a puck that ARRIVES soft and still gets there.
#
# Never apply it to the finished LAUNCH — scaling after the solve discards the
# solve. A receiver streaking away at 6 m/s needs a 26 m/s world arrival to
# close at 20; knocking that launch to 0.7 delivers ~12 m/s of closing and the
# feed dies behind him, where scaling the target hands him a 23 m/s arrival for
# a 17 m/s close: softer by exactly the dial, and still caught.
# Defaults to 1.0, which is bit-identical to the unscaled solve, so the
# cross-player threat model (expected_pass_speed) is untouched by the knob.
static func pass_launch_speed(distance: float, max_launch: float,
		speed_scale: float = 1.0,
		receiver_vel: Vector3 = Vector3.ZERO,
		pass_dir: Vector3 = Vector3.ZERO) -> float:
	# The pace dial rides HERE, on the target the solve aims at (see above).
	var target_closing: float = PASS_TARGET_CLOSING_M_S * maxf(speed_scale, 0.01)
	var world_arrival: float = target_closing
	if pass_dir.length_squared() > 0.0001:
		var along: float = pass_dir.dot(receiver_vel)
		var perp_sq: float = maxf(0.0, receiver_vel.length_squared() - along * along)
		# Two receiver-frame launch bounds, both solving
		# (world_arrival − along)² + perp² = target² for the world arrival speed:
		#   soft  — lands at the IDEAL closing pace (target_closing, a comfortable
		#           any-angle catch)
		#   crisp — lands at the catch CEILING (PASS_RECEIVE_CEILING, the hardest
		#           the squared-up receiver can still corral). NOT scaled by the
		#           pace dial: it is a fact about what a receiver can handle, not a
		#           choice about how hard to pass.
		# Fire at the crisp WORLD pace we'd throw a stationary receiver
		# (target_closing), clamped between them. Streaking onto a lead feed
		# (along > 0) pushes the soft floor ABOVE that pace, so we fire HARDER to
		# lead — the give-with-the-puck read is preserved. Curling back toward the
		# passer (along < 0) pulls both bounds down, but the crisp ceiling caps how
		# far: rather than collapsing to the min-wrister floor (a "super soft"
		# floater), the launch only softens to what the receiver can still catch.
		var soft_arrival: float = along + sqrt(maxf(0.0,
				target_closing * target_closing - perp_sq))
		var crisp_arrival: float = along + sqrt(maxf(0.0,
				PASS_RECEIVE_CEILING_M_S * PASS_RECEIVE_CEILING_M_S - perp_sq))
		world_arrival = clampf(target_closing, soft_arrival, crisp_arrival)
		# A receiver charging the passer harder than the target could drive this
		# negative/tiny; floor at the soft-pass minimum so we still fire a real pass.
		world_arrival = maxf(world_arrival, GameRules.DEFAULT_WRISTER_POWER_MIN_M_S)
	var launch: float = sqrt(
			world_arrival * world_arrival
			+ 2.0 * GameRules.PUCK_ICE_DECEL_M_S2 * maxf(distance, 0.0))
	return clampf(launch, GameRules.DEFAULT_WRISTER_POWER_MIN_M_S, max_launch)

# ── Saucer pass ──────────────────────────────────────────────────────────────
# A saucer (LOW-loft) pass lofts the puck off the ice so it flies over a
# defender's grounded stick mid-lane and settles back down before the
# receiver. The whole flight profile is pure kinematics of the LOW loft's
# fixed vertical launch (GameRules.DEFAULT_LOFT_VY_LOW_M_S) under gravity —
# no shape parameters:
#
#   hang time      T_hang = 2·vy / g                       (~0.45 s)
#   over window    [t_over, t_down] where y(t) exceeds the blade plane
#                  (GameRules.PUCK_AIRBORNE_HEIGHT_M — the same on-ice/
#                  off-ice gate PuckReceptionRules.blade_can_interact uses,
#                  so "over a grounded stick" here means exactly what the
#                  live reception physics enforces)
#   airborne carry = launch speed × T_hang (no ice friction in the air)
#
# Inside the over window a defender's reach collapses to their BODY radius
# — you can't react a grounded blade up into a puck overhead, but you
# can't fly a low flip through a torso either. Outside it (just off the
# blade, or landed) a stick intercepts normally — a stick already on the
# puck at release still stuffs the flip.
#
# Because the airborne carry scales with LAUNCH SPEED, a soft flip is the
# close-quarters tool: fired at ~11 m/s an 8 m feed clears a mid-lane
# stick and still lands with runway, while the same feed at the crisp
# ~20 m/s magnet pace would arrive still airborne — and an airborne puck
# flies OVER the receiver's grounded blade (blade_can_interact), so it
# isn't a pass at all. saucer_max_launch_speed is that receivability
# bound; the carrier picks min(normal pace, that bound) and lets the EV
# compete decide if the softer, longer-hanging flip beats the flat lane.

# Grounded slide runway the saucer must land with before the receiver's
# tape: the puck has to be back on the blade plane — landed and settled
# out of its touch-down skip — for a grounded blade to play it.
const SAUCER_LANDING_RUN_M: float = 2.0

# If the grounded lane is already this clear, never bother scoring a
# saucer variant — there's no defender worth lofting over (and the flip
# carries extra execution risk for nothing).
const SAUCER_SKIP_WHEN_LANE_CLEAR: float = 0.85

# Extra execution-miss probability a saucer adds on top of PASS_MISS_PROB:
# the flip-and-land is fiddlier than a flat feed — the touch-down can skip
# or wobble off line. This is the natural margin in the grounded-vs-saucer
# EV compete: the loft only wins when the lane it clears is worth more
# than the added landing risk.
const SAUCER_EXTRA_MISS_PROB: float = 0.05


# Time a LOW-loft puck spends off the ice (launch to touch-down).
static func saucer_hang_time_s() -> float:
	return 2.0 * GameRules.DEFAULT_LOFT_VY_LOW_M_S / GRAVITY_M_S2


# Horizontal distance a saucer launched at `launch_speed` covers before
# touching back down. No ice friction while airborne, so it's linear.
static func saucer_airborne_distance_m(launch_speed: float) -> float:
	return launch_speed * saucer_hang_time_s()


# The fastest launch that still LANDS with SAUCER_LANDING_RUN_M of grounded
# slide before a receiver `distance` away — the receivability bound (an
# airborne arrival flies over the tape). Negative/tiny for very short
# feeds: below min wrister pace there is no legal saucer, the physical
# floor on saucer distance (~6.5 m at the 10 m/s soft-touch minimum).
static func saucer_max_launch_speed(distance: float) -> float:
	return (distance - SAUCER_LANDING_RUN_M) / saucer_hang_time_s()


# Returns the LAUNCH speed a pass from `shooter` to `receiver` will fire at — set
# so the puck arrives at the magnet pace (see pass_launch_speed), a hair above the
# target arrival speed to cover friction. Capped at the league default max wrister
# here; the passer's own scoring/execution uses its own max
# (ctx.self_wrister_shot_speed). Used by both offensive scoring (lead / lane
# math) and defensive scoring (threat_surface_pass assuming opponents play the
# same way).
static func expected_pass_speed(shooter: Vector3, receiver: Vector3) -> float:
	return pass_launch_speed(shooter.distance_to(receiver), GameRules.DEFAULT_WRISTER_POWER_MAX_M_S)


# Reference top skating speed. Single source of truth shared with
# SkaterController.max_speed via GameRules.DEFAULT_SKATER_MAX_SPEED_M_S.
# Used by time_to_arrive() for momentum-aware ETAs across every role
# behavior + chase intercept lookahead.
# League-average FALLBACK: any read with a peer in view resolves that
# player's real top speed through AISkaterCaps (caps_by_peer) and only
# falls back here for unresolvable peers. The sites that price at this
# reference by design are the genuinely cross-player ones — the
# realization discount and the counter-cover teammate races — each
# documented at its site.
const SKATER_REF_SPEED_M_S: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

# Approximate kinematic stopping time for a skater steering against
# their own velocity. Derived from the friction model in
# SkaterController (drag = friction + friction_drag × |v| ≈ 3.6 m/s²
# at top speed) plus reverse-thrust steering. Used by OUTLET's
# offside filter to project a candidate forward by current velocity:
# if "where I'd be in BRAKE_TIME_S given current momentum" is past
# the blue line, the candidate is rejected as effectively offside.
# Pure kinematic — the constant is "how long does momentum dominate
# steering," not a behavioral knob.
const SKATER_BRAKE_TIME_S: float = 0.3

# Floor for momentum-adverse `time_to_arrive` returns. When the
# velocity component along the destination is so negative that
# effective_speed would go non-positive, clamp at this minimum so
# reverse candidates have finite (large) ETAs rather than infinite
# decay. 1.0 m/s ≈ "I have to brake and reverse, but I'll get there
# eventually."
const MIN_TRAVEL_SPEED_M_S: float = 1.0

# League-default all-direction thrust (Acceleration-scaled per skater) — the
# redirect authority a caps-less time_to_arrive caller assumes for the cross-
# momentum shed. Per-bot callers pass the skater's REAL max_accel
# (AISkaterCaps.max_accel) instead, so a high-Acceleration build sheds sideways
# momentum faster than a low one. Mirrors SkaterController.thrust; a physical
# acceleration, not an evaluation shape knob.
const SHED_ACCEL_DEFAULT_M_S2: float = GameRules.DEFAULT_SKATER_THRUST_M_S2

# Utility-AI knobs. AIRoleCarrier._pick_action re-runs every
# PICK_ACTION_PERIOD_TICKS physics ticks and treats
# CARRY as a fourth competing option scored as
#
#   carry_score = score_at(destination) × delay_discount(time_to_destination)
#
# ── The delay discount (see delay_discount / READ_VALIDITY_TAU_S below) ────────
# A future action (a carry that arrives in `t` s, a pass in flight, a spot whose
# shot must still be skated to) is worth less than the same value NOW, because the
# tactical read it was scored against decays over time: a defender commits, a lane
# closes, the puck situation turns. This is the survival function of a
# CONSTANT-HAZARD process — at each instant a fixed probability the read stops
# holding — so it is exactly geometric, exp(-t / τ). It is NOT a shaped curve; the
# ONLY free parameter is the hazard timescale τ = READ_VALIDITY_TAU_S, the mean
# time a read stays roughly valid. (A per-second form like pow(0.8, t) is the same
# model written opaquely: 0.8/s is exp(-1/4.5 s). Prefer the τ form — it names the
# physical quantity.)
#
# τ is an honest AGGREGATE, not a derived quantity: plausible physical
# decorrelation times span ~0.4 s (a defender closing a stick-width) to a
# rush-scale several seconds, so there is no single number to derive it from — it
# is the one "how much do I trust the near future" feel dial, now stated as the
# physical quantity it represents rather than a bare rate. Raise it for more
# patient play (more developing feeds / cross-ice / hold-for-the-backdoor), lower
# it for more direct, take-what's-there play. Applied uniformly to every future
# action so an on-route step trades travel time for realization decay one-for-one.
#
# Calibration caveat (from the value sweep): the unit suite guards the IMPATIENT
# edge (breakouts / developing feeds / walkouts start failing below ~0.7/s ↔
# τ ≈ 2.8 s). The PATIENT edge is pinned at the parameter level by
# test_delay_discount_bounds_patience (patience can't be cranked to "the future
# is free") — but whether a longer τ PLAYS better is a feel judgment, a playtest
# call the suite can't settle.
#
# ACTION_HYSTERESIS_MARGIN_FRAC — once a fire intent is set, that intent's
# (positive) score is scaled by (1 + this) when re-scored, so a challenger must
# beat the committed intent by 15% rather than by a flat margin. Prevents flicker
# between two close-scoring fire options during pre-aim.
#
# PROPORTIONAL, not additive, because utility scores span ~0.02 (deep-DZ escape
# reads) to ~0.7 (slot chances): a flat margin that is a sane ~10% of a typical OZ
# score can exceed the ENTIRE gap between options in the defensive zone, making
# stale intents disproportionately sticky exactly where scores are smallest. Same
# pattern as AIThreatAssignment.HYSTERESIS_MARGIN_FRAC.
#
# Applied only to POSITIVE scores — a committed intent decayed to worthless (or
# negative EV) earns no stickiness — and only to fire intents (SHOOT, QUICK_PASS,
# PASS), so the bot may switch to fire the moment fire scores higher. Raise toward
# 0.30 if intent flickers visibly; lower toward 0.05 if it feels too sticky.
# Mean seconds a tactical read stays roughly valid (the hazard timescale above).
# τ ≈ 4.5 s ↔ a ~0.80 per-second discount — the patient end of the range, favouring
# developing plays. See the sweep caveat above: this side is judged by feel, not by
# the suite.
const READ_VALIDITY_TAU_S: float = 4.5
const ACTION_HYSTERESIS_MARGIN_FRAC: float = 0.15


# Value multiplier for a play `delay_s` seconds in the future — constant-hazard
# survival, exp(-delay_s / READ_VALIDITY_TAU_S). One chokepoint for the delay
# discount (see the block above): every future-action scorer routes through here
# so the entropy model lives in exactly one place. Allocation-free.
static func delay_discount(delay_s: float) -> float:
	return exp(-maxf(delay_s, 0.0) / READ_VALIDITY_TAU_S)


# Shot value in [0, 1] — the MAKE PROBABILITY of firing at the best goalie
# hole, seen from the shooter's eye, with the goalie a body that occludes part
# of the net. Distance, angle, squareness, and reaction all emerge from the
# geometry — no curves. best_shot_loft returns the same winner's elevation
# class so the shot's loft matches where it's aimed.
#
# ── The soft edge ────────────────────────────────────────────────────────────
# The boundary between goal and save is not a line: the keeper's edge moves
# with pose (stance vs. mid-drop vs. splayed), with tracking lag inside the read
# quantum, and with the deflection-vs-clean-miss lottery at the pad edge; the
# puck's arrival is scattered by more than the release angle. So the model
# carries ONE uncertainty for that whole boundary (GOALIE_EDGE_SOFTNESS_M, in
# metres at the keeper, combined in quadrature with the shooter's release
# scatter) and applies it consistently:
#
#   margin  = best_signed_margin — how far the net clears his cover edge,
#             NEGATIVE by the overlap depth when he has it covered
#   w_eff   = softplus(margin, σ) — the effective window, which decays
#             smoothly toward zero instead of clamping to it
#   P(make) = _placement_probability(w_eff, σ)
#
# For a genuinely open window (margin ≫ σ) softplus is the identity and this is
# plain geometry. What it adds is gradient at both ends: a covered look is
# small-but-ordered by HOW covered, and an open one keeps climbing instead of
# pinning. That is what lets "carry left and make him track" out-score "pass it
# back and let him re-square".
#
# Never go back to clamping a raw window against release scatter alone
# (test_shot_currency_saturation.gd measures both failures). At the Hard hand's
# floored 0.01 rad that ramp saturates at a 0.020 rad opening — one fifteenth
# of the 0.298 rad empty net subtended from the dot line — so most dangerous
# ice pins at 1.000, nothing can out-score a set keeper, and moving him buys
# exactly zero. At the other end a hard zero throws the overlap DEPTH away, so
# "he covers this now, but two strides left opens him" is indistinguishable
# from hopeless, precisely on the walk-out ice where making him move is
# easiest.
#
# NOTE this is the BOT'S decision currency and nothing else. expected_goals
# (the post-game analytic) is a separate function on the same geometry with a
# deliberately different input — a context-only spread, never the shooter's
# skill, so goals-above-expected cannot be circular. It reads the CLAMPED
# best_open_angle and is untouched by any of the above.
static func open_net_danger(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> float:
	# Best of the holes, SIGNED. Pure value-type math, no allocation — safe to
	# run per carry candidate at tick rate (see _hole_margin). Pace is per-band
	# inside _hole_margin: HIGH holes fly at the arrival-honest solved pace,
	# flat bands at the committed full pace; the reach budget divides the
	# shooter→goalie gap by it.
	var margin: float = best_signed_margin(shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
			screen_dist_m, goalie_hands, goalie_pads, loft_tans)
	# The two spreads are kept SEPARATE, and the distinction is load-bearing.
	# The keeper's edge fuzziness widens the effective WINDOW (his wall is not
	# a line); the shooter's dispersion decides whether the puck lands in it.
	# Never fuse them into one sigma: a wider hand would then widen the fuzzed
	# window too, so a covered shot scores HIGHER the worse you shoot. Nothing
	# the shooter does may ever improve the geometry.
	return danger_from_margin(shooter, goalie_pos, margin, aim_spread_rad)


# The margin -> make-probability mapping, split out so it has exactly one
# implementation. AIDangerField needs it separately because interpolating the
# MARGIN and mapping afterwards is far more accurate than interpolating the
# mapped value: the margin is smooth geometry, while the mapping is a sigmoid
# whose knee is the steepest feature on the whole surface. Same lattice, most
# of the error gone.
static func danger_from_margin(shooter: Vector3, goalie_pos: Vector3,
		margin: float, aim_spread_rad: float = 0.0) -> float:
	return _make_probability(margin, placement_spread(aim_spread_rad),
			goalie_edge_spread(shooter, goalie_pos))


# Half-normal moments of |placement error| in units of its own σ:
# E = √(2/π), Var = 1 − 2/π. Properties of the distribution, not tunables.
const _HALFNORM_MEAN: float = 0.7978845608
const _HALFNORM_VAR: float = 0.3633802276


# P(goal) for a signed `margin`, a shooter whose placement scatters by
# `sigma_p`, and a cover edge uncertain by `sigma_e` — all radians at the eye.
#
# The shot beats him iff the puck lands inside the window, and the window's
# half-width is itself uncertain: |X| < margin/2 + ε, with X the placement
# error and ε the edge error. Rearranged, that is a single CDF —
#
#     P = P(|X| − ε < margin/2)
#
# — of a half-normal minus a normal, evaluated here at its first two moments.
# Max error 0.075 against a dense numerical reference across the whole
# (margin, σ_p, σ_e) operating grid, mean 0.014, at the cost of one erf.
#
# The two must compose as independent VARIANCES. Softening the window by σ_e
# and then hitting that softened window with precision σ_p instead treats edge
# uncertainty as extra window the shooter can reliably exploit: the tail comes
# out proportional to σ_e/σ_p, so an identical shot — the same number of edge
# sigmas inside the cover — scores 0.041 against a distant keeper and 0.343
# against a near one, and nothing physical says how covered you are should
# depend on his range once you have measured it in his own uncertainty.
# Variances also keep the scatter dial monotone: a wider hand raises the mean
# penalty AND the spread, so it can only ever lower the value.
static func _make_probability(margin: float, sigma_p: float,
		sigma_e: float) -> float:
	var spread: float = sqrt(
			_HALFNORM_VAR * sigma_p * sigma_p + sigma_e * sigma_e)
	if spread <= 0.000001:
		return 1.0 if margin > 0.0 else 0.0
	var z: float = (margin * 0.5 - _HALFNORM_MEAN * sigma_p) / spread
	return clampf(0.5 * (1.0 + _erf(z / sqrt(2.0))), 0.0, 1.0)


# 1σ of the keeper's cover EDGE for this look, in radians at the shooter's eye.
# GOALIE_EDGE_SOFTNESS_M is a linear figure at his body, so it foreshortens
# with range exactly like every other target: the same physical fuzziness is a
# wide uncertainty from in tight and a narrow one from the point.
static func goalie_edge_spread(shooter: Vector3, goalie_pos: Vector3) -> float:
	var dx: float = goalie_pos.x - shooter.x
	var dz: float = goalie_pos.z - shooter.z
	return GOALIE_EDGE_SOFTNESS_M / maxf(sqrt(dx * dx + dz * dz), 0.5)


# 1σ of where the shot actually ARRIVES, in radians: the shooter's aim error
# (the tier dial / the bot's own hand) in quadrature with the dispersion every
# release carries however well aimed — blade contact, puck roll, release
# timing. Without that floor the dial alone governs saturation, and at the Hard
# hand's 0.01 rad the currency pins at a 0.02 rad window.
static func placement_spread(aim_spread_rad: float) -> float:
	var aim: float = maxf(aim_spread_rad, MIN_RELEASE_SPREAD_RAD)
	return sqrt(aim * aim + PLACEMENT_DISPERSION_RAD * PLACEMENT_DISPERSION_RAD)


# The best signed margin (radians) over the five holes — how far the widest
# hole clears the keeper's cover edge, NEGATIVE by the overlap depth when he
# has every hole covered. The raw geometry open_net_danger (the bot's decision
# currency) sits on. Pure value-type math, no allocation.
static func best_signed_margin(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> float:
	var best: float = HOLE_STRUCTURALLY_CLOSED_RAD
	for i: int in HOLE_COUNT:
		var m: float = _hole_margin(i, shooter, attacking_goal, goalie_pos,
				net_half_width, shot_speed_m_s, goalie_unsettled_factor,
				goalie_five_hole_m, goalie_down,
				goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
				screen_dist_m, goalie_hands, goalie_pads, loft_tans)
		if m > best:
			best = m
	return best


# The widest goalie-beating opening (radians) over the five holes, CLAMPED at
# zero — the "is there a window, and how wide" read. expected_goals (the
# post-game analytic) sits on this; so do the aim / loft / power choosers,
# which only ever target a hole that is genuinely open. Pure value-type math,
# no allocation.
static func best_open_angle(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> float:
	var best_angle: float = 0.0
	for i: int in HOLE_COUNT:
		var a: float = _hole_open_angle(i, shooter, attacking_goal, goalie_pos,
				net_half_width, shot_speed_m_s, goalie_unsettled_factor,
				goalie_five_hole_m, goalie_down,
				goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
				screen_dist_m, goalie_hands, goalie_pads, loft_tans)
		if a > best_angle:
			best_angle = a
	return best_angle


# ── Expected goals (xG) — the analytics stat ─────────────────────────────────
# Beating a goalie is TWO things: getting net open, and putting the puck in it.
# This model prices both, which is what separates it from the bot's
# open_net_danger (that one fuses geometry and the bot's own precision into a
# single spread — correct for a decision the bot then executes with exactly that
# precision, wrong for a stat about arbitrary shooters).
#
#   xG = P(placement lands in the open window) + P(miss it) × P(goalie leaks)
#
#   1. GEOMETRY — best_open_angle: the real open net past the real goalie, in
#      radians. Measured with a SHARP hand (XG_ENTRY_SPREAD_RAD): "what is open"
#      is a question about the goalie, not the shooter, and charging the release
#      spread here too would double-count it (at range, spread × distance would
#      exceed the net and zero every point shot).
#   2. EXECUTION — the release spread, as a Gaussian placement distribution over
#      that window. Geometry alone rates a deke that yawns the net open at ~0.9
#      however brutal the shot itself is, and a max over binary hole tests is a
#      cliff rather than a probability — non-monotonic, hard zero both in tight
#      and from the point.
#
# Passes are excluded upstream — expected_goals only ever sees a shot the
# resolution gate counted.
const XG_ENTRY_SPREAD_RAD: float = MIN_RELEASE_SPREAD_RAD
# Release scatter (radians, 1σ) for a reference shooter taking a SETTLED shot.
# Calibrated against the observed on-net fraction: every missed shot is direct
# evidence about this number, and a game has far more misses than goals.
const XG_BASE_SPREAD_RAD: float = 0.12
# A backhand is materially harder to place than a forehand.
const XG_BACKHAND_SPREAD_MULT: float = 1.6
# Shooting on the move — across the body, in transition, out of a deke — widens
# the release, scaled by speed against a reference clip.
const XG_MOTION_SPREAD_GAIN: float = 0.6
const XG_MOTION_REFERENCE_M_S: float = 8.0
# A shot the goalie can physically cover still goes in sometimes: a misplay, a
# five-hole leak, a deflection off traffic, a rebound he can't smother. Without
# this term the model floors at exactly zero for every point shot and every
# in-tight look at a square goalie — the false zeros at both ends of the curve.
const XG_COVERED_LEAK: float = 0.04
# Nothing is a certain goal — you can still fan on it or ring it off the iron
# with the net empty. Mirrors the leak at the other end of the range.
const XG_MAX: float = 0.95


# Release scatter for a shot's CONTEXT — never for the shooter's skill. A weaker
# player drawing lower xG on an identical chance would make goals-above-expected
# circular, so this reads the situation (hand, motion) and nothing about who is
# holding the stick.
static func xg_release_spread(is_backhand: bool, skater_speed_m_s: float) -> float:
	var spread: float = XG_BASE_SPREAD_RAD
	if is_backhand:
		spread *= XG_BACKHAND_SPREAD_MULT
	spread *= 1.0 + XG_MOTION_SPREAD_GAIN \
			* clampf(skater_speed_m_s / XG_MOTION_REFERENCE_M_S, 0.0, 2.0)
	return spread


# Fraction of a Gaussian release distribution landing inside a window of
# `window_rad` TOTAL angular width, aimed at its centre.
static func _placement_probability(window_rad: float, spread_rad: float) -> float:
	if window_rad <= 0.0:
		return 0.0
	if spread_rad <= 0.0001:
		return 1.0
	return _erf(window_rad * 0.5 / (spread_rad * sqrt(2.0)))


# erf via Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7) — GDScript has no erf.
static func _erf(x: float) -> float:
	var ax: float = absf(x)
	var t: float = 1.0 / (1.0 + 0.3275911 * ax)
	var poly: float = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741
			+ t * (-1.453152027 + t * 1.061405429))))
	return signf(x) * (1.0 - poly * exp(-ax * ax))


static func expected_goals(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS,
		release_spread_rad: float = XG_BASE_SPREAD_RAD) -> float:
	var window: float = best_open_angle(shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, XG_ENTRY_SPREAD_RAD,
			screen_dist_m, goalie_hands, goalie_pads, loft_tans)
	var placed: float = _placement_probability(window, release_spread_rad)
	# Miss the open window and the goalie still has to actually stop it.
	return minf(XG_MAX, placed + (1.0 - placed) * XG_COVERED_LEAK)


# The LOFT the bot should shoot with, from the same hole geometry that
# open_net_danger scores: the elevation class of the CHOSEN hole (see
# _choose_shot_hole). A slot shot whose only opening is over the shoulder returns
# HIGH; a five-hole off a caught-moving goalie returns FLAT; a body-side seam
# returns LOW. Called once when SHOOT commits, so the re-scan is free.
static func best_shot_loft(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> int:
	var hole: int = _choose_shot_hole(shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
			screen_dist_m, goalie_hands, goalie_pads, loft_tans)
	if hole < 0 or HOLE_BAND[hole] != HOLE_BAND_HIGH:
		return ShotMechanics.ELEVATION_FLAT
	return _best_high_rung(shooter.distance_to(attacking_goal), shot_speed_m_s,
			loft_tans, _xz_dist(shooter, goalie_pos), goalie_down)


# The world aim POINT (on the net plane, y = 0) of the CHOSEN hole — the exact
# target the loft was picked for, so aim and loft always describe the same hole.
# The state machine locks this as the wrister aim at charge start. Falls back to
# the goal centre if the goalie leaves nothing (defensive — SHOOT only commits
# when there's an opening).
static func best_shot_aim(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		aim_spread_rad: float = 0.0,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> Vector3:
	var hole: int = _choose_shot_hole(shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
			screen_dist_m, goalie_hands, goalie_pads, loft_tans)
	if hole < 0:
		return Vector3(attacking_goal.x, 0.0, attacking_goal.z)
	var aim_x: float = _hole_aim_x(hole, shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor, aim_spread_rad,
			goalie_down, screen_dist_m, goalie_hands, goalie_pads, loft_tans)
	return Vector3(aim_x, 0.0, attacking_goal.z)


# Picks the shot hole the bot commits to: the widest opening, then tie-broken
# toward the FLATTEST loft within LOFT_TIE_FRAC of it (bury it low if you can,
# ride the toe only when the top is the real way in), and within that flattest
# tier the widest opening. Returns the hole index, or -1 if nothing is open.
# One chooser shared by best_shot_loft and best_shot_aim so they never disagree.
static func _choose_shot_hole(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float, unsettled: float,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> int:
	# Chosen on the SIGNED margin, not the clamped opening, so the hole the bot
	# aims at is the hole open_net_danger scored. With a soft cover edge a
	# marginally-covered corner still carries real value, and choosing on the
	# clamped opening reads every such hole as 0.0, finds "nothing open", and
	# falls back to dead centre — a goal-crest shot while the compete priced a
	# corner. On the signed margin it targets the LEAST-BAD hole instead. Only a
	# structurally impossible hole (behind the line, unreachable band, sealed
	# post, smothered release) is off the table.
	var best_margin: float = HOLE_STRUCTURALLY_CLOSED_RAD
	for i: int in HOLE_COUNT:
		var a: float = _hole_margin(i, shooter, attacking_goal, goalie_pos,
				net_half_width, shot_speed_m_s, unsettled, goalie_five_hole_m, goalie_down,
				goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
				screen_dist_m, goalie_hands, goalie_pads, loft_tans)
		if a > best_margin:
			best_margin = a
	if best_margin <= HOLE_STRUCTURALLY_CLOSED_RAD:
		return -1
	# Same "within LOFT_TIE_FRAC of the best" slack, written so it also means
	# something for a negative best: identical to best × LOFT_TIE_FRAC whenever
	# best is positive, and a symmetric widening below zero.
	var threshold: float = best_margin - (1.0 - LOFT_TIE_FRAC) * absf(best_margin)
	var chosen: int = -1
	var chosen_loft: int = ShotMechanics.ELEVATION_HIGH + 1
	var chosen_angle: float = HOLE_STRUCTURALLY_CLOSED_RAD
	for i: int in HOLE_COUNT:
		var a: float = _hole_margin(i, shooter, attacking_goal, goalie_pos,
				net_half_width, shot_speed_m_s, unsettled, goalie_five_hole_m, goalie_down,
				goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
				screen_dist_m, goalie_hands, goalie_pads, loft_tans)
		if a < threshold or a <= HOLE_STRUCTURALLY_CLOSED_RAD:
			continue
		var band_loft: int = HOLE_BAND[i]   # LOW band (flat) orders before HIGH
		if band_loft < chosen_loft or (band_loft == chosen_loft and a > chosen_angle):
			chosen_loft = band_loft
			chosen_angle = a
			chosen = i
	return chosen


# The net-plane aim x for a chosen hole. Corners aim at the open segment's
# midpoint biased toward the post (matching AIShotAim's tuned corner bias); the
# five-hole aims at the goalie's centre (between the legs). Reuses the same
# body-disc cover model and unsettled-fade as _hole_open_angle so aim and score
# agree.
static func _hole_aim_x(
		i: int, shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float, unsettled: float,
		aim_spread_rad: float = 0.0, goalie_down: bool = false,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> float:
	var kind: int = HOLE_KIND[i]
	var side: int = HOLE_SIDE[i]
	var band: int = HOLE_BAND[i]
	# Same rung the opening was scored with (_hole_margin), so aim and score
	# read the same arrival height and the same reaction-gated cover. A chosen
	# hole is never band-unreachable (its opening would have scored 0), so the
	# FLAT fallback on a HIGH hole is belt-and-braces.
	var dist_to_goal: float = shooter.distance_to(attacking_goal)
	var level: int = _hole_rung(band, dist_to_goal, shot_speed_m_s, loft_tans,
			_xz_dist(shooter, goalie_pos), goalie_down)
	var pace: float = _rung_pace(level, shot_speed_m_s, loft_tans)
	var arrival_y: float = _rung_arrival(level, dist_to_goal, shot_speed_m_s,
			loft_tans)
	var net_z: float = attacking_goal.z
	var post_lo_x: float = attacking_goal.x - net_half_width
	var post_hi_x: float = attacking_goal.x + net_half_width
	# Post clearance: the widest |x| the puck's CENTER can cross the line at
	# without clipping the pipe (post + puck radius — see
	# GameRules.NET_ENTRY_HALF_WIDTH), PLUS the shooter's own execution spread
	# projected to the net plane (aim_spread_rad × range). The bare physical
	# clamp put the puck's edge exactly TANGENT to the post edge — a knife-edge
	# any wobble turns into iron — and a noisy hand needs its wobble budgeted
	# inside the entry, so the spread lands as goals/saves/misses, not clanks.
	var entry_inset: float = GameRules.NET_POST_RADIUS \
			+ GameRules.PUCK_COLLISION_RADIUS \
			+ aim_spread_rad * shooter.distance_to(attacking_goal)
	var entry_lo_x: float = post_lo_x + entry_inset
	var entry_hi_x: float = post_hi_x - entry_inset

	if kind == HOLE_KIND_FIVE:
		return clampf(_shadow_x(shooter, goalie_pos.x, goalie_pos.z, net_z),
				entry_lo_x, entry_hi_x)

	# Corner: aim at the open segment [post ↔ cover edge] on the hole's side,
	# midpoint biased toward the post. Cover edges come from the same disc-tangent
	# body model _hole_open_angle scores with (see the doc there), projected back
	# onto the net plane so the midpoint math stays in x.
	var u: float = goalie_pos.x - shooter.x
	var net_normal_z: float = -signf(attacking_goal.z)
	var fwd: float = (shooter.z - attacking_goal.z) * net_normal_z
	var dv: float = fwd - (goalie_pos.z - attacking_goal.z) * net_normal_z
	# Same reach budget as _hole_open_angle: the puck reaches HIS body, not the
	# goal line, and the cover is the shared _band_cover read at that moment —
	# including the same screened-read shrink (t_read), so aim and score
	# always describe the same edge.
	var t_reach: float = sqrt(u * u + dv * dv) / pace
	var t_read: float = t_reach - screen_dist_m / pace \
			- clampf(unsettled, 0.0, 1.0) * UNSETTLE_READ_PENALTY_S
	var cover: float = _cover_at_height(arrival_y, t_read, goalie_down, side,
			goalie_hands, goalie_pads)
	var cov_lo_x: float = post_hi_x
	var cov_hi_x: float = post_lo_x
	if dv >= 0.001:
		var d: float = sqrt(u * u + dv * dv)
		if d <= cover:
			# Smothered (scored 0 anyway) — degenerate; aim the near entry edge.
			return entry_lo_x if side < 0 else entry_hi_x
		var alpha: float = atan2(u, dv)
		var beta: float = asin(clampf(cover / d, 0.0, 1.0))
		var g_lo: float = alpha - beta
		var g_hi: float = alpha + beta
		cov_lo_x = post_lo_x if g_lo <= -PI * 0.5 + 0.001 \
				else clampf(shooter.x + tan(g_lo) * fwd, post_lo_x, post_hi_x)
		cov_hi_x = post_hi_x if g_hi >= PI * 0.5 - 0.001 \
				else clampf(shooter.x + tan(g_hi) * fwd, post_lo_x, post_hi_x)
	if side < 0:
		var mid_lo: float = (post_lo_x + cov_lo_x) * 0.5
		return maxf(lerpf(mid_lo, post_lo_x, AIShotAim.DEFAULT_CORNER_BIAS), entry_lo_x)
	var mid_hi: float = (cov_hi_x + post_hi_x) * 0.5
	return minf(lerpf(mid_hi, post_hi_x, AIShotAim.DEFAULT_CORNER_BIAS), entry_hi_x)


# Projects a point (px at depth pz) onto the net plane (z = net_z) along the
# sightline from the shooter — the point's "shadow" on the net. Only the
# five-hole aim still uses this centre-point projection; the corner holes read
# the goalie's cover as a body-disc tangent cone (see _hole_open_angle), which
# is what keeps sharp angles honest.
static func _shadow_x(shooter: Vector3, px: float, pz: float, net_z: float) -> float:
	var dz: float = pz - shooter.z
	if absf(dz) < 0.000001:
		return px
	return shooter.x + (net_z - shooter.z) / dz * (px - shooter.x)


# RAW open angle (radians, from the shooter's eye) of hole `i` — 0 if the
# goalie covers it. The CLAMPED view of _hole_margin, for the consumers that
# only care whether a hole is a target at all: the aim / loft / power choosers
# and expected_goals. open_net_danger reads the signed margin instead, because
# HOW covered a covered hole is is exactly the gradient it needs (see there).
static func _hole_open_angle(
		i: int, shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float, unsettled: float,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> float:
	return maxf(0.0, _hole_margin(i, shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, unsettled, goalie_five_hole_m,
			goalie_down, goalie_post_seal_x, goalie_post_seal_tall,
			aim_spread_rad, screen_dist_m, goalie_hands, goalie_pads, loft_tans))


# The five-hole's SIGNED margin from an effective slot width. The puck either
# fits between his pads or it does not, and that verdict does NOT foreshorten:
# a slot at half a puck-width is equally unthreadable from 5 m and from 25 m.
# Dividing the shortfall by range (the way an open window's angular size
# legitimately shrinks) makes a fully SEALED slot read as "a hair closed" from
# distance, which the soft edge then pays out on — a 32 m point shot scoring
# 0.20 off a five-hole that is physically shut. So a slot the puck cannot pass
# is structurally closed; only a real opening is measured as an angle. The
# unsettle gradient is upstream of this, in `slot` itself (the drop race), so
# catching him moving still opens the hole — it just has to open it for real.
static func _five_hole_margin(slot: float, dist: float) -> float:
	var clearance: float = slot - 2.0 * GameRules.PUCK_COLLISION_RADIUS
	if clearance <= 0.0:
		return HOLE_STRUCTURALLY_CLOSED_RAD
	return clearance / maxf(dist, 0.5)


# SIGNED margin (radians, from the shooter's eye) of hole `i`: how much net
# clears the reaction-gated cover edge, going NEGATIVE by the overlap depth
# when the keeper has the hole covered. The five-hole is a central gap that
# opens with the goalie's unsettle, signed by how far the slot falls short of
# the puck's own diameter. All openings are computed on the net plane so
# foreshortening is automatic. The shooter's execution spread does NOT enter
# here (the make-probability mapping in open_net_danger owns it, exactly once);
# the `_aim_spread_rad` slot is kept so the chooser/aim/score call chain stays
# positionally aligned with _hole_aim_x, which does consume it.
#
# Holes that are not targets at all — behind the goal line, an unreachable
# band, a deployed post seal, a release inside his body — return
# HOLE_STRUCTURALLY_CLOSED_RAD rather than a near-zero negative, so the
# softness tail in open_net_danger never reads them as nearly open.
static func _hole_margin(
		i: int, shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float, unsettled: float,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		_aim_spread_rad: float = 0.0,
		screen_dist_m: float = 0.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		# On/behind the goal line — no shot in.
		return HOLE_STRUCTURALLY_CLOSED_RAD
	var kind: int = HOLE_KIND[i]
	var side: int = HOLE_SIDE[i]
	var band: int = HOLE_BAND[i]
	# One rung read, shared by the pace, the arrival height and the cover, so
	# the score and the aim describe a single shot. A HIGH hole with no legal
	# rung is structurally closed — not a target at all.
	var dist_to_goal: float = shooter.distance_to(attacking_goal)
	var level: int = _hole_rung(band, dist_to_goal, shot_speed_m_s, loft_tans,
			_xz_dist(shooter, goalie_pos), goalie_down)
	if band == HOLE_BAND_HIGH and level == ShotMechanics.ELEVATION_FLAT:
		return HOLE_STRUCTURALLY_CLOSED_RAD
	var pace: float = _rung_pace(level, shot_speed_m_s, loft_tans)
	var arrival_y: float = _rung_arrival(level, dist_to_goal, shot_speed_m_s,
			loft_tans)
	# Reach budget: the puck crosses the goalie's reach envelope at HIS body —
	# the shooter→goalie gap at the band's pace — not at the goal line. This is
	# what range genuinely buys him; in tight it's a fraction of the flight, and
	# it's why a quick release beats the same keeper a long shot can't.
	var u: float = goalie_pos.x - shooter.x
	var dv: float = forward - (goalie_pos.z - attacking_goal.z) * net_normal_z
	var t_reach: float = sqrt(u * u + dv * dv) / pace
	# Delayed read: the goalie can't start reacting until he SEES the release
	# — the puck must EMERGE past the worst screener (screen_dist_m / pace,
	# the same sightline occlusion the live goalie suffers), and a
	# caught-moving keeper reads late on top of it (the unsettle penalty,
	# mirroring the live read model). Only the READ budget shrinks: the body
	# geometry and the physical race (t_reach) are untouched — a screened or
	# scrambling goalie still fills his ice, he just deploys late, and a long
	# flight hands the lateness back through the same reach race (the
	# recovery is emergent, not a separate fade). Per-band pace makes the
	# occlusion honest per hole (a lofted arc is hidden longer than a bullet
	# along the same geometry).
	var t_read: float = t_reach - screen_dist_m / pace \
			- clampf(unsettled, 0.0, 1.0) * UNSETTLE_READ_PENALTY_S

	# A post-seal stance (VH/RVH, read off the replicated state — see
	# GoalieNetworkState.post_seal_x_sign) is a DEPLOYED wall at the post: the
	# coverage is the pose itself, already in place at release, so nothing on
	# the sealed side is reaction-gated. The between-the-legs slot is closed in
	# both families (back pad + post-sealed pad — no FIVE to thread). VH stands
	# the vertical pad + tall torso in the whole near column, ice to over the
	# shoulder: sealed-side LOW and HIGH are both gone. RVH stays compressed —
	# sealed-side LOW is gone but short-side HIGH stays measured (its
	# documented weakness). The FAR side is deliberately untouched: it's read
	# from the goalie's actual parked-at-the-post position below, which is what
	# keeps the walkout / cross-crease counter visible to the model.
	#
	# DEPLOYMENT RACE: the wall only exists if the keeper is ACTUALLY at the
	# seal post at release. His predicted position (goalie_pos) already bakes
	# in the setup time — a slow carry to a dead angle hands him the whole trip
	# to set at the post; a fast cross-crease feed to a caught-moving keeper
	# leaves him stranded off it — so the check is purely positional: his body
	# EDGE (his stance already spans LOW_CORE_STANDING_M, plus the lateral push
	# he can still make over the shot flight t_read) must reach the seal post.
	# A dead-angle wraparound seals (keeper set at the post); the point-blank
	# back-door one-timer does NOT (keeper stranded) — the tap-in that beats
	# real post play, kept visible to the finisher/feed models.
	if goalie_post_seal_x != 0.0 \
			and absf(attacking_goal.x + signf(goalie_post_seal_x)
					* GameRules.NET_HALF_WIDTH - goalie_pos.x) \
				<= LOW_CORE_STANDING_M + goalie_lateral_reach(maxf(t_read, 0.0)):
		if kind == HOLE_KIND_FIVE:
			return HOLE_STRUCTURALLY_CLOSED_RAD
		if float(side) == signf(goalie_post_seal_x) \
				and (goalie_post_seal_tall or HOLE_BAND[i] == HOLE_BAND_LOW):
			return HOLE_STRUCTURALLY_CLOSED_RAD
	if kind == HOLE_KIND_FIVE:
		# Jam smother: a release already inside the goalie's standing pad
		# column (a behind-the-goalie release clamped to his toes) has no
		# five-hole — the body it would thread is ON the puck. Mirrors the
		# corner branch's release-inside-the-body smother.
		var jam_r: float = LOW_CORE_STANDING_M + GameRules.PUCK_COLLISION_RADIUS
		if u * u + dv * dv <= jam_r * jam_r:
			return HOLE_STRUCTURALLY_CLOSED_RAD
		# Between-the-legs gap, foreshortened with range (gap / distance); only a
		# roughly head-on look can thread the legs (centrality). The puck has to
		# FIT here too: what scores is the gap's CLEARANCE past the puck's own
		# diameter (the same honesty the corners pay via the clean-entry inset).
		# Without it, the standing ~0.16-0.20 m slot — barely wider than the
		# 0.13 m puck — read as generous as a real corner window; with it, the
		# standing five is the razor-thin look it actually is and the live
		# five-hole is the DOWN goalie's slide leak, which genuinely opens.
		var centrality: float = clampf(
				1.0 - absf(shooter.x - goalie_pos.x) / FIVE_CENTER_REF_M, 0.0, 1.0)
		var dist: float = shooter.distance_to(attacking_goal)
		# The shooter's execution spread eats the slot exactly as it eats a
		# corner window (the corners subtract it via fit_angle below): a
		# razor-thin five-hole a noisy hand can't actually thread must not
		# out-score a wider corner through the flat-loft tie-break.
		if goalie_five_hole_m >= 0.0:
			# MEASURED slot from the replicated pose (GoalieBehaviorRules.
			# five_hole_gap_m): standing it's a real ~0.20 m ice-to-pad-top slot
			# the goalie seals by DROPPING once he reads the release — legs
			# reaction delay then pads-to-floor, raced against the puck reaching
			# HIM (t_reach) — so only an in-tight release beats the drop. Down,
			# the residual gap (slide leak) is already the measurement and there
			# is nothing left to drop. The paddle lying ACROSS the slot is
			# charged too, while he is upright: the blade is nearly twice the
			# standing slot (0.38 m vs ~0.20 m) and stays over the centre even
			# yawed to the cap, so standing it shuts the five outright. Its yaw
			# away from an off-centre shooter is not a reason to leave it out —
			# that is what `centrality` prices — and the live keeper stick-saves
			# 24/24 of the straight-on in-tight looks an unmodeled slot rates
			# ~0.9 (test_slot_shot_value_truth.gd). DOWN is left alone: the
			# residual there is the slide leak between sprawled pads, not the
			# slot the paddle lies over.
			var gap: float = goalie_five_hole_m
			if not goalie_down:
				var seal: float = clampf(
						(t_read - _delay_at_height(0.0, goalie_down))
							/ goalie_butterfly_drop_s,
						0.0, 1.0)
				gap *= 1.0 - seal
			# The PADDLE is deliberately not subtracted here, though
			# GoalieStickRules.five_hole_gap_after_blade exists to do it and
			# claims a standing keeper "closes outright". It takes the blade's
			# 0.38 m WIDTH off a ~0.20 m slot, so it clamps to zero and the
			# five-hole dies for every standing keeper at every range and every
			# timing — the butterfly-drop race just above stops mattering. The
			# blade is 0.07 m TALL: a lifted wrister clears it and goes through
			# the legs, which is the five-hole goal players actually score. This
			# model has no height resolution inside the LOW band, so it cannot
			# represent "over the blade, between the pads" as a distinct hole;
			# given that, keeping the slot open and letting the drop race decide
			# is the branch that matches the live keeper.
			#
			# Centrality narrows the SLOT (off-axis you see less daylight
			# between the pads) rather than scaling the finished margin —
			# scaling a NEGATIVE margin by a small centrality would push it
			# toward zero, i.e. read a hopeless off-axis look as nearly open.
			return _five_hole_margin(gap * centrality, dist)
		# Legacy proxy (no replicated stance in scope — threat surfaces, tests):
		# the nominal standing slot raced against the same read-delayed
		# butterfly seal the measured branch runs — a set goalie seals it, a
		# caught-moving or point-blank release beats the drop (the unsettle
		# lateness is already inside t_read).
		var proxy_gap: float = FIVE_GAP_M
		var proxy_seal: float = clampf(
				(t_read - _delay_at_height(0.0, goalie_down)) / goalie_butterfly_drop_s,
				0.0, 1.0)
		proxy_gap *= 1.0 - proxy_seal
		return _five_hole_margin(proxy_gap * centrality, dist)

	# Cover at the height this shot actually arrives at, raced against the read
	# budget (t_reach less screen occlusion and caught-moving lateness) — pad
	# column widened by the butterfly drop where the pads still are, structure
	# plus a reaction-gated hand where they no longer reach, the real lateral
	# push throughout — see _cover_at_height.
	var cover: float = _cover_at_height(arrival_y, t_read, goalie_down, side,
			goalie_hands, goalie_pads)

	# Net posts and the goalie's cover, all as bearings from the shooter's eye.
	var post_lo_x: float = attacking_goal.x - net_half_width
	var post_hi_x: float = attacking_goal.x + net_half_width
	var net_lo: float = atan2(post_lo_x - shooter.x, forward)
	var net_hi: float = atan2(post_hi_x - shooter.x, forward)
	# The goalie occludes as a BODY (a disc of the band's cover radius), not a
	# paper cutout on the x-axis: he squares to the puck, so he presents the
	# band's cover half-width perpendicular to the shooter's sightline from any
	# bearing. The covered bearing interval is the disc's tangent cone. For a
	# frontal shooter this reduces to a net-plane point projection
	# (tan β ≈ cover / depth), but from a sharp angle the body's DEPTH occludes
	# the cross-crease lane. A zero-depth model instead leaves the far post
	# "open" from beside the net — the hopeless bad-angle fire.
	var covb_lo: float
	var covb_hi: float
	if dv < 0.001:
		# Goalie at/behind the release plane — he covers nothing (upstream release
		# clamps keep real shooters from exploiting this; it's a degenerate read).
		covb_lo = net_hi
		covb_hi = net_lo
	else:
		var d_sq: float = u * u + dv * dv
		if d_sq <= cover * cover:
			# Release inside the goalie's body — smothered.
			return HOLE_STRUCTURALLY_CLOSED_RAD
		var alpha: float = atan2(u, dv)
		var beta: float = asin(clampf(cover / sqrt(d_sq), 0.0, 1.0))
		# Bounded ABOVE by the far post (a keeper entirely off the net can only
		# open the net's own width) but NOT below: clamping the near side to the
		# post throws the overlap depth away and flat-lines the covered region
		# at exactly 0.
		covb_lo = minf(alpha - beta, net_hi)
		covb_hi = maxf(alpha + beta, net_lo)

	var open_angle: float
	if side < 0:
		open_angle = covb_lo - net_lo   # left post → cover's left edge
	else:
		open_angle = net_hi - covb_hi   # cover's right edge → right post
	# The puck has to FIT: a corner only scores by what remains after the puck's
	# clean-entry inset off the pipe — post radius + puck radius, the exact
	# GameRules.NET_ENTRY_HALF_WIDTH inset _hole_aim_x buys the aim point. This is a
	# HARD geometric requirement (the puck physically clips the iron short of it),
	# so it's subtracted outright. (The cover side charges the puck's radius
	# inside _band_cover — the mirror inset off the pad/glove edge.) The
	# inset's angular size foreshortens with range like any target, so in
	# tight it costs almost nothing. The RAW window is returned — the
	# shooter's execution spread enters exactly once, in open_net_danger's
	# make-probability mapping (window / 2·spread), never here.
	var pipe_clearance: float = (GameRules.NET_POST_RADIUS + GameRules.PUCK_COLLISION_RADIUS) \
			/ maxf(shooter.distance_to(attacking_goal), 0.5)
	return maxf(open_angle - pipe_clearance, HOLE_STRUCTURALLY_CLOSED_RAD)


# ── Screen perception (sightline occlusion) ──────────────────────────────────
# Planning mirror of the live goalie's screen model
# (GoalieBehaviorRules.screen_occlusion_delay): a body between the release and
# the goalie hides the puck, and his read clock only starts when the puck
# EMERGES past the screener. Returns the worst screener's along-sightline
# distance (m) from the release — 0.0 for a clean look. A DISTANCE, not a
# time: each hole band divides by its own pace (_hole_open_angle's t_read), so
# the slower lofted arc is hidden longer than the bullet on the same geometry.
# A net-front body hides the puck almost the whole way in (the deadly screen);
# a body up near the shooter is passed early and barely delays the read.
#
# Two body lists so callers hand over defenders + own teammates without
# merging (hot-path: no combined array). BOTH sides screen — the parked
# net-front teammate is the classic screen, and a boxing-out defender hides
# the puck from his own goalie just the same. The block risk those same
# defender bodies carry is priced separately by lane_clear; conditioned on
# the shot getting through, the body still hid the release — that's the real
# point-shot-through-traffic trade. Radius and shooter self-exclusion mirror
# GoalieBehaviorRules.ScreenConfig.
const SCREEN_BODY_HALF_WIDTH_M: float = 0.6
const SCREEN_MIN_ALONG_M: float = 0.6

static func _xz_dist(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


static func screen_along_m(
		shooter: Vector3, goalie_pos: Vector3,
		bodies_a: Array[Vector3], bodies_b: Array[Vector3]) -> float:
	var dx: float = goalie_pos.x - shooter.x
	var dz: float = goalie_pos.z - shooter.z
	var goalie_along: float = sqrt(dx * dx + dz * dz)
	if goalie_along <= SCREEN_MIN_ALONG_M:
		return 0.0
	var hx: float = dx / goalie_along
	var hz: float = dz / goalie_along
	var worst: float = _worst_screener_along(
			bodies_a, shooter, hx, hz, goalie_along, 0.0)
	return _worst_screener_along(bodies_b, shooter, hx, hz, goalie_along, worst)


# One body list's worst on-sightline screener (see screen_along_m). A screener
# counts only ON the line (perp < body half-width), past the shooter's own
# body, and NEARER than the goalie (a body level with or behind him can't
# hide an incoming puck). Scalar loop, allocation-free.
static func _worst_screener_along(
		bodies: Array[Vector3], shooter: Vector3,
		hx: float, hz: float, goalie_along: float, worst: float) -> float:
	for s: Vector3 in bodies:
		var relx: float = s.x - shooter.x
		var relz: float = s.z - shooter.z
		var along: float = relx * hx + relz * hz
		if along <= SCREEN_MIN_ALONG_M or along >= goalie_along:
			continue
		if absf(relx * -hz + relz * hx) >= SCREEN_BODY_HALF_WIDTH_M:
			continue
		if along > worst:
			worst = along
	return worst


# ── Shoot-for-tip EV ──────────────────────────────────────────────────────────
# The value of ripping a shot AT THE NET through a net-front teammate's blade —
# the deflection play. Physically: an incoming puck above the deflect threshold
# redirects off an angled blade at near-full pace (PuckReceptionRules /
# PuckCollisionRules.deflect_velocity — the finisher's reactive TIP mode angles
# the blade at the net and steps onto the shot path), so the outcome is a NEW
# release from the tip point that the goalie has almost no flight left to read.
# Three independent physical events compose:
#   P(rip reaches the tipper)   — lane_clear over release→tip vs the DEFENDERS
#                                 (the tipper is the target, not a blocker)
# × P(blade contacts the puck)  — the SAME per-body reach/reaction race a lane
#                                 defender runs (_lane_block_at): a stationed
#                                 tipper on the line is the near-certain
#                                 contact it really is, a man metres off it
#                                 contributes ~0, and the reactive tip's
#                                 step-onto-the-path is the close-speed term
# × score_shoot(tip point → net) — the redirect priced by the ONE xG model:
#                                 t_reach from crease-edge at shot pace sits
#                                 inside the goalie's leg delay (no drop, no
#                                 extension), and defenders boxing out the
#                                 tipper contest the redirect through
#                                 score_shoot's own release-contest term.
# max() against the direct read at the call site, never additive — the two are
# different aims of the same rip (through the tipper vs at a corner).

# Domain mirror of Puck.deflect_min_speed (the receiver-relative pace above
# which a blade deflects instead of catching): a rip below it lands on the
# tape as a pass — no tip outcome exists.
const TIP_DEFLECT_MIN_SPEED_M_S: float = 22.0

# Outgoing-line scatter of a deflection (radians), fed to score_shoot's
# aim-spread term. A set net-front blade controls its FACE angle against a
# 30+ m/s arrival to roughly ±7°, and the reflection doubles face error into
# outgoing error — ~±14° (0.25 rad) of scatter on where the redirect actually
# goes. This is the physical difference between a tip (get a piece, change
# the line) and a swept one-timer (a genuinely aimed release): without it a
# stationed tipper's redirect reads as corner-picking sniper fire and
# out-scores the open backdoor tap-in in a 2-on-0.
const TIP_AIM_SPREAD_RAD: float = 0.25


static func tip_ev(
		release: Vector3,
		tip_man: Vector3,
		attacking_goal: Vector3,
		goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3],
		shot_speed_m_s: float,
		opponent_caps: Array = [],
		tip_caps: AISkaterCaps = null) -> float:
	if shot_speed_m_s < TIP_DEFLECT_MIN_SPEED_M_S:
		return 0.0
	# Shot line: release → net centre (the reactive tip steps ONTO this line,
	# so planning against it is self-consistent with the execution).
	var dx: float = attacking_goal.x - release.x
	var dz: float = attacking_goal.z - release.z
	var line_len: float = sqrt(dx * dx + dz * dz)
	if line_len < 0.001:
		return 0.0
	var hx: float = dx / line_len
	var hz: float = dz / line_len
	# Tip point: the tipper's foot on the line — where blade meets puck. Must
	# be a real mid-flight contact: past the shooter's own handle, short of
	# the goal mouth.
	var relx: float = tip_man.x - release.x
	var relz: float = tip_man.z - release.z
	var along: float = relx * hx + relz * hz
	if along <= SCREEN_MIN_ALONG_M or along >= line_len - 0.3:
		return 0.0
	var tip_pt := Vector3(release.x + hx * along, 0.0, release.z + hz * along)
	# P(blade contacts): the tipper's real stick reach + lateral close.
	var stick: float = LANE_DEFENDER_REACH_M
	var close: float = LANE_DEFENDER_CLOSE_SPEED_M_S
	if tip_caps != null:
		stick = tip_caps.stick_reach
		close = LANE_LATERAL_FRACTION * tip_caps.max_speed
	var speed: float = maxf(shot_speed_m_s, 1.0)
	var p_contact: float = _lane_block_at(
			release.x, release.z, hx * speed, hz * speed, along / speed,
			tip_man.x, tip_man.z, 0.0, 0.0, stick, close)
	if p_contact <= 0.0:
		return 0.0
	# P(rip reaches him): the defenders' lane over the release→tip segment.
	var lane: float = lane_clear(release, tip_pt, opponents, speed, EMPTY_VEC3, opponent_caps)
	if lane <= 0.0:
		return 0.0
	# The redirect: a new release at the tip point holding the incoming pace
	# (a tip keeps the along-face glance), scattered by the deflection's
	# outgoing-line control (TIP_AIM_SPREAD_RAD). No unsettle bonus — the
	# collapsed read window IS the tip's edge, and it falls out of t_reach.
	var redirect: float = score_shoot(
			tip_pt, attacking_goal, goalie_pos, net_half_width, opponents,
			speed, 0.0, opponent_caps, -1.0, false, 0.0, false,
			TIP_AIM_SPREAD_RAD)
	return p_contact * lane * redirect


# Returns SHOOT score in [0, 1]: the geometric open-net danger × lane clearance
# × forward-cone pressure. `predicted_goalie_pos` is the goalie at shot release
# (use `predict_goalie_pos`); the hole geometry handles "too close" on its
# own. `shot_speed_m_s` sets the puck's pace (goalie reach budget) and the lane math;
# `goalie_unsettled_factor` cuts his reaction (a mid-slide goalie reads the shot
# late). `screeners` are ADDITIONAL sightline bodies (the shooter's own
# traffic — teammates); the defender bodies in `opponents` screen implicitly.
static func score_shoot(
		shooter: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3],
		shot_speed_m_s: float = WRISTER_SHOT_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0,
		opponent_caps: Array = [],
		goalie_five_hole_m: float = -1.0,
		goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0,
		screeners: Array[Vector3] = [],
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		loft_tans: Vector3 = DEFAULT_LOFT_TANS) -> float:
	# No shot from on/behind the goal line: the mouth faces the other way, so there
	# is no straight line from a back-there release into the net. Checked BEFORE
	# the release clamp below: clamping a behind-the-net release teleports it to
	# a phantom point-blank spot in front of the goalie, scoring a behind-the-net
	# carrier's "shot" as a doorstep open net (the wraparound is a CARRY around
	# the post, never a direct fire from back there).
	if (shooter.z - attacking_goal.z) * -signf(attacking_goal.z) < 0.001:
		return 0.0
	# The puck can't be shot from behind the goalie — clamp the shooter to the jam
	# distance in front of him. Without this a hard drive's projected release, or a
	# carry candidate placed in the crease, reads as a phantom open net (keeper
	# modelled behind the shooter). No-op for any normal in-front shot.
	shooter = release_ahead_of_goalie(shooter, attacking_goal, predicted_goalie_pos)
	# Sightline traffic: the worst screener's along-distance (defender bodies
	# AND the shooter's own net-front men) delays the goalie's read inside the
	# hole geometry — the point-shot-through-traffic disadvantage the live
	# goalie genuinely suffers.
	var screen_dist: float = screen_along_m(
			shooter, predicted_goalie_pos, opponents, screeners)
	var shot_quality: float = open_net_danger(
			shooter, attacking_goal, predicted_goalie_pos, net_half_width,
			shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad,
			screen_dist, goalie_hands, goalie_pads, loft_tans)
	if shot_quality <= 0.0:
		return 0.0
	# Lane clear vs the aim point ShotAim picks (past the goalie's shadow) —
	# defenders on the shot line reduce it via the reaction-window model.
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, predicted_goalie_pos, attacking_goal.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = lane_clear(shooter, aim, opponents, shot_speed_m_s, EMPTY_VEC3, opponent_caps)
	# Release duress: opponents whose blade can reach the puck during the
	# windup contest the release (release_contest_clean — bodies merely
	# NEAR the shooter don't; bodies on the shot line are the lane's job).
	var pressure_factor: float = release_contest_clean(
			release_point_toward(shooter, attacking_goal), opponents, opponent_caps)
	return shot_quality * lane * pressure_factor


# ── The SEAM's composed counterpart ──────────────────────────────────────────
# score_shoot's structure with AIShotValue supplying the shot quality instead
# of the five-hole geometry. Same guards, same release clamp, same defender
# terms — a lane the puck has to survive and a release the shooter has to get
# off are facts about DEFENDERS, and swapping the goalie model says nothing
# about them.
#
# What changes is the quality term: a smooth, monotone, goalie-displacement-
# aware probability rather than a max over five holes with structural cliffs.
static func score_shoot_value(
		shooter: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		keeper_displacement_m: float,
		net_half_width: float,
		opponents: Array[Vector3],
		shot_speed_m_s: float = WRISTER_SHOT_SPEED_M_S,
		opponent_caps: Array = [],
		shot_type: int = ShotEvent.ShotType.SHOT) -> float:
	if (shooter.z - attacking_goal.z) * -signf(attacking_goal.z) < 0.001:
		return 0.0
	shooter = release_ahead_of_goalie(shooter, attacking_goal, predicted_goalie_pos)
	# The seal is derived from the same geometric trigger the live keeper uses
	# (derive_post_seal_x_sign — inside the post zone AND past the bearing), so
	# predictive and shoot-now paths agree about it without threading state.
	var seal_x: float = derive_post_seal_x_sign(shooter, attacking_goal)
	var quality: float = AIShotValue.for_release(
			shooter, attacking_goal, keeper_displacement_m, shot_type,
			seal_x != 0.0)
	if quality <= 0.0:
		return 0.0
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, predicted_goalie_pos, attacking_goal.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = lane_clear(shooter, aim, opponents, shot_speed_m_s,
			EMPTY_VEC3, opponent_caps)
	var pressure: float = release_contest_clean(
			release_point_toward(shooter, attacking_goal), opponents, opponent_caps)
	return quality * lane * pressure


# score_pass's twin on the seam — lane × the receiver's shot value from where
# he catches it, with the keeper's displacement at the receiver's release the
# one goalie term (score_pass reads the whole pose instead).
#
# Exists so the DEVELOPING-feed hold can be compared with the fire it competes
# against. That compete is `fire_score >= hold_value`, a straight numeric test,
# and the two models do not share a range: the hole geometry reaches 1.0 while
# this form tops out near 0.45 from any real spot. Feeding it a score_pass hold
# is not a mispriced hold, it is a permanent veto on shooting.
static func score_pass_value(
		shooter: Vector3,
		receiver: Vector3,
		attacking_goal: Vector3,
		keeper_displacement_m: float,
		opponents: Array[Vector3],
		pass_speed_m_s: float = PASS_SPEED_M_S,
		opponent_caps: Array = EMPTY_CAPS,
		shot_type: int = ShotEvent.ShotType.SHOT) -> float:
	if _is_past_goal_line(receiver, attacking_goal):
		return 0.0
	if pass_lane_blocked_by_net(shooter, receiver):
		return 0.0
	var lane: float = lane_clear(shooter, receiver, opponents, pass_speed_m_s,
			EMPTY_VEC3, opponent_caps)
	if lane <= 0.0:
		return 0.0
	return lane * AIShotValue.for_release(
			receiver, attacking_goal, keeper_displacement_m, shot_type,
			derive_post_seal_x_sign(receiver, attacking_goal) != 0.0)


# FIELDED twin of score_shoot for the threat-surface consumer family
# (threat_surface_shoot / threat_local_shoot / the zone soft-lock read):
# the goalie-hole core comes from AIDangerField's memoized surface — league
# pace, unsettled 0, declared stance, seal derived from position, goalie at
# his CURRENT spot, which are exactly this family's inputs — and only the
# defender terms (shot lane, release contest) run live, so a hypothetical
# defender body still blocks exactly. Two deliberate drops vs the exact
# twin, both bounded by the calibration test (test_danger_field.gd):
#   - sightline screening (a body delaying the goalie's read raises true
#     quality — the fielded read understates a screened shooter);
#   - the second-chance rebound term (its screeners input is always empty
#     on this family, so it contributes 0 there anyway).
# Same guard + release clamp as the exact twin, applied BEFORE sampling so
# the memo is keyed on the clamped release like score_shoot scores it.
static func score_shoot_threat_fielded(
		shooter: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		defenders: Array[Vector3],
		defender_caps: Array = EMPTY_CAPS) -> float:
	if (shooter.z - our_net.z) * -signf(our_net.z) < 0.001:
		return 0.0
	var clamped: Vector3 = release_ahead_of_goalie(shooter, our_net, our_goalie_pos)
	var q: float = AIDangerField.quality(
			clamped, our_net, our_goalie_pos, net_half_width)
	if q <= 0.0:
		return 0.0
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			clamped, our_goalie_pos, our_net.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = lane_clear(clamped, aim, defenders, WRISTER_SHOT_SPEED_M_S,
			EMPTY_VEC3, defender_caps)
	var pressure: float = release_contest_clean(
			release_point_toward(clamped, our_net), defenders, defender_caps)
	return q * lane * pressure


# ── Predicted post-seal (RVH/VH) — the ONE xG model, consistent inputs ─────────
# score_shoot is the single xG model, so it can only give two answers for the
# same spot through its INPUTS. The shoot-now eval reads the LIVE goalie's seal
# state (GoalieNetworkState.post_seal_x_sign) and threads it; a predictive
# caller (carry candidate, pass receiver) has no such state, and left at the
# unsealed default a sharp-angle origin scores a PHANTOM far-side open net that
# the bot carries to and then meets a keeper already walled at the post. So the
# seal a competent keeper WILL adopt is predicted here from the SAME geometric
# trigger the live goalie uses (GoalieBehaviorRules.is_puck_in_defensive_zone),
# and the predictive paths feed the model the coverage the shoot-now path reads
# live.
#
# Mirrors GoalieController.zone_post_z / rvh_early_angle (the RVH/VH trigger):
# within this depth of the goal line AND past this bearing off the goal normal,
# the keeper is post-sealed. Deliberately narrow (2 m, 80°) — it touches only the
# wraparound/extreme-corner region, never a normal slot or mid look.
const GOALIE_SEAL_ZONE_POST_Z_M: float = 2.0
const GOALIE_SEAL_ANGLE_RAD: float = deg_to_rad(80.0)


# Predicted post-seal x-sign for a shot from `shooter`: the side (relative to goal
# center) a keeper would seal, or 0.0 for the common in-front look where no seal
# applies. Only the IN-FRONT sharp angle is sealed here (VH — tall); a release
# behind the goal line is already zeroed by score_shoot's forward guard, so it
# needs no seal. Pure float, allocation-free — safe on the per-candidate path.
#
# Two triggers, both grounded in the live keeper:
#  · The RVH/VH zone (2 m, 80°) — the live controller's own stance trigger.
#  · DEAD-ANGLE ERASURE: outside that zone, a competent keeper still kills a
#    sharp-angle look by post-integrated positioning — pad edge ON the near-
#    post sightline, full stance span extending into the window. The shot dies
#    when the net's whole angular window from the shooter is no wider than
#    that body plus a puck diameter of fit (the puck's center must clear the
#    body edge and the far pipe by its radius). Pure projection geometry
#    (posts + the live stance span the band model already uses), so it scales
#    with range by construction: the slot and any honest mid look stay far
#    wider than a body and are untouched. Without it a close sharp-angle
#    release (~65°+, past the 2 m zone) scores a phantom far-side window and
#    the carry surface drifts bots to the dead corner.
static func derive_post_seal_x_sign(shooter: Vector3, attacking_goal: Vector3) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0
	var lateral: float = absf(shooter.x - attacking_goal.x)
	# Frontal early-out (hot path — this is on every arc-match): neither
	# trigger can fire at or inside 45° off the normal. The RVH/VH zone needs
	# 80°, and the erasure's window at 45° (≥ 1.83·cos 45° / d) is always
	# wider than the post-body cover (≤ 0.80 / d) at any range.
	if lateral <= forward:
		return 0.0
	var side: float = signf(shooter.x - attacking_goal.x)
	if forward <= GOALIE_SEAL_ZONE_POST_Z_M \
			and atan2(lateral, maxf(forward, 0.01)) >= GOALIE_SEAL_ANGLE_RAD:
		return side
	if side == 0.0:
		return 0.0
	# Dead-angle erasure: net angular window vs the post-hugging keeper's
	# stance span + puck fit, anchored at the near-post sightline.
	var near_x: float = attacking_goal.x + side * GameRules.NET_HALF_WIDTH
	var far_x: float = attacking_goal.x - side * GameRules.NET_HALF_WIDTH
	var dz: float = attacking_goal.z - shooter.z
	var a_near: float = atan2(near_x - shooter.x, dz)
	var a_far: float = atan2(far_x - shooter.x, dz)
	var window: float = absf(a_near - a_far)
	var d_near: float = sqrt(
			(near_x - shooter.x) * (near_x - shooter.x) + dz * dz)
	var cover: float = atan((2.0 * LOW_CORE_STANDING_M
			+ 2.0 * GameRules.PUCK_COLLISION_RADIUS) / maxf(d_near, 0.1))
	if window <= cover:
		return side
	return 0.0


# Point-blank jam distance: the closest the puck realistically gets to a set goalie
# before his body/pads stop it. A physical measurement (skate + pad depth), not a
# tuning knob — it just keeps the shooter strictly in FRONT of the keeper so the
# shadow geometry stays well-defined (a shooter coincident with the goalie is a
# degenerate projection).
const GOALIE_JAM_DISTANCE_M: float = 0.4

# A shot's release point can't sit CLOSER to the goal than the goalie: the goalie
# is a body in the way, so the puck leaves the blade in FRONT of him, never behind
# (and no nearer than the jam distance). Clamps a shooter/release so its distance
# out from the goal is at least the goalie's + the jam margin — killing the
# "shooter past the goalie → phantom open net" read, where a hard drive's projected
# release (or a carry candidate placed in the crease) overshoots the goalie's depth
# and the shot scores as if the keeper were behind the shooter. Only the goalward
# axis is clamped; lateral offset (a cut across the slot) is untouched.
#
# A release on/behind the GOAL LINE is returned unchanged: there is no shot from
# back there at all (score_shoot hard-zeros it, and every hole's forward guard
# reads 0 net). Clamping it instead invents a legal-looking point-blank release
# in front of the keeper — the phantom that has bots firing from behind the net.
static func release_ahead_of_goalie(
		release: Vector3, attacking_goal: Vector3, goalie_pos: Vector3) -> Vector3:
	var net_normal_z: float = -signf(attacking_goal.z)
	var release_fwd: float = (release.z - attacking_goal.z) * net_normal_z
	if release_fwd < 0.001:
		return release
	var goalie_fwd: float = (goalie_pos.z - attacking_goal.z) * net_normal_z
	var min_fwd: float = goalie_fwd + GOALIE_JAM_DISTANCE_M
	if release_fwd >= min_fwd:
		return release
	return Vector3(release.x, release.y, attacking_goal.z + min_fwd * net_normal_z)


# The ARC-MATCHING x a properly squared goalie sits at for a puck at
# `puck_pos`: since the goalie sits much closer to the goal than the shooter,
# arc_x = goalie_depth × (puck.x − goal.x) / puck_forward_from_goal. Shared by
# predict_goalie_pos / goalie_unsettled / goalie_squared_pos so all three agree.
static func goalie_arc_match_x(
		goalie_now: Vector3, attacking_goal: Vector3, puck_pos: Vector3) -> float:
	# A POST-SEALED look (derive_post_seal_x_sign — the RVH/VH zone or the
	# dead-angle erasure) has no arc to square on: there is nothing to defend
	# wide of the post, so the competent keeper's square IS the post. Without
	# this the arc formula extrapolates past the net frame at sharp angles (a
	# keeper "squared" ~0.7 m wide of the post), the seal's deployment race
	# reads him as stranded off the post he would really be sealing, and the
	# arc-x's hypersensitivity out there saturates the unsettle credit — a carry
	# to the dead corner scores a phantom certain goal. Post-clamping here keeps
	# prediction, unsettle, and the seal race mutually consistent (all three
	# share this function).
	var seal: float = derive_post_seal_x_sign(puck_pos, attacking_goal)
	if seal != 0.0:
		return attacking_goal.x + seal * GameRules.NET_HALF_WIDTH
	var net_normal_z: float = -signf(attacking_goal.z)
	var puck_forward: float = (puck_pos.z - attacking_goal.z) * net_normal_z
	var goalie_depth: float = (goalie_now.z - attacking_goal.z) * net_normal_z
	# The goalie squares along his ARC — his lateral offset can never exceed his
	# own radial distance from the goal (fully lateral = on the goal line at his
	# radius). Off the arc there is no squaring, only a keeper who abandoned the
	# cage. Unbounded, a near-goal-line puck reference explodes the arc-x toward
	# the corner boards — a phantom far-side opening that has bots firing from
	# beside the net while rounding it. Moderate angles are untouched (their
	# arc-x sits well inside the radius, wider than the posts — which is real:
	# an out-challenging goalie legitimately squares past the post line).
	var radius: float = Vector3(
			goalie_now.x - attacking_goal.x, 0.0,
			goalie_now.z - attacking_goal.z).length()
	if puck_forward < 0.001 or goalie_depth < 0.001:
		# Degenerate: puck on/behind goal line, or goalie there. Best-effort: the
		# puck's side, bounded to the arc.
		return attacking_goal.x + clampf(
				puck_pos.x - attacking_goal.x, -radius, radius)
	var arc_x: float = goalie_depth * (puck_pos.x - attacking_goal.x) / puck_forward
	return attacking_goal.x + clampf(arc_x, -radius, radius)


# The goalie SQUARED to a puck at `puck_pos` — arc-matched and set, no forced
# motion. This is the right model for a CARRY destination: the keeper tracks the
# puck continuously as the bot skates there (gradual move, not a relocation it
# reacts to from a standstill), so on arrival it is square, full stop. Using the
# react-then-slide predict_goalie_pos for a carry under-tracks the keeper —
# especially at a short release lookahead, where he is predicted to fall short of
# arc-matching a diagonal step and leak the far side, which sends the bot chasing
# an ever-receding "one more cut catches him moving" shot into the crease. The
# caught-moving credit belongs to puck RELOCATIONS (shots/passes), not carries.
static func goalie_squared_pos(
		goalie_now: Vector3, attacking_goal: Vector3, puck_pos: Vector3,
		travel_time_s: float = 0.0, closing_speed_m_s: float = 0.0) -> Vector3:
	# DEPTH travels with the puck too (see the planning-depth doc): a keeper
	# tracking a drive backs in along the chart / backflow curve while he
	# squares. `travel_time_s` = 0 leaves him where he is, so callers with no
	# time in scope keep the pure square.
	var based: Vector3 = _at_depth(goalie_now, attacking_goal, planned_goalie_depth(
			goalie_now, attacking_goal, puck_pos, travel_time_s, closing_speed_m_s))
	return Vector3(goalie_arc_match_x(based, attacking_goal, puck_pos),
			based.y, based.z)


# Predicts the goalie's position at a future moment (shot release).
# React-then-push model: a fixed reaction delay, then movement toward
# the ARC-MATCHING x on the accelerate-onto-the-edge push profile
# (_goalie_lateral_reach — ramping at lateral_accel to t_push speed).
#
# Arc-matching: a properly squared goalie sits at the position whose
# arc angle from the goal matches the shooter's. Since the goalie sits
# much closer to the goal than the shooter, that's
#   arc_x = goalie_depth × (puck.x - goal.x) / puck_forward_from_goal
# Never use puck.x directly as the slide target: it is geometrically
# wrong for off-axis shooters, and diagonal carry candidates then read
# as "open net" plays a perfectly-tracking goalie would cover.
#
# `goalie_now` is the goalie's current world position.
# `attacking_goal` is the goal the puck is aimed at; provides goal
# center and the sign for "forward."
# `release_time_s` is seconds from now until the shot fires.
# `puck_pos_at_release` is where the puck will be when fired (= the
# shooter's position for direct shots; receiver lead for passes;
# carry candidate for carry-then-shoot).
# ── The backdoor pre-arm (planning keeper) ──────────────────────────────────
# A live goalie who can see a one-timer man on the weak side is never out at
# full carrier-challenge depth when the feed goes — his challenge radius is
# capped by GoalieBehaviorRules.backdoor_depth_cap (the same rule the real
# keeper runs). The planning keeper for a FEED therefore reads:
#   position    — arc-matched ON the receiver's shot line at the capped
#                 depth: the cap's construction proves line-arrival inside
#                 the feed's window for a keeper who RESPECTED it (r ≤ cap).
#                 Caught out beyond it (r > cap) he covers only cap/r of the
#                 lateral gap — the chord he must cover is r·sinθ against a
#                 window that buys cap·sinθ — so the arrival falls short of
#                 the line by the overrun and the feed sees a real,
#                 continuously-growing positional miss.
#   unsettled   — the race's TIGHTNESS, radius/cap exactly (cap = coverable
#                 / sinθ, so r·sinθ/coverable collapses to r/cap): riding
#                 the cap edge he arrives at the buzzer, parked deep he
#                 arrives set.
#   hands       — predicted_goalie_hands sunk by that tightness: an
#                 at-the-buzzer keeper crosses the line mid-push with his
#                 hands at the slide height, so the band above the pads
#                 stays honestly open — the "merely strong" outcome. The
#                 sunk hands are load-bearing: without them score_shoot
#                 prices the on-line keeper as a SET wall and erases
#                 proven-reachable feeds to zero.
# Fill via resolve_feed_keeper (one call, static outputs — the scratch
# pattern; single-threaded AI tick), consumed by the feed evaluators.
static var feed_keeper_pos: Vector3 = Vector3.INF
static var feed_keeper_unsettled: float = 0.0
static var feed_keeper_hands: Vector4 = Vector4.INF

# Planning-side mirror of the live goalie's backdoor tuning (GoalieController
# exports at league defaults; values cited from the controller).
static var _backdoor_cfg_planning: GoalieBehaviorRules.BackdoorThreatConfig = \
		_build_planning_backdoor_cfg()


static func _build_planning_backdoor_cfg() -> GoalieBehaviorRules.BackdoorThreatConfig:
	var cfg := GoalieBehaviorRules.BackdoorThreatConfig.new()
	cfg.pass_speed = GameRules.DEFAULT_QUICK_PASS_POWER_M_S
	cfg.release_time = 0.15         # backdoor_release_time export default
	cfg.react_delay = 0.12          # cross_crease_react_delay export default
	cfg.goalie_lateral_speed = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S
	cfg.goalie_lateral_accel = GameRules.DEFAULT_GOALIE_LATERAL_ACCEL_M_S2
	cfg.max_shooter_distance = 9.0  # backdoor_max_shooter_distance export default
	return cfg


# Minimum radius the pre-arm can pull the planning keeper to — the live
# caller floors an unwinnable race at its defensive crease depth.
const _BACKDOOR_PLANNING_FLOOR_M: float = 0.8


# Resolves the pre-armed feed keeper into the feed_keeper_* statics.
# Returns true when the backdoor cap BOUND (the pre-armed triple is live);
# false leaves the caller on the ordinary predict_goalie_pos path (no live
# one-timer geometry — receiver behind the line, out of range, or on the
# carrier's own shot line).
static func resolve_feed_keeper(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		release_time_s: float,
		receiver_pos: Vector3,
		carrier_pos: Vector3,
		pose_hands: Vector4 = Vector4.INF,
		pass_speed_m_s: float = -1.0,
		defender_positions: Array[Vector3] = []) -> bool:
	var dir_sign: int = int(-signf(attacking_goal.z))
	# The cap must be priced at the feed actually being scored: the callers
	# fire expected_pass_speed (charged for long cross-seam feeds), and a
	# quick-pass-priced cap hands the planning keeper ~35% more window than
	# the real puck gives him. Default keeps the league quick-pass read for
	# callers with no speed in scope.
	_backdoor_cfg_planning.pass_speed = pass_speed_m_s \
			if pass_speed_m_s > 0.0 else GameRules.DEFAULT_QUICK_PASS_POWER_M_S
	# AI MIRROR: the live keeper discounts a weak-side man his own defence is
	# standing on (backdoor_depth_cap), so the planning keeper has to see the same
	# coverage or the bots feed against a goalie parked metres deeper than the one
	# they actually face. `defender_positions` is whoever wears the modelled
	# goalie's colours — the opposing D when scoring a feed at THEIR net, our own
	# when weighing a threat at ours. Empty (nobody in scope) restores the
	# uncovered read exactly.
	var d_nearest_sq: float = INF
	for d in defender_positions:
		var ddx: float = d.x - receiver_pos.x
		var ddz: float = d.z - receiver_pos.z
		var d_sq: float = ddx * ddx + ddz * ddz
		if d_sq < d_nearest_sq:
			d_nearest_sq = d_sq
	var d_arrival: float = INF
	if not is_inf(d_nearest_sq):
		d_arrival = GoalieBehaviorRules.defender_arrival_time(
				sqrt(d_nearest_sq), GameRules.DEFAULT_STICK_LENGTH_M,
				GameRules.DEFAULT_SKATER_MAX_SPEED_M_S,
				GameRules.DEFAULT_SKATER_THRUST_M_S2)
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			carrier_pos, carrier_pos, receiver_pos,
			attacking_goal.z, attacking_goal.x, dir_sign, d_arrival,
			_backdoor_cfg_planning)
	if cap >= INF:
		feed_keeper_pos = predict_goalie_pos(
				goalie_now, attacking_goal, release_time_s, receiver_pos)
		feed_keeper_unsettled = goalie_unsettled(
				goalie_now, attacking_goal, release_time_s, receiver_pos)
		feed_keeper_hands = pose_hands
		return false
	var cap_floored: float = maxf(cap, _BACKDOOR_PLANNING_FLOOR_M)
	var gx: float = goalie_now.x - attacking_goal.x
	var gz: float = goalie_now.z - attacking_goal.z
	var radius: float = sqrt(gx * gx + gz * gz)
	var start: Vector3 = goalie_now
	if radius > cap_floored and radius > 0.001:
		var s: float = cap_floored / radius
		start = Vector3(attacking_goal.x + gx * s, goalie_now.y,
				attacking_goal.z + gz * s)
	var tightness: float = clampf(
			minf(radius, cap_floored) / maxf(cap, 0.001), 0.0, 1.0)
	# The cap's line-arrival guarantee holds only for a keeper who RESPECTED
	# it: the chord he must cover to re-square is r·sinθ and the feed window
	# buys cap·sinθ, so a keeper caught out at r > cap covers only cap/r of
	# the lateral gap — his arrival falls short of the receiver's line by the
	# overrun. An over-challenged keeper honestly bleeds a positional miss
	# that grows with how far past his doctrine he was caught (continuous at
	# r = cap, where progress hits 1 and the guarantee resumes).
	var progress: float = 1.0
	if radius > cap_floored:
		progress = cap_floored / radius
	var matched_x: float = goalie_arc_match_x(start, attacking_goal, receiver_pos)
	feed_keeper_pos = Vector3(
			lerpf(start.x, matched_x, progress), start.y, start.z)
	feed_keeper_unsettled = tightness
	# No replicated pose in scope → the league READY stance
	# (GoalieBodyConfigBuilder's hands) stands in, so the sunk-hands read —
	# the piece that keeps a buzzer-arrival from pricing as a set wall —
	# exists for every caller.
	var hands: Vector4 = pose_hands if pose_hands.is_finite() \
			else Vector4(-0.42, 0.90, 0.44, 0.86)
	feed_keeper_hands = predicted_goalie_hands(hands, tightness)
	return true


static func predict_goalie_pos(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		release_time_s: float,
		puck_pos_at_release: Vector3,
		closing_speed_m_s: float = 0.0) -> Vector3:
	# DEPTH first (see the planning-depth doc): the chart / rush-backflow depth
	# he skates to over the same budget. The arc match is then solved AT that
	# depth, so position, arc-x and the unsettle read all agree about where he
	# is standing.
	var based: Vector3 = _at_depth(goalie_now, attacking_goal, planned_goalie_depth(
			goalie_now, attacking_goal, puck_pos_at_release,
			release_time_s, closing_speed_m_s))
	var target_x: float = goalie_arc_match_x(based, attacking_goal, puck_pos_at_release)
	var move_time: float = maxf(0.0, release_time_s - goalie_leg_delay_s)
	var max_move: float = goalie_lateral_reach(move_time)
	var dx: float = target_x - based.x
	var dist_to_target: float = absf(dx)
	if dist_to_target < 0.001 or max_move <= 0.0:
		return based
	if dist_to_target <= max_move:
		return Vector3(target_x, based.y, based.z)
	return Vector3(based.x + signf(dx) * max_move, based.y, based.z)


# PREDICTED hands for a keeper in motion — the pose accompaniment to
# predict_goalie_pos: a pushing/recovering goalie's hands ride at
# the SLIDING pose height (glove y 0.55, GoalieBodyConfigBuilder's slide —
# arms tucked for the push, not presented in the band), so a keeper
# predicted to be moving at release is scored against hands that genuinely
# trail low — the unsettled body's partial silhouette, measured instead of
# declared. Laterals are kept (the hands travel with the body); heights
# sink toward the slide pose by the unsettled fraction. INF passes through.
const SLIDING_HANDS_Y_M: float = 0.55


static func predicted_goalie_hands(current: Vector4, unsettled: float) -> Vector4:
	if not current.is_finite():
		return current
	var u: float = clampf(unsettled, 0.0, 1.0)
	return Vector4(current.x, lerpf(current.y, SLIDING_HANDS_Y_M, u),
			current.z, lerpf(current.w, SLIDING_HANDS_Y_M, u))


# Companion to predict_goalie_pos: how UNSETTLED [0, 1] the goalie is AT release.
#   0 = set and square (already at its arc-match target, no forced motion)
#   1 = still sliding (positionally behind) or only just arrived — reading late
# Same react-then-push kinematics as predict_goalie_pos (accel ramp included),
# so the predicted position and this motion estimate agree. score_shoot cuts the goalie's
# glove/blocker reaction by this fraction (a recovering goalie reads the shot
# late). A fast cross-seam one-timer leaves the goalie mid-slide → near 1; a
# static shot at a set goalie → 0.
static func goalie_unsettled(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		release_time_s: float,
		puck_pos_at_release: Vector3,
		closing_speed_m_s: float = 0.0) -> float:
	# Same depth the position prediction lands on — the arc-x he is chasing is
	# solved from where he will be standing, not where he stands now.
	var based: Vector3 = _at_depth(goalie_now, attacking_goal, planned_goalie_depth(
			goalie_now, attacking_goal, puck_pos_at_release,
			release_time_s, closing_speed_m_s))
	var target_x: float = goalie_arc_match_x(based, attacking_goal, puck_pos_at_release)
	var need: float = absf(target_x - goalie_now.x)
	if need < 0.001:
		return 0.0  # already squared — no forced motion, fully set
	var move_time: float = maxf(0.0, release_time_s - goalie_leg_delay_s)
	var max_move: float = goalie_lateral_reach(move_time)
	if need >= max_move:
		return 1.0  # still sliding at release (or hasn't even reacted) — caught moving
	# Reached the target with time to spare; ramps back to 0 as it re-sets.
	var slide_time: float = _goalie_lateral_time(need)
	var settled_for: float = move_time - slide_time
	return clampf(1.0 - settled_for / GOALIE_SETTLE_REF_S, 0.0, 1.0)


# Returns PASS score in [0, 1] for a specific receiver. Multiplicative:
#   - pass_lane:             1.0 if no opponent in the shooter→receiver line
#   - score_shoot(receiver): receiver's value as a shooter from where
#                            they are (geometry × shot lane × pressure).
#
# No receiver-quality terms (open-man, advancement): at top level the
# carrier evaluates each teammate via a recursive score_at(receiver)
# that captures "they could shoot or drive to slot". This leaf is what
# score_at falls back to for the shoot branch from a receiver position;
# it does not recurse further (no leaf-pass at depth 2), so the bot
# cannot get into infinite pass-back-and-forth evaluation loops.
static func score_pass(
		shooter: Vector3,
		receiver: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3],
		pass_speed_m_s: float = PASS_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0,
		precomputed_lane: float = -1.0,
		goalie_hands: Vector4 = Vector4.INF,
		goalie_pads: Vector4 = Vector4.INF,
		opponent_caps: Array = EMPTY_CAPS) -> float:
	if _is_past_goal_line(receiver, attacking_goal):
		return 0.0
	if pass_lane_blocked_by_net(shooter, receiver):
		return 0.0
	# Lane-clear's reaction window scales with puck flight time, so
	# passing the actual fire speed matters: a charged pass at ~19 m/s
	# gives defenders 36% less reaction time than the quick-shot
	# default. Caller picks via expected_pass_speed(shooter, receiver)
	# when the distance gate is appropriate. `precomputed_lane` (>= 0)
	# lets a caller that already ran the identical lane_clear (see
	# threat_surface_pass) hand it in instead of paying for it twice.
	# `opponent_caps` (index-matched to `opponents`) prices each lane
	# defender's real stick reach and closing pace; empty = league.
	var lane: float = precomputed_lane if precomputed_lane >= 0.0 \
			else lane_clear(shooter, receiver, opponents, pass_speed_m_s,
					EMPTY_VEC3, opponent_caps)
	if lane <= 0.0:
		return 0.0
	# Receiver's value as a shooter from where they are. Caller is
	# responsible for predicting the goalie at the receiver's release
	# time (flight + receiver wrister charge) — see predict_goalie_pos.
	# goalie_unsettled_factor lets the caller credit a feed that catches the
	# goalie mid-slide (a cross-seam one-timer to an off-axis receiver) — the
	# off-puck staging roles pass it so they prize the back-door spot. Default
	# 0.0 keeps the position-only behaviour for callers that don't (SUPPORT).
	# Receiver shot speed stays the league default (cross-player; no teammate caps).
	# Predicted post-seal for the receiver's spot (derive_post_seal_x_sign): a feed
	# to a sharp near-goal-line angle faces the RVH/VH wall a competent keeper
	# adopts, so this leaf reads the same sealed coverage the carrier's own
	# _score_at does — no phantom dead-angle receiver value, whether score_pass is
	# a defensive threat read or an offensive developing-feed one.
	var seal_x: float = derive_post_seal_x_sign(receiver, attacking_goal)
	var receiver_shot: float = score_shoot(
			receiver, attacking_goal, predicted_goalie_pos, net_half_width, opponents,
			WRISTER_SHOT_SPEED_M_S, goalie_unsettled_factor, opponent_caps, -1.0, false,
			seal_x, seal_x != 0.0, 0.0, EMPTY_VEC3, goalie_hands, goalie_pads)
	return lane * receiver_shot


# ── Helpers ──────────────────────────────────────────────────────────────────


# True if `pos` is past the attacking goal line in the direction the
# attacking team is going (i.e. "behind the net" relative to the
# shooter). For Team 0 attacking -Z (attacking_goal.z = -26.65),
# "past" means z < -26.65; for Team 1 attacking +Z, z > +26.65.
static func _is_past_goal_line(pos: Vector3, attacking_goal: Vector3) -> bool:
	return (pos.z - attacking_goal.z) * signf(attacking_goal.z) > 0.0


# ── Release contest: the pressure read, as a physical race ────────────────────
# P(the release completes clean) in [0, 1] against every nearby opponent —
# the factor score_shoot and position_potential multiply by. Pressure here is a
# physical contest, never a density curve: to disrupt the action, an opponent's
# BLADE must reach the RELEASE POINT — the puck held a carry-handle ahead of the
# body toward the target — while the puck is still on the blade.
#
# Per opponent, the lane model's own vocabulary (same reach convention,
# read delay, and lateral close pace as _lane_block_at, so the two contest
# reads agree on what a defender's stick can do):
#
#   reach_i  = stick_i + close_speed_i × max(0, T_window − read delay)
#              — his stick, plus what he closes after a competitive read,
#              over the real windup window
#   block_i  = clamp((reach_i − d_i) / stick_i, 0, 1)
#              — one full stick inside reach ⇒ certain blade-on-puck
#   p_i      = block_i × (T_window − read delay)⁺ / T_window
#              — a blade can only disrupt the fraction of the release
#              that remains after its read: arriving as the puck leaves
#              does nothing, arriving at the start of the windup kills it
#
#   clean    = Π (1 − p_i)      — independent contests compose as a
#              product; no count normalizer, no saturation constant
#
# T_window is the bot's real decision→puck-away time
# (SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S — pre-aim + charge, the
# same span score_shoot already projects the goalie across). Directionality
# is emergent geometry: the release point sits a carry-handle toward the
# target, so a man behind the shooter is a couple of metres farther from
# the puck than one at the release — no cosine shaping. Even a blade
# planted on the release point leaves the clean floor at
# read_delay / T_window per opponent — contested shots still get off
# sometimes, which is what lets a bot shoot through traffic when the
# window is worth it.
static func release_contest_clean(release_pt: Vector3,
		opponents: Array[Vector3], opponent_caps: Array = []) -> float:
	var t_window: float = SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var contest_frac: float = maxf(0.0, t_window - LANE_REACTION_DELAY_S) \
			/ t_window
	var has_caps: bool = opponent_caps.size() == opponents.size()
	var clean: float = 1.0
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var stick_reach: float = LANE_DEFENDER_REACH_M
		var close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S
		if has_caps:
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				stick_reach = caps.stick_reach
				close_speed = LANE_LATERAL_FRACTION * caps.max_speed
		var reach: float = stick_reach \
				+ close_speed * maxf(0.0, t_window - LANE_REACTION_DELAY_S)
		var dx: float = p.x - release_pt.x
		var dz: float = p.z - release_pt.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq >= reach * reach:
			continue
		var block: float = clampf(
				(reach - sqrt(d_sq)) / maxf(stick_reach, 0.001), 0.0, 1.0)
		clean *= 1.0 - block * contest_frac
	return clean


# The release point the contest is raced to: the puck on the blade, one
# carry-handle ahead of the body toward the target (the same handle
# distance the evasion model uses for a carried puck). Falls back to the
# body itself when the target direction is degenerate.
static func release_point_toward(shooter: Vector3, target: Vector3) -> Vector3:
	var dx: float = target.x - shooter.x
	var dz: float = target.z - shooter.z
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.0001:
		return shooter
	var inv: float = EVADE_CARRY_HANDLE_M / sqrt(len_sq)
	return Vector3(shooter.x + dx * inv, 0.0, shooter.z + dz * inv)


# Unclamped closest-approach time τ* that minimises the distance between
# the fired puck and a dead-reckoned defender. `pvx/pvz` are the puck's
# velocity components (dir × speed); `vx/vz` the defender's. May be < 0
# (closest approach already behind us — defender drifting off) or
# > seg_time (closest approach only AFTER the puck reaches the receiver —
# the defender is trailing the play and never intercepts it in flight).
# Callers clamp the low end to 0 and skip the high end. Pure float math
# (no allocation) — safe per defender on the lane hot path.
static func _lane_closest_approach_t(
		fx: float, fz: float, pvx: float, pvz: float,
		px: float, pz: float, vx: float, vz: float) -> float:
	# W(τ) = (from − D) + (puck_vel − defender_vel)·τ ; minimise |W(τ)|.
	var w0x: float = fx - px
	var w0z: float = fz - pz
	var wdx: float = pvx - vx
	var wdz: float = pvz - vz
	var wd_sq: float = wdx * wdx + wdz * wdz
	if wd_sq < 0.0001:
		return 0.0  # no relative motion — closest approach is now
	return -(w0x * wdx + w0z * wdz) / wd_sq


# Miss distance: how far the puck passes from the dead-reckoned defender
# at approach time `t`. Pure float math — shared by the flat-pass and
# saucer (body-only) block calculations so the two agree on the geometry.
static func _lane_miss_at(
		fx: float, fz: float, pvx: float, pvz: float, t: float,
		px: float, pz: float, vx: float, vz: float) -> float:
	var wx: float = (fx - px) + (pvx - vx) * t
	var wz: float = (fz - pz) + (pvz - vz) * t
	return sqrt(wx * wx + wz * wz)


# Flat per-defender block strength [0, 1] at a given approach time `t`:
# reach = stick + closing they can do after the reaction delay; block is
# how far the lane penetrates that reach, normalised by a stick length
# (one full stick inside reach ⇒ certain block). Pure float math.
static func _lane_block_at(
		fx: float, fz: float, pvx: float, pvz: float, t: float,
		px: float, pz: float, vx: float, vz: float,
		stick_reach: float = LANE_DEFENDER_REACH_M,
		close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S) -> float:
	var miss: float = _lane_miss_at(fx, fz, pvx, pvz, t, px, pz, vx, vz)
	# reach = this defender's stick + how far it slides into the lane after
	# its read delay (Speed × the ~0.5 lateral factor); normalised by its own stick
	# so "one full stick inside reach ⇒ certain block" scales with the defender.
	var reach: float = stick_reach + close_speed * maxf(0.0, t - LANE_REACTION_DELAY_S)
	return clampf((reach - miss) / stick_reach, 0.0, 1.0)


# Brake-and-clog reachability block [0, 1] for one defender: the best lane point
# he can skate to and STOP on before the puck crosses it. The ballistic closest-
# approach term (_lane_block_at) lets a fast defender COAST straight through the
# lane and out the far side — past ~10 m/s of perpendicular closing he reads as
# clear, because the dead-reckon never lets him brake. But a real defender about
# to overshoot a lane he's trying to defend plants and occupies it. This asks the
# guided-interceptor question instead: given his read delay and lateral pace, can
# he reach the crossing point in time and stay? He can, so this only ever ADDS
# block — it floors the coasting term's overshoot tail without weakening any lane
# the coasting model already blocks (lane_clear takes the max of the two).
#
# Closed form: maximise block(u) = (stick + close·(u/speed − reaction) − |X(u)−D|)
# over the lane arc-coord u, where X(u) is the point u metres along the lane and
# the puck reaches it at u/speed. With a = the defender's along-lane coord and
# b = his perpendicular distance, |X(u)−D| = √((u−a)²+b²); setting d/du = 0 gives
# the interior optimum (u−a) = k·b/√(1−k²), k = close/speed. Evaluated there and
# at the perpendicular foot (u = a, robust to the reaction-delay kink), best wins.
# Pure float math, allocation-free.
static func _lane_brake_block(
		fx: float, fz: float, dirx: float, dirz: float, seg_len: float,
		speed: float, px: float, pz: float,
		stick_reach: float, close_speed: float) -> float:
	var rx: float = px - fx
	var rz: float = pz - fz
	var a: float = rx * dirx + rz * dirz             # along-lane coord of the defender
	var perp_x: float = rx - a * dirx
	var perp_z: float = rz - a * dirz
	var b: float = sqrt(perp_x * perp_x + perp_z * perp_z)   # perpendicular distance
	var k: float = close_speed / speed
	var u_opt: float = seg_len if k >= 1.0 else a + k * b / sqrt(1.0 - k * k)
	var blk_opt: float = _brake_block_at(
			clampf(u_opt, 0.0, seg_len), a, b, speed, stick_reach, close_speed)
	var blk_foot: float = _brake_block_at(
			clampf(a, 0.0, seg_len), a, b, speed, stick_reach, close_speed)
	return maxf(blk_opt, blk_foot)


# Block strength if the defender aims to occupy lane arc-coord `u` — reach at the
# puck's arrival time there, minus the distance he must cover to it. Shared by the
# two candidate points _lane_brake_block evaluates.
static func _brake_block_at(u: float, a: float, b: float, speed: float,
		stick_reach: float, close_speed: float) -> float:
	var t_x: float = u / speed
	var reach: float = stick_reach + close_speed * maxf(0.0, t_x - LANE_REACTION_DELAY_S)
	var du: float = u - a
	var gap: float = sqrt(du * du + b * b)
	return clampf((reach - gap) / stick_reach, 0.0, 1.0)


# Time for a puck launched at `v0` to slide `dist` against ice friction (Coulomb
# decel PUCK_ICE_DECEL_M_S2): dist = v0·T − ½·a·T² → the first (arrival) root
# T = (v0 − √(v0²−2·a·dist))/a. Friction is small (~0.5 m/s²), so this is a
# few-percent correction to dist/v0 even on a long pass — it just makes the puck
# honestly slower on average than its launch speed, giving lane defenders slightly
# more time on the far (receiver) end. Frictionless fallback if the puck would
# stop before arriving (can't happen for a real pass_launch_speed-solved feed, but
# guards the sqrt).
static func _friction_traverse_time(dist: float, v0: float) -> float:
	var a: float = GameRules.PUCK_ICE_DECEL_M_S2
	if a <= 0.0:
		return dist / v0
	var disc: float = v0 * v0 - 2.0 * a * dist
	if disc <= 0.0:
		return dist / v0
	return (v0 - sqrt(disc)) / a


# Lane-clear factor in [0, 1] for a FIRED puck (shot or pass) — the
# closest-approach reachability model (see the doc-block above the lane
# constants). Public because the carrier's pass scoring uses it directly:
# a pass is a fired puck, so it gets this model rather than the geometric
# carry-path `path_clearance`.
#
# `puck_speed_m_s` is the actual speed the puck travels the segment —
# shots ~30 m/s, passes ~14–20 m/s. Faster pucks leave defenders less
# time to close, so they contribute less (falls out of the geometry).
#
# `opponent_vels` is an OPTIONAL parallel array of defender velocities
# (index-matched to `opponents`). When empty (or shorter), the missing
# defenders are read as stationary — every position-only caller keeps
# working; the carrier's pass scoring passes real velocities so a
# defender bearing down on the lane is priced as the threat they are.
#
# ── `accurate`: the physically-honest fired-pass lane model ───────────────────
# Off by default, so every existing caller — the fast SHOT lane, the off-puck /
# threat score_pass — keeps the legacy `1 − max(block)` single-blocker, constant-
# speed, ballistic model and its tuned tests. The carrier's own pass EV opts in.
# When on, three refinements compose (each documented at its site):
#   1. Guided interceptor (_lane_brake_block, max'd per defender) — a defender who
#      would ballistically COAST through the lane brakes and clogs it instead,
#      fixing the overshoot where a fast crosser read as clear.
#   2. Independent-defender SURVIVAL (product, not max) — the puck must beat EVERY
#      defender who threatens the lane, so two on different segments compound
#      (max only ever priced the single worst, so a long lane through traffic read
#      as open as its easiest gap). Product treats them as independent; two
#      genuinely stacked on one spot are mildly over-counted, which errs
#      conservative (a real sandwich IS dangerous).
#   3. Friction timing — the puck's real (decelerating) traversal, so the far end
#      of a long lane gives defenders the extra time they really get.
static func lane_clear(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float, opponent_vels: Array[Vector3] = [],
		opponent_caps: Array = [], accurate: bool = false) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0  # degenerate (overlapping endpoints)
	var line_len: float = sqrt(line_len_sq)
	var speed: float = maxf(puck_speed_m_s, 1.0)
	# Friction-aware average speed over the real traversal (accurate only).
	var eff_speed: float = speed
	if accurate:
		eff_speed = line_len / _friction_traverse_time(line_len, speed)
	var seg_time: float = line_len / eff_speed
	var inv_len: float = 1.0 / line_len
	var pvx: float = dx * inv_len * eff_speed
	var pvz: float = dz * inv_len * eff_speed
	var dirx: float = dx * inv_len
	var dirz: float = dz * inv_len
	var vel_count: int = opponent_vels.size()
	var has_caps: bool = opponent_caps.size() == opponents.size()
	var max_block: float = 0.0
	var survival: float = 1.0   # accurate: independent-defender survival product
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var vx: float = 0.0
		var vz: float = 0.0
		if i < vel_count:
			vx = opponent_vels[i].x
			vz = opponent_vels[i].z
		# This defender's real stick reach and lateral close speed.
		var stick_reach: float = LANE_DEFENDER_REACH_M
		var close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S
		if has_caps:
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				stick_reach = caps.stick_reach
				close_speed = LANE_LATERAL_FRACTION * caps.max_speed
		# Ballistic (coasting) block — 0 for a defender whose closest approach is
		# only AFTER the puck reaches the receiver (trailing the play).
		var block: float = 0.0
		var t_raw: float = _lane_closest_approach_t(
				from.x, from.z, pvx, pvz, p.x, p.z, vx, vz)
		if t_raw <= seg_time:
			block = _lane_block_at(from.x, from.z, pvx, pvz, maxf(t_raw, 0.0),
					p.x, p.z, vx, vz, stick_reach, close_speed)
		if not accurate:
			if block > max_block:
				max_block = block
				if max_block >= 1.0:
					break
			continue
		# Guided-interceptor floor: he can brake and clog a reachable crossing
		# instead of coasting through it (only ADDS block; see _lane_brake_block).
		var brake_block: float = _lane_brake_block(
				from.x, from.z, dirx, dirz, line_len, eff_speed,
				p.x, p.z, stick_reach, close_speed)
		if brake_block > block:
			block = brake_block
		# Survival: the puck must beat this defender too.
		survival *= 1.0 - block
		if survival <= 0.0:
			break
	if accurate:
		return clampf(survival, 0.0, 1.0)
	return clampf(1.0 - max_block, 0.0, 1.0)


# Lane-clear for a SAUCER (LOW-loft) pass fired at `puck_speed_m_s`. Same
# closest-approach model as lane_clear, except while the puck is above the
# blade plane — the kinematic over window [t_over, t_down] of the LOW
# loft's fixed vertical launch (see the saucer doc-block) — a defender's
# reach collapses to their BODY radius: sticks fly under it, only a body
# in the lane stops it (LANE_DEFENDER_BODY_RADIUS_M). Before the window
# (puck still rising off the blade) and after it (landed) a stick
# intercepts with full grounded reach + closing, per-defender caps
# included — so a stick already on the puck at release still stuffs the
# flip, and a defender past the touch-down point plays it like any flat
# pass. Because the window is TIME-fixed, a softer launch shortens the
# airborne carry — the close-quarters soft flip falls out of the same
# geometry.
static func lane_clear_saucer(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float, opponent_vels: Array[Vector3] = [],
		opponent_caps: Array = []) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0  # degenerate (overlapping endpoints)
	var line_len: float = sqrt(line_len_sq)
	var speed: float = maxf(puck_speed_m_s, 1.0)
	var seg_time: float = line_len / speed
	var inv_len: float = 1.0 / line_len
	var pvx: float = dx * inv_len * speed
	var pvz: float = dz * inv_len * speed
	var vel_count: int = opponent_vels.size()
	var has_caps: bool = opponent_caps.size() == opponents.size()
	# Over window: y(t) = vy·t − ½·g·t² above the blade plane between the
	# two roots. vy (2.2) comfortably clears the ~5 cm plane, so the
	# discriminant is always positive; the maxf is belt-and-suspenders.
	var vy: float = GameRules.DEFAULT_LOFT_VY_LOW_M_S
	var root: float = sqrt(maxf(0.0,
			vy * vy - 2.0 * GRAVITY_M_S2 * GameRules.PUCK_AIRBORNE_HEIGHT_M))
	var t_over: float = (vy - root) / GRAVITY_M_S2
	var t_down: float = (vy + root) / GRAVITY_M_S2
	var max_block: float = 0.0
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var vx: float = 0.0
		var vz: float = 0.0
		if i < vel_count:
			vx = opponent_vels[i].x
			vz = opponent_vels[i].z
		var t_raw: float = _lane_closest_approach_t(
				from.x, from.z, pvx, pvz, p.x, p.z, vx, vz)
		if t_raw > seg_time:
			continue  # trailing the play — never closest in flight
		var t: float = maxf(t_raw, 0.0)
		var block: float
		if t >= t_over and t <= t_down:
			# Puck is above the blade plane — flies over a grounded stick,
			# so only the defender's body can block it: reach = body
			# radius, no stick, no closing.
			var miss: float = _lane_miss_at(
					from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz)
			block = clampf(
					(LANE_DEFENDER_BODY_RADIUS_M - miss) / LANE_DEFENDER_BODY_RADIUS_M,
					0.0, 1.0)
		else:
			# On/near the ice (rising off the blade, or landed) — full
			# stick reach + closing, at this defender's real caps.
			var stick_reach: float = LANE_DEFENDER_REACH_M
			var close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S
			if has_caps:
				var caps: AISkaterCaps = opponent_caps[i]
				if caps != null:
					stick_reach = caps.stick_reach
					close_speed = LANE_LATERAL_FRACTION * caps.max_speed
			block = _lane_block_at(
					from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz, stick_reach, close_speed)
		if block > max_block:
			max_block = block
	return clampf(1.0 - max_block, 0.0, 1.0)


# Interceptor point for a fired-puck lane: where on the puck's path the
# strongest-blocking defender reaches it (their closest-approach point) —
# the spot the puck is most likely to be picked off. Returns Vector3.INF
# when no defender blocks the lane (i.e. lane_clear would return 1.0).
#
# This is the loss location for the carrier's pass turnover-cost term
# (turnover_cost): "if this pass is intercepted, the opponent gains the
# puck HERE." Shares the per-defender block helpers with lane_clear, so
# the two agree on which defender is worst by construction.
static func lane_loss_point(from: Vector3, to: Vector3,
		opponents: Array[Vector3], puck_speed_m_s: float,
		opponent_vels: Array[Vector3] = [],
		opponent_caps: Array = []) -> Vector3:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return Vector3.INF
	var line_len: float = sqrt(line_len_sq)
	var speed: float = maxf(puck_speed_m_s, 1.0)
	var seg_time: float = line_len / speed
	var inv_len: float = 1.0 / line_len
	var pvx: float = dx * inv_len * speed
	var pvz: float = dz * inv_len * speed
	var vel_count: int = opponent_vels.size()
	var has_caps: bool = opponent_caps.size() == opponents.size()
	var max_block: float = 0.0
	var best_point: Vector3 = Vector3.INF
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var vx: float = 0.0
		var vz: float = 0.0
		if i < vel_count:
			vx = opponent_vels[i].x
			vz = opponent_vels[i].z
		var t_raw: float = _lane_closest_approach_t(
				from.x, from.z, pvx, pvz, p.x, p.z, vx, vz)
		if t_raw > seg_time:
			continue  # trailing the play — never closest in flight
		var t: float = maxf(t_raw, 0.0)
		# Same per-defender build resolution as lane_clear, so the two keep
		# agreeing on which defender is worst when the caller threads caps.
		var stick_reach: float = LANE_DEFENDER_REACH_M
		var close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S
		if has_caps:
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				stick_reach = caps.stick_reach
				close_speed = LANE_LATERAL_FRACTION * caps.max_speed
		var block: float = _lane_block_at(
				from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz,
				stick_reach, close_speed)
		if block > max_block:
			max_block = block
			# Puck position at the defender's closest approach = the pick spot.
			best_point = Vector3(from.x + pvx * t, 0.0, from.z + pvz * t)
	return best_point


# True when `pos` is on the attacking side of the attacking blue line — the
# offensive zone, and the value-map regime boundary: `_score_at` prices in-zone
# positions by shot danger and out-of-zone positions by position_potential, and
# a carrier already in the zone won't carry or pass back out of it. Sign-folded
# so it works for either attacking direction.
# `buffer` demands the position sit that much DEEPER than the line — the
# carrier's blue-line keep-out bands (retreat / reception) use it so "in the
# zone" can mean "in the zone with margin for the stick's reach".
static func in_offensive_zone(pos: Vector3, attacking_goal: Vector3,
		buffer: float = 0.0) -> bool:
	return pos.z * signf(attacking_goal.z) > GameRules.BLUE_LINE_Z + buffer


# Position potential in [0, 1] — the value of being at this position with no
# specific shot or pass in view, as closeness × the goal mouth's projected width
# from this bearing × openness (each derived below). `_score_at` reads it only
# while the CARRIER is outside the offensive zone; in the zone the bot prices
# real shot danger instead. Behind the attacking goal line it returns 0.
static func position_potential(
		pos: Vector3,
		attacking_goal: Vector3,
		opponents: Array[Vector3],
		opponent_caps: Array = EMPTY_CAPS) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (pos.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0
	var dist: float = pos.distance_to(attacking_goal)
	# Closeness: 0 at goal, 1 at slot, 0 at goal-to-goal distance.
	# Far-norm derived from rink geometry — the gradient covers the
	# whole rink so deep-zone positions still have a forward-progress
	# signal.
	var rink_length: float = absf(GameRules.GOAL_LINE_Z) * 2.0
	var closeness: float
	if dist <= SLOT_RADIUS_M:
		closeness = clampf(dist / SLOT_RADIUS_M, 0.0, 1.0)
	else:
		closeness = clampf(
				1.0 - (dist - SLOT_RADIUS_M) / (rink_length - SLOT_RADIUS_M),
				0.0, 1.0)
	# Angle quality = the goal mouth's PROJECTED width from this bearing. A goal
	# viewed off its face-normal presents cos(θ) of its width (a door seen at an
	# angle), and cos(θ) = forward / horizontal_distance — the real foreshortening,
	# not a hand-picked taper. 1 head-on, → 0 along the goal line. Same projection
	# geometry the hole-based shot model reasons in.
	var lateral: float = pos.x - attacking_goal.x
	var horiz_dist: float = sqrt(forward * forward + lateral * lateral)
	var angle_factor: float = forward / horiz_dist
	# Openness: could a carrier get his action off from this spot — the same
	# release-contest read score_shoot uses, raced to the puck a carry-handle
	# ahead of the body toward the net.
	var openness: float = release_contest_clean(
			release_point_toward(pos, attacking_goal), opponents, opponent_caps)
	return closeness * angle_factor * openness


# Realization discount for position_potential when it prices a CARRY /
# receiver destination in the carrier's expected-value compete: potential
# is FUTURE value — its promise (a real shot) is only cashed by skating
# from `pos` to the slot — so it must pay the same delay_discount that
# every other future action in the model pays, over that remaining travel time.
#
# Without this, the carrier's stand-still candidate held its potential
# UNDECAYED while every movement candidate paid decay over its travel
# time; outside shooting range the potential gradient (~3%/m) is
# shallower than that decay (~4%/m at rest), so standing still strictly
# beat stepping toward the net and an open carrier PLANTED at the blue
# line ("hesitant to take space that's clearly theirs"). With the
# discount, an on-route step trades travel decay for realization decay
# one-for-one (triangle equality), the decays cancel, and the compete
# reduces to the pure positional gradient — open ice ahead always wins.
#
# Travel time is measured to the slot platform edge (SLOT_RADIUS_M — the
# ring where potential's promise becomes a real shot) at the league
# reference speed (cross-player boundary: receivers use it too).
static func potential_realization_discount(pos: Vector3,
		attacking_goal: Vector3) -> float:
	var travel_dist: float = maxf(0.0, pos.distance_to(attacking_goal) - SLOT_RADIUS_M)
	return delay_discount(travel_dist / SKATER_REF_SPEED_M_S)


# ── Dumping ───────────────────────────────────────────────────────────────────
# Dumping is a deliberate LAST-RESORT giveaway at a SAFE location, in two spots:
#   - DZ clear: pinned in our own end with no play, rim it out to the neutral zone.
#   - NZ dump-and-chase: past centre (so it isn't icing) but contained before the
#     blue line with no outlet, flip it into the offensive corner and race for it.
# It never needs an "if no options" gate — its EV rides the same turnover_cost the
# rest of the model uses (≈0 for a giveaway in the offensive end, large in front of
# our net), so it only wins when every real play (carry/pass/shoot) prices worse
# than conceding at the dump spot. The pieces below are the grounded terms the
# carrier assembles into that EV (see _best_dump).

# Corner depth from the goal line for a dump-in target (a corner retrieval, not a
# behind-the-net wrap).
const DUMP_CORNER_DEPTH_M: float = 3.0
const DUMP_RINK_INSET_M: float = 0.5
# The head-start that turns a 50/50 loose-puck race into a near-sure recovery: a
# stride, expressed as the TIME a stride buys at reference pace, because that is
# the currency the race below is actually run in. The same physical measurement
# the metre form named — a stride is a stride — but a metre band is only a
# contest band at the range a metre means something. Over the 30-40 m a clear
# travels, two metres is a rounding error, so a distance race saturated to 0 or 1
# on essentially every placement and the whole concession became a step function
# of who happened to be standing marginally nearer (#650).
const CHASE_CONTEST_MARGIN_M: float = 2.0
const CHASE_CONTEST_MARGIN_S: float = CHASE_CONTEST_MARGIN_M / SKATER_REF_SPEED_M_S


# True when `pos` is on the attacking side of centre ice (z = 0) — past the red
# line, where a dump-in to the offensive zone can't be icing.
static func past_center_toward_attack(pos: Vector3, attacking_goal: Vector3) -> bool:
	return pos.z * signf(attacking_goal.z) > 0.0


# How far UP-ICE of the carrier the DZ clear aims along the strong-side wall when
# that beats centre ice: one full neutral zone of depth (blue line to blue line).
# An aim DIRECTION, not a settle point — the rim fires toward it and keeps
# running the boards.
const DUMP_CLEAR_AHEAD_M: float = 2.0 * GameRules.BLUE_LINE_Z


# DZ clear target: the strong-side boards (the side the carrier is on), at
# whichever is FARTHER up-ice of centre ice and one neutral zone ahead of the
# carrier. From deep in our end that's the classic centre-ice rim (unchanged);
# for a carrier just inside the blue line the fixed z=0 point degenerated — the
# "clear" banged the wall basically sideways, gaining nothing — so the target
# extends up-ice to keep the clear a genuine forward diagonal from anywhere.
# `up_ice_dir` is the direction OUT of our end (-own_goal_dir). `carrier_vel`
# is the carrier's horizontal velocity — the strong side is read at the puck's
# RELEASE-time lateral position (`_dump_side_sign`), so a carrier crossing centre
# rims up the wall its momentum commits to instead of flipping to the wall behind
# its body on the raw x-sign (the "dump sideways/behind me" artifact).
static func dump_clear_target(carrier_pos: Vector3, up_ice_dir: float,
		carrier_vel: Vector3 = Vector3.ZERO) -> Vector3:
	var side: float = _dump_side_sign(carrier_pos, carrier_vel)
	# Depth measured into OUR half (positive = our side of centre). Centre ice is
	# 0; one NZ ahead of the carrier may land past centre (negative) — take the
	# farther up-ice of the two.
	var own_side_depth: float = -up_ice_dir * carrier_pos.z
	var target_depth: float = minf(0.0, own_side_depth - DUMP_CLEAR_AHEAD_M)
	return Vector3(
			side * (GameRules.RINK_HALF_WIDTH - DUMP_RINK_INSET_M),
			0.0,
			-up_ice_dir * target_depth)


# The strong-side sign used by the dump targets: the sign of the carrier's
# lateral position at PUCK RELEASE (position led by velocity over the release
# lookahead), so the choice of wall/corner is stable through centre ice. A
# carrier drifting across the red line keeps the wall its momentum commits to
# instead of flipping to the opposite board on the raw x-sign — the fix for
# dumps that fired sideways or back across the carrier's body. Falls back to the
# raw position sign (then +1) when the projected lateral is exactly centred.
static func _dump_side_sign(carrier_pos: Vector3, carrier_vel: Vector3) -> float:
	var lateral_at_release: float = carrier_pos.x \
			+ carrier_vel.x * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var side: float = signf(lateral_at_release)
	if side == 0.0:
		side = signf(carrier_pos.x)
	if side == 0.0:
		side = 1.0
	return side


# Dump-in target: the FAR offensive corner (opposite the carrier's side), near the
# goal line — forces the defence to turn and retrieve with their back to the play.
# `carrier_vel` reads the strong side at release time (see `_dump_side_sign`) so
# the far corner doesn't flip cross-ice as the carrier drifts through centre.
static func dump_in_target(carrier_pos: Vector3, attacking_goal: Vector3,
		carrier_vel: Vector3 = Vector3.ZERO) -> Vector3:
	var far_side: float = -_dump_side_sign(carrier_pos, carrier_vel)
	var goal_dir: float = signf(attacking_goal.z)
	return Vector3(
			far_side * (GameRules.RINK_HALF_WIDTH - DUMP_RINK_INSET_M),
			0.0,
			attacking_goal.z - goal_dir * DUMP_CORNER_DEPTH_M)


# Probability our team wins the race to a dumped puck: an ARRIVAL race to the
# dump `target` between our first body there and their first, with a contest band
# around a tie (CHASE_CONTEST_MARGIN_S). 1.0 uncontested, 0.0 if we have no
# chaser. This is what makes a dump-in worth it ONLY when the chase is winnable —
# outnumbered in a 3v3, it self-suppresses.
#
# Momentum-honest, through the same time_to_arrive every other arrival in the
# model uses: nearest by ETA, not by metres. A distance race can only answer
# "who is closer", which is not the question — a body two metres nearer but
# skating the other way loses this race, and over a clear's 30-40 m the ramp is
# worth several metres by itself. `_best_dump` already priced its chase CLOCK
# this way while its recovery PROBABILITY stayed on raw distance; one function,
# two clocks (#650).
#
# `our_vels` / `opp_vels` are index-matched to their position arrays; omit them
# and every chaser races from rest, which is still a real ramp rather than an
# instant full-speed sprint. Everyone runs at the league reference build — the
# same perception simplification counter_rush_cost makes for teammates.
static func chase_recovery(
		target: Vector3,
		our_chasers: Array[Vector3],
		opp_chasers: Array[Vector3],
		our_vels: Array[Vector3] = EMPTY_VEC3,
		opp_vels: Array[Vector3] = EMPTY_VEC3) -> float:
	if our_chasers.is_empty():
		return 0.0
	var our_t: float = _first_arrival(target, our_chasers, our_vels)
	if opp_chasers.is_empty():
		return 1.0
	var opp_t: float = _first_arrival(target, opp_chasers, opp_vels)
	return clampf(0.5 + (opp_t - our_t) / (2.0 * CHASE_CONTEST_MARGIN_S), 0.0, 1.0)


# Soonest any of `chasers` reaches `target`. `vels` is used only when it is
# index-matched to `chasers`, so callers that hold no velocities pass EMPTY_VEC3
# and every body races from rest.
#
# Only bodies that could still win pay for the full arrival solve. time_to_arrive
# caps its ramp at the speed cap and only ever ADDS time for cross momentum, a
# reversal, or a route around the net, so `straight_line_distance / cap` is a hard
# lower bound on any chaser's answer — one already beaten by the best ETA so far
# is out of the race arithmetically, not probably. Exact, and it matters because
# the dump searches call this per candidate spot.
static func _first_arrival(target: Vector3, chasers: Array[Vector3],
		vels: Array[Vector3]) -> float:
	var has_vels: bool = vels.size() == chasers.size()
	var vmax: float = maxf(SKATER_REF_SPEED_M_S, MIN_TRAVEL_SPEED_M_S)
	var best: float = INF
	for i: int in chasers.size():
		if chasers[i].distance_to(target) >= best * vmax:
			continue
		best = minf(best, time_to_arrive(chasers[i], target,
				vels[i] if has_vels else Vector3.ZERO))
	return best


# "Threat surface" — the value an opp can extract from their current
# position from a defender's perspective. score_shoot fades to ~0 as the
# opp gets far from our net (the hole geometry foreshortens); that's fine
# for a carrier choosing whether to release, but useless for a defender
# trying to position relative to a far-but-still-dangerous opp.
# Falling back to position_potential gives a non-zero gradient over
# any legal opp position, so the MARK defenders pull toward the opp's
# pressure cone (reducing position_potential.openness) instead of
# sitting flat at slot when no immediate shot threat exists.
#
# Used by MARK's recovery fallback for inverse shot-threat scoring across all opps.
# How far from the net mouth the goalie still counts as HOME for the
# threat-surface shot skip below — the crease depth plus a stride. Beyond it
# (pulled, or out playing the puck) the direct-shot branch must be computed
# from anywhere on the rink.
const THREAT_GOALIE_HOME_M: float = 3.0

static func threat_surface_shoot(
		opp_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		defenders: Array[Vector3],
		defender_caps: Array = EMPTY_CAPS) -> float:
	var positional: float = position_potential(opp_pos, our_net, defenders,
			defender_caps)
	# Hot-path skip, not a shaping choice: with the goalie HOME, a direct shot
	# from outside the attacking zone is dead by score_shoot's own coverage
	# math (the arrival-honest race hands any beyond-the-blue-line look to a
	# keeper who is square long before the puck arrives), so the max() below
	# is always the positional branch there — don't pay the hole geometry to
	# find ~0. This runs per carry candidate (turnover pricing) and per marked
	# opponent, at ~30 Hz; the skip covers most of the rink. A displaced /
	# pulled goalie voids the proof (an empty net scores from centre ice), so
	# it computes fully.
	if not in_offensive_zone(opp_pos, our_net) \
			and our_goalie_pos.distance_to(our_net) < THREAT_GOALIE_HOME_M:
		return positional
	# FIELDED read (see AIDangerField): the goalie-hole core — including the
	# predicted post-seal for the opponent's spot, derived inside the field,
	# so a dead-angle look at OUR net is walled exactly as before — comes
	# from the memoized surface; only the lane / release-contest terms run
	# against `defenders` live.
	var shoot: float = score_shoot_threat_fielded(
			opp_pos, our_net, our_goalie_pos, net_half_width, defenders,
			defender_caps)
	return maxf(shoot, positional)


# LOCAL threat — the score_shoot branch of threat_surface_shoot WITHOUT the
# positional-gradient fallback. The fallback is right for MARK positioning
# (a defender needs a non-zero gradient toward a far-but-dangerous man) and
# WRONG for absolute turnover pricing: it floors possession-against-us at
# ~0.25–0.55 everywhere on the rink, so conceding at the safest spot on the
# ice read like handing over half a slot chance and the own-zone clear
# could never win a compete. The honest split prices the immediate danger
# here (this function — ~0 outside our zone with the goalie home, hot in
# our slot) and the FUTURE carry-in danger via counter_rush_cost, which
# sees the covering set — a clear against a committed forecheck then reads
# nearly free exactly because our posts beat the counter home.
static func threat_local_shoot(
		opp_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		defenders: Array[Vector3],
		defender_caps: Array = EMPTY_CAPS) -> float:
	if not in_offensive_zone(opp_pos, our_net) \
			and our_goalie_pos.distance_to(our_net) < THREAT_GOALIE_HOME_M:
		return 0.0
	# FIELDED read — same memoized core as threat_surface_shoot (seal derived
	# inside the field), live lane/contest terms.
	return score_shoot_threat_fielded(
			opp_pos, our_net, our_goalie_pos, net_half_width, defenders,
			defender_caps)


# turnover_cost with the LOCAL threat surface (see threat_local_shoot) —
# the absolute-price variant for competes that pair it with the
# counter-rush term carrying the future-danger half.
static func turnover_cost_local(
		loss_point: Vector3,
		loss_prob: float,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		our_defenders: Array[Vector3],
		defender_caps: Array = EMPTY_CAPS) -> float:
	if not loss_point.is_finite():
		return 0.0
	if loss_prob <= 0.0:
		return 0.0
	return loss_prob * threat_local_shoot(
			loss_point, our_net, our_goalie_pos, net_half_width, our_defenders,
			defender_caps)


# Pass-threat surface — score_pass with a positional fallback for
# the same reason as threat_surface_shoot. score_pass folds in
# lane_clear × score_shoot(receiver); when receiver_shot collapses
# to 0, the lane has no value to defend. Fallback rewards defenders
# for being in the lane (lane_clear ↓) AND for closing on the
# receiver (position_potential.openness ↓).
#
# Used by PRESSURE / FORECHECK for inverse pass-threat scoring across opp teammates.
# `defender_caps` (index-matched to `defenders` — OUR skaters, plus the caller's
# hypothetical self-at-candidate body carrying its own caps) prices each
# defending blade's real reach and closing pace; empty = league.
static func threat_surface_pass(
		carrier_pos: Vector3,
		receiver_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		defenders: Array[Vector3],
		defender_caps: Array = EMPTY_CAPS) -> float:
	if pass_lane_blocked_by_net(carrier_pos, receiver_pos):
		return 0.0
	# Assume the opponent would fire this hypothetical pass at the
	# speed our bots would — charged wrister for long passes, quick-
	# shot otherwise. Without this, the carrier-quick-shot 14 m/s
	# default would overestimate defender reaction time on long
	# opponent passes and underestimate the threat.
	var pass_speed: float = expected_pass_speed(carrier_pos, receiver_pos)
	# Compute the lane once and share it: score_pass would otherwise run the
	# identical lane_clear internally, and it's the same call feeding the
	# positional floor below — a doubled, now-heavier (#427 survival/friction
	# model) lane solve on a per-candidate defensive read.
	var lane: float = lane_clear(carrier_pos, receiver_pos, defenders, pass_speed,
			EMPTY_VEC3, defender_caps)
	var pass_score: float = score_pass(
			carrier_pos, receiver_pos, our_net, our_goalie_pos,
			net_half_width, defenders, pass_speed, 0.0, lane,
			Vector4.INF, Vector4.INF, defender_caps)
	var positional: float = position_potential(receiver_pos, our_net, defenders,
			defender_caps)
	return maxf(pass_score, lane * positional)


# Expected turnover cost — the defensive half of the carrier's
# expected-value model. The value of having the puck (score_at / pass
# upside) is one side; this is the other: the possession value the
# OPPONENT gains if we lose the puck at `loss_point`, weighted by the
# probability of losing it.
#
#   turnover_cost = loss_prob × threat_surface_shoot(loss_point → our net)
#
# The benefit (us shooting their net) and the cost (them shooting ours)
# are scored with the SAME threat surface — score_shoot-shaped value of
# possessing the puck at a location. Because both sides share one
# (uncalibrated but consistent) surface, any miscalibration factor is
# common to both terms and cancels in the argmax: the exchange rate
# between a goal-for and a goal-against is exactly 1, so there is NO
# aversion weight. "Don't turn it over where it hurts" then falls out of
# geometry alone — threat_surface_shoot is ~0 when loss_point is far
# from / wide of our net (offensive-zone turnover) and large in front of
# it (own-zone turnover), so the cost self-localizes with no zone flag.
#
# `our_defenders` are our skaters (excluding the carrier, who just got
# beat); they reduce the opponent's threat exactly as in the defensive
# roles. Returns 0 when there's no loss location (INF) or no loss
# probability.
static func turnover_cost(
		loss_point: Vector3,
		loss_prob: float,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		our_defenders: Array[Vector3],
		defender_caps: Array = EMPTY_CAPS) -> float:
	if not loss_point.is_finite():
		return 0.0
	if loss_prob <= 0.0:
		return 0.0
	return loss_prob * threat_surface_shoot(
			loss_point, our_net, our_goalie_pos, net_half_width, our_defenders,
			defender_caps)


# ── Transition-exposure: the counter-rush cost (5v5-gated at the caller) ─────
# turnover_cost above prices the threat AT the loss point — which is exactly
# why it can't see a defenseman caught deep: a loss in the O-zone reads ~0
# there, while the true cost is the COUNTER-RUSH that develops into the ice
# the carrier vacated. This is the additive second half (plan §6): the value
# of the rush the opponent builds from the loss, priced with only the
# defenders who genuinely beat that rush home.
#
#   counter_point  = the slot in front of OUR net (where a rush shoots from —
#                    a physical landmark, not a shape parameter).
#   t_counter      = the fastest opponent's time to collect the loss and
#                    carry to the counter_point (momentum-aware first leg at
#                    his real Speed cap, straight carry second leg).
#   covering set   = every teammate — and the carrier himself, recovering
#                    from the candidate spot — who can reach the counter
#                    point by t_counter. Bodies that can't beat the rush
#                    home simply don't exist to this read; that is the whole
#                    "who's behind the play?" perception. Covering bodies
#                    stand at the goal-side cover anchor (the same
#                    stick-in-the-lane point the threat partition uses).
#   cost           = loss_prob × threat_surface_shoot(counter_point | covering
#                    set) × delay_discount(t_counter)   — a future threat,
#                    decayed over the time the rush needs to develop.
#
# One-up-one-back falls out with no pairing rule: a partner holding the
# point beats any counter home → the covering set is non-empty → the threat
# collapses → the other D is free to attack. Both D deep → nobody covers →
# near-breakaway threat → the deep carry prices itself out. A fast carrier
# covers himself (his own recovery race) — Speed buys activation freedom.
# Teammates race at the league reference speed (their positions are in the
# defender scratch, their caps are not — a perception simplification, not a
# tuning knob).

# Scratch for the covering-defender positions (caller-owned pattern; this
# is per-candidate hot-ish path at the AI dispatch cadence).
static var _scratch_counter_cover: Array[Vector3] = []


# The counter point a rush shoots from, and each teammate's standing-start
# ETA to it — candidate-invariant inputs the carrier precomputes once per
# compete (fill_counter_cover_etas) instead of re-racing per candidate.
static func counter_point_for(our_net: Vector3) -> Vector3:
	var own_dir: float = signf(our_net.z)
	return Vector3(0.0, 0.0, our_net.z - own_dir * GameRules.SLOT_DIST_M)


static func fill_counter_cover_etas(our_net: Vector3,
		teammates: Array[Vector3], out_etas: Array[float]) -> void:
	var cp: Vector3 = counter_point_for(our_net)
	out_etas.clear()
	for tm: Vector3 in teammates:
		out_etas.append(tm.distance_to(cp) / SKATER_REF_SPEED_M_S)


static func counter_rush_cost(
		loss_point: Vector3,
		loss_prob: float,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		teammates: Array[Vector3],
		self_recover_pos: Vector3,
		self_max_speed: float,
		opponents: Array[Vector3],
		opponent_vels: Array[Vector3],
		opponent_caps: Array,
		mate_etas: Array[float] = [],
		threat_by_cover: Array[float] = [],
		opponent_stamina: Array[float] = []) -> float:
	if not loss_point.is_finite() or loss_prob <= 0.0 or opponents.is_empty():
		return 0.0
	var counter_point: Vector3 = counter_point_for(our_net)

	# Fastest opponent: collect the loss, then carry to the counter point —
	# SPRINTING it (the collect is a loose-puck race, the carry the breakaway
	# sprint), at his stamina-gated race cap. `opponent_stamina` carries the
	# pool with the exhaustion lockout folded in as 0.0 (race_speed reads
	# both as cruise); missing → 1.0, the fresh worst case a danger term
	# defaults to.
	var carry_dist: float = loss_point.distance_to(counter_point)
	var t_counter: float = INF
	var t_collect_best: float = INF
	var has_vels: bool = opponent_vels.size() == opponents.size()
	var has_caps: bool = opponent_caps.size() == opponents.size()
	var has_stam: bool = opponent_stamina.size() == opponents.size()
	for i: int in opponents.size():
		var speed: float = SKATER_REF_SPEED_M_S
		var sprint_mult: float = AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
		if has_caps:
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				speed = caps.max_speed
				sprint_mult = caps.sprint_speed_mult
		var collect_dist: float = opponents[i].distance_to(loss_point)
		speed = BotSprintRules.race_speed(speed, sprint_mult,
				opponent_stamina[i] if has_stam else 1.0, false,
				collect_dist + carry_dist)
		var vel: Vector3 = opponent_vels[i] if has_vels else Vector3.ZERO
		var t_collect: float = time_to_arrive(opponents[i], loss_point, vel, speed)
		if t_collect < t_collect_best:
			t_collect_best = t_collect
		var t: float = t_collect + carry_dist / maxf(speed, 0.001)
		if t < t_counter:
			t_counter = t
	if t_counter == INF:
		return 0.0
	# PASS-FORWARD leg (transition-exposure follow-up, plan §6): the
	# collector doesn't have to lug it the length of the ice — the real
	# counter hits the outlet already AHEAD. From the fastest collect,
	# price the hardest feed to each other opponent's spot and HIS carry
	# home (gather → carry, same restart-from-rest read as the retrieve
	# channels), and let the min compete with the lone-carrier time. This
	# is what makes an everyone-deep shape genuinely expensive: on the lone
	# read a corner collector's 5+ s lug keeps the covering set full, while
	# the stretch man at centre turns it into a ~4 s strike.
	for j: int in opponents.size():
		var j_speed: float = SKATER_REF_SPEED_M_S
		var j_mult: float = AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
		if has_caps:
			var j_caps: AISkaterCaps = opponent_caps[j]
			if j_caps != null:
				j_speed = j_caps.max_speed
				j_mult = j_caps.sprint_speed_mult
		var j_carry: float = opponents[j].distance_to(counter_point)
		# The feed only helps when the outlet is genuinely AHEAD of the
		# lug — skip receivers whose own carry isn't shorter.
		if j_carry >= carry_dist:
			continue
		j_speed = BotSprintRules.race_speed(j_speed, j_mult,
				opponent_stamina[j] if has_stam else 1.0, false, j_carry)
		var t_pf: float = t_collect_best \
				+ loss_point.distance_to(opponents[j]) \
						/ GameRules.DEFAULT_WRISTER_POWER_MAX_M_S \
				+ time_to_arrive(opponents[j], counter_point, Vector3.ZERO, j_speed)
		if t_pf < t_counter:
			t_counter = t_pf

	# Covering set: bodies that beat the counter home WITH TIME TO SET —
	# the same brake-to-arrive margin race_home_radius charges (a defender
	# racing stride-for-stride beside the rush is chasing, not covering).
	# Standing-start straight-line races (positions only — see header), so
	# the brake-out margin is the league one by design: the mate ETAs it
	# pads are themselves league-paced, and a per-build margin on a
	# league-paced race would be false precision.
	var setup_margin: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S \
			/ AISteering.ARRIVAL_BRAKE_DECEL_M_S2
	var cover_anchor: Vector3 = AIThreatAssignment.cover_anchor(
			counter_point, our_net)
	_scratch_counter_cover.clear()
	if mate_etas.size() == teammates.size():
		# Precomputed teammate races (fill_counter_cover_etas) — the hot
		# per-candidate path.
		for eta: float in mate_etas:
			if eta + setup_margin <= t_counter:
				_scratch_counter_cover.append(cover_anchor)
	else:
		for tm: Vector3 in teammates:
			if tm.distance_to(counter_point) / SKATER_REF_SPEED_M_S \
					+ setup_margin <= t_counter:
				_scratch_counter_cover.append(cover_anchor)
	if self_recover_pos.is_finite() \
			and self_recover_pos.distance_to(counter_point) \
					/ maxf(self_max_speed, 0.001) + setup_margin <= t_counter:
		_scratch_counter_cover.append(cover_anchor)

	# score_shoot directly, not threat_surface_shoot: the counter point IS a
	# shot location (the slot), squarely in score_shoot's domain — the
	# positional fallback would hold its value regardless of the covering
	# set (closeness × angle ignore defenders' block) and dilute the whole
	# covered-vs-open signal this term exists to read.
	#
	# Memo by cover count: within one carrier compete the counter point,
	# goalie, and cover anchor are all candidate-INVARIANT — the only thing
	# a candidate changes here is HOW MANY bodies stand at the anchor. So
	# the shot geometry has just (roster+2) distinct values; the caller may
	# pass a -1-seeded scratch (`threat_by_cover`, indexed by cover count,
	# reset each compete) and the ~25 candidate calls collapse to ≤ a
	# handful of real score_shoot evaluations.
	var cover_count: int = _scratch_counter_cover.size()
	var threat: float
	if cover_count < threat_by_cover.size():
		threat = threat_by_cover[cover_count]
		if threat < 0.0:
			threat = score_shoot(
					counter_point, our_net, our_goalie_pos, net_half_width,
					_scratch_counter_cover)
			threat_by_cover[cover_count] = threat
	else:
		threat = score_shoot(
				counter_point, our_net, our_goalie_pos, net_half_width,
				_scratch_counter_cover)
	return loss_prob * threat * delay_discount(t_counter)


# ── Pass execution risk ──────────────────────────────────────────────────────
# Even a clear-lane pass isn't a sure thing: leads run long, receptions
# fumble off an unsquared blade, a bouncing puck skips the tape. The lane
# model prices INTERCEPTION only, so without this a clear-lane backpass deep
# in our own zone scores as risk-free — and since fire wins ties against
# carry, that alone is enough to make bots dump the puck backward for
# near-zero gain and surrender all the ice behind them on the occasional
# real miss. PASS_MISS_PROB is the residual chance a lane-clear pass still
# fails on execution; the puck ends up loose PAST the receiver (overled /
# through the blade), PASS_MISS_OVERSHOOT_M beyond them along the pass line.
# Feeding that loss point to turnover_cost makes the risk self-localize
# exactly like interception risk does: an OZ miss costs ~0 (loose puck in
# their end), a DZ backpass miss prices the opponent's chance in front of our
# net. No zone flag, no backpass heuristic — the geometry does it.
#
# NOT a flat rate — pass_miss_prob() DERIVES it, since a bare constant here
# would be a magic number in an evaluator. Two grounded parts:
#   · The bot solves its LAUNCH so the puck ARRIVES catchable (at
#     PASS_TARGET_CLOSING_M_S, under the any-angle reception ceiling), so
#     reception DIFFICULTY (closing speed vs blade angle) is designed OUT of its
#     own passes — it never fires a feed that arrives as a knock-down. The
#     residual is therefore hand + luck, not the catch.
#   · PASS_MISS_BASE_PROB — an irreducible floor (a bounce, a skate, ice
#     chatter; no pass is 100%), plus HAND execution: the release-direction error
#     (BotSkillProfile.pass_aim_error_rad) projected to the tape over the pass
#     distance, which misses when that lateral spread exceeds the receiver's
#     catch envelope (its Hands handle reach). Same uniform-error model the shot
#     window uses.
# So miss scales with the passer's Hands tier AND the pass length: a Hard bot's
# short feed sits at the base, an Easy bot's cross-ice stretch is genuinely risky.
# The backpass suppression rides the base floor, so even a perfect short feed
# keeps a small DZ miss cost. OVERSHOOT is the physical "how far past the receiver
# does a missed pass die" scale, not a knob.
const PASS_MISS_BASE_PROB: float = 0.04
const PASS_MISS_OVERSHOOT_M: float = 3.0


# Per-pass execution-miss probability (see the block above). `aim_error_rad` is
# the passer's release-direction error — 0 for the perfect baseline and the
# cross-player threat model (we don't know another player's hand), collapsing to
# the base floor. `catch_radius` is how far off the tape the receiver can still
# corral the feed (its Hands handle reach). Uniform-error model: the base floor
# compounded with the fraction of the ±(aim_error × distance) lateral spread that
# lands outside the catch envelope.
static func pass_miss_prob(distance: float, aim_error_rad: float,
		catch_radius: float = EVADE_CARRY_HANDLE_M,
		receiver_uncertainty_m: float = 0.0) -> float:
	# Two lateral catch-point offsets, both in metres, both measured against the
	# receiver's catch envelope: the passer's own aim spread (hand error over the
	# pass distance) and the receiver's heading uncertainty (a turning receiver
	# curves off the straight-line lead — receiver_heading_uncertainty_m). They
	# add: either one alone can push the catch point out of reach, and the
	# worst case is they align. A settled receiver contributes 0, so a clean feed
	# is unchanged.
	var spread: float = maxf(aim_error_rad, 0.0) * maxf(distance, 0.0) \
			+ maxf(receiver_uncertainty_m, 0.0)
	var execution: float = 0.0
	if spread > 0.0001:
		execution = clampf(
				(spread - catch_radius) / spread, 0.0, 1.0)
	return clampf(
			1.0 - (1.0 - PASS_MISS_BASE_PROB) * (1.0 - execution), 0.0, 1.0)


# Catch-point positional uncertainty (metres) a TURNING receiver adds to a pass,
# from the receiver's own commitment — NOT the passer's hand. The lead aims down
# the receiver's current heading (AIPassLead strips the centripetal component and
# extrapolates the straight-line continuation), but a receiver rotating its
# heading at `omega` rad/s curves off that tangent line over the flight. The exact
# lateral deviation of a constant-radius arc from its launch tangent is
# R·(1 − cos θ), where R = v/ω is the turn radius and θ = ω·t is the angle swept
# over flight time `t`. That is the metres by which the receiver misses the spot
# the pass was led to — precisely "how much can't I trust this lead." Grounded
# geometry, self-bounding (1 − cos saturates), and it collapses to ~0 for a
# receiver holding a line (ω → 0) so clean feeds pay nothing. The swept angle is
# capped at π (beyond a half-turn the tangent-deviation model no longer grows
# monotonically, and such a receiver is uncatchable regardless).
static func receiver_heading_uncertainty_m(
		receiver_speed: float, omega: float, flight_t: float) -> float:
	var w: float = absf(omega)
	if w < 0.0001 or receiver_speed <= 0.0 or flight_t <= 0.0:
		return 0.0
	var theta: float = minf(w * flight_t, PI)
	var radius: float = receiver_speed / w
	return radius * (1.0 - cos(theta))


# Loss point for the execution-miss mode of a pass: the puck sails past
# the receiver and dies PASS_MISS_OVERSHOOT_M beyond them on the pass
# line. Degenerate (overlapping endpoints) falls back to the receiver.
static func pass_miss_loss_point(from: Vector3, receiver: Vector3) -> Vector3:
	var dx: float = receiver.x - from.x
	var dz: float = receiver.z - from.z
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.0001:
		return receiver
	var inv: float = PASS_MISS_OVERSHOOT_M / sqrt(len_sq)
	return Vector3(receiver.x + dx * inv, 0.0, receiver.z + dz * inv)


# Base puck-protect reach: how far a carrier holds the puck off his body while
# handling. Hands scales it (a better handler protects it further out / threads a
# tighter seam) — callers pass the scaled value; this is the league default.
const EVADE_CARRY_HANDLE_M: float = 0.9

# ── Calibrated phase model ─────────────────────────────────────────────────────
# The measured controller (SkaterMovementRules at 120 Hz driven by the real
# steering — the velocity-matched seek plus the pivot brake, see
# tests/unit/ai/test_time_to_arrive_calibration.gd, which pins every constant
# here against simulated arrivals) decomposes into:
#
#   REDIRECT — cross-momentum beyond what the seek sheds for free. The
#     velocity-matched anchor pull cancels cross-drift out of the thrust's
#     spare headroom, so moderate drift costs nothing; only the EXCESS above
#     VM_FREE_SHED_M_S pays, at the measured net shed rate.
#   REVERSAL — velocity pointed away brakes out at the brake key's real
#     friction decel and gives back the ground lost while braking (both
#     measured; the decel is brake_multiplier × (friction + drag·v) at game
#     speeds).
#   PURSUIT — a capped ramp at the NET accel the movement model delivers
#     (thrust minus friction/drag losses — RAMP_EFFICIENCY) up to top speed,
#     then cruise. A standing start genuinely pays ~0.5 s over a plain
#     dist/speed read; a full-speed head-on drive pays nothing.
#
# Never collapse this to `effective = ref + v_along` with the shed as a pure
# delay: that credits a full-speed closer with up to DOUBLE top speed and hands
# standing starts top speed for free, distorting every race in the AI at the
# extremes. Errors vs the measured table are within ~±20% on the clean
# families; the one known
# soft spot is short diagonal cuts at high speed (the controller's lateral
# miss-loop — it can overfly the catch window and circle once), where reality
# runs up to ~2× the estimate. The calibration suite fails loudly if the
# movement tuning drifts.

# Cross speed the velocity-matched seek sheds inside the thrust headroom
# (costs no time). Measured.
const VM_FREE_SHED_M_S: float = 3.5
# Net shed rate for cross speed beyond the free band. Measured.
const VM_SHED_DECEL_M_S2: float = 6.5
# Brake-key deceleration for reversals: brake_multiplier × (friction +
# drag·v̄) at game speeds — physical, and confirmed by the reversal cells.
const REVERSAL_BRAKE_DECEL_M_S2: float = 10.5
# Fraction of commanded thrust the movement model nets after friction and
# velocity drag over a 0→top ramp. Measured (≈0.51 s ramp overhead at league
# tuning).
const RAMP_EFFICIENCY: float = 0.84


# `ref_speed_m_s` is the actor's flat skating speed; `accel_m_s2` its all-direction
# thrust (Acceleration-scaled) — both default to league references so cross-player
# callers (opponent / teammate ETA, the loose-puck election that must stay
# consistent across all bots) keep the shared baseline. A bot estimating ITS OWN
# arrival passes its attribute-scaled top speed AND max_accel (a higher-Acceleration
# build redirects and ramps faster, so it reaches an off-axis cut sooner).
#
# NET-AWARE: a route whose straight line crosses a cage prices the real
# around-the-cage detour (see _time_to_arrive_routed) — a skater cannot skate
# through the net frame, and a straight-line time is a fiction exactly in the
# races that decide behind-net play (retrieval races, chase elections, station
# races near the nets), where it predicts race wins the skater cannot deliver.
# The common open-ice case pays only the cheap z-gate below (a cage sits at
# |z| ≥ the goal line; a segment that never reaches it cannot cross one).
static func time_to_arrive(from_pos: Vector3, dest: Vector3,
		from_velocity: Vector3, ref_speed_m_s: float = SKATER_REF_SPEED_M_S,
		accel_m_s2: float = SHED_ACCEL_DEFAULT_M_S2,
		lateral_grip: float = 1.0) -> float:
	# Route only when the segment passes THROUGH a cage — an endpoint inside
	# the inflated frame box is a conceptual "at the net" destination (race-
	# home reads target the net center as their home proxy; a pinned body
	# starts against the mesh) and keeps the direct model.
	if maxf(absf(from_pos.z), absf(dest.z)) \
			>= GameRules.GOAL_LINE_Z - CARRY_NET_CLEAR_MARGIN_M \
			and carry_path_blocked_by_net(from_pos, dest) \
			and not _point_in_cage_box(from_pos) \
			and not _point_in_cage_box(dest):
		return _time_to_arrive_routed(
				from_pos, dest, from_velocity, ref_speed_m_s, accel_m_s2,
				lateral_grip)
	return _time_to_arrive_direct(
			from_pos, dest, from_velocity, ref_speed_m_s, accel_m_s2,
			lateral_grip)


# True when `p` sits inside either inflated cage frame box (the same
# inflation carry_path_blocked_by_net tests against).
static func _point_in_cage_box(p: Vector3) -> bool:
	if absf(p.x) > GameRules.NET_BACK_HALF_WIDTH + CARRY_NET_CLEAR_MARGIN_M:
		return false
	var az: float = absf(p.z)
	return az >= GameRules.GOAL_LINE_Z - CARRY_NET_CLEAR_MARGIN_M \
			and az <= GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH \
					+ CARRY_NET_CLEAR_MARGIN_M


# The around-the-cage route: the better of four corner waypoints — beside
# either post at mid-cage depth, the behind-net alley, and the front lip.
# The four cover every crossing geometry with its honest small detour (a
# behind-net traverse routes through the alley, a crease-front graze dips in
# front, a front-to-behind trip rounds the nearer post); post waypoints alone
# route a 2 m behind-net skate the long way around. Each leg runs
# the calibrated direct model, carrying pace through the corner exactly like
# the wheel's two-leg pricing. Legs are not re-checked for blockage: the
# waypoints sit a body's clearance outside the inflated frame, which clears
# them in every practical geometry.
static func _time_to_arrive_routed(from_pos: Vector3, dest: Vector3,
		from_velocity: Vector3, ref_speed_m_s: float,
		accel_m_s2: float, lateral_grip: float = 1.0) -> float:
	# The cage being crossed is on the side the route actually reaches.
	var s: float = signf(from_pos.z) \
			if absf(from_pos.z) >= absf(dest.z) else signf(dest.z)
	var side_x: float = GameRules.NET_BACK_HALF_WIDTH \
			+ CARRY_NET_CLEAR_MARGIN_M + NET_ROUTE_CLEAR_M
	var mid_z: float = s * (GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH * 0.5)
	var back_z: float = s * (GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH \
			+ CARRY_NET_CLEAR_MARGIN_M + NET_ROUTE_CLEAR_M)
	var front_z: float = s * (GameRules.GOAL_LINE_Z \
			- CARRY_NET_CLEAR_MARGIN_M - NET_ROUTE_CLEAR_M)
	var vmax: float = maxf(ref_speed_m_s, MIN_TRAVEL_SPEED_M_S)
	var best: float = INF
	for wp: Vector3 in [
			Vector3(-side_x, 0.0, mid_z), Vector3(side_x, 0.0, mid_z),
			Vector3(0.0, 0.0, back_z), Vector3(0.0, 0.0, front_z)]:
		var t1: float = _time_to_arrive_direct(
				from_pos, wp, from_velocity, ref_speed_m_s, accel_m_s2,
				lateral_grip)
		var to_dest: Vector3 = dest - wp
		to_dest.y = 0.0
		var v_wp := Vector3.ZERO
		if to_dest.length_squared() > 0.0001:
			v_wp = to_dest.normalized() * minf(
					from_pos.distance_to(wp) / maxf(t1, 0.001), vmax)
		var t: float = t1 + _time_to_arrive_direct(
				wp, dest, v_wp, ref_speed_m_s, accel_m_s2, lateral_grip)
		if t < best:
			best = t
	return best


# The calibrated direct-route travel model (no net awareness — the public
# time_to_arrive gates and routes; the routed legs call this).
static func _time_to_arrive_direct(from_pos: Vector3, dest: Vector3,
		from_velocity: Vector3, ref_speed_m_s: float = SKATER_REF_SPEED_M_S,
		accel_m_s2: float = SHED_ACCEL_DEFAULT_M_S2,
		lateral_grip: float = 1.0) -> float:
	var dx: float = dest.x - from_pos.x
	var dz: float = dest.z - from_pos.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.001:
		return 0.0
	var vmax: float = maxf(ref_speed_m_s, MIN_TRAVEL_SPEED_M_S)
	var inv: float = 1.0 / dist
	var v_along: float = from_velocity.x * dx * inv + from_velocity.z * dz * inv
	var v_len_sq: float = from_velocity.x * from_velocity.x \
			+ from_velocity.z * from_velocity.z
	var v_perp: float = sqrt(maxf(0.0, v_len_sq - v_along * v_along))
	# REDIRECT: only the cross momentum the seek can't shed for free pays,
	# scaled by this build's PERPENDICULAR authority relative to league —
	# thrust × lateral_grip, exactly the quantity SkaterMovementRules scales
	# in the real body (a power-profile/heavy build sheds sideways momentum
	# slower; the ramp below stays pure accel — grip never limits parallel
	# drive, in planning or in physics).
	var accel_ratio: float = maxf(accel_m_s2 * lateral_grip, 0.001) / SHED_ACCEL_DEFAULT_M_S2
	var t: float = maxf(0.0, v_perp - VM_FREE_SHED_M_S * accel_ratio) \
			/ (VM_SHED_DECEL_M_S2 * accel_ratio)
	var r: float = dist
	var v0: float = v_along
	if v0 < 0.0:
		# Reversal: brake the retreat out, giving back the ground lost while
		# braking; the pursuit then ramps from rest. (Brake friction is
		# attribute-flat — the brake key, not thrust.)
		t += -v0 / REVERSAL_BRAKE_DECEL_M_S2
		r += v0 * v0 / (2.0 * REVERSAL_BRAKE_DECEL_M_S2)
		v0 = 0.0
	v0 = minf(v0, vmax)
	# PURSUIT: capped ramp at the delivered net accel, then cruise.
	var a_net: float = maxf(accel_m_s2 * RAMP_EFFICIENCY, 0.001)
	var d_ramp: float = (vmax * vmax - v0 * v0) / (2.0 * a_net)
	if r <= d_ramp:
		t += (sqrt(v0 * v0 + 2.0 * a_net * r) - v0) / a_net
	else:
		t += (vmax - v0) / a_net + (r - d_ramp) / vmax
	return t


# True iff the segment from `from` to `to` (in world XZ) intersects
# either net's PHYSICAL footprint. The blocking rectangle is the net at its
# widest — the back-frame trapezoid half-width (NET_BACK_HALF_WIDTH, wider than
# the goal mouth's post span) — inflated by the puck's own radius on every side,
# since the puck is a disc whose EDGE clanks the frame, not a point. Matching
# GameRules.is_over_net_footprint's widest-span reading. Narrowed to the post
# half-width with no inflation, feeds from below the goal line aimed across the
# slot read "clear" and ring off the OUTSIDE of the cage: the lane threads the
# 0.915 post line but not the 1.02 (+ puck radius) back frame.
# Used by score_pass / the carrier pass EV / the live fired aim to treat the net
# as a hard pass-lane obstruction.
static func pass_lane_blocked_by_net(from: Vector3, to: Vector3) -> bool:
	var goal_line_z: float = GameRules.GOAL_LINE_Z - GameRules.PUCK_COLLISION_RADIUS
	var net_half_w: float = GameRules.NET_BACK_HALF_WIDTH + GameRules.PUCK_COLLISION_RADIUS
	var net_back_z: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH \
			+ GameRules.PUCK_COLLISION_RADIUS
	# Team 0's net (positive z).
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			goal_line_z, net_back_z):
		return true
	# Team 1's net (negative z), mirrored.
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			-net_back_z, -goal_line_z):
		return true
	return false


# ── The net as a CARRY / BLADE obstacle ──────────────────────────────────────
# The cage is a solid frame in the middle of the behind-the-net game, and the
# carry model has to see it the same way the body steering already does
# (AISteering._net_detour rounds the post). Two consumers:
#   - carry_path_blocked_by_net — a carried traverse (body + puck) cannot pass
#     through the cage, so a carry candidate whose straight route crosses it
#     is unreachable as priced (the post-walkout candidates are the legal
#     routes out from behind the line; see AIRoleCarrier._best_carry).
#   - net_safe_blade_target — the carry cursor must never ask the blade IK to
#     reach THROUGH the frame: stick-on-net contact dislodges the carried
#     puck (the behind-the-net giveaway), so a crossing chord is swung to the
#     tangent bearing around the nearer post — the blade-level mirror of the
#     body's net detour.
# Margins are physical half-widths of the thing traversing: a carried body +
# puck for the path, a blade length of standoff for the cursor (same standard
# as the boards clamp).
const CARRY_NET_CLEAR_MARGIN_M: float = 0.5
# Extra lateral/depth clearance the net-aware ETA's corner waypoints keep
# beyond the inflated frame — a body's half-width, the corner is skated
# around, not clipped (see _time_to_arrive_routed).
const NET_ROUTE_CLEAR_M: float = 0.4
const BLADE_NET_CLEAR_MARGIN_M: float = GameRules.DEFAULT_BLADE_LENGTH_M


# True iff a carried traverse from → to would pass through either cage
# (frame AABB inflated by the carry margin). From-inside counts as blocked —
# the slab test's t_min = 0 is inside the box — which is correct: a body
# standing against the mesh can't carry through it.
static func carry_path_blocked_by_net(from: Vector3, to: Vector3) -> bool:
	var hw: float = GameRules.NET_BACK_HALF_WIDTH + CARRY_NET_CLEAR_MARGIN_M
	var z_front: float = GameRules.GOAL_LINE_Z - CARRY_NET_CLEAR_MARGIN_M
	var z_back: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + CARRY_NET_CLEAR_MARGIN_M
	if _segment_crosses_aabb_xz(from.x, from.z, to.x, to.z, -hw, hw, z_front, z_back):
		return true
	return _segment_crosses_aabb_xz(from.x, from.z, to.x, to.z, -hw, hw, -z_back, -z_front)


# Redirect a blade-aim target whose chord from `from` crosses a net frame:
# rotate the aim to the frame's tangent bearing around the nearer post (the
# occluded bearing interval is bounded by the inflated frame's corner
# bearings; the chord crosses, so the original bearing lies inside it — clamp
# to the nearer edge plus a small step of daylight). Distance from `from` is
# preserved, y is flattened (blade targets live on the ice plane). A
# non-crossing target returns unchanged. Degenerate case — `from` itself
# inside the inflated frame region (pinned against the mesh): no tangent
# exists, so slide the aim laterally toward the nearer post-side exit.
static func net_safe_blade_target(from: Vector3, target: Vector3) -> Vector3:
	var hw: float = GameRules.NET_BACK_HALF_WIDTH + BLADE_NET_CLEAR_MARGIN_M
	var z_front: float = GameRules.GOAL_LINE_Z - BLADE_NET_CLEAR_MARGIN_M
	var z_back: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + BLADE_NET_CLEAR_MARGIN_M
	var box_z0: float
	var box_z1: float
	if _segment_crosses_aabb_xz(from.x, from.z, target.x, target.z, -hw, hw, z_front, z_back):
		box_z0 = z_front
		box_z1 = z_back
	elif _segment_crosses_aabb_xz(from.x, from.z, target.x, target.z, -hw, hw, -z_back, -z_front):
		box_z0 = -z_back
		box_z1 = -z_front
	else:
		return target
	var to_target := Vector2(target.x - from.x, target.z - from.z)
	var dist: float = to_target.length()
	if dist < 0.001:
		return target
	if from.x > -hw and from.x < hw and from.z > box_z0 and from.z < box_z1:
		var side: float = signf(from.x) if from.x != 0.0 else 1.0
		return Vector3(from.x + side * dist, 0.0, from.z)
	var target_ang: float = atan2(to_target.x, to_target.y)
	var min_rel: float = INF
	var max_rel: float = -INF
	for corner_x: float in [-hw, hw]:
		for corner_z: float in [box_z0, box_z1]:
			var rel: float = wrapf(
					atan2(corner_x - from.x, corner_z - from.z) - target_ang, -PI, PI)
			min_rel = minf(min_rel, rel)
			max_rel = maxf(max_rel, rel)
	# The chord crosses, so 0 ∈ [min_rel, max_rel]. Swing to the nearer edge,
	# plus a small step of daylight past the corner.
	var swing: float = min_rel if -min_rel <= max_rel else max_rel
	var out_ang: float = target_ang + swing + signf(swing) * 0.05
	return Vector3(from.x + sin(out_ang) * dist, 0.0, from.z + cos(out_ang) * dist)


# Own-DZ slot danger zone. True iff the pass segment crosses the
# rectangle in front of OUR net — the high-danger area where a
# deflected/intercepted pass becomes a goal against. Asymmetric to
# `pass_lane_blocked_by_net` because passes through OPP slot are
# legitimate (backdoor / cross-crease feeds); only OWN slot is risky.
#
# Slot rect: x ∈ ±OWN_DZ_SLOT_HALF_WIDTH_M, z ∈ [own_goal_line - depth,
# own_goal_line] for own_goal_z > 0; mirrored for own_goal_z < 0.
# Sized to the real "home plate" high-danger area, not just the net mouth: a
# blind feed across the front of your own net that clips the flanks (a receiver
# a stick outside the posts, a lead point past the crease top) is the cardinal
# giveaway — it deserves the same hard veto as a dead-centre one. Half-width
# ~3× NET_HALF_WIDTH (0.915) covers the posts plus a stick either side; depth
# reaches out toward the hash marks. At 2.0×5.0 side-of-crease centring feeds
# slip the veto and become goals-against.
const OWN_DZ_SLOT_HALF_WIDTH_M: float = 2.75
const OWN_DZ_SLOT_DEPTH_M: float = 6.0
static func pass_crosses_own_slot(from: Vector3, to: Vector3, own_goal_z: float) -> bool:
	var depth: float = OWN_DZ_SLOT_DEPTH_M
	var half_w: float = OWN_DZ_SLOT_HALF_WIDTH_M
	if own_goal_z > 0.0:
		# Team 0: own net at +z. Slot is in front of goal line,
		# z ∈ [own_goal_z - depth, own_goal_z].
		return _segment_crosses_aabb_xz(
				from.x, from.z, to.x, to.z,
				-half_w, half_w,
				own_goal_z - depth, own_goal_z)
	else:
		# Team 1: own net at -z. Slot z ∈ [own_goal_z, own_goal_z + depth].
		return _segment_crosses_aabb_xz(
				from.x, from.z, to.x, to.z,
				-half_w, half_w,
				own_goal_z, own_goal_z + depth)


# Liang-Barsky parametric clipping: returns true iff the segment from
# (fx, fz) to (tx, tz) intersects the axis-aligned rectangle bounded
# by [x_min, x_max] × [z_min, z_max]. Endpoint inside the rect counts
# as intersection.
static func _segment_crosses_aabb_xz(
		fx: float, fz: float, tx: float, tz: float,
		x_min: float, x_max: float, z_min: float, z_max: float) -> bool:
	var dx: float = tx - fx
	var dz: float = tz - fz
	var t_min: float = 0.0
	var t_max: float = 1.0
	# X slab.
	if absf(dx) < 0.0001:
		if fx < x_min or fx > x_max:
			return false
	else:
		var t1: float = (x_min - fx) / dx
		var t2: float = (x_max - fx) / dx
		if t1 > t2:
			var tmp: float = t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	# Z slab.
	if absf(dz) < 0.0001:
		if fz < z_min or fz > z_max:
			return false
	else:
		var t1: float = (z_min - fz) / dz
		var t2: float = (z_max - fz) / dz
		if t1 > t2:
			var tmp: float = t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	return true


# ── Dump delivery search ─────────────────────────────────────────────────────
# A dump is a RELEASE, not a spot: the puck goes where its launch and the boards
# send it. Both dumps are therefore chosen by searching launches and reading
# where each one actually ends up (AITrajectory.puck_release_landing), rather
# than by aiming at a hand-placed target and pricing the concession there.
#
# The two dumps want opposite things and are scored separately:
#   DZ CLEAR — get it out, and do not ice it. Hybrid icing is a race timed from
#     the goal-line crossing, so a delivery that never reaches the line cannot
#     be iced at all; a steep bank into the near boards buys that, because the
#     contact sheds 37-60% where a glancing rim sheds ~5% AND the carom bends
#     the path. Legality is bought by the PATH, which matters because the
#     wrister floor means no release the bot can make dies inside the rink.
#   NZ DUMP-IN — the opposite errand entirely. It is an offensive play (get it
#     deep, forecheck it back), it cannot be icing by construction (it is only
#     offered past the red line, and icing requires a release from our own
#     half), so it is scored purely on winning the race to wherever the puck
#     comes to rest.

# Launch bearings tried per dump, as offsets from the aim axis. Spread wide
# enough to include the steep bank into the near boards — the delivery that
# makes a DZ clear legal — and dense enough that the corner it wraps into is
# resolved. Each bearing is one closed-form landing solve.
const DUMP_SEARCH_BEARINGS_RAD: Array = [
	-1.20, -0.90, -0.60, -0.30, 0.0, 0.30, 0.60, 0.90, 1.20,
]

# Launch PACES tried per bearing on the dump-IN, as fractions of the release
# band between the soft-touch floor (DEFAULT_WRISTER_POWER_MIN_M_S) and the pace
# the dumper can actually produce. Bearing alone cannot place a dump: the puck's
# runout at any pace the bot can make (100 m at the wrister floor, ~200 m at
# pass pace) out-slides the rink several times over, so WHERE it stops is set by
# how much speed the boards take out of it — and the only deliveries that die
# in the offensive zone at a fixed hot pace are the ones banked steeply enough
# to shed 40-60% on contact. Unpaced, the search reads a centre chip as a puck
# returning to the neutral zone (square off the end boards and back out) and has
# to reach for a wall to kill anything, because depth is not on its axis list.
# With pace searched a soft chip dies where it is aimed, and a rim is chosen
# because it wins the race rather than because it was the only way to stop the
# puck.
#
# Spaced toward the SOFT end, because that is where the answer changes. Runout
# goes as v², so the top of the band is a wall of deliveries that all rattle
# off the end boards and differ only in where they finish bouncing, while the
# metre-scale placement lives in the first few m/s above the floor. The full
# pace is kept as the last rung: a hard rim around the boards genuinely beats a
# defender to the corner, and it should stay on the menu — it just should not
# spend three of four samples.
const DUMP_SEARCH_PACE_FRACS: Array = [0.0, 0.18, 0.45, 1.0]

# Keeper puck-play travel build — GoalieController's `puck_play_skate_speed` /
# `puck_play_skate_accel` export defaults, and `puck_play_capture_radius` (the
# paddle trap reach at the spot he stops on). Kept UNTIERED, like every other
# goalie read in here: what a resting puck's ownership turns on is how far a
# keeper can skate, which no difficulty knob changes.
const GOALIE_PUCK_PLAY_SPEED_M_S: float = 4.2
const GOALIE_PUCK_PLAY_ACCEL_M_S2: float = 8.0
const GOALIE_PUCK_PLAY_REACH_M: float = 1.0


# Does the KEEPER get to a puck resting at `spot` before our nearest chaser?
#
# `chase_recovery` sees skaters only, so without this a dump dying on the
# doorstep — the spot `position_potential` rates highest on the whole rink —
# reads as a free recovery and the delivery search aims there. It is the
# keeper's puck, and he is standing on it.
#
# A straight race at both sides' real builds, with no margin term: he leaves the
# paint at a keeper's pace (GOALIE_PUCK_PLAY_*, ramped from rest) and collects
# from a paddle's length, we run at skater pace. That bounds how far out the
# ice is his WITHOUT a radius anybody had to pick — the slot is his because he
# is metres away and we are twenty, the corner is ours because his 4.2 m/s
# cannot beat a winger's 9 to it. Deliberately blind to the trip conditions the
# live keeper also weighs (net-front exclusion, cooldown, the tiered GO margin):
# each of those only makes him STAY, so ignoring them errs toward not feeding
# him — the safe direction for a dumper — and keeps this untiered.
static func keeper_collects_first(spot: Vector3, keeper_pos: Vector3,
		our_chasers: Array[Vector3], chaser_speed: float) -> bool:
	if our_chasers.is_empty():
		return true
	var ours: float = INF
	for c: Vector3 in our_chasers:
		ours = minf(ours, c.distance_to(spot))
	var keeper_dist: float = maxf(
			keeper_pos.distance_to(spot) - GOALIE_PUCK_PLAY_REACH_M, 0.0)
	return GoalieBehaviorRules.travel_time_from_rest(
			keeper_dist, GOALIE_PUCK_PLAY_SPEED_M_S, GOALIE_PUCK_PLAY_ACCEL_M_S2) \
			<= ours / maxf(chaser_speed, 0.001)


# Hang time of a release at `loft_level` and `launch_speed` — the airborne
# window, 2*vy/g. Airborne carry costs no runout, which is why loft moves WHERE
# a dump lands without slowing WHEN it arrives.
static func dump_loft_hang_s(loft_level: int) -> float:
	var vy: float = 0.0
	if loft_level == ShotMechanics.ELEVATION_LOW:
		vy = GameRules.DEFAULT_LOFT_VY_LOW_M_S
	elif loft_level == ShotMechanics.ELEVATION_HIGH:
		vy = GameRules.DEFAULT_LOFT_VY_HIGH_M_S
	return 2.0 * vy / GameRules.GRAVITY_M_S2


# The DZ clear: enumerate the launches it is LEGAL to make, and leave the
# choosing to the caller.
#
# Two refusals, both DOCTRINE rather than valuation — they say what a clear IS,
# so they are filters and never penalties a good enough price could outvote:
#   ICES — a launch that reaches their goal line starts a hybrid race we have no
#     reason to run. Legality is bought by the PATH, not the pace: a steep bank
#     into the near boards sheds 40-60% on contact and the carom lengthens the
#     route, so the puck dies before the line and no race is ever judged.
#   DOESN'T CLEAR — a launch that comes to rest still inside our own zone did not
#     clear anything, however certainly we would win it back.
#
# It deliberately does not CHOOSE among the survivors — `_best_dump` does, in
# CONCESSION. Ranking here by depth (nearest their blue line) ranks in METRES
# while the caller prices in concession, so the search can hand over a spot we
# have no chance at while a spot we would win outright sits one bearing away.
# Depth cannot separate them anyway: fired at the fixed quick-pass pace from a
# pinned corner EVERY legal landing is deep (the softest release the bot can make
# out-slides the rink twice over), so which deep spot is right is entirely a
# question of who gets there first.
#
# The clear stays a pure concession with NO gain term, so its value can never
# exceed zero. Paying it a positive gain for the race it wins makes a clear score
# above zero and beat CARRYING where a clean regroup exists.
#
# `out_vels` / `out_spots` are caller-owned and index-matched (the caller-owned
# out-param pattern — the search allocates nothing on the compete path). Returns
# the candidate count; 0 means no legal clear exists from here, which leaves the
# caller to decide what to do with a puck that cannot be cleared at all.
static func dump_clear_candidates(origin: Vector3, up_ice_dir: float,
		launch_speed: float, loft_level: int, our_net: Vector3,
		out_vels: Array[Vector3], out_spots: Array[Vector3]) -> int:
	var hang_s: float = dump_loft_hang_s(loft_level)
	# Their goal line is the one icing is judged at: up-ice of us.
	var their_line_z: float = up_ice_dir * GameRules.GOAL_LINE_Z
	var axis := Vector3(0.0, 0.0, up_ice_dir)
	out_vels.clear()
	out_spots.clear()
	for offset: float in DUMP_SEARCH_BEARINGS_RAD:
		var vel: Vector3 = axis.rotated(Vector3.UP, offset) * launch_speed
		var landing: Transform3D = AITrajectory.puck_release_landing(
				origin, vel, hang_s, their_line_z, up_ice_dir)
		if landing.basis.x.x > 0.5:
			continue
		if in_offensive_zone(landing.origin, our_net):
			continue  # dies in our own zone — that is not a clear
		out_vels.append(vel)
		out_spots.append(landing.origin)
	return out_spots.size()


# The NZ dump-in: search launches — BEARING x PACE — and take the one whose
# RESTING spot we are most likely to win. `out_landing` receives the chosen spot
# and `max_launch_speed` bounds the pace ladder (the top of the dumper's own
# release band); the returned velocity's LENGTH is the pace that won, which the
# release then has to actually fire at. Caller-owned out-param, so the search
# allocates nothing on the compete path.
#
# Scored as recovery x realized position value: the race is the play, and what
# it wins is a spot whose promise still has to be skated in — the same
# realization discount every other future-value read in the model pays, so the
# search optimizes exactly what _best_dump prices.
#
# There is no icing branch — this dump is only offered past the red line, and
# icing requires a release from our own half, so the two are mutually exclusive.
static func solve_dump_in(origin: Vector3, attacking_goal: Vector3,
		max_launch_speed: float, loft_level: int,
		our_chasers: Array[Vector3], opp_chasers: Array[Vector3],
		keeper_pos: Vector3, out_landing: Array[Vector3],
		our_vels: Array[Vector3] = EMPTY_VEC3,
		opp_vels: Array[Vector3] = EMPTY_VEC3) -> Vector3:
	var hang_s: float = dump_loft_hang_s(loft_level)
	var goal_dir: float = signf(attacking_goal.z)
	var axis := Vector3(0.0, 0.0, goal_dir)
	var best_vel: Vector3 = Vector3.ZERO
	var best_score: float = -INF
	var best_spot: Vector3 = origin
	var floor_speed: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
	var band: float = maxf(max_launch_speed - floor_speed, 0.0)
	for offset: float in DUMP_SEARCH_BEARINGS_RAD:
		var dir: Vector3 = axis.rotated(Vector3.UP, offset)
		for frac: float in DUMP_SEARCH_PACE_FRACS:
			var vel: Vector3 = dir * (floor_speed + band * frac)
			var landing: Transform3D = AITrajectory.puck_release_landing(
					origin, vel, hang_s)
			var spot: Vector3 = landing.origin
			# A dump-in that does not get the puck deeper than we already are is
			# not a dump-in; it is a giveaway in the neutral zone.
			if goal_dir * (spot.z - origin.z) <= 0.0:
				continue
			# The keeper is a body in this race, and on the doorstep he is the
			# only one in it (see keeper_collects_first): a puck he collects is
			# not a dump-in at any pace, so the delivery is simply unavailable.
			if keeper_collects_first(spot, keeper_pos, our_chasers,
					SKATER_REF_SPEED_M_S):
				continue
			# What the spot is worth if we win it OUTRIGHT. Recovery is a
			# probability, so this is the candidate's ceiling and a spot whose
			# ceiling already loses cannot win at any odds — an exact prune, and
			# the one that keeps the pace ladder affordable now that the race
			# below is an arrival solve per chaser rather than a distance.
			var ceiling: float = position_potential(spot, attacking_goal, opp_chasers) \
					* potential_realization_discount(spot, attacking_goal)
			if ceiling <= best_score:
				continue
			# The race is run to where the puck STOPS, over the time the puck
			# spends getting there — chasers are not frozen while it travels,
			# and a longer flight is exactly what a forecheck converts into
			# position.
			var recovery: float = chase_recovery(
					spot, our_chasers, opp_chasers, our_vels, opp_vels)
			var score: float = recovery * ceiling
			if score > best_score:
				best_score = score
				best_spot = spot
				best_vel = vel
	out_landing[0] = best_spot
	return best_vel
