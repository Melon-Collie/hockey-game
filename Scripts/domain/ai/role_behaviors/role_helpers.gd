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

# Returns the standard off-puck candidate set: anchor + self
# (stand-still) + 8 polar samples around the anchor at SEARCH_STEP_M.
# Polar pattern is fixed-cardinal (0°, 45°, ..., 315°) — roles that
# need slot-oriented search (like CARRIER) roll their own.
#
# Phase 4d / Step 2 of the no-anchors refactor: roles increasingly
# compute their own search center from in-game refs (carrier pos,
# nets, etc.) instead of leaning on ctx.anchor. New code should
# call `generate_candidates_around(self_pos, center)` directly.
static func generate_candidates(ctx: RoleContext) -> Array[Vector3]:
	return generate_candidates_around(ctx.self_pos, ctx.anchor)


# Returns the standard 10-candidate set centered on `center`:
# `center` itself + `self_pos` (stand-still) + 8 polar samples
# around `center` at SEARCH_STEP_M. Use this when a role wants to
# pick its own search center from in-game references rather than
# inheriting whatever ctx.anchor happens to be.
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
# The search center used to be the midpoint between the man and our net,
# which sagged the whole candidate set: a man 12 m out was "covered" from
# ~6 m away, and because a midpoint moves at HALF the man's speed, a
# cutting man walked away from his check every time ("bots lose their
# man"). Anchoring on cover_anchor keeps the defender attached (it tracks
# the man 1:1) and matches the anchor the partition already scored
# reachability against, so the pairing and the coverage agree. The ±3 m
# candidate ring still lets the argmax shade off the body and into the
# carrier→man lane when that deflates the threat more.
#
# This replaces the legacy "minimize the MAX threat over ALL opponents" scoring
# for the assigned-man case: because each backline defender gets a DISTINCT man,
# two defenders no longer collapse onto the single most dangerous opponent.
# Roles fall back to their all-opponents behavior when unassigned (man_pid -1).
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
		# it candidate-free this iteration.
		teammates.push_back(c)
		# Minimize the carrier's threat of feeding THIS man (lane × his shot).
		var threat: float = AIActionScoring.threat_surface_pass(
				carrier_pos, man_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, teammates)
		teammates.pop_back()
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
		out_bases: Array[float]) -> void:
	out_bases.clear()
	out_bases.append(AIActionScoring.threat_surface_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self))
	for opp_pos: Vector3 in opp_teammates:
		out_bases.append(AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self))


static func carrier_best_option(
		candidate: Vector3,
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3],
		bases: Array[float] = []) -> float:
	# Carrier's view of defenders = our team + me at the candidate. This helper
	# is called once per candidate in PRESSURE's argmax (up to ~19×/decide), so
	# duplicating the array every call was pure hot-path churn. Append the
	# candidate to the caller's array in place and pop it before returning — the
	# array is left exactly as passed, and after the first call the backing
	# store keeps its capacity so the push/pop allocates nothing.
	our_team_excluding_self.push_back(candidate)
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
						GameRules.NET_HALF_WIDTH, our_team_excluding_self)
			else:
				v = AIActionScoring.threat_surface_pass(
						carrier_pos, opp_teammates[bi - 1], our_net, our_goalie_pos,
						GameRules.NET_HALF_WIDTH, our_team_excluding_self)
			if v > best:
				best = v
		our_team_excluding_self.pop_back()
		return best

	# Exact/unpruned path (no bases supplied — one-shot callers).
	# Carrier's best shot at our net (with positional fallback floor).
	var shoot_value: float = AIActionScoring.threat_surface_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self)

	# Carrier's best pass to any teammate (with positional fallback).
	# `our_net` is the attacking goal from the carrier's perspective, so the
	# receiver's threat is evaluated against our goalie.
	var pass_value: float = 0.0
	for opp_pos: Vector3 in opp_teammates:
		var pass_score: float = AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self)
		if pass_score > pass_value:
			pass_value = pass_score

	our_team_excluding_self.pop_back()
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
		abort_above: float = INF) -> float:
	# Defenders = our team + me at the candidate. Append-and-restore the caller's
	# array in place instead of duplicating it — called once per candidate in
	# RUSH_D1's lane fan (up to ~13×/decide), so a fresh Array per call was pure
	# churn. The array is left exactly as passed; capacity is retained across the
	# push/pop so steady-state calls allocate nothing.
	our_team_excluding_self.push_back(candidate)
	var best: float = AIActionScoring.score_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self)
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
				GameRules.NET_HALF_WIDTH, our_team_excluding_self, pass_speed, unsettled)
		if pass_value > best:
			best = pass_value
	our_team_excluding_self.pop_back()
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
	# The victim's real mass (Size) — don't leave your feet for a hit you'd bounce
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


