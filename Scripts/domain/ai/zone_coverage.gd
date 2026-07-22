class_name AIZoneCoverage

# D-zone coverage geometry — the shared evaluator behind the 5v5 DZONE roles
# (AIRoleZoneDefense), the defenseman's retreat bounds (AIRoleDefenseman) and
# the transition-exposure term's defensive anchors. Design:
# docs/5v5-ai-plan.md §3/§5; the numbers are the researched NHL hybrid
# ("man-on-man below the dots, zone above") mapped onto this rink.
#
# Model: five puck-relative RESPONSIBILITY AREAS (strong/weak D low, C in
# the slot, strong/weak W high), each with a breathing rest anchor — the
# structure collapses toward the house as the puck goes below the goal line
# and extends toward the points as it goes high. Within its area a defender
# soft-locks the most dangerous man (finish-danger read, the same
# measurement the house pin uses) and RELEASES HIM AT THE AREA BOUNDARY —
# the neighbor whose ice he enters inherits him. Exactly one role owns
# pressure on the puck at any time (pressure_owner) — "closest defender
# pressures, everyone else holds shape" falls out of the area split.
#
# All coordinates are world-space; "depth" is metres from the defended goal
# line INTO the zone (negative = behind the goal line). The strong side is
# the brain's hysteretic strong_x sign; lateral positions use u = s·x so
# the geometry mirrors automatically.

# ── The house (researched scoring-chance polygon: posts → dots → circle tops)
const HOUSE_DOT_X_M: float = 6.71          # end-zone dot lateral
const HOUSE_DOT_DEPTH_M: float = 6.1       # dots' depth off the goal line
const HOUSE_TOP_DEPTH_M: float = 10.7      # tops of the circles

# ── Area boundaries (depths off the goal line, lateral half-widths) ─────────
const LOW_ZONE_DEPTH_M: float = 8.0        # below this = the low battle ice
const NET_FRONT_HALF_WIDTH_M: float = 2.6  # net-front box lateral half-width
const NET_FRONT_DEPTH_M: float = 4.5       # net-front box depth
const SLOT_HALF_WIDTH_M: float = 4.3       # the slot corridor (circle gap)
const SLOT_TOP_DEPTH_M: float = 9.5        # ZONE_C's ceiling
# Boundary hysteresis for the soft-lock: an incumbent man is held this far
# past his area's edge before release, so a man skating the seam doesn't
# flicker between two defenders every tick.
const AREA_RELEASE_MARGIN_M: float = 1.0

# ── Breathing anchors ────────────────────────────────────────────────────────
# Rest posts per role at the neutral pose (puck mid-depth), and the collapse/
# extend poses the anchors interpolate toward as the puck depth moves.
const D_STRONG_REST_U_M: float = 2.0       # low-slot strong edge
const D_STRONG_REST_DEPTH_M: float = 3.0
const D_WEAK_REST_U_M: float = -0.8        # net-front, weak shade
const D_WEAK_REST_DEPTH_M: float = 2.0
const C_REST_U_M: float = 1.5              # mid-slot, strong shade
const C_REST_DEPTH_LOW_M: float = 4.5      # collapsed (puck below goal line)
const C_REST_DEPTH_HIGH_M: float = 6.5     # extended (puck at the point)
const W_STRONG_WALL_U_M: float = 8.5       # wall lane (neutral)
const W_STRONG_WALL_DEPTH_M: float = 9.5
const W_STRONG_SINK_U_M: float = 6.7       # collapsed: top of the strong circle
const W_STRONG_SINK_DEPTH_M: float = 10.7
const W_WEAK_SAG_U_M: float = -3.0         # collapsed: high-slot sag
const W_WEAK_SAG_DEPTH_M: float = 8.5
const W_WEAK_POINT_U_M: float = -4.5       # extended: loose on the weak point
const W_WEAK_POINT_DEPTH_M: float = 11.0
# Puck depths that bracket the collapse ↔ extend interpolation: fully
# collapsed when the puck is below the goal line, fully extended at the
# circle tops (the point threat).
const BREATHE_LOW_DEPTH_M: float = 0.0
const BREATHE_HIGH_DEPTH_M: float = HOUSE_TOP_DEPTH_M
# When the puck is at the point, the strong winger steps INTO the shot lane —
# this far up the puck→net line from the puck (block the lane, don't chase
# the body: the researched winger technique).
const SHOT_LANE_STEP_M: float = 3.0
const POINT_THREAT_DEPTH_M: float = 10.7   # puck deeper than this = "at the point"

# ── Defensive-responsibility anchors (plan §5 — one primitive, 3 consumers) ─
const D_HOME_U_M: float = 5.0              # a D's home post: dot lane at his blue line
const F_HOME_DEPTH_INTO_NZ_M: float = 4.0  # a forward's home post: high F3 ice


