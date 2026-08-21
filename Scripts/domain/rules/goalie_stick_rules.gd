class_name GoalieStickRules

# The goalie's STICK — geometry, aim, and what it covers. Pure/static and
# engine-free: the pose builder (GoalieBodyConfigBuilder) and the bot planner
# both read from here, so the stick they each believe in cannot diverge.
#
# ── What the stick actually does (measured, not assumed) ─────────────────────
# tests/unit/ai/test_goalie_low_cover.gd sweeps flat shots for the point where
# saves stop. Against a standing keeper, with the blade seated on the ice:
#   * the BLOCKER side — the side the stick covers — is shut at every range
#     tested, 3 m to 12 m, out to the post;
#   * the GLOVE side is shut at 3, 5 and 12 m and leaks at 7 m (0.15 m from his
#     plane) and 9 m (0.16). Those two are the pad and glove's, not the stick's:
#     both rows record no blade contact on that side at all.
# So the stick — not the pads — is the primary LOW surface while he is upright.
# The pad column alone is 0.36 m; the stick takes the silhouette to ~0.62 m.
#
# WHERE it covers, measured from real contact positions (not derived): the blade
# takes a FIXED band of roughly +/-0.22 m in the goalie's local x, straddling the
# midline, at every range tested. It does not range out to the posts — the outer
# aim points are PAD saves. That matches the reported feel ("five-hole-ish and to
# the blocker side"), with one caveat: the measured band reaches ~0.22 m onto the
# GLOVE side of centre, which is further across the body than a real paddle held
# in the blocker hand should reach. The blade sits closer to centred than
# blocker-side.
#
# NOTE the goalie is rotated ~180 deg, so local +x (blocker side) is world -x.
# Any table of world-frame contact positions reads mirrored.
#
# A caution on the reach number below: an apparent full-width wall in tight is
# ANGLE COMPRESSION, not stick reach. From 3 m the keeper stands 1.68 m out, so
# every aim from post to post crosses his plane inside +/-0.20 m and meets the
# same fixed band.
#
# ── The reach is DERIVED, not declared ───────────────────────────────────────
# `standing_lateral_reach()` falls out of the blade's own geometry: where the
# assembly can put the blade centre at the yaw cap, plus the blade's half-width.
# Change the collider box, the assembly offset or the yaw cap and the planning
# cover follows automatically.

# ── Geometry (mirrors Goalie.tscn; pinned by
# tests/unit/rules/test_goalie_scene_mirrors.gd) ─────────────────────────────
# StickBladeCollider is a 0.38 x 0.07 x 0.03 box. The width is what closes the
# five-hole; the height is why a BLADE save is an ice-level event. Note the
# paddle below, though: a lifted puck clears the blade but not necessarily the
# assembly, which stands 0.66 m. Lifting beats the stick only once the puck is
# genuinely above that by the time it reaches him.
# NHL Rule 10.2 sizes the goalkeeper's blade: at most 15.5 in heel to toe, 3.5 in
# tall, widening to 4.5 in at the heel, with 0.75 in of curve. The collider takes
# the 3.5 in standard height rather than the heel's bulge, which is a local
# thickening right at the paddle and sits inside the paddle's own box anyway.
const BLADE_WIDTH_M: float = 0.38
const BLADE_HEIGHT_M: float = 0.089
# Mesh-only, and the two the collider cannot express: a single box has one height
# and no bow. StickBladeMeshBuilder takes both.
const BLADE_HEEL_HEIGHT_M: float = 0.108
const BLADE_CURVE_DEPTH_M: float = 0.019
# The blade's thickness, which matters only once the face is turned: an open face
# swings part of it into the vertical, and the seating solve projects all three
# extents. Mirrored from the scene like the other two.
const BLADE_THICKNESS_M: float = 0.03

# The PADDLE — the shaft's lower section, StickPaddleCollier, a 0.10 x 0.66
# box standing between the wrist and the blade. Narrow, so it adds nothing to
# the lateral cover the blade already sets; what it adds is HEIGHT, and that
# is not cosmetic. It means the stick is NOT the ice-level-only surface the
# blade alone suggests: there is two thirds of a metre of it in the way, all
# of it below the 0.86 m pad-top seam and therefore inside the planner's LOW
# band.
#
# The consequence is a timing one, which is why it is recorded here rather
# than turned into a cover term. A lofted arc solved to clear the seam AT THE
# GOAL LINE is still climbing when it passes the keeper metres earlier — at
# 4 m it crosses his plane around 0.57 m, i.e. inside this box — so it reads
# as a top-corner shot and arrives as a stick save. AIActionScoring's
# _high_band_horizontal_speed therefore takes the band clearance at the
# KEEPER'S plane, not the net's.
const PADDLE_WIDTH_M: float = 0.10
const PADDLE_HEIGHT_M: float = 0.66