# Fills `out` with the positions of teammates excluding self. Used as the
# anti-crowd filter input. Caller-owned scratch (see collect_opponents).
static func collect_teammates_excluding_self(ctx: RoleContext,
		out: Array[Vector3]) -> void:
	out.clear()
	for pid: int in ctx.snapshot.skater_states:
		if pid == ctx.peer_id:
			continue
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
			out.append(ctx.snapshot.skater_states[pid].position)


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


# Fills `out_states` (+ index-matched `out_caps`) with the opponents genuinely
# involved in a counter-attack — AIRushRead.attackers — rather than every body
# on the ice. This is the threat set fill_counter_channels should race against.
#
# The unfiltered list is why the race-home bound over-retreated: it priced the
# opposing team's stay-home defenseman, 40 m away behind his own blue line, as a
# live counter threat receiving the hardest legal feed on the rink, and since
# feasibility is a conjunction over every channel, that one phantom collapsed
# the stand and bisected the defender toward his own crease. A body who cannot
# be at our net within the late-man window of the puck is furniture; the pinch
# read should not see him at all.
#
# An UNWIRED read (no brain — unit tests, a brainless agent) falls back to every
# opponent. "No attackers" from a read that was never filled means "nobody told
# me anything", not "the coast is clear", and treating those the same would
# silently disable every race-home bound in the game. A LIVE read reporting no
# attackers is believed.
static func collect_counter_threats(ctx: RoleContext,
		out_states: Array[SkaterNetworkState],
		out_caps: Array[AISkaterCaps]) -> void:
	out_states.clear()
	out_caps.clear()
	var read: AIRushRead = ctx.rush_read
	var live: bool = read.is_live
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
			continue
		if live and not read.is_attacker(pid):
			continue
		out_states.append(ctx.snapshot.skater_states[pid])
		out_caps.append(ctx.caps_by_peer.get(pid))


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
	var stand_d: float = _xz_distance(stand, our_net)
	var deepest: float = stand_d
	for lead: Vector3 in read.attacker_leads:
		var d: float = _xz_distance(lead, our_net)
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


# Is any attacker currently deeper (nearer our net) than `stand`?
static func _attacker_behind(ctx: RoleContext, stand: Vector3,
		was_holding: bool = false) -> bool:
	var our_net: Vector3 = ctx.defending_goal_pos
	var stand_d: float = _xz_distance(stand, our_net)
	# "Behind me" means MEANINGFULLY behind, not merely a metre nearer the net: a
	# defending winger covering the point sits LEVEL with a D and must not read as
	# a man who has beaten him. The grounded span for "same layer" is the cover
	# envelope — the distance within which one body owns another (a goal-side stand
	# plus a stick). Past it he is genuinely behind the play.
	var margin: float = AIRushRead.cover_envelope_m()
	if was_holding:
		margin += BEHIND_HOLD_EXTRA_M
	for lead: Vector3 in ctx.rush_read.attacker_leads:
		if _xz_distance(lead, our_net) < stand_d - margin:
			return true
	return false


