class_name AIRoleHelpers

# Shared helpers for off-puck role behaviors. Every role that picks
# a position via candidate-set argmax (SUPPORT, OUTLET, FINISHER, and
# the defensive roles PRESSURE / MARK / the rush layers) uses the
# same candidate generation, legality / anti-crowding filters, and
# context resolution. The role-specific differentiator is the
# scoring function — everything else lives here.

# Search radius around the anchor for polar candidate generation.
# Same scale as AIRoleCarrier.CARRY_SEARCH_STEP_M (3.0 m); roughly
# one brain-tick of travel at top skating speed. Sampling parameter,
# not a behavioral knob.
const SEARCH_STEP_M: float = 3.0

# Candidates within this distance of any teammate (excluding self)
# are filtered out — physical-overlap distance, prevents two
# teammates stacking on the same spot. Matches the blade-reach
# physical scale rather than an arbitrary "personal space" radius.
const ANTI_CROWD_RADIUS_M: float = 1.8

# Beyond this distance from a role's analytic station center, the candidate
# argmax refines between spots the bot cannot differentiate en route: the
# ring spans ±SEARCH_STEP_M, so from three ring-radii out the heading to
# "center" vs "refined spot" differs by under ~20°, and the role re-evals
# from closer long before arrival and re-refines there. Sampled roles
# collapse to their CALCULATED station until the refinement is consumable —
# the off-puck argmaxes are the whole off-puck AI bill, and most of the
# time each bot is skating toward its station, not standing on it.
const STATION_ARGMAX_LOD_M: float = SEARCH_STEP_M * 3.0


# True when the bot is close enough to its station center that the
# candidate argmax's refinement affects the path it actually skates.
static func station_needs_refinement(self_pos: Vector3, center: Vector3) -> bool:
	return self_pos.distance_squared_to(center) \
			< STATION_ARGMAX_LOD_M * STATION_ARGMAX_LOD_M

# Margin from the rink boards / goal lines that candidates are
# clamped inside of. Sampling parameter.
const RINK_INSET_M: float = 0.5
const GOAL_LINE_BUFFER_M: float = 1.0

# Pre-baked rotations for the 8 polar cardinal candidates.
const POLAR_ANGLES: Array[float] = [
		0.0, PI * 0.25, PI * 0.5, PI * 0.75,
		PI, -PI * 0.75, -PI * 0.5, -PI * 0.25,
]


# ── Candidate generation ─────────────────────────────────────────────────────

# Returns the standard 10-candidate set centered on `center`:
# `center` itself + `self_pos` (stand-still) + 8 polar samples
# around `center` at SEARCH_STEP_M. Every role picks its own search
# center from in-game references (the carrier, a man, our net).
#
# `with_inner_ring` appends 8 more polar samples at half step so the
# argmax can express small corrections instead of jumping in 3 m
# quanta — used by PRESSURE, whose chosen cut-off point is consumed
# directly as a steering target every dispatch (a coarser role that
# re-centers each brain tick doesn't need the resolution).
static func generate_candidates_around(self_pos: Vector3,
		center: Vector3, with_inner_ring: bool = false) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(center)
	result.append(self_pos)
	for angle: float in POLAR_ANGLES:
		result.append(Vector3(
				center.x + SEARCH_STEP_M * cos(angle),
				0.0,
				center.z + SEARCH_STEP_M * sin(angle)))
	if with_inner_ring:
		var inner: float = SEARCH_STEP_M * 0.5
		for angle: float in POLAR_ANGLES:
			result.append(Vector3(
					center.x + inner * cos(angle),
					0.0,
					center.z + inner * sin(angle)))
	return result


# Rejects candidates outside the playable rink, in either crease,
# or past either goal line. Common to every off-puck role.
static func is_legal_position(c: Vector3) -> bool:
	if absf(c.x) > GameRules.RINK_HALF_WIDTH - RINK_INSET_M:
		return false
	if absf(c.z) > GameRules.GOAL_LINE_Z - GOAL_LINE_BUFFER_M:
		return false
	if CreaseRules.is_in_crease(Vector2(c.x, c.z)):
		return false
	return true


# True if `c` is within ANTI_CROWD_RADIUS_M of any teammate position
# (callers should exclude self before passing the list, see
# `collect_teammates_excluding_self`).
static func too_close_to_teammate(c: Vector3,
		teammate_positions: Array[Vector3]) -> bool:
	var r2: float = ANTI_CROWD_RADIUS_M * ANTI_CROWD_RADIUS_M
	for tp: Vector3 in teammate_positions:
		var dx: float = c.x - tp.x
		var dz: float = c.z - tp.z
		if dx * dx + dz * dz < r2:
			return true
	return false


# ── Target switch-hysteresis ─────────────────────────────────────────────────
#
# Every off-puck positional role picks its spot by a candidate-set argmax. Along
# the argmax's tie ridge two spots trade the lead dispatch-to-dispatch on
# noise-level score differences, so the chosen target HOPS between them — and
# because the off-puck ready-stance cursor SNAPS to the role target (the FACE aim
# turns the body under facing_drag, but the blade IK chases the cursor with no
# slew), a per-dispatch hop whips the cosmetic blade ("blade jitter while just
# skating around").
#
# The fix is to steady the INTENT, not filter the symptom: give the incumbent
# spot (ctx.prev_role_target — last dispatch's chosen target, INF'd across a slot
# change so no role inherits another's) a stickiness bonus in the argmax, so a
# bot HOLDS its chosen spot and only switches when a fresh candidate is
# meaningfully — not marginally — better. That's how a real player commits to
# where they've decided to be. With a stable target the ready-stance cursor snaps
# to a fixed point and the downstream max_blade_speed clamp is the only smoother
# the blade needs.
#
# Mechanically the incumbent is injected as one extra candidate (append_incumbent)
# and scored by the role's OWN scoring — no separate re-score path — with
# incumbent_bonus() added to its score. It runs through the role's same legality
# / anti-crowd / role-specific filters, so a now-illegal or now-crowded incumbent
# is dropped outright rather than camped, and because it's re-scored live its edge
# decays as the play moves: the switch fires exactly when the geometry really
# changed, not on argmax noise.
#
# TARGET_SWITCH_MARGIN is in threat-surface units — the shared 0..1 currency of
# score_shoot / score_pass and the threat surfaces every off-puck role argmaxes
# over. Tuned on PRESSURE first; raise toward 0.08 if a role still wobbles
# between spots, lower toward 0.02 if it visibly camps a stale one. Feel tunable,
# hand-set.
const TARGET_SWITCH_MARGIN: float = 0.04


# Injects the incumbent role target (ctx.prev_role_target) into `candidates` so
# the role's argmax scores it alongside the fresh set. No-op when there's no
# incumbent (first dispatch, or a slot change INF'd it). Pair with incumbent_bonus
# in the scoring loop — see the switch-hysteresis note above.
static func append_incumbent(ctx: RoleContext, candidates: Array[Vector3]) -> void:
	if ctx.prev_role_target.is_finite():
		candidates.append(ctx.prev_role_target)


# The stickiness bonus a candidate earns for BEING the incumbent role target:
# TARGET_SWITCH_MARGIN when `c` is ctx.prev_role_target, else 0. Add it to the
# role's own score inside its argmax so the held spot only yields to a clearly-
# better fresh candidate. Exact-equality is safe: the incumbent is the same
# Vector3 append_incumbent injected (a coincidental fresh-candidate match just
# earns the same benefit-of-the-doubt at that identical spot).
static func incumbent_bonus(ctx: RoleContext, c: Vector3) -> float:
	if ctx.prev_role_target.is_finite() and c == ctx.prev_role_target:
		return TARGET_SWITCH_MARGIN
	return 0.0


# ── Defensive anticipation ───────────────────────────────────────────────────

# How far ahead (seconds) defensive roles lead an opponent's position when
# scoring threats, so they defend where the attack is GOING rather than the
# freeze-frame. Mirrors how PRESSURE already leads its search center off the
# carrier's velocity; this extends that anticipation to the receivers / men the
# other defensive roles cover.
const DEFENSIVE_ANTICIPATION_S: float = 0.3
# Clamp on the lead distance so a fast skater — or a momentary velocity spike on
# a curling route — can't drag a defender far off the man. Keeps anticipation a
# half-step nudge, not a commit to a phantom.
const DEFENSIVE_ANTICIPATION_MAX_M: float = 2.5


# Leads a threat position by its velocity over DEFENSIVE_ANTICIPATION_S, clamped
# to DEFENSIVE_ANTICIPATION_MAX_M. XZ only; y stays 0. `scale` is the difficulty
# pace knob (ctx.defensive_anticipation_scale): 1.0 = today, lower leads less so
# the defender sits a step behind the play (more space for the carrier).
static func lead_threat(pos: Vector3, vel: Vector3, scale: float = 1.0) -> Vector3:
	var anticipation_s: float = DEFENSIVE_ANTICIPATION_S * scale
	var lead_x: float = vel.x * anticipation_s
	var lead_z: float = vel.z * anticipation_s
	var l: float = sqrt(lead_x * lead_x + lead_z * lead_z)
	if l > DEFENSIVE_ANTICIPATION_MAX_M:
		var s: float = DEFENSIVE_ANTICIPATION_MAX_M / l
		lead_x *= s
		lead_z *= s
	return Vector3(pos.x + lead_x, 0.0, pos.z + lead_z)


# ── Man-on-threat coverage ───────────────────────────────────────────────────

# Slack on cover_man_target's goal-side filter: candidates may sit up to
# this far toward the play from the man (roughly even with him) but no
# further. Tight coverage must never trade the defensive side for lane
# denial — a defender ahead of his man is one burst from being beaten to
# the net. Goal-side is measured along the man→our-net LINE (the same
# projection the cover anchor and the threat partition use), not the Z
# axis: for a man wide of the net or near the goal-line-extended, "behind
# him in Z" and "between him and the net" point different ways, and the
# Z reading let the marker legally park BESIDE his man, off the sealing
# lane.
const COVER_GOAL_SIDE_TOLERANCE_M: float = 0.5

