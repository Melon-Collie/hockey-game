class_name GoalieStickRules

# The goalie's STICK — geometry, aim, and what it covers.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# The stick was the one part of the goalie with no owner. Its geometry lived in
# Goalie.tscn (collider boxes), its aim solve and per-stance tilts lived in
# GoalieBodyConfigBuilder (application layer, next to pose transforms), and the
# planning model did not know it existed AT ALL — every `stick` in
# action_scoring.gd was LANE_DEFENDER_REACH_M, a SKATER's blade in a passing
# lane. So the bots planned against a keeper with pads and hands and no stick.
#
# That cost a +1.00 shot-value error across the whole slot: the planner read the
# low corners and the five-hole off pad geometry, found daylight, and rated a
# flat corner near-certain, while the live keeper stick-saved 24/24 of them
# (tests/unit/ai/test_slot_shot_value_truth.gd). It is the clearest case in the
# goalie of a MISSING PERCEPTION rather than a mis-tuned number — no constant
# was wrong, a body part was absent.
#
# ── What the stick actually does (measured, not assumed) ─────────────────────
# tests/unit/ai/test_goalie_low_cover.gd sweeps flat shots for the point where
# saves stop. Against a standing keeper:
#   * inside 7 m NOTHING scores at any aim point, out to the post, either side;
#   * at 9 m the edge is 0.65 m from his plane, at 12 m 0.62 m.
# So the stick — not the pads — is the primary LOW surface while he is upright.
# The pad column alone is 0.36 m; the stick takes the silhouette to ~0.64 m.
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
# cover follows automatically — which is the point, since the drift between the
# posed stick and the planned stick is exactly the bug this file closes.
#
# Pure/static and engine-free: the pose builder and the bot planner both read
# from here, so the stick they each believe in cannot diverge again.

# ── Geometry (mirrors Goalie.tscn) ───────────────────────────────────────────
# StickBladeCollider is a 0.38 x 0.07 x 0.03 box. The width is what closes the
# five-hole; the height is why a BLADE save is an ice-level event. Note the
# paddle below, though: a lifted puck clears the blade but not necessarily the
# assembly, which stands 0.66 m. Lifting beats the stick only once the puck is
# genuinely above that by the time it reaches him.
const BLADE_WIDTH_M: float = 0.38
const BLADE_HEIGHT_M: float = 0.07

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

# Blade offset from the BlockArm assembly origin, assembly-local (keep in sync
# with Goalie.tscn: Stick at y −0.25, StickBladeCollider at (−0.15, −0.67, 0)
# inside Stick → blade centre ≈ (−0.15, −0.92, 0) below the wrist).
const ASSEMBLY_LATERAL_M: float = -0.15
const ASSEMBLY_DROP_M: float = 0.92

# Forward tilt per stance (X rotation on the blocker assembly), which swings the
# below-wrist offset FORWARD onto the ice.
const TILT_STANDING_DEG: float = 22.0
const TILT_READY_DEG: float = 22.0
const TILT_BUTTERFLY_DEG: float = 72.0   # hand y=0.49 → ~72°, near-flat
const TILT_RVH_DEG: float = 65.0