# ── The race-home read: puck-path intercept model ───────────────────────────
#
# Every "am I recoverable / can I hold this forward stand?" question (the
# points' keep-in bound, the forecheck line holds, DVALVE, SUPPORT's exposure)
# races the defender against a hypothetical
# counter-attack. Two grounded facts the old beat-them-to-our-net radius
# missed, both of which made it unsatisfiable from any forward stand against
# an opponent of equal top speed (the pacing-between-the-blue-lines bug):
#
#   1. A counter must move the PUCK, not a body. The threat clock for
#      opponent i starts with a puck-GAIN leg — an outlet pass's flight to
#      his lead point (at the league pass-flight model's pace), or him
#      skating to a loose/stripped puck — before his carry home even begins.
#      A puckless body near our net is only as fast as the pass that finds it.
#   2. The defender doesn't race the counter to his own cage — he races it to
#      the first point where he can stand IN ITS PATH. Standing goal-side on
#      the carry route wins by retreating in front of the rush (gap control);
#      only a threat that gets to a path point before he can be there, set,
#      beats him.
#
# Race legs, all symmetric kinematics (no shape knobs) — both sides priced by
# the calibrated time_to_arrive (its capped ramp charges standing starts and
# credits momentum honestly, so neither side gets top speed for free):
#   puck side:  t_gain + momentum-aware carry to the station.
#   defender:   standing-start run to the station minus blade reach
#     (containment radius is body + stick — "even with him" is a physical
#     span, not a point). At the net station he additionally pays the brake
#     margin — the last-resort stand must arrive stopped, not flying past
#     the cage.
#
# Stations sample the carry path STRICTLY AFTER the gain point: contesting
# the reception itself is an opportunistic play owned by the chase/pressure
# roles — recoverability asks "once he HAS it, do I contain the rush?", and
# a station past the catch forces a genuinely goal-side arrival.
const RACE_PATH_FRACTIONS: Array[float] = [0.2, 0.4, 0.6, 0.8, 1.0]

# Per-fill scratch: one station grid (channel-major, RACE_PATH_FRACTIONS wide)
# shared by every candidate the caller tests. AI dispatch is single-threaded,
# same pattern as AIActionScoring._scratch_counter_cover.
static var _race_station_pts: Array[Vector3] = []
static var _race_station_ts: Array[float] = []
# Per-station squared containment radii for the CURRENT caller's build: a
# stand at `c` contains station j iff dist²(c, station_j) ≤ _race_reach_sq[j].
# Precomputed once per fill (see _prepare_reach) so the per-candidate
# feasibility loop is a single multiply-compare per station — the loop runs
# candidates × channels × stations at role-decide rate, which made the
# sqrt-and-ramp-per-station version the hottest line of every 5v5 D decide.
static var _race_reach_sq: Array[float] = []
static var _race_channel_count: int = 0
static var _race_net: Vector3 = Vector3.ZERO
# The deepest useful defensive stand: the net-front spot at the top of the
# crease repel skirt (crease arc + extension). Deeper than this a skater
# adds nothing the goalie doesn't already cover, his own steering fights
# the spot (crease repel), and body overshoot carries him onto/behind the
# goal line — the retreat bisection floors here, never at the net point.
static var _race_home_stand: Vector3 = Vector3.ZERO
# Memo key: every full-opponent-list consumer of the same team on the same
# snapshot builds IDENTICAL channels (points, high slot, valve, line holds all
# fill right after collect_opponents) — one fill serves them all. The
# attacker-filtered counter list is tagged by `variant`, which the key catches
# even when it happens to be the same SIZE. Speed/accel
# key the reach radii (different bots re-derive only those, keeping the
# stations).
static var _race_key_snapshot_id: int = 0
static var _race_key_net_z: float = 0.0
static var _race_key_count: int = -1
# Which threat list built the current grid (see ThreatSet) — same-size lists
# from different callers must not alias.
static var _race_key_variant: int = -1
# The channel build reads ctx.offsides_enforced (blue-line gain clamps), so
# the memo must key on it — match-global in play, but tests flip it between
# calls on one snapshot.
static var _race_key_offsides: int = -1
static var _race_key_speed: float = -1.0
static var _race_key_accel: float = -1.0


# Threat-list variants, for the memo key. Two callers can legitimately pass
# DIFFERENT lists of the SAME size on one snapshot (the full opponent list vs the
# attacker-filtered counter set), which a size-only key would silently alias into
# one station grid.
enum ThreatSet { ALL_OPPONENTS, COUNTER_ATTACKERS }