# Shared "cover this assigned man" target for the backline defenders
# (MARK) when TeamBrain's threat partition hands them a specific
# opponent. Picks the position that most deflates the carrier→man pass-threat
# surface (lane interception × the man's resulting shot), searching a candidate
# set centered on the threat partition's own cover anchor — a stick into the
# man→net lane (AIThreatAssignment.cover_anchor, COVER_DEPTH_M goal-side of
# him) — i.e. set up ON the man, in the feed lane, to kill the one-timer.
#
# The anchor must track the man 1:1. Centering the search anywhere that moves
# SLOWER than he does — a man/net midpoint being the tempting one — lets a
# cutting man walk away from his check every time, and sags the whole candidate
# set besides (a man 12 m out gets "covered" from 6 m away). cover_anchor is
# also the anchor the threat partition already scored reachability against, so
# the pairing and the coverage agree. The ±3 m candidate ring still lets the
# argmax shade off the body into the carrier→man lane when that deflates the
# threat more.
#
# Scoring the ASSIGNED man (rather than minimizing the max threat over ALL
# opponents) is what stops two defenders collapsing onto the single most
# dangerous opponent, since each gets a distinct man. Roles fall back to their
# all-opponents behavior when unassigned (man_pid -1).
static func cover_man_target(ctx: RoleContext, man_pos: Vector3,
		carrier_pos: Vector3) -> Vector3:
	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = resolve_our_goalie_pos(ctx)
	var teammates: Array[Vector3] = ctx.scratch_teammates
	collect_teammates_excluding_self(ctx, teammates)

	var search_center: Vector3 = AIThreatAssignment.cover_anchor(man_pos, our_net)
	var candidates: Array[Vector3] = generate_candidates_around(ctx.self_pos, search_center)
	# Switch-hysteresis: hold the covering spot unless a fresh one deflates the
	# feed clearly more (see TARGET_SWITCH_MARGIN).
	append_incumbent(ctx, candidates)

	# Goal-side axis: the man→our-net direction. A candidate is goal-side
	# when its projection onto this line from the man is positive (with the
	# tolerance slack) — i.e. it sits between the man and the net he
	# threatens, wherever on the ice that lane points.
	var to_net_x: float = our_net.x - man_pos.x
	var to_net_z: float = our_net.z - man_pos.z
	var to_net_len: float = sqrt(to_net_x * to_net_x + to_net_z * to_net_z)
	var has_lane: bool = to_net_len > 0.001
	if has_lane:
		to_net_x /= to_net_len
		to_net_z /= to_net_len

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	# Fallback across candidates that failed ONLY the goal-side filter —
	# used when a man parked against our goal line leaves no legal
	# goal-side spot (goal-line buffer + crease eat the ring), so the
	# defender still covers from the front instead of freezing.
	var fallback_pos: Vector3 = ctx.self_pos
	var fallback_score: float = -INF
	for c: Vector3 in candidates:
		if not is_legal_position(c):
			continue
		if too_close_to_teammate(c, teammates):
			continue
		# Carrier's view of defenders: our team + us hypothetically at c. Append
		# c to the shared teammates scratch in place and pop it after scoring —
		# a duplicate() per candidate (10×/decide) was pure hot-path churn. The
		# array is restored exactly, and too_close_to_teammate above already read
		# it candidate-free this iteration. The hypothetical body carries OUR
		# real caps so the threat prices this defender's actual blade.
		teammates.push_back(c)
		ctx.scratch_teammate_caps.push_back(ctx.caps_by_peer.get(ctx.peer_id))
		# Minimize the carrier's threat of feeding THIS man (lane × his shot).
		var threat: float = AIActionScoring.threat_surface_pass(
				carrier_pos, man_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, teammates, ctx.scratch_teammate_caps)
		teammates.pop_back()
		ctx.scratch_teammate_caps.pop_back()
		var score: float = -threat + incumbent_bonus(ctx, c)
		# Stay on the defensive side of the man: positive projection onto
		# the man→our-net line (see COVER_GOAL_SIDE_TOLERANCE_M). A man on
		# the net (no lane) disables the filter — any spot is "in front".
		var proj: float = (c.x - man_pos.x) * to_net_x + (c.z - man_pos.z) * to_net_z \
				if has_lane else 0.0
		if not has_lane or proj >= -COVER_GOAL_SIDE_TOLERANCE_M:
			if score > best_score:
				best_score = score
				best_pos = c
		elif score > fallback_score:
			fallback_score = score
			fallback_pos = c
	if best_score == -INF and fallback_score > -INF:
		return fallback_pos
	return best_pos


# THE stand for a defender who has been given somebody to cover — and the only
# one. Every off-puck defensive role in the game does this one job and differs
# only in WHO hands it the man: MARK gets him from the threat partition, the
# zone soft-lock from whoever is most dangerous in its area, TRACK_MID from
# whoever entered its lane, RUSH_D2 from whoever is driving the middle. Man
# defense and zone defense are the same behavior under different assigners.
#
# Returns false when there is no man to cover, or no play to cover him from,
# which is the caller's cue to fall back to its own post. A cover stand with
# nobody in it is not a stand — see the ride-velocity note below.
#
# The man's POSITION and his VELOCITY are read from one snapshot entry, so the
# point and the frame it rides cannot name different bodies. Three of the four
# call sites sourced them separately and each carried a comment worrying about
# exactly that; the worry is now structural.
#
# NO ANTICIPATION LEAD. The stand rides him (RoleDecision.target_velocity), so
# the route already carries his motion as a feed-forward, and aiming the anchor
# downrange as well double-counts it — the same defect the gap ladder and the
# backchecker's hip were fixed for, surviving in the four roles nobody revisited.
# Leading and riding together inflate the frame-relative gap by pace x lookahead:
# a defender covering from up to DEFENSIVE_ANTICIPATION_MAX_M further off his man
# the faster that man skates, which is backwards.
static func cover_threat(ctx: RoleContext, d: RoleDecision, man_pid: int,
		play_ref: Vector3) -> bool:
	if man_pid == -1 or ctx.snapshot == null \
			or not ctx.snapshot.skater_states.has(man_pid):
		return false
	if not play_ref.is_finite():
		return false
	var man: SkaterNetworkState = ctx.snapshot.skater_states[man_pid]
	d.target_position = cover_man_target(ctx, man.position, play_ref)
	d.target_velocity = man.velocity
	return true


# ── Closing the carrier: the angle ───────────────────────────────────────────

# How far to the INSIDE of the carrier→our-net line a defender who owns the
# carrier stands. The stand is deliberately NOT on that line: shading to the
# middle steers his retreat path toward the boards — take away the middle, give
# the outside. A defender sitting dead on the line offers both lanes equally,
# which is how a carrier walks straight into the slot.
const ANGLE_INSIDE_M: float = 1.5
# Lateral offset at which the shade reaches full depth — the end-zone dot lane.
# Inside the dots a carrier is still IN the middle and there is no outside to
# concede yet; at the dots the inside/outside split is real.
const ANGLE_INSIDE_FULL_X_M: float = GameRules.END_ZONE_FACEOFF_DOT_X
# The shade's depth for a carrier at `carrier_pos` — nil at centre ice, full at
# the dot lane and beyond.
#
# Scaling to zero at centre is load-bearing, not a taper for feel: a carrier in
# the middle has no inside to take away (both lanes are the same lane), so a
# fixed shade there has to pick a side arbitrarily and flips a full
# 2 x ANGLE_INSIDE_M the instant he crosses x = 0. That discontinuity lands
# exactly on the mid-lane drive. Where the sign is ambiguous the magnitude is
# nil, so the two sides meet continuously instead of needing damping.
static func inside_shade_m(carrier_pos: Vector3) -> float:
	return ANGLE_INSIDE_M * minf(
			absf(carrier_pos.x) / ANGLE_INSIDE_FULL_X_M, 1.0)


# Unit vector perpendicular to the carrier's retreat line, pointing toward the
# middle of the ice. ZERO when the carrier is dead centre — there is no inside
# to take, and no side to pick.
static func inside_dir(carrier_pos: Vector3, dir_net: Vector3) -> Vector3:
	var side: float = -signf(carrier_pos.x)
	if side == 0.0:
		return Vector3.ZERO
	var perp := Vector3(-dir_net.z, 0.0, dir_net.x)
	return perp if perp.x * side > 0.0 else -perp


# The stand for a defender who owns the carrier: `gap` metres up the carrier→our
# -net line, shaded to the inside. Shared by every role that closes a puck
# carrier — the rush gap (AIRoleRushD) and the in-zone pressurer
# (AIRolePressure) — so both defend him the same way and the TRANS_OD → DZONE
# handoff is not a change of doctrine. Falls back to the unshaded stand when the
# shade would put the body somewhere illegal.
static func carrier_stand(ap: AICarrierApproach, gap: float) -> Vector3:
	# Never project the stand past the net — the gap is a cushion in front of
	# him, and beyond his own route there is no ice to hold.
	var stand: Vector3 = ap.carrier_pos + ap.dir_net * minf(gap, ap.net_dist)
	var depth: float = inside_shade_m(ap.carrier_pos)
	if depth < 0.001:
		return stand
	var shaded: Vector3 = stand + inside_dir(ap.carrier_pos, ap.dir_net) * depth
	return shaded if is_legal_position(shaded) else stand