# ── The lie angle ────────────────────────────────────────────────────────────
# The fixed angle between the blade and the shaft. Every real stick has one; the
# authored geometry has none — Goalie.tscn hangs the blade at (−0.15, −0.67, 0)
# inside Stick, essentially straight below the wrist and COLLINEAR with the
# shaft, so the blade's face is whatever the shaft's tilt makes it.
#
# What that cost: the tilts above are solved to swing the blade down to the ice,
# and with a collinear blade the only way to get there is to lay the whole stick
# over (hence the butterfly's 72°). At 72° the blade's broad face ends up pointing
# nearly straight DOWN — measured face normal (−0.15, −0.95, −0.27). The stick is
# the one surface GoalieSaveRules never deadens, so every blade contact is a live
# reflection off whichever face the sweep picks; face-down, the reachable surfaces
# are the heel and the UNDERSIDE, and an underside normal reflects a shot down and
# GOALWARD. Measured: (0, 0, −26) → (+1.4, −12.7, −20.8), the goalie's own blade
# putting the puck in his net at 24 m/s, on 8 of 72 in-tight shots. The
# upward-facing side wedged the rest skyward at 10–21 m/s.
#
# The value is the shaft angle at which the face comes vertical, so it is the same
# quantity a stick's lie number encodes (~55° off vertical for a goalie stick).
# Swept over the in-tight grid it is also where the artifacts bottom out — own
# goals 8 → 1 and pop-ups 33 → 4, with the contact count unchanged at 71, so it
# removes the artifact without making him a better goalie.
#
# It does NOT move the blade centre (a CollisionShape3D rotates about its own
# origin), so blade_center_x and standing_lateral_reach are unaffected and the
# planner's cover number still matches the posed stick.
const BLADE_LIE_DEG: float = -55.0

# Yaw cap for active blade intent — how far the assembly may swing the blade
# toward a threat before the rigidly-attached blocker pad comes off the body.
const ACTIVE_YAW_CAP_DEG: float = 25.0
# The yaw extremes standing_lateral_reach probes. A const rather than a literal
# in the loop header, which would allocate an Array per call.
const _REACH_PROBE_YAWS: Array[float] = [-ACTIVE_YAW_CAP_DEG, 0.0, ACTIVE_YAW_CAP_DEG]

# Blocker wrist lateral offset in the READY stance (GoalieBodyConfigBuilder's
# `c.blocker_pos.x`). READY rather than STANDING because a keeper set on a
# shooter is the state the planning cover describes; STANDING's 0.38 wrist puts
# the derived reach at 0.58 m instead of 0.64 m, both inside the measured band.
const READY_WRIST_X_M: float = 0.44


# Horizontal offset of the blade centre from the wrist at forward tilt `φ`:
# (lateral, forward). The drop below the wrist rotates into forward reach as the
# stick tilts down onto the ice.
static func blade_offset_from_wrist(tilt_deg: float) -> Vector2:
	return Vector2(ASSEMBLY_LATERAL_M, -ASSEMBLY_DROP_M * sin(deg_to_rad(tilt_deg)))


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
		# the blade still hangs ASSEMBLY_LATERAL_M to the side, so yaw still moves
		# it. (The comment this replaced claimed otherwise and was never true.)
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
	# _REACH_PROBE_YAWS is a const, not an inline literal: an Array literal in a
	# loop header is rebuilt on every call.
	# The cap is the extreme, but which SIGN of yaw reaches furthest depends on
	# the assembly offset's own lateral sign, so try both rather than assume.
	for yaw: float in _REACH_PROBE_YAWS:
		best = maxf(best, blade_center_x(READY_WRIST_X_M, TILT_READY_DEG, yaw))
	return best + BLADE_WIDTH_M * 0.5


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
# It was gated on `lunge_trigger_distance` (1.2 m, goalie-to-puck) instead, and
# the characterisation shows what that produced: the BLADE was already 0.15-0.24
# m from the puck — inside the 0.25 m poke radius — in every case where the lunge
# fired (tests/unit/ai/test_goalie_stick_engagement_curve.gd). He was spending
# his most expensive action precisely where his cheapest one was already touching
# the puck, and paying the unset-read penalty for nothing.
#
# Two physical quantities, no threshold: he jabs when the blade cannot reach from
# where it is, and CAN reach if it commits. Beyond that the jab does not get
# there either, so it is pure cost — a goalie flailing at a puck he was never
# going to touch.
#
# Distances are BLADE-to-puck, which is also the boundary a shooter actually
# feels. The old constant measured goalie-to-puck while he was challenging out,
# so its effective range was roughly double and slid with his depth.
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