# Build the counter-attack channels for a turnover-now hypothesis and
# precompute the puck's arrival time at every path station. One call per
# decide(), before any race_home_feasible / most_forward_feasible queries.
# `opp_states` is the caller's threat list with `opp_caps` index-aligned to it;
# `variant` tags which list it is (see ThreatSet). Memoized per (snapshot, net,
# list size, variant): repeat fills for the same team on the same tick reuse the
# station grid and only re-derive the caller-build reach radii when the bot
# differs.
static func fill_counter_channels(ctx: RoleContext,
		opp_states: Array[SkaterNetworkState],
		opp_caps: Array[AISkaterCaps],
		our_net: Vector3,
		variant: int = ThreatSet.ALL_OPPONENTS) -> void:
	var snap_id: int = ctx.snapshot.get_instance_id() if ctx.snapshot != null else 0
	if snap_id == _race_key_snapshot_id and our_net.z == _race_key_net_z \
			and opp_states.size() == _race_key_count \
			and variant == _race_key_variant \
			and int(ctx.offsides_enforced) == _race_key_offsides and snap_id != 0:
		_prepare_reach(ctx.self_max_speed, ctx.self_max_accel)
		return
	_race_key_snapshot_id = snap_id
	_race_key_net_z = our_net.z
	_race_key_count = opp_states.size()
	_race_key_variant = variant
	_race_key_offsides = int(ctx.offsides_enforced)
	_race_station_pts.clear()
	_race_station_ts.clear()
	_race_channel_count = 0
	_race_net = our_net
	_race_home_stand = Vector3(our_net.x, 0.0,
			our_net.z - signf(our_net.z) * (
					CreaseRules.ARC_RADIUS + AISteering.CREASE_REPEL_EXTENSION))
	var puck_pos: Vector3 = Vector3.INF
	var opp_has_puck: bool = false
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		puck_pos = ctx.snapshot.puck_state.position
		var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
		opp_has_puck = carrier_pid != -1 \
				and ctx.team_id_by_peer.get(carrier_pid, -1) != ctx.team_id
	# Offside-aware outlets: an opponent already IN his attacking zone (our
	# defensive zone) while the puck is NOT there cannot legally receive an
	# outlet where he stands — ARCADE ghosts him, NHL whistles the touch;
	# either way his earliest legal involvement is at the blue line, tagged
	# up. His channels route through that point below. Only the OFF ruleset
	# plays a cherry-picker as the live doorstep threat he'd otherwise be.
	var own_dir: float = signf(our_net.z)
	var offside_reads: bool = ctx.offsides_enforced and puck_pos.is_finite() \
			and own_dir * puck_pos.z <= GameRules.BLUE_LINE_Z
	var has_caps: bool = opp_caps.size() == opp_states.size()
	for i: int in opp_states.size():
		var s: SkaterNetworkState = opp_states[i]
		var speed: float = AIActionScoring.SKATER_REF_SPEED_M_S
		var accel: float = AIActionScoring.SHED_ACCEL_DEFAULT_M_S2
		var sprint_mult: float = AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
		if has_caps:
			var caps: AISkaterCaps = opp_caps[i]
			if caps != null:
				speed = caps.max_speed
				accel = caps.max_accel
				sprint_mult = caps.sprint_speed_mult
		# The counter racer SPRINTS his rush — the gain race as a loose-puck
		# race, the carry as the breakaway sprint (carry-penalty bypass) —
		# so a cruise-priced channel under-clocked every counter this build
		# could actually run. Race length ≈ his whole trip to our net;
		# stamina-gated by his replicated pool.
		speed = BotSprintRules.race_speed(speed, sprint_mult,
				s.stamina, s.sprint_locked,
				_xz_distance(s.position, our_net))
		# A skater's momentum can't exceed his real top speed — an over-cap
		# state velocity (transient physics, or test inputs) would otherwise
		# double-credit the carry legs through time_to_arrive's along-speed.
		var vel: Vector3 = s.velocity
		var v_len: float = sqrt(vel.x * vel.x + vel.z * vel.z)
		if v_len > speed:
			vel = vel * (speed / v_len)
		if not puck_pos.is_finite():
			# No puck in the world (degenerate) — the body itself is the
			# threat clock, gain leg zero.
			_append_channel(s.position, 0.0, vel, speed, accel)
			continue
		# Outlet: the pass flies to the receiver's lead point, then he carries
		# with his momentum. A safety read races the HARDEST feed the rink
		# allows — the league launch ceiling — not the friction-solved likely
		# pass; a stretch outlet is fired near max. For the opponent CARRIER
		# this collapses to gain ≈ 0, carry from his blade.
		var v_pass: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
		var pass_dist: float = _xz_distance(puck_pos, s.position)
		var lead: Vector3 = s.position + vel * (pass_dist / v_pass)
		var lead_xz: Vector2 = GameRules.clamp_to_rink_inner(
				Vector2(lead.x, lead.z), 0.5)
		var gain_pt := Vector3(lead_xz.x, 0.0, lead_xz.y)
		# Offside-positioned (in his attacking zone before the puck): his
		# gain clamps to the blue line — timed by BOTH clocks (the feed's
		# flight there and his own skate back to tag), with the carry
		# restarting from the tag rather than at his lurking momentum.
		var offside_positioned: bool = offside_reads \
				and own_dir * s.position.z > GameRules.BLUE_LINE_Z
		if offside_positioned:
			gain_pt = Vector3(lead_xz.x, 0.0, own_dir * GameRules.BLUE_LINE_Z)
			var t_feed: float = _xz_distance(puck_pos, gain_pt) / v_pass
			var t_tag: float = AIActionScoring.time_to_arrive(
					s.position, gain_pt, vel, speed)
			_append_channel(gain_pt, maxf(t_feed, t_tag),
					Vector3.ZERO, speed, accel)
		else:
			_append_channel(gain_pt, _xz_distance(puck_pos, gain_pt) / v_pass,
					vel, speed, accel)
		# Retrieve: only when the puck is loose or on OUR team's blade — the
		# opponent skates to it, gathers (carry restarts from rest). An
		# offside-positioned body must tag up before it may touch the puck
		# (ARCADE can't interact; an NHL touch is a whistle, not a counter),
		# so its retrieval routes through the blue line.
		if not opp_has_puck:
			var t_ret: float
			if offside_positioned:
				var tag_pt := Vector3(s.position.x, 0.0,
						own_dir * GameRules.BLUE_LINE_Z)
				t_ret = AIActionScoring.time_to_arrive(
						s.position, tag_pt, vel, speed) \
						+ AIActionScoring.time_to_arrive(
								tag_pt, puck_pos, Vector3.ZERO, speed)
			else:
				t_ret = AIActionScoring.time_to_arrive(
						s.position, puck_pos, vel, speed)
			_append_channel(puck_pos, t_ret, Vector3.ZERO, speed, accel)
	_race_key_speed = -1.0
	_prepare_reach(self_race_vmax(ctx), ctx.self_max_accel)