# Fills `out` with everything a defender needs about the carrier he owns, and
# reports whether there is a play to read at all. False means no puck anywhere —
# the caller holds, because there is nothing to close on.
#
# A LOOSE puck is a live read, not a failure: resolve_defensive_play_ref falls
# back to the puck itself, which is where the next play comes from and what a
# pressurer is closing on while a pass is in flight.
#
# `out.dir_net` is left ZERO when the carrier is on top of our net — the one case
# with no well-defined retreat line. Roles branch on that themselves rather than
# being handed a fabricated direction, because what to do there differs: the rush
# gap collapses onto him, the pressurer keeps its ring centred on him.
static func read_carrier_approach(ctx: RoleContext,
		out: AICarrierApproach) -> bool:
	var carrier_pos: Vector3 = resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		return false
	fill_approach(ctx, carrier_pos, resolve_play_ref_velocity(ctx), out)
	return true


# The same read against an EXPLICIT subject rather than the play reference. A
# loose puck running toward our end is approaching us exactly as a carrier is,
# and the stand you hold against it is the same stand — see AIRoleChase's
# pre-contain, which is this read on the puck itself. Split out because "go get
# the puck" is always about the PUCK, while resolve_defensive_play_ref answers
# with the carrier whenever one exists.
static func fill_approach(ctx: RoleContext, subject_pos: Vector3,
		subject_vel: Vector3, out: AICarrierApproach) -> void:
	out.carrier_pos = subject_pos
	out.carrier_vel = subject_vel
	var to_net: Vector3 = ctx.defending_goal_pos - subject_pos
	var dist: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
	out.net_dist = dist
	if dist < 0.001:
		out.dir_net = Vector3.ZERO
		out.closing = 0.0
		return
	out.dir_net = Vector3(to_net.x / dist, 0.0, to_net.z / dist)
	out.closing = maxf(
			subject_vel.x * out.dir_net.x + subject_vel.z * out.dir_net.z, 0.0)


# ── Going to get the puck ────────────────────────────────────────────────────

# The third defensive verb: nobody has it, so do I go?
#
# Returns TRUE when we are running the race — `d` gets the puck itself, and the
# state machine's CHASE_PUCK does the real retrieval (lead intercept, blade gate,
# contest drive-through) from there. This target is the hint it steers on until
# then.
#
# Returns FALSE when an opponent has already won it (loose_puck_race_lost, which
# also asks whether declining buys anything — a lost race is only worth declining
# when there isn't already a body home). `d` then gets the PRE-CONTAIN stand, and
# that stand is the closing verb applied to the puck: the gap ladder's distance
# goal-side of it, angled off the middle, with the puck's own closing speed
# toward our net standing in for a rush's pace. A puck still running at our end
# keeps the cushion; a dead settle is met tight.
#
# The angle is what makes the handoff exact rather than merely similar. This
# stand exists so the chaser who declines plants where RUSH_D1 will want to be
# the instant somebody collects and the state flips to TRANS_OD — and RUSH_D1's
# stand is angled, so an unangled pre-contain was a spot the gap defender then
# had to correct off, in the direction that concedes the middle.
static func chase_puck(ctx: RoleContext, d: RoleDecision) -> bool:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		d.target_position = ctx.self_pos
		return false
	var puck_pos: Vector3 = ctx.snapshot.puck_state.position
	if not loose_puck_race_lost(
			ctx.snapshot, ctx.self_pos, ctx.self_velocity, ctx.self_max_speed,
			ctx.team_id, ctx.team_id_by_peer, ctx.caps_by_peer, ctx.peer_id,
			ctx.own_goal_dir):
		d.target_position = puck_pos
		return true
	var ap: AICarrierApproach = ctx.scratch_carrier_approach
	fill_approach(ctx, puck_pos, ctx.snapshot.puck_state.velocity, ap)
	if ap.dir_net == Vector3.ZERO:
		d.target_position = puck_pos   # on our own goal line — just go
		return true
	d.target_position = carrier_stand(ap, AIRoleRushD.ladder_gap_m(
			puck_pos, ctx.own_goal_dir, ctx.self_blade_reach, ap.closing))
	return false


# ── Carrier-best-option (inverse scoring) ────────────────────────────────────

# Computes the opposing carrier's best option — shoot at our net, or pass to
# any of `opp_teammates` — with our hypothetical defender position `candidate`
# appended to the carrier's view of the defenders. The on-puck / rush
# defensive roles (PRESSURE's cut-off argmax, RUSH_D1's odd-man lane fan)
# argmax the NEGATION of this over their candidate sets: the spot that most
# deflates the carrier's best option wins.
#
# Uses the threat-surface helpers so the gradient survives when score_shoot /
# score_pass collapse to 0 (carrier far from net or all receivers far from
# net). The position_potential floor pulls the defender tight to the carrier
# in TRANS_OD scenarios where there's no immediate scoring threat to defend —
# without it the score is flat across goal-side candidates and the argmax
# picks arbitrarily.
#
# Coverage is CONTINUOUS by construction: `our_team_excluding_self` rides
# into both surfaces, so a teammate already on a receiver suppresses that
# pass threat and an uncovered receiver's threat stands — "who is really
# open" needs no separate boolean read.
# Per-decide upper bounds for carrier_best_option's early-out. Every threat
# surface is monotone NON-INCREASING in the defender set (an extra body can
# only block lanes, add pressure, shrink openness), so the option values with
# the CURRENT defenders only — no hypothetical candidate appended — bound the
# candidate-adjusted values from above. carrier_best_option evaluates terms
# in descending-bound order and stops the moment the running max meets the
# next bound: identical result, most pass surfaces never computed. Fill once
# per decide (out_bases[0] = shoot, [1..] = opp_teammates in order) and pass
# to every candidate's carrier_best_option call.
static func carrier_option_bases(
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3],
		out_bases: Array[float],
		our_team_caps: Array = []) -> void:
	out_bases.clear()
	out_bases.append(AIActionScoring.threat_surface_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self, our_team_caps))
	for opp_pos: Vector3 in opp_teammates:
		out_bases.append(AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self, our_team_caps))


static func carrier_best_option(
		candidate: Vector3,
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3],
		bases: Array[float] = [],
		our_team_caps: Array = [],
		self_caps: AISkaterCaps = null) -> float:
	# Carrier's view of defenders = our team + me at the candidate. This helper
	# is called once per candidate in PRESSURE's argmax (up to ~19×/decide), so
	# duplicating the array every call was pure hot-path churn. Append the
	# candidate to the caller's array in place and pop it before returning — the
	# array is left exactly as passed, and after the first call the backing
	# store keeps its capacity so the push/pop allocates nothing. The caps ride
	# alongside only when the caller supplied a matched array (the hypothetical
	# body carries OUR caps) — a mismatched/empty caps array stays untouched and
	# the surfaces fall back to league.
	var caps_matched: bool = our_team_caps.size() == our_team_excluding_self.size()
	our_team_excluding_self.push_back(candidate)
	if caps_matched:
		our_team_caps.push_back(self_caps)
	var best: float = 0.0

	if bases.size() == opp_teammates.size() + 1:
		# Pruned path (see carrier_option_bases): evaluate terms in
		# descending-bound order, stop when no remaining bound can beat the
		# running max. Exact — a skipped term's value ≤ its bound ≤ best.
		var used: int = 0
		while true:
			var bi: int = -1
			var bound: float = -1.0
			for i: int in bases.size():
				if used & (1 << i) == 0 and bases[i] > bound:
					bound = bases[i]
					bi = i
			if bi == -1 or bound <= best:
				break
			used |= 1 << bi
			var v: float
			if bi == 0:
				v = AIActionScoring.threat_surface_shoot(
						carrier_pos, our_net, our_goalie_pos,
						GameRules.NET_HALF_WIDTH, our_team_excluding_self,
						our_team_caps)
			else:
				v = AIActionScoring.threat_surface_pass(
						carrier_pos, opp_teammates[bi - 1], our_net, our_goalie_pos,
						GameRules.NET_HALF_WIDTH, our_team_excluding_self,
						our_team_caps)
			if v > best:
				best = v
		our_team_excluding_self.pop_back()
		if caps_matched:
			our_team_caps.pop_back()
		return best

	# Exact/unpruned path (no bases supplied — one-shot callers).
	# Carrier's best shot at our net (with positional fallback floor).
	var shoot_value: float = AIActionScoring.threat_surface_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self, our_team_caps)

	# Carrier's best pass to any teammate (with positional fallback).
	# `our_net` is the attacking goal from the carrier's perspective, so the
	# receiver's threat is evaluated against our goalie.
	var pass_value: float = 0.0
	for opp_pos: Vector3 in opp_teammates:
		var pass_score: float = AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self, our_team_caps)
		if pass_score > pass_value:
			pass_value = pass_score

	our_team_excluding_self.pop_back()
	if caps_matched:
		our_team_caps.pop_back()
	return maxf(shoot_value, pass_value)