# Depth of `pos` off the defended goal line, into the zone (negative =
# behind the goal line). own_goal_z is the defended net's z (±GOAL_LINE_Z).
static func depth_of(own_goal_z: float, pos: Vector3) -> float:
	return GameRules.GOAL_LINE_Z - signf(own_goal_z) * pos.z


# Which zone role owns PRESSURE on a puck at `puck_pos` — exactly one owner
# per position, so the area split never double-commits (or zero-commits)
# on the carrier. Priority: the low battle beats the net-front box beats
# the slot beats the high halves.
static func pressure_owner(strong_x: float, own_goal_z: float,
		puck_pos: Vector3) -> int:
	var d: float = depth_of(own_goal_z, puck_pos)
	var u: float = strong_x * puck_pos.x
	# The box starts AT the goal line: behind the net is the battle D's ice.
	if d >= 0.0 and d < NET_FRONT_DEPTH_M \
			and absf(puck_pos.x) <= NET_FRONT_HALF_WIDTH_M:
		return AIRoleSlots.Slot.ZONE_D_WEAK
	if d < LOW_ZONE_DEPTH_M:
		# The low perimeter — corners, boards, behind the net — is the
		# puck-side D's battle regardless of which half it's on (the strong
		# side flips with the brain's hysteresis as the puck crosses).
		return AIRoleSlots.Slot.ZONE_D_STRONG
	if d < SLOT_TOP_DEPTH_M and absf(puck_pos.x) <= SLOT_HALF_WIDTH_M:
		return AIRoleSlots.Slot.ZONE_C
	if u >= 0.0:
		return AIRoleSlots.Slot.ZONE_W_STRONG
	return AIRoleSlots.Slot.ZONE_W_WEAK


# Whether `pos` is inside `slot`'s responsibility area, expanded by `margin`
# metres (pass AREA_RELEASE_MARGIN_M for the incumbent-man hysteresis).
# Areas deliberately overlap a little at the seams — a man on a boundary is
# briefly double-covered while he's passed off, which is the real handshake.
static func in_area(slot: int, strong_x: float, own_goal_z: float,
		pos: Vector3, margin: float = 0.0) -> bool:
	var d: float = depth_of(own_goal_z, pos)
	var u: float = strong_x * pos.x
	match slot:
		AIRoleSlots.Slot.ZONE_D_STRONG:
			# The whole low perimeter — corners, boards, behind the net, on
			# BOTH halves (the strong sign flips with the puck; whoever the
			# battle D is owns the low battle ice wherever it sits).
			return d < LOW_ZONE_DEPTH_M + margin
		AIRoleSlots.Slot.ZONE_D_WEAK:
			# The net-front box (in front of the goal line).
			return d >= -margin and d < NET_FRONT_DEPTH_M + margin \
					and absf(pos.x) <= NET_FRONT_HALF_WIDTH_M + margin
		AIRoleSlots.Slot.ZONE_C:
			# The slot corridor between the circles.
			return d >= NET_FRONT_DEPTH_M - margin and d < SLOT_TOP_DEPTH_M + margin \
					and absf(pos.x) <= SLOT_HALF_WIDTH_M + margin
		AIRoleSlots.Slot.ZONE_W_STRONG:
			# Strong half high (wall + point coverage). Closed at the center
			# seam (>=) so the halves overlap there — the handshake ice.
			return d >= LOW_ZONE_DEPTH_M - margin and u >= -margin
		AIRoleSlots.Slot.ZONE_W_WEAK:
			# Weak half from the house up (the whole weak side above the box).
			return d >= NET_FRONT_DEPTH_M - margin and u <= margin
		_:
			return false