# Sprint-aware SELF cap for home/station races — the backchecking body
# sprints (an explicit BotSprintRules use case), so a cruise-priced
# containment radius under-reached every long race home and the stands
# sagged earlier than the legs they model. Race length ≈ the trip home;
# pool/lockout from our own replicated state. Every race_home_feasible /
# most_forward_feasible caller passes THIS (not ctx.self_max_speed) so the
# per-fill reach memo keys one consistent value.
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
			_xz_distance(ctx.self_pos, ctx.defending_goal_pos))


# Precompute, for the calling defender's build, the squared containment
# radius of every station: reach (blade span) + the run a standing start
# covers in the time the puck needs to get there (same capped ramp the
# calibrated time_to_arrive charges), minus the SET margin at every station.
# Exact inversion of the per-station race race_home_feasible used to solve
# candidate-by-candidate.
#
# SET ARRIVAL at every station — containment is not presence. A defender who
# merely GETS to a mid-path station as the rush arrives is screaming through
# it at full stride — beaten through it exactly like the "holds the blue
# line, gets beat through the middle" failure. Playing the man at a station
# means arriving with your closing speed already killed, whether the station
# is the net mouth or mid-NZ. So the radius solves the SET-ARRIVAL profile
# (not raw travel):
#   short budget — triangular: accelerate then brake to zero inside `avail`;
#     covered ground is ½·k·avail² with k = a·B/(a+B) (the effective accel of
#     an accelerate-brake round trip; B = the arrival brake decel);
#   long budget — trapezoidal: full ramp (d_ramp) + brake run (v²/2B, the
#     braking DISTANCE the old net-only margin forgot to credit) + cruise for
#     whatever time remains.
# A station already under the blade needs no travel and stays contained at
# any budget — the camped line stand still stuffs the man who skates into
# it. Charging the set profile everywhere collapses feasibility while a
# breakout is still FORMING (the carrier gathering speed deep in his zone),
# which is what starts the back-off early enough to gap up, instead of after
# the race is already lost. (Replaces the old net-station-only brake margin.)
static func _prepare_reach(self_max_speed: float, self_max_accel: float) -> void:
	if self_max_speed == _race_key_speed and self_max_accel == _race_key_accel:
		return
	_race_key_speed = self_max_speed
	_race_key_accel = self_max_accel
	var reach: float = SkaterAgentStateMachine.BLADE_REACH_M
	var n_fracs: int = RACE_PATH_FRACTIONS.size()
	_race_reach_sq.clear()
	var total: int = _race_channel_count * n_fracs
	for idx: int in total:
		var avail: float = _race_station_ts[idx]
		if avail < 0.0:
			_race_reach_sq.append(-1.0)
			continue
		var r: float = reach + set_arrival_distance(
				avail, self_max_speed, self_max_accel)
		_race_reach_sq.append(r * r)