# Blade offset from the BlockArm assembly origin, which is the HAND — the
# BlockerHand mesh and the blocker pad both sit on it. The drop is therefore the
# grip-to-blade lever, and it is the paddle's own length because the hand grips
# the paddle's top: Goalie.tscn puts Stick at the BlockArm origin, the paddle
# spanning 0.66 m below it and the shaft above. test_goalie_scene_mirrors holds
# the chain.
const ASSEMBLY_LATERAL_M: float = -0.15
const ASSEMBLY_DROP_M: float = 0.67

# Roll of the blade about its own long axis, authored LEVEL — a blade rolled off
# level rests on one end, which is the heel-down habit every goalie coach warns
# about. It is a constant rather than an assumed zero because blade_basis needs
# the scene's authored value to compose, and because the seating solve is more
# sensitive to it than to anything else: 0.19 m of half-width tipped 13° was more
# vertical span than the whole 0.07 m box height. Whatever tips the blade in play
# is the assembly's own roll, which is a pose, not the stick.
const BLADE_TOE_CANT_DEG: float = 0.0

# ── The lie angle ────────────────────────────────────────────────────────────
# THE LIE IS THE STICK'S, NOT A TUNING KNOB. A goalie stick's lie number is the
# angle between the paddle and the blade — where the paddle sits when the blade
# is flat on the ice. Intermediate and senior goalie sticks run 13-15 on the
# standard scale (two degrees a step off the 135° that is a player's lie 5),
# putting a senior stick near 117°: markedly more L-shaped than a player's,
# which is what lets a keeper hold the blade flat with his hand low.
#
# ONE HONEST CAVEAT ABOUT THE PLANE. A real stick's bend is in the paddle-blade
# plane, and on this rig that plane is LATERAL — the blade's long axis runs
# across the goalie. So a literal lie would swing the blade sideways, not out in
# front, and what puts our blade ahead of the pads is the assembly's forward
# tilt. This number is the fixed paddle-to-blade angle applied in THAT plane
# instead: same role — the offset that lets the blade lie flat while the paddle
# is angled — and the same magnitude, because "how far the paddle leans when the
# blade is flat" is the quantity either plane needs.
#
# Everything else about the stick's pose follows from it. The blade is flat when
# the paddle stands PADDLE_TO_BLADE_DEG - 90 off vertical, which is what
# flat_blade_tilt_deg returns and what the stance tilts are solved against.
const PADDLE_TO_BLADE_DEG: float = 117.0

# The blade's fixed rotation relative to the paddle, applied once in
# Goalie._apply_blade_lie. Negative because the assembly's forward tilt is
# positive: at tilt φ the blade's face sits at φ + BLADE_LIE_DEG off vertical,
# so the blade comes flat exactly at φ = flat_blade_tilt_deg().
#
# Why it exists at all: Goalie.tscn hangs the blade COLLINEAR with the shaft, so
# without a lie the only way to reach the ice is to lay the whole stick over,
# which points the blade's broad face down and turns every low shot into a
# reflection off its UNDERSIDE — down and goalward, measured (0,0,-26) →
# (+1.4,-12.7,-20.8), eight own goals in 72 in-tight shots. The stick is the one
# surface GoalieSaveRules never deadens, so every blade contact is live.
#
# It does NOT move the blade centre (a CollisionShape3D rotates about its own
# origin), so blade_center_x and standing_lateral_reach still describe the posed
# stick.
const BLADE_LIE_DEG: float = -(PADDLE_TO_BLADE_DEG - 90.0)