# Rush variant of carrier_best_option, for RUSH_D1's odd-man lane fan: RAW xG
# threats (no position_potential floor) with each pass modeled as a ONE-TIMER
# feed — the goalie must traverse to the receiver's line over the pass flight
# and reads the release late (predict_goalie_pos + goalie_unsettled), which is
# exactly what makes the cross-crease feed the threat the 2-on-1 doctrine
# plays ("the goalie takes the shooter, I take the pass"). The carrier's
# direct shot is scored against the goalie where he IS — squared to the known
# shooter, the doctrine's other half.
#
# Why not the surfaced variant above: its position_potential floor exists to
# give PRESSURE close-in gradients, but across RUSH_D1's gap-distance fan the
# floor flattens (every candidate sits outside the pressure cone) and masks
# the reducible-threat comparison entirely; and a set-goalie pass read scores
# the one-timer feed near zero, hiding the very threat the fan exists to
# take away. Raw xG also ties at ~0 far from the net, so the fan's hold
# margin keeps the classic retreat line out there — the correct far-out read.
# `abort_above`: exact argmin pruning for RUSH_D1's lane fan — the caller
# MINIMIZES this value across candidates, so once the running best exceeds the
# incumbent's, the exact value cannot matter and the remaining (expensive,
# score_pass-heavy) receiver evaluations are skipped. Default INF evaluates
# everything.
static func carrier_live_option(
		candidate: Vector3,
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3],
		abort_above: float = INF,
		our_team_caps: Array = [],
		self_caps: AISkaterCaps = null) -> float:
	# Defenders = our team + me at the candidate. Append-and-restore the caller's
	# array in place instead of duplicating it — called once per candidate in
	# RUSH_D1's lane fan (up to ~13×/decide), so a fresh Array per call was pure
	# churn. The array is left exactly as passed; capacity is retained across the
	# push/pop so steady-state calls allocate nothing. Caps ride alongside only
	# when the caller supplied a matched array (the hypothetical body carries OUR
	# caps); otherwise the reads fall back to league.
	var caps_matched: bool = our_team_caps.size() == our_team_excluding_self.size()
	our_team_excluding_self.push_back(candidate)
	if caps_matched:
		our_team_caps.push_back(self_caps)
	var best: float = AIActionScoring.score_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, our_team_caps)
	for receiver: Vector3 in opp_teammates:
		if best >= abort_above:
			break
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, receiver)
		var flight_s: float = carrier_pos.distance_to(receiver) / maxf(pass_speed, 1.0)
		var pred_goalie: Vector3 = AIActionScoring.predict_goalie_pos(
				our_goalie_pos, our_net, flight_s, receiver)
		var unsettled: float = AIActionScoring.goalie_unsettled(
				our_goalie_pos, our_net, flight_s, receiver)
		var pass_value: float = AIActionScoring.score_pass(
				carrier_pos, receiver, our_net, pred_goalie,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self, pass_speed,
				unsettled, -1.0, Vector4.INF, Vector4.INF, our_team_caps)
		if pass_value > best:
			best = pass_value
	our_team_excluding_self.pop_back()
	if caps_matched:
		our_team_caps.pop_back()
	return best


# ── Body check ───────────────────────────────────────────────────────────────

# Evaluates whether the on-puck pressurer should commit to a body check on the
# live OPPONENT carrier this tick (AIBodyCheck), resolving the carrier from the
# snapshot. Returns a no-commit Result when the puck is loose, carried by a
# teammate, or absent — so only a real opponent carrier is ever a hit target.
# Used by PRESSURE (which also serves FORECHECK's F1), the pressurers that have
# support behind them; the last-man gap defender never calls this.
static func evaluate_body_check(ctx: RoleContext) -> AIBodyCheck.Result:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return AIBodyCheck.Result.new()
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1 or ctx.team_id_by_peer.get(carrier_pid, -1) == ctx.team_id:
		return AIBodyCheck.Result.new()
	if not ctx.snapshot.skater_states.has(carrier_pid):
		return AIBodyCheck.Result.new()
	# Difficulty pace knob: check_aggression gates hit-hunting. 0.0 = never
	# commit (pure containment — the easiest, least intimidating tier); below 1.0
	# raises the required separating-hit impulse inversely, so an easier bot only
	# commits to the hardest hits and mostly just contains. 1.0 = today's gate.
	if ctx.check_aggression <= 0.0:
		return AIBodyCheck.Result.new()
	var commit_threshold: float = AIBodyCheck.COMMIT_IMPULSE_M_S / ctx.check_aggression
	var carrier: SkaterNetworkState = ctx.snapshot.skater_states[carrier_pid]
	# The victim's real mass (weight-derived) — don't leave your feet for a hit you'd bounce
	# off a heavy carrier with. League default when the build isn't wired.
	var victim_caps: AISkaterCaps = ctx.caps_by_peer.get(carrier_pid)
	var victim_weight: float = victim_caps.weight if victim_caps != null \
			else AIBodyCheck.LEAGUE_VICTIM_WEIGHT
	return AIBodyCheck.evaluate(
			ctx.self_pos, ctx.self_max_speed, ctx.self_weight,
			ctx.self_body_check_transfer, ctx.self_stagger_timer,
			carrier.position, carrier.velocity, commit_threshold, victim_weight)


# ── Context resolution ──────────────────────────────────────────────────────