# ── Last-man step-up discipline ──────────────────────────────────────────────
# PRESSURE's last-man step-up bound. RUSH_D1 no longer uses it — the rush gap
# is the ladder now (AIRoleRushD), which is bounded by design rather than by a
# rendezvous clamp — so this is the in-zone pressurer's own discipline: don't
# lunge a cut-off you cannot arrive at set.
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
# home from behind. So the step-up is bounded by the RENDEZVOUS: cover only what
# can be covered and still be TRAVELLING WITH THE RUSH by the time the sweeping
# stand meets us there. A step-up of `s` leaves the stand `step_needed - s` of
# ice to cover at `closing`, and the budget that buys is charged twice:
#   • the trip itself, priced as a set arrival (set_arrival_distance — up to
#     speed and back down, since a stand overrun at pace is no stand);
#   • the PIVOT out of it, `closing / accel` — the time to spin the body back up
#     to the rush's own speed going the other way. Being merely stopped when the
#     carrier arrives is not gap control: a stationary defender is beaten by any
#     lateral cut, so the posture the step-up has to leave time for is matching
#     his pace goal-side. Charging it is also what makes the bound stable under
#     re-planning — without it the budget only shrinks as fast as the carrier
#     closes, so a defender re-granted a fresh step every dispatch never gets
#     around to executing the braking half and creeps into a lunge anyway.
# Feasibility is monotone in `s` (a longer step costs more ground AND leaves less
# time for it), so one bisection lands the largest one.
#
# The shape falls out at both ends by construction: a stalled or regrouping
# carrier's stand isn't going anywhere, so the budget is unbounded and the
# defender closes right up (gapping up); a carrier flying in leaves almost no
# budget, so the defender holds his ground and makes the rush come to him.
# Returns `desired_depth` unchanged whenever no bound applies — a stand already
# goal-side of us is a retreat, which costs no reversal.
static func settable_stand_depth(ctx: RoleContext, threat_pos: Vector3,
		dir_net: Vector3, desired_depth: float, closing: float) -> float:
	var self_along: float = (ctx.self_pos.x - threat_pos.x) * dir_net.x \
			+ (ctx.self_pos.z - threat_pos.z) * dir_net.z
	var step_needed: float = self_along - desired_depth
	if step_needed <= 0.0 or closing <= 0.01:
		return desired_depth
	var v_max: float = self_race_vmax(ctx)
	if _step_arrives_set(step_needed, step_needed, closing, v_max, ctx.self_max_accel):
		return desired_depth
	var lo: float = 0.0
	var hi: float = step_needed
	for _i: int in 6:
		var mid: float = (lo + hi) * 0.5
		if _step_arrives_set(mid, step_needed, closing, v_max, ctx.self_max_accel):
			lo = mid
		else:
			hi = mid
	return self_along - lo


# Can we cover a step-up of `s` and be back up to the rush's pace going the other
# way by the time the stand — still `step_needed - s` of ice away, sweeping at
# that pace — gets there? The pivot out of the step-up is charged off the top of
# the budget; what's left has to pay for the trip as a set arrival.
static func _step_arrives_set(s: float, step_needed: float, closing: float,
		v_max: float, max_accel: float) -> bool:
	var pivot_s: float = closing / maxf(
			max_accel * AIActionScoring.RAMP_EFFICIENCY, 0.001)
	return set_arrival_distance(
			(step_needed - s) / closing - pivot_s, v_max, max_accel) >= s