# The role's breathing rest anchor for the current puck position. Anchors
# interpolate between the collapsed pose (puck below the goal line) and the
# extended pose (puck at the point) on the puck's depth, so the structure
# slides continuously instead of teleporting between stances.
static func anchor_of(slot: int, strong_x: float, own_goal_z: float,
		puck_pos: Vector3) -> Vector3:
	var own_dir: float = signf(own_goal_z)
	var d_p: float = depth_of(own_goal_z, puck_pos)
	# 0 = fully collapsed (puck at/below the goal line), 1 = fully extended.
	var t: float = clampf((d_p - BREATHE_LOW_DEPTH_M)
			/ (BREATHE_HIGH_DEPTH_M - BREATHE_LOW_DEPTH_M), 0.0, 1.0)
	match slot:
		AIRoleSlots.Slot.ZONE_D_STRONG:
			return _at(strong_x, own_goal_z, D_STRONG_REST_U_M, D_STRONG_REST_DEPTH_M)
		AIRoleSlots.Slot.ZONE_D_WEAK:
			return _at(strong_x, own_goal_z, D_WEAK_REST_U_M, D_WEAK_REST_DEPTH_M)
		AIRoleSlots.Slot.ZONE_C:
			return _at(strong_x, own_goal_z, C_REST_U_M,
					lerpf(C_REST_DEPTH_LOW_M, C_REST_DEPTH_HIGH_M, t))
		AIRoleSlots.Slot.ZONE_W_STRONG:
			# Point threat: step into the shot lane (a fraction up the
			# puck→net line) rather than body-chasing the point man.
			if d_p > POINT_THREAT_DEPTH_M:
				var our_net := Vector3(0.0, 0.0, own_goal_z)
				var to_net: Vector3 = our_net - puck_pos
				var lane_len: float = to_net.length()
				if lane_len > 0.001:
					return puck_pos + to_net * (SHOT_LANE_STEP_M / lane_len)
			# Otherwise breathe between the circle-top sink and the wall lane.
			return _at(strong_x, own_goal_z,
					lerpf(W_STRONG_SINK_U_M, W_STRONG_WALL_U_M, t),
					lerpf(W_STRONG_SINK_DEPTH_M, W_STRONG_WALL_DEPTH_M, t))
		AIRoleSlots.Slot.ZONE_W_WEAK:
			return _at(strong_x, own_goal_z,
					lerpf(W_WEAK_SAG_U_M, W_WEAK_POINT_U_M, t),
					lerpf(W_WEAK_SAG_DEPTH_M, W_WEAK_POINT_DEPTH_M, t))
		_:
			return Vector3(0.0, 0.0, own_goal_z)
	# (unreachable — every zone slot returns above)


# The most dangerous opponent inside `slot`'s area — the soft-lock target.
# Danger is the finish-if-fed read (score_shoot from the man's spot, goalie
# where it is, no field defenders — the same measurement the house pin and
# CONTAIN's lane gate use). `incumbent_pid` (last dispatch's man, -1 none)
# is tested against the area + release margin and wins ties, so the lock
# holds until the man genuinely leaves the ice this role owns. The carrier
# (`carrier_pid`) is excluded — pressure handles him.
static func most_dangerous_man_in_area(
		slot: int, strong_x: float, own_goal_z: float,
		snapshot: WorldSnapshot, team_id: int, team_id_by_peer: Dictionary,
		our_goalie_pos: Vector3, carrier_pid: int,
		incumbent_pid: int = -1) -> int:
	if snapshot == null:
		return -1
	var our_net := Vector3(0.0, 0.0, own_goal_z)
	var no_defenders: Array[Vector3] = _scratch_no_defenders
	var best_pid: int = -1
	var best_danger: float = 0.0
	for pid: int in snapshot.skater_states:
		if pid == carrier_pid or team_id_by_peer.get(pid, -1) == team_id:
			continue
		var pos: Vector3 = snapshot.skater_states[pid].position
		var margin: float = AREA_RELEASE_MARGIN_M if pid == incumbent_pid else 0.0
		if not in_area(slot, strong_x, own_goal_z, pos, margin):
			continue
		# FIELDED finish-danger read (AIDangerField memoized core; no field
		# defenders, so the fielded value IS the core). Also aligns this read
		# with the threat family's derived post-seal — a dead-angle man walled
		# by the keeper's RVH/VH no longer out-dangers a live mid-ice man.
		var danger: float = AIActionScoring.score_shoot_threat_fielded(
				pos, our_net, our_goalie_pos, GameRules.NET_HALF_WIDTH,
				no_defenders)
		# Incumbent wins ties (>=); a challenger needs strictly more danger.
		if danger > best_danger or (pid == incumbent_pid and danger >= best_danger):
			best_danger = danger
			best_pid = pid
	return best_pid


# Defensive-responsibility anchor — where a player's defensive post is
# (plan §5: shared by the zone roles' geometry, the defenseman's retreat
# bounds, and the transition-exposure back-cover read). A defenseman's post
# is the dot lane at his own blue line; a forward's is the high (F3) ice
# just up-ice of it. `side_sign` is the player's home side (-1 = L, +1 = R,
# 0 = C/unknown → middle).
static func defensive_anchor(is_defense: bool, side_sign: float,
		own_goal_z: float) -> Vector3:
	var own_dir: float = signf(own_goal_z)
	if is_defense:
		return Vector3(side_sign * D_HOME_U_M, 0.0, own_dir * GameRules.BLUE_LINE_Z)
	return Vector3(side_sign * D_HOME_U_M, 0.0,
			own_dir * (GameRules.BLUE_LINE_Z - F_HOME_DEPTH_INTO_NZ_M))


# Shared empty-defenders array for the finish-danger reads (no per-call
# allocation; never mutated).
static var _scratch_no_defenders: Array[Vector3] = []


# World point at lateral u (strong-signed) and depth d in the defended zone.
static func _at(strong_x: float, own_goal_z: float, u: float, d: float) -> Vector3:
	var own_dir: float = signf(own_goal_z)
	return Vector3(strong_x * u, 0.0, own_dir * (GameRules.GOAL_LINE_Z - d))