# Yaw cap for active blade intent — how far the assembly may swing the blade
# toward a threat before the rigidly-attached blocker pad comes off the body.
# ── The blade's curve ────────────────────────────────────────────────────────
# How far the blade's face is turned in plan — about the blade's HEIGHT axis, so
# the toe leads and the face looks off to one side rather than straight up-ice.
#
# IT IS THE CURVE'S MEAN FACE ANGLE, AND IT IS DERIVED. A curved blade has no
# single face direction: the normal rotates along its length, so heel and toe
# send pucks on different bearings. One flat box cannot fan like that, and this
# is the one plane closest to the surface a real blade presents.
#
# The mean falls out of the bow with no curve left over. For a bow of d·u^p over
# a chord of L the face angle at u is atan(d·p·u^(p-1)/L), and the mean of
# p·u^(p-1) across the blade is exactly 1 for any p — so the mean face angle is
# atan(d/L), whatever the pattern's character. At the rulebook's 0.75 in of curve
# over a 15 in blade that is under three degrees.
#
# IT WAS 18, WHICH IS SIX TIMES THE REAL FIGURE, and it showed: at 18 the toe sat
# 11.7 cm out of the paddle's plane, so the blade read as skewed across the stick
# rather than running out of it. That was buying rebound steer by cheating the
# geometry, and the geometry is visible. A real blade steers a few degrees, and
# this now says so.
#
# Do not confuse it with the "Open"/"Closed" face angle a pattern also
# advertises — that one is loft, about the long axis, and BLADE_LIE_DEG owns it.
#
# It is the blade's, not the pose's, which is what makes it safe: a rotation
# about the joint does not move the blade's reach or its cover, the same argument
# BLADE_LIE_DEG makes. Steering with the assembly YAW instead turns the face by
# swinging the whole stick sideways and pays for every degree in cover.
static func blade_curve_face_deg() -> float:
	return rad_to_deg(atan(BLADE_CURVE_DEPTH_M / BLADE_WIDTH_M))

const ACTIVE_YAW_CAP_DEG: float = 25.0
# The yaw extremes standing_lateral_reach probes. A const rather than a literal
# in the loop header, which would allocate an Array per call.
const _REACH_PROBE_YAWS: Array[float] = [-ACTIVE_YAW_CAP_DEG, 0.0, ACTIVE_YAW_CAP_DEG]

# Blocker wrist lateral offset in the READY stance (GoalieBodyConfigBuilder's
# `c.blocker_pos.x`). READY rather than STANDING because a keeper set on a
# shooter is the state the planning cover describes; STANDING's 0.38 wrist puts
# the derived reach at 0.58 m instead of 0.64 m, both inside the measured band.
const READY_WRIST_X_M: float = 0.44
# Assembly roll in the upright stances (`c.blocker_rot.z`). It matters here
# because it shortens the wrist-to-blade lever: the lateral offset rolls partly
# into the vertical, so the blade hangs less far below the hand than
# ASSEMBLY_DROP_M alone says. See blade_offset_at_roll.
const READY_ROLL_DEG: float = -20.0


# The blade CENTRE's offset from the wrist, assembly-local and before any stance
# rotation. Constant, and NOT simply (ASSEMBLY_LATERAL_M, -ASSEMBLY_DROP_M):
# Goalie._seat_blade hangs the blade from its HEEL so the lie and the curve pivot
# at the joint, which swings the centre off the authored point — including out of
# the assembly's plane, since the curve turns the blade in plan. Everything that
# needs to know where the blade IS goes through here, or it is describing a blade
# that pivots somewhere the rig does not.
static func blade_centre_offset() -> Vector3:
	var heel := Vector3(
			ASSEMBLY_LATERAL_M + BLADE_WIDTH_M * 0.5, -ASSEMBLY_DROP_M, 0.0)
	var blade := Basis.from_euler(Vector3(
			deg_to_rad(BLADE_LIE_DEG), deg_to_rad(blade_curve_face_deg()),
			deg_to_rad(BLADE_TOE_CANT_DEG)), EULER_ORDER_YXZ)
	return heel + blade * Vector3(-BLADE_WIDTH_M * 0.5, 0.0, 0.0)


# Horizontal offset of the blade centre from the wrist at forward tilt `φ`:
# (lateral, forward). The drop below the wrist rotates into forward reach as the
# stick tilts down onto the ice.
static func blade_offset_from_wrist(tilt_deg: float) -> Vector2:
	var c: Vector3 = blade_centre_offset()
	var t: float = deg_to_rad(tilt_deg)
	return Vector2(c.x, c.y * sin(t) + c.z * cos(t))