# How far a skater can travel in `t` seconds from a standing start and still
# arrive SET — closing speed already killed. The shared home of the set-arrival
# profile described above (_prepare_reach's containment radii and CONTAIN's
# step-up clamp both ask "can I be there, stopped, in time?"):
#   short budget — triangular: accelerate then brake to zero inside `t`; the
#     covered ground is ½·k·t² with k = a·B/(a+B), the effective accel of an
#     accelerate-brake round trip (B = the arrival brake decel);
#   long budget — trapezoidal: full ramp (v²/2a) + brake run (v²/2B) + cruise
#     for whatever time remains.
static func set_arrival_distance(t: float, v_max: float,
		max_accel: float) -> float:
	if t <= 0.0:
		return 0.0
	var v: float = maxf(v_max, 1.0)
	var brake_decel: float = AISteering.ARRIVAL_BRAKE_DECEL_M_S2
	var a_net: float = maxf(max_accel * AIActionScoring.RAMP_EFFICIENCY, 0.001)
	var t_tri_max: float = v / a_net + v / brake_decel
	if t <= t_tri_max:
		return 0.5 * (a_net * brake_decel / (a_net + brake_decel)) * t * t
	return v * v / (2.0 * a_net) + v * v / (2.0 * brake_decel) \
			+ v * (t - t_tri_max)


static func _append_channel(gain_pt: Vector3, t_gain: float,
		carry_vel: Vector3, speed: float, accel: float) -> void:
	# The calibrated time_to_arrive prices the whole carry (redirect + ramp +
	# cruise). Stations along the straight path share its redirect cost and
	# split the pursuit leg by the fraction of distance — a slight
	# near-station optimism for the rush (the ramp is front-loaded in time),
	# which errs conservative for the defender.
	var t_full: float = AIActionScoring.time_to_arrive(
			gain_pt, _race_net, carry_vel, speed, accel)
	for f: float in RACE_PATH_FRACTIONS:
		_race_station_pts.append(gain_pt.lerp(_race_net, f))
		_race_station_ts.append(t_gain + f * t_full)
	_race_channel_count += 1


# Can a defender standing at `c` contain every filled counter channel — i.e.
# for each channel, reach SOME post-gain path station (within blade reach),
# set, before the puck gets there? Requires a prior fill_counter_channels
# (which precomputes this build's per-station containment radii — the loop
# here is one squared-distance compare per station).
static func race_home_feasible(c: Vector3,
		self_max_speed: float, self_max_accel: float) -> bool:
	_prepare_reach(self_max_speed, self_max_accel)
	var n_fracs: int = RACE_PATH_FRACTIONS.size()
	for k: int in _race_channel_count:
		var contained: bool = false
		for j: int in n_fracs:
			var idx: int = k * n_fracs + j
			var p: Vector3 = _race_station_pts[idx]
			var r_sq: float = _race_reach_sq[idx]
			if r_sq < 0.0:
				continue
			var dx: float = p.x - c.x
			var dz: float = p.z - c.z
			if dx * dx + dz * dz <= r_sq:
				contained = true
				break
		if not contained:
			return false
	return true


# A station's home post has to be meaningfully deeper than the stand it is
# bounding to be a retreat at all — one stride, so a station already standing on
# its own post doesn't read as "retreat zero metres" and lose its bound entirely.
const HOME_FLOOR_BIND_MARGIN_M: float = 1.0


# The deepest a station may sag (see most_forward_feasible's `floor_point`).
#
# The principle: an OFF-PUCK STATION's retreat is about repositioning for a
# possible turnover, not about defending an actual rush. Defending an actual
# rush is transition defense's job — a different possession state with different
# roles. So when a station's forward stand stops being recoverable, the answer is
# "get back to your post", not "keep skating to the crease". Bisecting to the
# net-front stand is how a defenseman ended up parked on his own goal line while
# the play was still in the offensive zone (docs/transition-defense-plan.md §2.1).
#
# Two tiers, and which applies falls out of the geometry rather than a per-caller
# decision:
#   • a station that plays UP-ICE of home (the points, the forecheck line pair,
#     F3, the high slot, the trailing valve) floors at its own defensive home
#     post — the dot lane at its blue line for a D, the high ice just up-ice of
#     it for a forward (AIZoneCoverage.defensive_anchor);
#   • a station whose stand already IS its home (the NEUTRAL back pair, the
#     flanks) can't be bounded by it, so it floors at the HOUSE GATE — the top of
#     the circles, the depth the research names as where backcheckers stop. Still
#     never the crease.
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