# Returns the puck-carrying teammate's position, or Vector3.ZERO if
# no teammate carries the puck (loose puck or opp possession). Roles
# that argmax over score_pass(carrier, candidate) need this; they
# fall back to the anchor when ZERO is returned.
static func resolve_teammate_carrier_pos(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.INF
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1:
		return Vector3.INF
	if ctx.team_id_by_peer.get(carrier_pid, -1) != ctx.team_id:
		return Vector3.INF
	if not ctx.snapshot.skater_states.has(carrier_pid):
		return Vector3.INF
	return ctx.snapshot.skater_states[carrier_pid].position


# Our carrier's CLOSING speed (m/s) toward the attacking net — the forward
# (toward-attacking-goal) component of the carrier's velocity, floored at 0.
# The "is this a rush?" primitive: a carrier driving up-ice at speed reads
# high; one cycling laterally, stalled, or retreating reads ~0. Returns 0.0
# when there's no teammate carrier to read (loose puck / opp possession), so
# roles default to their non-rush shape. Lateral velocity is deliberately
# ignored — only driving AT the net counts as a rush.
static func carrier_closing_speed(ctx: RoleContext) -> float:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return 0.0
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1 or not ctx.snapshot.skater_states.has(carrier_pid):
		return 0.0
	if ctx.team_id_by_peer.get(carrier_pid, -1) != ctx.team_id:
		return 0.0
	var vel: Vector3 = ctx.snapshot.skater_states[carrier_pid].velocity
	# Forward = toward the attacking goal along Z (-own_goal_dir).
	return maxf(-ctx.own_goal_dir * vel.z, 0.0)


# Returns the opposing goalie's CURRENT world position. Falls back
# to the attacking goal mouth when goalie state isn't buffered yet
# (first-frame edge case). Used as the `predicted_goalie_pos` arg
# to AIActionScoring.score_pass — v1 uses live position rather than
# future-projected, since differences across candidates dominate
# any prediction error.
static func resolve_opp_goalie_pos(ctx: RoleContext) -> Vector3:
	var opp_team_id: int = 1 - ctx.team_id
	var goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(opp_team_id)
	if goalie == null:
		return ctx.attacking_goal_pos
	return Vector3(goalie.position_x, 0.0, goalie.position_z)


# Returns OUR goalie's current position. Defensive roles use this
# as the predicted_goalie_pos when scoring the carrier's shot
# threat against our net.
static func resolve_our_goalie_pos(ctx: RoleContext) -> Vector3:
	var goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(ctx.team_id)
	if goalie == null:
		return ctx.defending_goal_pos
	return Vector3(goalie.position_x, 0.0, goalie.position_z)


# The opposing goalie's replicated hand read (hole-model v3), for the
# pre-armed feed keeper (AIActionScoring.resolve_feed_keeper). INF when no
# state is buffered — the resolver synthesizes the league stance.
static func opp_goalie_hands(ctx: RoleContext) -> Vector4:
	var goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(1 - ctx.team_id)
	if goalie == null:
		return Vector4.INF
	return goalie.hands_read(ctx.attacking_goal_pos.z)


# OUR goalie's replicated hand read — the defensive mirror.
static func our_goalie_hands(ctx: RoleContext) -> Vector4:
	var goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(ctx.team_id)
	if goalie == null:
		return Vector4.INF
	return goalie.hands_read(ctx.defending_goal_pos.z)


# Returns the position of whichever peer carries the puck (regardless
# of team), or Vector3.ZERO when the puck is loose / null. Defensive
# roles use this since they're scoring against the opp carrier; the
# offensive `resolve_teammate_carrier_pos` filters to our team and
# returns ZERO when an opp carries.
static func resolve_any_carrier_pos(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.INF
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1:
		return Vector3.INF
	if not ctx.snapshot.skater_states.has(carrier_pid):
		return Vector3.INF
	return ctx.snapshot.skater_states[carrier_pid].position


# ── Play reference (anti-freeze) ─────────────────────────────────────────────
# Off-puck roles orient their candidate search around the carrier. But
# there's no live carrier for most of every transition — a loose puck,
# a breakout pass in flight, the beat after a won battle. The old
# fallback was to freeze at self_pos, which is the "stuck on the heels"
# bug: standing still is almost never the right call mid-transition.
#
# These resolvers fall back to the PUCK itself when no carrier holds it,
# so the role keeps flowing toward the developing play (the elected
# chaser contests it; the others set up as the next option / recover
# into shape). Returns INF only when there's no puck state at all
# (degenerate first frame) — callers still self_pos that case.

# Offensive roles (SUPPORT, OUTLET, FINISHER): prefer a live teammate
# carrier; else, when the puck is genuinely LOOSE, orient off the puck.
# An opp carrier is deliberately NOT a fallback — there's no offensive
# context to a candidate-pass-from-the-opp, and the brain re-ticks to a
# defensive role the same frame on the carrier change, so the caller
# holds for that one transient frame.
static func resolve_offensive_play_ref(ctx: RoleContext) -> Vector3:
	var carrier: Vector3 = resolve_teammate_carrier_pos(ctx)
	if carrier.is_finite():
		return carrier
	if ctx.snapshot != null and ctx.snapshot.puck_state != null \
			and ctx.snapshot.puck_state.carrier_peer_id == -1:
		return ctx.snapshot.puck_state.position
	return Vector3.INF


# Defensive roles (PRESSURE, MARK, the rush layers): prefer whoever carries the
# puck (an opp by definition in their states); else orient off the puck.
static func resolve_defensive_play_ref(ctx: RoleContext) -> Vector3:
	var carrier: Vector3 = resolve_any_carrier_pos(ctx)
	if carrier.is_finite():
		return carrier
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		return ctx.snapshot.puck_state.position
	return Vector3.INF


# Velocity of the play reference — the carrier's velocity when one holds
# the puck, else the puck's own velocity (loose / in flight). Roles that
# lead their search center off the reference (PRESSURE) use this so the
# lead is well-defined even with no live carrier.
static func resolve_play_ref_velocity(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.ZERO
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid != -1 and ctx.snapshot.skater_states.has(carrier_pid):
		return ctx.snapshot.skater_states[carrier_pid].velocity
	return ctx.snapshot.puck_state.velocity


# The velocity a defensive stand built off the play reference is ITSELF moving at
# — what a role publishes as RoleDecision.target_velocity so the steering flies
# the route in the stand's frame (AISteering, "moving-frame pursuit").
#
# A stand riding a live opposing CARRIER moves at his pace, and that is a frame a
# defender can hold station in: the whole job is travelling with him. A stand
# built off a LOOSE PUCK is not — a puck is decelerating, unowned, and nobody
# "gaps up" on one; the answer there is the ordinary chase/contain, which the
# point seek already expresses. So this returns ZERO for anything but a live
# opposing carrier, and every consumer degrades to today's routing exactly when
# there is no man to ride.
static func stand_ride_velocity(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.ZERO
	var pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if pid == -1 or pid == ctx.peer_id:
		return Vector3.ZERO
	if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
		return Vector3.ZERO   # our own carrier — not a man anyone is defending
	if not ctx.snapshot.skater_states.has(pid):
		return Vector3.ZERO
	return ctx.snapshot.skater_states[pid].velocity


# Fills `out` with positions of opp peers other than the puck carrier — i.e.,
# the carrier's potential pass receivers. Defensive roles use this to score
# "carrier's best pass" when evaluating how much a candidate defender position
# deflates the carrier's options. Caller-owned scratch (see collect_opponents).
static func collect_opp_team_excluding_carrier(ctx: RoleContext,
		out: Array[Vector3], anticipate: bool = false) -> void:
	out.clear()
	var carrier_pid: int = -1
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		carrier_pid = ctx.snapshot.puck_state.carrier_peer_id
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
			continue  # our team
		if pid == carrier_pid:
			continue
		var s: SkaterNetworkState = ctx.snapshot.skater_states[pid]
		# Defensive anticipation: lead the receiver to where they're cutting.
		out.append(lead_threat(s.position, s.velocity, ctx.defensive_anticipation_scale) \
				if anticipate else s.position)


# Fills `out` with the positions of teammates excluding self — the anti-crowd
# filter input and the defender set of the threat-surface reads. Also fills
# ctx.scratch_teammate_caps index-matched, so those reads price each defending
# teammate's real blade/pace. Caller-owned scratch (see collect_opponents).
static func collect_teammates_excluding_self(ctx: RoleContext,
		out: Array[Vector3]) -> void:
	out.clear()
	ctx.scratch_teammate_caps.clear()
	for pid: int in ctx.snapshot.skater_states:
		if pid == ctx.peer_id:
			continue
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
			out.append(ctx.snapshot.skater_states[pid].position)
			ctx.scratch_teammate_caps.append(ctx.caps_by_peer.get(pid))


# Returns parallel arrays of opponent positions and full state refs.
# Positions feed AIActionScoring.score_pass / path_clearance; full
# states feed AIActionScoring.time_to_arrive (needs velocity for
# momentum-aware ETA).
static func collect_opponents(ctx: RoleContext,
		out_positions: Array[Vector3],
		out_states: Array[SkaterNetworkState],
		anticipate: bool = false) -> void:
	out_positions.clear()
	out_states.clear()
	ctx.scratch_opp_caps.clear()
	ctx.scratch_opp_ids.clear()
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			var s: SkaterNetworkState = ctx.snapshot.skater_states[pid]
			# Defensive anticipation: lead each opponent to where they're headed.
			# States keep their raw velocity for any momentum-aware ETA caller.
			out_positions.append(lead_threat(s.position, s.velocity, ctx.defensive_anticipation_scale) \
					if anticipate else s.position)
			out_states.append(s)
			ctx.scratch_opp_caps.append(ctx.caps_by_peer.get(pid))
			ctx.scratch_opp_ids.append(pid)


# ── Offensive stations: the pinch read (plan §13) ────────────────────────────
#
# Replaces the counter-channel race for every station that holds forward ice
# while WE have the puck (the O-zone points, the forecheck line pair, F3 / the
# high slot, the trailing valve). The race model is not how the decision is
# actually made, and it is systematically more pessimistic than the real read —
# which is what stranded these bodies 30 m from the play.
#
# The doctrine's read is three coarse, categorical facts:
#
#   1. CONTROL   — "the only time a defenseman should be standing on the
#                  offensive blue line is when his team has complete control of
#                  the puck."          → AIRushRead.pressure_eta_s
#                  In practice this drives NEITHER the hold decision nor the
#                  station leash. Contested control with nobody behind you gives
#                  a retreat nothing to cover, so it must not send bodies home;
#                  and shrinking the leash under pressure turns an outer bound
#                  into an attractor that drags a POINT into the corner. The
#                  pressure-dependent "give close support under heavy pressure"
#                  belongs to the SUPPORT role's own positioning, which already
#                  prices pressure — not to the stations. Left published and
#                  unread here rather than mis-wired.
#   2. SUPPORT   — "a defenceman can only pinch when they have a supporting
#                  player in position to back them up should the puck/player get
#                  past them."                       → has_support_behind
#
#                  Which body that IS falls out of the geometry, and it is not
#                  the one the phrase "F3 high" suggests. During an O-zone cycle
#                  the POINTS are the rearmost bodies (~9 m from our blue line);
#                  F3's high-slot float sits ~8 m further UP-ice. So:
#                    · the points read no support and therefore respect any man
#                      who gets behind them — correct, they ARE the last layer;
#                    · F3 reads the points as support and holds his float —
#                      correct, the layer behind him is home.
#                  The D-vs-forward asymmetry the doctrine describes therefore
#                  emerges from who is physically rearmost, which is why no
#                  per-position appetite scalar is needed.
#   3. NUMBERS   — "the first rule defensemen are taught is to count numbers —
#                  how many opponents are in front of them and if any are
#                  behind them."                     → an attacker behind my stand
#
# And when the read says back off, the target is NOT home. "It's better to stay
# safe with a 3 on 2, rather than pinch and end up with a 3 on 1, 2 on 0 or
# breakaway": backing off restores a NUMBERS LAYER and then stops.

# While HOLDING, a station demands this much extra separation before it accepts
# that a man has got behind it — anti-flicker on the numbers read, in the physical
# unit (one more stick beyond the cover envelope).
const BEHIND_HOLD_EXTRA_M: float = 1.8

# How long a feed may be in flight and still make you a live passing option.
# The literature defines support by whether A PASS IS ON, never in feet — the
# triangle "contracts or expands" — so the play-connection bound is a flight
# time, not an invented radius. Sized on how long a carrier holds the puck in the
# offensive zone before he must move it.
const PLAY_CONNECTION_FLIGHT_S: float = 1.1


# True when a station may keep its forward stand.
#
# Two ways to lose it, and NEITHER is "control is contested":
#   · they have it and it is coming at us (their breakout is under way), or
#   · somebody is behind us and nobody is covering for us.
#
# Contested control deliberately does NOT send a station home on its own. Backing
# off with nobody behind you is precisely the "out of the play" failure this
# replaces — there is nothing to restore, so the retreat buys no coverage and
# costs the attack a body. What contested control legitimately changes is how
# CLOSE the support plays (pull_into_play, "give close support to a teammate under
# heavy pressure"), which is the job the research actually assigns it.
static func may_hold_forward_stand(ctx: RoleContext, was_holding: bool,
		stand: Vector3) -> bool:
	var read: AIRushRead = ctx.rush_read
	# An unwired read knows nothing; the honest default is to hold the shape, so
	# the station's own geometry is the only thing positioning it.
	if not read.is_live:
		return true
	if not _we_possess(ctx) and read.mode == AIRushRead.Mode.RUSH:
		# THEIR puck: forechecking is aggressive by design, so possession alone is
		# no reason to bail — a bottled carrier with nowhere to go is exactly who
		# you pinch on. The doctrine's trigger is that they are "moving out of the
		# zone", which is what Mode.RUSH measures (advancing on our net, or already
		# in our zone). Still bottled or turning back reads REGROUP: hold.
		return false
	# The numbers half: nobody behind us, or somebody covering for us if we get
	# beaten. `was_holding` makes it hysteretic — see _attacker_behind.
	return has_support_behind(ctx) or not _attacker_behind(ctx, stand, was_holding)


# True when the puck is genuinely ours right now — the branch that decides whether
# a station is making a PINCH decision at all. Once the opponent has it (or it is
# loose), there is nothing to pinch on: the answer is the ordinary retreat to
# structure, and TRANS_OD takes over as soon as the puck reaches the neutral zone.
static func _we_possess(ctx: RoleContext) -> bool:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return false
	var pid: int = ctx.snapshot.puck_state.carrier_peer_id
	return pid != -1 and ctx.team_id_by_peer.get(pid, -1) == ctx.team_id


# The numbers-restoring retreat: only as far back as puts us goal-side of the
# deepest attacker who is currently behind our stand — "count numbers, and if any
# are behind you, deal with it". When nobody is behind the stand there is nothing
# to restore and the stand itself is the floor, so this never walks a station home
# for a threat that does not exist.
static func numbers_floor(ctx: RoleContext, stand: Vector3) -> Vector3:
	var read: AIRushRead = ctx.rush_read
	var our_net: Vector3 = ctx.defending_goal_pos
	var stand_d: float = xz_distance(stand, our_net)
	var deepest: float = stand_d
	for lead: Vector3 in read.attacker_leads:
		var d: float = xz_distance(lead, our_net)
		if d < deepest:
			deepest = d
	if deepest >= stand_d:
		return stand   # nobody behind us — hold
	# Goal-side of him by a cover depth, along our own retreat line.
	var target_d: float = maxf(deepest - AIThreatAssignment.COVER_DEPTH_M, 0.0)
	var dx: float = stand.x - our_net.x
	var dz: float = stand.z - our_net.z
	var len_s: float = sqrt(dx * dx + dz * dz)
	if len_s < 0.001:
		return stand
	return Vector3(our_net.x + dx * (target_d / len_s), 0.0,
			our_net.z + dz * (target_d / len_s))


# Pull a station's target back INTO the play if it has drifted outside feedable
# range of the puck. The bound nothing had: every other bound pulls toward home,
# so there was no term that could ever say "you have left the attack". This is
# what makes the support triangle CONTRACT under pressure instead of stretching —
# and it is the direct answer to "float far away from the puck in an effort to be
# open instead of finding angles of support".
static func pull_into_play(ctx: RoleContext, target: Vector3) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return target
	# Only meaningful while WE have it: the leash is about being a live passing
	# OPTION, and there is no option to be when the puck is theirs or loose. A
	# forechecking station standing off a bottled carrier is doing its job, not
	# drifting out of an attack that isn't happening.
	if not _we_possess(ctx):
		return target
	var puck: Vector3 = ctx.snapshot.puck_state.position
	var reach: float = AIActionScoring.expected_pass_speed(puck, target) \
			* PLAY_CONNECTION_FLIGHT_S
	var dx: float = target.x - puck.x
	var dz: float = target.z - puck.z
	var d: float = sqrt(dx * dx + dz * dz)
	if d <= reach or d < 0.001:
		return target
	return Vector3(puck.x + dx * (reach / d), 0.0, puck.z + dz * (reach / d))


# The whole offensive-station decision in one seam, so all five stations behave
# consistently: hold the forward stand while the read allows it, else back off to
# the numbers layer — and either way stay inside feedable range of the puck.
static func offensive_station_target(ctx: RoleContext, stand: Vector3,
		was_holding: bool, as_back_layer: bool = false) -> Vector3:
	if may_hold_forward_stand(ctx, was_holding, stand):
		# Holding: the only bound is staying a live passing option.
		return pull_into_play(ctx, stand)
	if _we_possess(ctx):
		# We still have it, but somebody is behind us with no cover — restore the
		# numbers layer and no further. The play-connection leash deliberately does
		# NOT apply to a retreat: it exists to stop a HOLDING station drifting out
		# of the attack, and clamping a legitimate recovery back up-ice toward the
		# puck would undo the very coverage the read just called for.
		return numbers_floor(ctx, stand)
	# They have it (or it is loose): this is no longer a pinch decision. Retreat to
	# structure. The play-connection leash does NOT apply — it is about being a
	# passing option for OUR carrier, and there isn't one.
	return station_retreat_floor(ctx, stand, as_back_layer)


# The last-man bound for the two NEUTRAL shapes — 3v3's FLANK pair and 5v5's
# DBACK pair, the only stations that hold ice in front of a puck NOBODY owns.
#
# Same three-fact read as offensive_station_target, with one difference that
# falls out of the possession state rather than a per-caller flag: NEUTRAL has
# no carrier, so there is no attack to leave and no structure to hurry back to.
# A slow loose puck is not a rush, and collapsing to a defensive post for one
# concedes the whole neutral zone to whoever picks it up — so losing the forward
# stand restores a NUMBERS LAYER (numbers_floor) and stops there. That keeps the
# concession GRADED, which is what the puck-relative flank shape needs: the bound
# exists to refuse the guaranteed-breakaway geometry, not to replace the shape.
#
# The house gate is the floor, as it is for every field skater — deeper than the
# top of the circles a station only duplicates the goalie and fights its own
# crease repel. Both candidates lie on the net → `stand` ray, so the clamp is a
# distance compare rather than a second projection.
static func neutral_station_target(ctx: RoleContext, stand: Vector3,
		was_holding: bool, layer_stand: Vector3 = Vector3.INF) -> Vector3:
	if may_hold_forward_stand(ctx, was_holding, stand) \
			and (not layer_stand.is_finite() or home_layer_behind_me(ctx)):
		return stand
	var our_net: Vector3 = ctx.defending_goal_pos
	var sagged: Vector3 = numbers_floor(ctx, stand)
	# The LAYER's own stand, when the caller has one. numbers_floor answers "a man
	# has beaten me, restore the layer against HIM" and returns the stand untouched
	# when nobody has — which is silence, not an answer, in the one state where the
	# puck belongs to nobody yet. Take whichever is deeper so both reasons bind.
	if layer_stand.is_finite() \
			and xz_distance(layer_stand, our_net) < xz_distance(sagged, our_net):
		sagged = layer_stand
	if xz_distance(sagged, our_net) >= AIZoneCoverage.HOUSE_TOP_DEPTH_M:
		return sagged
	return house_gate_floor(our_net, sagged)


# ── "If I go, is anybody home?" ──────────────────────────────────────────────
#
# The clause the neutral shape was missing, and it is one character of logic:
# `may_hold_forward_stand` is `has_support_behind OR not _attacker_behind`, so a
# station holds its forward stand whenever nobody has ALREADY got behind it —
# the genuine last man included. That is right where it is used (an offensive
# station with the puck ours has something to be forward FOR), and wrong in the
# one state where the puck belongs to nobody: both teams converge on a loose
# puck, so nobody is behind anybody yet, every station reads clear, the whole
# shape steps up together, and the man gets behind them BECAUSE they did.
#
# Measured on the real stack: a 3v3 whose two flanks both held their puck-side
# stand spent 66% of the following threat window with nobody between the opposing
# carrier and our own net — a coast-to-coast — with the elected RUSH_D1 already
# up-ice of the puck when the state flipped, and therefore unable to be a gap
# defender at all.
#
# So NEUTRAL demands both clauses: somebody home behind me AND nobody already
# past me. The depth read is `has_support_behind`'s (the risk priced is "beaten
# wide, nobody home", which is positional), with two differences that matter for
# a whole shape rather than one body:
#
#   · THE ELECTED CHASER DOES NOT COUNT. He is committed to the puck and is not
#     holding anything. Counting him is how a three-man team convinces itself it
#     has a defender while all three are on the same puck.
#   · A COVER ENVELOPE OF MARGIN, so "behind me" means meaningfully behind rather
#     than a metre nearer the net — the same quantity and the same reasoning as
#     `_attacker_behind`'s margin. Two flanks level with each other cover nothing
#     for one another, so both stay home; over-covering the house on a coin flip
#     is the safe direction, and the band is what stops the pair trading the job
#     back and forth every dispatch.
#
# Antisymmetric by construction — the deepest man cannot have anyone behind him —
# so exactly one body draws the layer and no two can each appoint the other.
static func home_layer_behind_me(ctx: RoleContext) -> bool:
	if ctx.snapshot == null:
		return false
	var chaser: int = ctx.snapshot.closest_to_puck_by_team.get(ctx.team_id, -1)
	var my_depth: float = ctx.own_goal_dir * ctx.self_pos.z \
			+ AIRushRead.cover_envelope_m()
	for pid: int in ctx.snapshot.skater_states:
		if pid == ctx.peer_id or pid == chaser:
			continue
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			continue
		var mate: SkaterNetworkState = ctx.snapshot.skater_states[pid]
		if mate.is_ghost:
			continue
		if ctx.own_goal_dir * mate.position.z > my_depth:
			return true
	return false


# Is any attacker currently deeper (nearer our net) than `stand`?
static func _attacker_behind(ctx: RoleContext, stand: Vector3,
		was_holding: bool = false) -> bool:
	var our_net: Vector3 = ctx.defending_goal_pos
	var stand_d: float = xz_distance(stand, our_net)
	# "Behind me" means MEANINGFULLY behind, not merely a metre nearer the net: a
	# defending winger covering the point sits LEVEL with a D and must not read as
	# a man who has beaten him. The grounded span for "same layer" is the cover
	# envelope — the distance within which one body owns another (a goal-side stand
	# plus a stick). Past it he is genuinely behind the play.
	var margin: float = AIRushRead.cover_envelope_m()
	if was_holding:
		margin += BEHIND_HOLD_EXTRA_M
	for lead: Vector3 in ctx.rush_read.attacker_leads:
		if xz_distance(lead, our_net) < stand_d - margin:
			return true
	return false


# Sprint-aware SELF cap for a defensive race — the backchecking body sprints
# (an explicit BotSprintRules use case), so a cruise-priced reach under-reaches
# every long recovery and the stand it bounds sags earlier than the legs it
# models. Race length ≈ the trip home; pool/lockout from our own replicated
# state. Consumed by the step-up clamp below.
static func self_race_vmax(ctx: RoleContext) -> float:
	if ctx.snapshot == null:
		return ctx.self_max_speed
	var s: SkaterNetworkState = ctx.snapshot.skater_states.get(ctx.peer_id)
	if s == null:
		return ctx.self_max_speed
	var caps: AISkaterCaps = ctx.caps_by_peer.get(ctx.peer_id)
	var mult: float = caps.sprint_speed_mult if caps != null \
			else AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
	return BotSprintRules.race_speed(
			ctx.self_max_speed, mult, s.stamina, s.sprint_locked,
			xz_distance(ctx.self_pos, ctx.defending_goal_pos))


# ── Last-man step-up discipline ──────────────────────────────────────────────
# The last-man step-up bound, shared by the two roles that own a carrier:
# PRESSURE's cut-off and RUSH_D1's gap stand (AIRoleRushD._settable_gap). The
# ladder sizes RUSH_D1's gap but says nothing about the trip to it, so a
# defender deeper than his own stand needs this the same way the in-zone
# pressurer does: don't lunge a stand you cannot arrive at set.
#
# True when a teammate is home BEHIND us — deeper toward our net (larger
# own_goal_dir * z) than we are — i.e. there's a safety layer that can pick the
# carrier up if our challenge gets beaten. When false we are the genuine last
# man back, and a beaten challenge is a breakaway. Depth-axis read (not a race):
# the risk being priced is specifically "beaten wide, nobody home", which is a
# positional question. Excludes self.
static func has_support_behind(ctx: RoleContext) -> bool:
	if ctx.snapshot == null:
		return false
	var my_depth: float = ctx.own_goal_dir * ctx.self_pos.z
	for pid: int in ctx.snapshot.skater_states:
		if pid == ctx.peer_id:
			continue
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			continue
		if ctx.own_goal_dir * ctx.snapshot.skater_states[pid].position.z > my_depth:
			return true
	return false


# The shallowest stand depth — metres goal-side of `threat_pos` along `dir_net`
# — the last man may take THIS dispatch, given that it wants to stand at
# `desired_depth` and the threat is closing on our net at `closing` m/s.
#
# A defensive stand is not a parked spot: it sweeps toward our net at the rush's
# own pace. A defender who charges the stand as it is TODAY arrives where the
# rush already was, carrying up-ice momentum into a carrier closing head-on, and
# the reversal costs him the rush — he gets walked around and trails the play
# home from behind.
#
# THE BOUND IS A SPEED LIMIT, expressed as the stand that enforces it. What it
# caps is the APPROACH — how fast the last man may be closing on the rush — and
# the geometry that sets the limit is measured in the THREAT-RELATIVE frame,
# where the defender's depth shrinks at `v + closing` because the carrier is
# eating the same ice from the other side. Becoming rush-matched from an
# approach speed `v` therefore costs him
#
#     consumed(v) = v²/2B  +  closing·v/B  +  closing²/2a
#                   \_____/    \________/     \_________/
#                   braking    the rush's     the PIVOT: spinning back up to
#                   distance   share of it    his pace going the other way
#
# and that must fit in the depth he has to spare, `self_along - desired_depth`.
# Being merely stopped when the carrier arrives is not gap control — a stationary
# defender is beaten by any lateral cut — which is what the pivot term buys.
# Solving `consumed(v) = spare` for v is a quadratic, so the cap is closed form,
# and the stand that produces it is the point at which a body travelling at the
# cap would just begin braking (v²/2B ahead of him): inside it he brakes, outside
# it he builds, at it he holds. The existing arrival brake is the actuator; this
# only has to place its trigger.
#
# WHY A LIMIT AND NOT A PLAN. The cap is a function of the ICE (spare depth and
# the rush's pace) and not of the defender's own speed, so it is state feedback
# and cannot wind itself up. Its predecessor asked the other question — "what is
# the largest step-up I could still arrive set at?" — and answered it afresh at
# 6 Hz with no memory of the plan it was revising, which is a structure that
# ratchets: every grant builds speed and the next grant is computed as though
# the body were parked. That version had to price its trip FROM REST to stay
# stable at all, and pricing it honestly instead (from the body's real speed)
# measured worse than having no bound whatsoever — meeting-point up-ice speed
# 2.4 -> 6.5-9.2 m/s, wander off our own net 4.2 m mean -> 13-25 m, on the sweep
# in tests/unit/ai/test_rush_gap_discipline.gd. A speed limit has no such
# failure mode to be conservative about: closing on the rush shrinks the spare
# depth, which lowers the cap, which is negative feedback by construction.
#
# The shape falls out at both ends: a stalled or regrouping carrier makes
# `closing` nil, so there is no rendezvous to lose, the cap goes to the body's
# own top speed and the defender closes right up (gapping up); a carrier flying
# in drives the cap to zero and he holds his ground and makes the rush come to
# him. Returns `desired_depth` unchanged whenever no bound applies — a stand
# already goal-side of us is a retreat, which costs no reversal.
static func settable_stand_depth(ctx: RoleContext, threat_pos: Vector3,
		dir_net: Vector3, desired_depth: float, closing: float) -> float:
	var self_along: float = (ctx.self_pos.x - threat_pos.x) * dir_net.x \
			+ (ctx.self_pos.z - threat_pos.z) * dir_net.z
	var spare: float = self_along - desired_depth
	if spare <= 0.0 or closing <= 0.01:
		return desired_depth
	var v_cap: float = approach_speed_cap(
			spare, closing, self_race_vmax(ctx), ctx.self_max_accel)
	# The stand IS the brake trigger for that speed: a body at the cap begins
	# braking v²/2B short of its target, so putting the target exactly there
	# regulates him onto the cap instead of past it.
	var brake_lead: float = v_cap * v_cap \
			/ (2.0 * AISteering.ARRIVAL_BRAKE_DECEL_M_S2)
	return maxf(desired_depth, self_along - brake_lead)


# The fastest a last man may be closing on a rush that is `spare` metres of his
# own depth away and coming at `closing` m/s — the positive root of
# `consumed(v) = spare` (see settable_stand_depth for the terms). Capped at the
# body's own top speed, and floored at zero: a defender with less spare depth
# than the pivot alone costs has no approach left to make and holds.
static func approach_speed_cap(spare: float, closing: float, v_max: float,
		max_accel: float) -> float:
	var brake_decel: float = AISteering.ARRIVAL_BRAKE_DECEL_M_S2
	var a_net: float = maxf(max_accel * AIActionScoring.RAMP_EFFICIENCY, 0.001)
	# v² + 2·closing·v + B·(closing²/a - 2·spare) = 0
	var disc: float = closing * closing * (1.0 - brake_decel / a_net) \
			+ 2.0 * brake_decel * spare
	if disc <= 0.0:
		return 0.0
	return clampf(sqrt(disc) - closing, 0.0, maxf(v_max, 0.0))


# A station's home post has to be meaningfully deeper than the stand it is
# bounding to be a retreat at all — one stride, so a station already standing on
# its own post doesn't read as "retreat zero metres" and lose its bound entirely.
const HOME_FLOOR_BIND_MARGIN_M: float = 1.0


# The deepest a station may sag — offensive_station_target's retreat target when
# the puck is no longer ours.
#
# The principle: an OFF-PUCK STATION's retreat is about repositioning for a
# possible turnover, not about defending an actual rush. Defending an actual
# rush is transition defense's job — a different possession state with different
# roles. So when a station gives up its forward stand, the answer is "get back to
# your post", not "keep skating to the crease" — retreating toward the net-front
# stand is how a defenseman ended up parked on his own goal line while the play
# was still in the offensive zone (docs/transition-defense-plan.md §2.1).
#
# Two tiers, and which applies falls out of the geometry rather than a per-caller
# decision:
#   • a station that plays UP-ICE of home (the points, the forecheck line pair,
#     F3, the high slot, the trailing valve) floors at its own defensive home
#     post — the dot lane at its blue line for a D, the high ice just up-ice of
#     it for a forward (AIZoneCoverage.defensive_anchor);
#   • a station whose stand already IS its home can't be bounded by it, so it
#     floors at the HOUSE GATE — the top of the circles, the depth the research
#     names as where backcheckers stop. Still never the crease.
# `as_back_layer` forces the DEFENSEMAN's home post regardless of lobby identity.
# ctx.self_is_defense is a lobby fact, and 3v3 has no lobby positions — every peer
# reads "forward" — so a role that IS its team's whole back layer would otherwise
# floor 4 m too shallow (the F post at our blue line minus 4 m, instead of the D
# post on it). 3v3's F3_HIGH is exactly that role.
static func station_retreat_floor(ctx: RoleContext, fwd: Vector3,
		as_back_layer: bool = false) -> Vector3:
	var our_net: Vector3 = ctx.defending_goal_pos
	var home: Vector3 = AIZoneCoverage.defensive_anchor(
			ctx.self_is_defense or as_back_layer, ctx.self_home_side, our_net.z)
	if ctx.own_goal_dir * home.z > ctx.own_goal_dir * fwd.z + HOME_FLOOR_BIND_MARGIN_M:
		return home
	return house_gate_floor(our_net, fwd)


# The other side of the same line: hold `pos` OUT at the top of the circles when
# it has been placed deeper than that. Where house_gate_floor bounds how far a
# retreating station may sag, this bounds how far a defender may be PUSHED, and
# the reason is the same one AIRoleRushD has always given for it — past the gate a
# field skater duplicates the goalie, fights his own crease repel, and gets beaten
# to the outside of a net he is standing on top of.
#
# Returns `pos` untouched when it is already outside the gate, and projects it out
# along the net → pos ray otherwise (degenerate at the net itself: straight out
# along the rink axis).
static func hold_out_to_house_gate(our_net: Vector3, pos: Vector3) -> Vector3:
	var dx: float = pos.x - our_net.x
	var dz: float = pos.z - our_net.z
	var dsq: float = dx * dx + dz * dz
	var gate: float = AIZoneCoverage.HOUSE_TOP_DEPTH_M
	if dsq >= gate * gate:
		return pos
	var dl: float = sqrt(dsq)
	if dl < 0.001:
		return Vector3(our_net.x, 0.0, our_net.z - signf(our_net.z) * gate)
	return Vector3(our_net.x + dx * (gate / dl), 0.0, our_net.z + dz * (gate / dl))


# The point on the net → `fwd` ray at the top of the circles: the deepest a field
# skater should ever be pushed by a last-man bound. Below it he duplicates the
# goalie, fights his own crease repel, and overshoots behind the goal line.
static func house_gate_floor(our_net: Vector3, fwd: Vector3) -> Vector3:
	var dx: float = fwd.x - our_net.x
	var dz: float = fwd.z - our_net.z
	var d: float = sqrt(dx * dx + dz * dz)
	if d < 0.001 or d <= AIZoneCoverage.HOUSE_TOP_DEPTH_M:
		return fwd
	var k: float = AIZoneCoverage.HOUSE_TOP_DEPTH_M / d
	return Vector3(our_net.x + dx * k, 0.0, our_net.z + dz * k)


static func xz_distance(a: Vector3, b: Vector3) -> float:
	var dx: float = b.x - a.x
	var dz: float = b.z - a.z
	return sqrt(dx * dx + dz * dz)


# Is the race to a loose puck already LOST — an opponent reaches it a clear
# contest-band ahead of me? Momentum-aware ETAs at each skater's real Speed
# cap, with the same physical contest margin the dump-chase race uses
# (CHASE_CONTEST_MARGIN_M, a stride's head-start): arriving inside that band
# still creates a live 50/50 (worth racing, the drive-through commits it);
# arriving clearly behind it means the collector has gathered and I'm just
# skating myself out of the play. A chaser that reads LOST should transition
# to defending the pickup instead of pushing (the missed-pass "third man keeps
# chasing while the counter develops" failure). False when no opponent
# threatens the puck.
#
# `own_goal_dir` (+1 = our net at +Z) enables the CONTAINMENT read below, which
# is what keeps the decline from becoming "the bots stopped trying". Pass 0.0
# only where the geometry genuinely isn't available (unit tests) — both
# production call sites pass the real value.
static func loose_puck_race_lost(
		snapshot: WorldSnapshot, self_pos: Vector3, self_vel: Vector3,
		self_max_speed: float, team_id: int, team_id_by_peer: Dictionary,
		caps_by_peer: Dictionary, self_pid: int = -1,
		own_goal_dir: float = 0.0) -> bool:
	if snapshot == null or snapshot.puck_state == null:
		return false
	var puck_pos: Vector3 = snapshot.puck_state.position
	# A FAST puck races on its predicted path, not its current position —
	# ETAs to where a rim IS misread both sides of the race (the tail-chaser
	# a metre behind it "wins" a race the puck itself outruns; the far-side
	# skater whose real intercept is where the wrap comes to him reads as
	# hopeless, declines, and the rim rides the zone untouched). Same walk
	# as the chase election, so the decline can never contradict it.
	var puck_vel: Vector3 = snapshot.puck_state.velocity
	var traj: Array[Vector3] = []
	if AILoosePuckChase.is_fast_puck(puck_vel):
		traj = AILoosePuckChase.race_trajectory(puck_pos, puck_vel)
	var step_dt: float = AILoosePuckChase.RACE_LOOKAHEAD_S \
			/ float(AILoosePuckChase.RACE_STEPS)
	# Sprint-aware self cap: same seam as the election (race_vmax), fed by
	# our own replicated stamina/lockout when the caller identifies us.
	var self_vmax: float = maxf(self_max_speed, 1.0)
	var self_state: SkaterNetworkState = snapshot.skater_states.get(self_pid)
	if self_state != null:
		var self_caps: AISkaterCaps = caps_by_peer.get(self_pid)
		var self_mult: float = self_caps.sprint_speed_mult if self_caps != null \
				else AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
		self_vmax = BotSprintRules.race_speed(
				self_vmax, self_mult, self_state.stamina, self_state.sprint_locked,
				Vector2(puck_pos.x - self_pos.x, puck_pos.z - self_pos.z).length())
	var my_eta: float
	if traj.is_empty():
		my_eta = AIActionScoring.time_to_arrive(
				self_pos, puck_pos, self_vel, self_vmax)
	else:
		my_eta = AILoosePuckChase.path_intercept_time(
				traj, step_dt, self_pos, self_vel, self_vmax)
	var best_opp_eta: float = INF
	var best_opp_meet: Vector3 = puck_pos
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) == team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		# The race is only lost to an opponent actually RUNNING it — on the
		# intercept point already (standing there is the play, no motion
		# needed), or genuinely closing on it. The ETA model prices his
		# hypothetical sprint-from-now; declining on a body that is not going
		# for the puck left it sitting between two staring teams, both sides
		# having declined on hypothetical winners.
		#
		# For a MOVING puck the question is per-path, not per-position: a rim's
		# downstream interceptor legitimately waits still, and he reads as
		# committed because the rim's own line runs through his contest band —
		# he makes the play without moving. What no longer counts is the body
		# 15 m off that line, or drifting away from it, whose "win" is a sprint
		# he was never running: that phantom veto is what talked our chaser off
		# a rim and sent him retreating to the pre-contain point while the puck
		# rode the whole zone untouched.
		var speed: float = AILoosePuckChase.race_vmax(
				s, caps_by_peer.get(pid), puck_pos)
		var t: float
		var committed: bool
		var meet: Vector3 = puck_pos
		if traj.is_empty():
			t = AIActionScoring.time_to_arrive(s.position, puck_pos, s.velocity, speed)
			committed = AILoosePuckChase.committed_to_race(s, puck_pos)
		else:
			t = AILoosePuckChase.path_intercept_time(
					traj, step_dt, s.position, s.velocity, speed)
			meet = AILoosePuckChase.path_intercept_point(traj, step_dt, t)
			committed = AILoosePuckChase.path_enters_band(traj, puck_pos,
					s.position, AIActionScoring.CHASE_CONTEST_MARGIN_M) \
					or AILoosePuckChase.committed_to_point(s, meet)
		if not committed:
			continue
		if t < best_opp_eta:
			best_opp_eta = t
			best_opp_meet = meet
	if best_opp_eta == INF:
		return false
	var contest_window: float = AIActionScoring.CHASE_CONTEST_MARGIN_M \
			/ maxf(self_max_speed, 1.0)
	if my_eta <= best_opp_eta + contest_window:
		return false
	# Losing the race is only a reason to STOP if stopping buys something. The
	# decline exists to pre-contain the collector so the counter meets a body —
	# which is worth a chaser only when there is not already one behind the
	# play. With a teammate goal-side of the pickup the counter is contained
	# without me and the honest read on a lost puck is to keep skating: that is
	# the forecheck, and refusing it is why a dumped-in puck got collected with
	# nobody within 20 m of it (measured: our team had NOBODY chasing for 53% of
	# the loose window on a routine dump-in).
	#
	# Naturally zone-aware, so no zone gate is needed: a puck dumped into the
	# attacking corner has our whole team goal-side of it and gets forechecked,
	# while a puck lost behind our own D — the last man with nobody home, the
	# geometry the decline was actually built for — still declines and
	# pre-contains. Goal-side is the plain support read ("is anyone behind the
	# puck") rather than a full can-he-hold model: cheap, and it errs toward
	# racing, which is the side of this trade-off that reads as hockey.
	return not _has_containment_behind(snapshot, team_id, team_id_by_peer,
			self_pid, best_opp_meet, own_goal_dir)


# Is someone else covering the counter, so that leaving to chase is free?
#
# TWO reads, OR'd, because each is structurally unobtainable in the regime the
# other answers. A live teammate qualifies if he is either:
#   GOAL-SIDE of the pickup — the plain support read. Right when the pickup is
#     far from our net (a dump into their corner puts our whole team goal-side
#     of it), and what makes the forecheck work.
#   HOLDING THE HOUSE — able to reach the top of the circles in front of our own
#     net inside the window an arrival there still matters. Right when the
#     pickup is at our own net, where nothing can be goal-side of it.
#
# The goal-side test alone leaves a hole exactly where declining costs the most.
# When the puck is the DEEPEST object in our own end — rimmed into our corner or
# around behind our own goal line, past everybody — no teammate CAN be goal-side
# of it. The valve read "nobody is covering" when the truth was "everybody is
# covering, the puck is just behind us", every eligible bot declined, and the
# puck sat in our own corner untouched: measured on the engagement harness at 93
# of 98 idle ticks, puck loose 0.8 s at 8.1 m/s, nearest man 13.4 m and closing,
# all three bots parked in OFF_PUCK. Only ONE bot per team is even eligible to
# chase (the election), so a single unearned decline is a whole-team no-show.
#
# Re-phrasing it as a race — "can a teammate beat the collector home?" — does not
# fix it, and the reason is worth keeping: the race runs to `best_opp_meet`, and
# when the puck caroms behind our own goal line that point IS our net, so the
# collector is already home and nobody can beat him there. Any guard that
# measures against the pickup dies the same way. The house read measures against
# OUR NET instead, which is why it survives.
#
# Doctrine (researched): "don't chase" in hockey means do not pursue a puck
# CARRIER into a low-danger area and turn your back on the slot. A LOOSE puck in
# our end is always pressured — "the nearest player pressures, and everyone else
# adjusts their support so the house stays covered". So the question is never
# "may I go?" but "if I go, is the house still covered?", which is a numbers
# read. The case the decline was built for survives it: the genuine last man,
# with his mates caught up-ice, has nobody who can hold the house, so he still
# declines and covers the net front instead of chasing into the corner.
#
# own_goal_dir 0.0 means the caller has no rink geometry to give us, so no
# containment can be claimed.
static func _has_containment_behind(snapshot: WorldSnapshot, team_id: int,
		team_id_by_peer: Dictionary, self_pid: int, pickup: Vector3,
		own_goal_dir: float) -> bool:
	if own_goal_dir == 0.0:
		return false
	# The house gate: tops of the circles off our own goal line — the researched
	# depth where a recovering defender stops, and so the honest finish line for
	# "is he back in time to matter".
	var gate := Vector3(0.0, 0.0, own_goal_dir
			* (GameRules.GOAL_LINE_Z - AIZoneCoverage.HOUSE_TOP_DEPTH_M))
	for pid: int in snapshot.skater_states:
		if pid == self_pid or team_id_by_peer.get(pid, -1) != team_id:
			continue
		var mate: SkaterNetworkState = snapshot.skater_states[pid]
		if mate.is_ghost:
			continue
		if own_goal_dir * (mate.position.z - pickup.z) \
				> AIActionScoring.CHASE_CONTEST_MARGIN_M:
			return true
		if AIActionScoring.time_to_arrive(mate.position, gate, mate.velocity) \
				<= AIRushRead.LATE_MAN_WINDOW_S:
			return true
	return false