# The assembly yaw (degrees, clamped to `max_yaw_deg`) that lands the BLADE on
# the wrist→target line — closed-loop aim rather than pointing the assembly in
# the puck's general direction. Godot's YXZ Euler order applies the Y yaw around
# the tilted offset, so the solve is
#   yaw = angle(wrist→target) − angle(blade offset at yaw 0).
# Angle convention matches the goalie reach math: A(v) = atan2(−v.x, −v.z), so
# positive yaw carries local −Z toward −X. All coordinates are goalie-local.
static func yaw_to_target(wrist_x: float, wrist_z: float,
		target_x: float, target_z: float,
		tilt_deg: float, max_yaw_deg: float) -> float:
	var tx: float = target_x - wrist_x
	var tz: float = target_z - wrist_z
	if tx * tx + tz * tz < 0.0004:
		return 0.0  # target at the wrist — direction undefined, hold neutral
	var b: Vector2 = blade_offset_from_wrist(tilt_deg)
	if b.length_squared() < 0.0004:
		# Assembly offset degenerate — the blade sits ON the wrist, so there is no
		# lever for yaw to swing. NOTE this is not the zero-tilt case: at zero tilt
		# the blade still hangs ASSEMBLY_LATERAL_M to the side, so yaw still moves it.
		return 0.0
	var desired: float = atan2(-tx, -tz)
	var base: float = atan2(-b.x, -b.y)
	return clampf(rad_to_deg(angle_difference(base, desired)), -max_yaw_deg, max_yaw_deg)


# Lateral position of the blade CENTRE for a wrist at `wrist_x`, at tilt `φ` and
# yaw `θ` — the assembly offset rotated about Y and added to the wrist.
static func blade_center_x(wrist_x: float, tilt_deg: float, yaw_deg: float) -> float:
	var b: Vector2 = blade_offset_from_wrist(tilt_deg)
	var t: float = deg_to_rad(yaw_deg)
	return wrist_x + b.x * cos(t) + b.y * sin(t)


# THE planning number: how far off centre the standing/ready keeper's stick
# covers, as a half-width — the furthest the blade's outer edge can reach once
# the aim solve has swung it as far toward the threat as the yaw cap allows.
#
# Derived, so it tracks the geometry above. Verified against the live goalie by
# tests/unit/ai/test_goalie_low_cover.gd, which brackets the true standing reach
# at 0.59-0.64 m; this returns ~0.64.
static func standing_lateral_reach() -> float:
	var best: float = -INF
	# The cap is the extreme, but which SIGN of yaw reaches furthest depends on
	# the assembly offset's own lateral sign, so try both rather than assume.
	for yaw: float in _REACH_PROBE_YAWS:
		best = maxf(best, blade_center_x(READY_WRIST_X_M, ready_tilt_deg(), yaw))
	return best + BLADE_WIDTH_M * 0.5


# ── Where the stick sits, solved rather than declared ──────────────────────
# Coaching's first instruction about a goalie stick is that the blade is flat on
# the ice, a foot in front of the skates, and never resting on its heel. That is
# not a pose choice — for a rigid stick it is a CONSTRAINT: the blade hangs a
# fixed distance below the hand, so where the hand is decides the paddle's angle,
# and the lie decides whether the blade lands flat when it gets there. These
# three solve that constraint, and the four hand-picked stance tilts that used to
# stand in for it are gone.

# The paddle angle off vertical at which the blade lies flat on the ice. A
# property of the stick, not of the stance.
static func flat_blade_tilt_deg() -> float:
	return PADDLE_TO_BLADE_DEG - 90.0


# The blade centre's offset with the assembly's roll `ψ` applied but not its
# tilt — the part of the drop that does not depend on what the solve below is
# solving for. Roll matters because it swings part of the lateral offset into the
# vertical, so the blade hangs less far below the hand than the raw drop says.
static func blade_offset_at_roll(roll_deg: float) -> Vector3:
	return Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(roll_deg)), EULER_ORDER_YXZ) \
			* blade_centre_offset()


# How far below the wrist the blade centre sits at a full stance pose.
static func blade_centre_drop(tilt_deg: float, roll_deg: float) -> float:
	var w: Vector3 = blade_offset_at_roll(roll_deg)
	var t: float = deg_to_rad(tilt_deg)
	return -(w.y * cos(t) - w.z * sin(t))


# The blade's world orientation at an assembly pose, which is the whole stick's
# rigidity written down: the arm's tilt and roll composed with the blade's own
# fixed lie, face angle and authored cant. The arm's YAW is deliberately absent —
# it turns the blade in the horizontal plane and cannot change how tall it
# stands, which is all this is used for.
static func blade_basis(tilt_deg: float, roll_deg: float) -> Basis:
	var arm := Basis.from_euler(Vector3(
			deg_to_rad(tilt_deg), 0.0, deg_to_rad(roll_deg)), EULER_ORDER_YXZ)
	var blade := Basis.from_euler(Vector3(
			deg_to_rad(BLADE_LIE_DEG), deg_to_rad(blade_curve_face_deg()),
			deg_to_rad(BLADE_TOE_CANT_DEG)), EULER_ORDER_YXZ)
	return arm * blade