# The point on the net → `fwd` ray at the top of the circles: the deepest a field
# skater should ever be pushed by a race-home bound. Below it he duplicates the
# goalie, fights his own crease repel, and overshoots behind the goal line.
static func house_gate_floor(our_net: Vector3, fwd: Vector3) -> Vector3:
	var dx: float = fwd.x - our_net.x
	var dz: float = fwd.z - our_net.z
	var d: float = sqrt(dx * dx + dz * dz)
	if d < 0.001 or d <= AIZoneCoverage.HOUSE_TOP_DEPTH_M:
		return fwd
	var k: float = AIZoneCoverage.HOUSE_TOP_DEPTH_M / d
	return Vector3(our_net.x + dx * k, 0.0, our_net.z + dz * k)


# The most forward point on the `fwd` → floor segment that is still
# race-home feasible: `fwd` itself when the stand holds, else a bisection
# down the retreat line — the sag-to-even that replaces the old radius
# clamp.
#
# `floor_point` is the deepest the retreat may go. Callers that own a defensive
# post pass station_retreat_floor(ctx); the default (INF) keeps the legacy
# NET-FRONT STAND (_race_home_stand), which is still the right floor for a body
# genuinely defending the doorstep — but is far too deep for an off-puck station,
# and passing it there is what produced the parked-on-the-goal-line failure.
# Never the net point itself: a skater on the goal line duplicates the goalie,
# fights his own crease repel, and overshoots behind the line.
#
# A `fwd` already at or deeper than the floor is returned untouched — the station
# is by definition already home, so there is nothing left to concede.
static func most_forward_feasible(fwd: Vector3,
		self_max_speed: float, self_max_accel: float,
		floor_point: Vector3 = Vector3.INF) -> Vector3:
	if race_home_feasible(fwd, self_max_speed, self_max_accel):
		return fwd
	var floor_pt: Vector3 = _race_home_stand
	if floor_point.is_finite():
		# Only binds when it is genuinely a RETREAT (nearer our net than the
		# stand we're giving up on); otherwise the bisection would push the
		# station the wrong way, away from its own goal.
		if _xz_distance(floor_point, _race_net) >= _xz_distance(fwd, _race_net):
			return fwd
		floor_pt = floor_point
	var lo: float = 0.0
	var hi: float = 1.0
	for _i: int in 6:
		var mid: float = (lo + hi) * 0.5
		if race_home_feasible(floor_pt.lerp(fwd, mid),
				self_max_speed, self_max_accel):
			lo = mid
		else:
			hi = mid
	return floor_pt.lerp(fwd, lo)


static func _xz_distance(a: Vector3, b: Vector3) -> float:
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
static func loose_puck_race_lost(
		snapshot: WorldSnapshot, self_pos: Vector3, self_vel: Vector3,
		self_max_speed: float, team_id: int, team_id_by_peer: Dictionary,
		caps_by_peer: Dictionary, self_pid: int = -1) -> bool:
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
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) == team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		# A SLOW puck's race is only lost to an opponent actually running it
		# (on the puck, or genuinely closing — committed_to_race). The ETA
		# model prices his hypothetical sprint-from-now; declining on a body
		# that is NOT going for the puck left it sitting between two staring
		# teams (both sides declined on hypothetical winners). Fast pucks
		# keep the pure path race: momentum already encodes commitment
		# there, and a downstream interceptor legitimately waits still.
		if traj.is_empty() \
				and not AILoosePuckChase.committed_to_race(s, puck_pos):
			continue
		var speed: float = AILoosePuckChase.race_vmax(
				s, caps_by_peer.get(pid), puck_pos)
		var t: float
		if traj.is_empty():
			t = AIActionScoring.time_to_arrive(s.position, puck_pos, s.velocity, speed)
		else:
			t = AILoosePuckChase.path_intercept_time(
					traj, step_dt, s.position, s.velocity, speed)
		if t < best_opp_eta:
			best_opp_eta = t
	if best_opp_eta == INF:
		return false
	var contest_window: float = AIActionScoring.CHASE_CONTEST_MARGIN_M \
			/ maxf(self_max_speed, 1.0)
	return my_eta > best_opp_eta + contest_window