# Half the blade's vertical span at that pose — so "blade centre at this height"
# and "blade's low edge on the ice" are the same statement. The box's three half
# extents projected onto vertical, exactly, because approximating it is how the
# blade ends up under the ice: the 0.38 m long axis is ten times the box height,
# so every degree that tips or turns it moves the low edge more than the height
# itself contributes.
static func blade_half_span_at(tilt_deg: float, roll_deg: float) -> float:
	var b: Basis = blade_basis(tilt_deg, roll_deg)
	return absf(b.x.y) * 0.5 * BLADE_WIDTH_M \
			+ absf(b.y.y) * 0.5 * BLADE_HEIGHT_M \
			+ absf(b.z.y) * 0.5 * BLADE_THICKNESS_M


# The forward tilt that lands the blade on the ice for a hand at `wrist_y` above
# it. Never LESS than flat: a stick does not rotate past the ice, and a keeper
# raising his blocker lifts the blade off rather than cocking his wrist under it,
# so a hand too high for the lever holds the flat pose and the blade hangs clear.
# The span depends on the tilt and the tilt on the span, so it is solved by
# iteration rather than in closed form. It converges immediately — the span moves
# by millimetres across the whole tilt range — and three passes is the belt and
# braces version of two.
static func tilt_for_blade_on_ice(wrist_y: float, roll_deg: float) -> float:
	var flat: float = flat_blade_tilt_deg()
	# drop(φ) = -w.y·cos φ + w.z·sin φ, which is R·cos(φ - α) — so the solve is
	# still one acos, just about α rather than zero. The z term is the curve's:
	# it turns the blade in plan, which puts the centre out of the assembly plane.
	var w: Vector3 = blade_offset_at_roll(roll_deg)
	var r: float = sqrt(w.y * w.y + w.z * w.z)
	if r < 0.01:
		return flat
	var alpha: float = atan2(w.z, -w.y)
	var tilt: float = flat
	for _i: int in 3:
		var c: float = clampf(
				(wrist_y - blade_half_span_at(tilt, roll_deg)) / r, -1.0, 1.0)
		tilt = maxf(flat, rad_to_deg(alpha + acos(c)))
	return tilt


# The inverse, and the reason the upright stances no longer pick a hand height:
# for the blade to be BOTH flat and down, the hand can only be here. A keeper
# standing taller than this is one whose blade rides on its heel.
static func wrist_y_for_flat_blade_on_ice(roll_deg: float) -> float:
	var flat: float = flat_blade_tilt_deg()
	return blade_half_span_at(flat, roll_deg) + blade_centre_drop(flat, roll_deg)


# The tilt the planning cover is measured at — the ready stance's, solved from
# the hand height that stance's own geometry forces.
static func ready_tilt_deg() -> float:
	return tilt_for_blade_on_ice(
			wrist_y_for_flat_blade_on_ice(READY_ROLL_DEG), READY_ROLL_DEG)


# ── The lunge: a STRIKE, and therefore the last resort ───────────────────────
# Is the forward jab the only thing that gets the blade to the puck?
#
# The three stick actions differ by how much of himself the goalie commits, not
# by distance: the mild yaw is free, a sweep extends the arm and is recoverable,
# and the lunge throws the whole assembly forward and leaves him FULLY UNSET
# while extended (GoalieController._movement_read_delay prices exactly that,
# modelling the coaching heuristic that a missed committed poke concedes roughly
# two goals per save). So the lunge is a gamble, and a gamble is only worth
# taking when the alternative is not reaching at all.
#
# Two physical quantities, no threshold: he jabs when the blade cannot reach from
# where it is, and CAN reach if it commits. Beyond that the jab does not get
# there either, so it is pure cost — a goalie flailing at a puck he was never
# going to touch.
#
# Distances are BLADE-to-puck, which is also the boundary a shooter actually
# feels; a goalie-to-puck gate would instead slide with his challenge depth.
static func lunge_is_the_only_reach(blade_to_puck_m: float, poke_radius_m: float,
		lunge_extension_m: float) -> bool:
	if blade_to_puck_m <= poke_radius_m:
		return false   # already on it — the jab buys nothing and costs the read
	return blade_to_puck_m <= poke_radius_m + lunge_extension_m


# What is left of a five-hole slot `gap_m` wide once the paddle is lying across
# it. The blade is nearly twice the standing slot (0.38 vs ~0.20 m) and stays
# over the slot centre even yawed to the cap, so standing this closes outright —
# leaving the five-hole as the DOWN goalie's slide leak, which is what it
# physically is.
static func five_hole_gap_after_blade(gap_m: float) -> float:
	return maxf(0.0, gap_m - BLADE_WIDTH_M)
