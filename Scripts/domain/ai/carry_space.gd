class_name AICarrySpace

# How much room a carrier has to operate, and what he can do with it: the
# pursuit-evasion half of the carrier's read, split out of AIActionScoring.
#
# It separates cleanly because it already was separate. Across six sections and
# ~1,200 lines it makes no calls the rest of the scorer depends on, touches none
# of the difficulty-synced goalie statics, and owns its own constants. What it
# still borrows is named: the shared arrival clock (`time_to_arrive`), the net
# obstacle test, six reference speeds, and the puck-protect handle the shot side
# also reads. **The dependency runs one way** — this class reads
# `AIActionScoring`, never the reverse — and it must stay that way, because a
# const read across a GDScript `class_name` cycle is a parse error rather than a
# runtime one.
#
# Everything here is a grounded model, per Scripts/domain/ai/CLAUDE.md: a
# reachable set is real pursuit-evasion geometry, controlled space is measured
# room rather than a proximity curve, and the deke and brake reads are races run
# at real accelerations. Keep them that way — a curve fitted to feel right does
# not belong in this file.

# ── Reachable-set evasion (pursuit-evasion possession safety) ────────────────
# Whether a defender threatens the puck is not "how close is he" but "can he get
# a stick to it given his MOMENTUM and reaction." Each skater is a bounded-accel
# body: over a short horizon its body rides its velocity to (pos + vel·T) and can
# deviate from that line by at most ½·A·(T−reaction)² (a double integrator's
# reachable set), with the stick reaching further. So a defender's stick can
# touch anywhere within (maneuver + stick) of his MOMENTUM-projected position.
#
# This is what a pure proximity model cannot see: a hard charger's
# disk rides downrange to where you WERE, leaving the space he vacated wide open
# (beat him by letting him overshoot); a contained/jockeying defender's disk stays
# on you (real containment); a stick on the puck stays a strip threat. The carrier
# evades by placing the puck in his own handling envelope at a point outside every
# defender disk — the SEAM. Two seam reads share one sampler: the max-clearance
# seam (best_evade_point) is the honest "can I keep the puck at all" safety read,
# and the objective-DIRECTED seam (best_evade_point_toward) is the playmaking one
# — the safe sample with the most progress toward the carry objective, so the
# deke goes PAST the man toward the spot the carrier wants, and doubles as a
# carry candidate. prefers_brake_check prices the third maneuver (stop dead, let
# a committed checker's reach fly past) in the same clearance currency.
#
# The BOARDS bound the seam search, not the clearance itself: a wall doesn't
# strip the puck (a carrier 0.3 m off the boards with no defender in reach is
# perfectly safe), it removes ESCAPE OPTIONS — the puck can't be handled through
# it. So the seam samplers intersect the handling envelope with the playing
# surface (off-surface samples are rejected), and the wall-pincer humans
# actually use emerges: pinned against the boards, half the envelope is illegal,
# the best legal seam runs along the wall, and its clearance from the sealing
# defender is honestly small.
const MANEUVER_ACCEL_M_S2: float = GameRules.DEFAULT_SKATER_THRUST_M_S2
const EVADE_HORIZON_S: float = 0.40    # a deke/cut's length — the evasion look-ahead
const EVADE_REACTION_S: float = 0.15   # a defender reads a cut before he can redirect to it
const EVADE_STICK_REACH_M: float = (   # how far a defender's stick touches from his body
		GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M)
# A full stick of clear room reads as fully safe; inside the reach reads as 0.
const EVADE_SAFE_MARGIN_M: float = EVADE_STICK_REACH_M
# Envelope sampling for the seam search (rings × angles). Coarse is fine — the
# seam is a broad region, not a point.
const EVADE_SAMPLE_RINGS: Array[float] = [0.4, 0.8, 1.0]
const EVADE_SAMPLE_ANGLES: int = 12
# A strip needs the blade ON the puck, so a sample sitting exactly at the edge
# of a defender's best-case reach (clearance 0) is escapable in the model's own
# terms — but the model reacts only once (the reaction gate), while a real
# defender re-reads continuously. One blade-length of air is the physical slop
# that survives that re-read: the puck stays a blade off his best-case touch.
# Samples at or above this clearance are treated as genuinely SAFE by the
# objective-directed seam (progress may be preferred among them); below it,
# clearance itself is the only currency.
const EVADE_SAFE_CLEAR_MIN_M: float = GameRules.DEFAULT_BLADE_LENGTH_M


# Gap (metres) from a puck point to the nearest board. Negative outside the
# playing surface — the seam samplers reject those samples (the handling
# envelope intersected with the rink; see the boards note above). Uses the
# INNER extents (the surface the puck actually lives on, inside kickplate lip
# + wall half-thickness).
static func board_gap_m(point: Vector3) -> float:
	return minf(GameRules.INNER_HALF_WIDTH - absf(point.x),
			GameRules.INNER_HALF_LENGTH - absf(point.z))


# Clearance (metres) of a puck point from every defender's reachable stick at
# `time` — >0 means no defender's stick TIP nominally reaches it (that much
# room), <0 means covered. Pure float math, no allocation.
#
# NOMINAL, not best-case: the defender's coverage is the calibrated
# time_to_arrive phase model in distance form — coast on momentum through the
# reaction gate, shed excess cross-speed at the measured rate, brake out a
# retreat (losing ground while braking), then a speed-capped pursuit ramp at
# the measured net accel (AIActionScoring.RAMP_EFFICIENCY) — plus the stick span. Measured
# against a committed defender under the real movement rules + rate-limited
# blade (the #27 probe): crossing times track reality within ~0.05 s at rest
# and toward-motion across 2–12 m, where a best-case 0.5·a·t² lunge over-reaches
# by 3+ m at long windows (the pacified carrier) while UNDER-reaching close-in. Known optimistic spots, same as time_to_arrive's:
# short perpendicular cuts at speed (the steering miss-loop). The safety maps
# below carry the residual as a measured probability band.
# `abort_below`: exact argmax pruning for sample-scanning callers (the seam
# search) — once the running worst drops below it, the exact value cannot
# matter to the caller, so the defender loop stops early. Default −INF scans
# every defender (every value-consuming caller).
static func reach_clearance(
		puck_point: Vector3, time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [], maneuver_time: float = -1.0,
		carry_dir: Vector2 = Vector2.ZERO, carry_speed: float = 0.0,
		abort_below: float = -INF) -> float:
	var n: int = opponents.size()
	if n == 0 or opponent_vels.size() != n:
		return EVADE_SAFE_MARGIN_M   # nothing to evade — fully clear
	# `maneuver_time` is the defender's COMMIT window — how long he actively
	# pursues the sample point; the body coasts on momentum for the remainder.
	# Default (< 0) commits the whole window (the carry/hold reads). The
	# PASS-RECEPTION and carry-END reads pass a short window (EVADE_HORIZON_S /
	# CARRY_LUNGE_WINDOW_S): the defender isn't credited with committing to the
	# catch spot for the whole flight — the in-flight interception is the lane
	# model's ledger, and at a carry's arrival the carrier is established and
	# protecting.
	var w: float = time if maneuver_time < 0.0 else minf(time, maneuver_time)
	var has_caps: bool = opponent_caps.size() == n
	var gated: bool = carry_speed > 0.0
	var worst: float = INF
	for i: int in n:
		var accel: float = MANEUVER_ACCEL_M_S2
		var stick: float = EVADE_STICK_REACH_M
		var vmax: float = AIActionScoring.SKATER_REF_SPEED_M_S
		var grip: float = 1.0
		if has_caps:
			# Per-opponent build — Acceleration (max_accel) sets the ramp, reach
			# (blade_span) the stick, Speed (max_speed) the cap. Empty caps →
			# league constants for all (every non-attribute caller).
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				accel = caps.max_accel
				stick = caps.blade_span
				vmax = caps.max_speed
				grip = caps.lateral_grip
		# PRESCREEN (exact): the phase model's total ground toward the point is
		# bounded by the whole window at the better of current pace or cap
		# (coast ≤ |v|·coast, capped pursuit ≤ vmax·τ; shed/brake only lose
		# ground) — so clearance ≥ dist − speed_ub·time − stick. When even that
		# floor can't come under the running worst, this defender cannot move
		# the min and the full model is skipped. L1 speed (≥ L2) keeps the
		# bound conservative; squared compare avoids the sqrt. In a 5v5 scene
		# this collapses the far bodies to a handful of flops each.
		var speed_ub: float = maxf(vmax,
				absf(opponent_vels[i].x) + absf(opponent_vels[i].z))
		var need: float = worst + speed_ub * time + stick
		if need <= 0.0:
			continue
		var sdx: float = puck_point.x - opponents[i].x
		var sdz: float = puck_point.z - opponents[i].z
		if sdx * sdx + sdz * sdz >= need * need:
			continue
		if gated:
			# ESCAPE-SPEED gate (opt-in, `carry_speed > 0`): a defender chasing
			# near the carrier's pace along `carry_dir` (world XZ as Vector2(x,z))
			# is committed to keeping up — only his surplus accel can redirect
			# onto the puck. Momentum progress (v0 below) is untouched: a faster
			# chaser still runs the carry down; a pace-matched one holds the gap.
			var v_along_carry: float = opponent_vels[i].x * carry_dir.x \
					+ opponent_vels[i].z * carry_dir.y
			accel *= clampf(1.0 - maxf(v_along_carry, 0.0) / carry_speed, 0.0, 1.0)
		var clear: float = _reach_clearance_one(
				puck_point.x, puck_point.z, time, w,
				opponents[i].x, opponents[i].z,
				opponent_vels[i].x, opponent_vels[i].z, accel, stick, vmax, grip)
		if clear < worst:
			worst = clear
			if worst < abort_below:
				return worst
	return worst


# One defender's nominal reach clearance (see reach_clearance): coast on
# momentum until the commit window `w` opens, react, then shed / brake / ramp
# toward the point at the calibrated net kinematics. Factored out so the carry
# reads can additionally sample each defender at its own closest-approach
# moment on the path.
static func _reach_clearance_one(point_x: float, point_z: float, time: float,
		w: float, ox: float, oz: float, vx: float, vz: float,
		accel: float, stick: float, vmax: float,
		lateral_grip: float = 1.0) -> float:
	var tau: float = maxf(0.0, minf(time, w) - EVADE_REACTION_S)
	var coast: float = time - tau
	var px: float = ox + vx * coast
	var pz: float = oz + vz * coast
	var dx: float = point_x - px
	var dz: float = point_z - pz
	var dist: float = sqrt(dx * dx + dz * dz)
	var d: float = 0.0
	if tau > 0.0 and dist > 0.001:
		var inv: float = 1.0 / dist
		var v_along: float = (vx * dx + vz * dz) * inv
		var v_perp: float = absf((vx * dz - vz * dx) * inv)
		# Shed excess cross-speed (a pure delay, as calibrated — perpendicular
		# authority = thrust × lateral_grip, the same quantity the movement
		# core scales), then brake out any retreat (losing ground), then the
		# capped pursuit ramp (pure accel — grip never limits parallel drive).
		var agility: float = maxf(accel * lateral_grip, 0.001) / AIActionScoring.SHED_ACCEL_DEFAULT_M_S2
		var tau_p: float = tau - maxf(0.0, v_perp - AIActionScoring.VM_FREE_SHED_M_S * agility) \
				/ (AIActionScoring.VM_SHED_DECEL_M_S2 * agility)
		if tau_p > 0.0:
			var v0: float = v_along
			if v0 < 0.0:
				var t_b: float = minf(-v0 / AIActionScoring.REVERSAL_BRAKE_DECEL_M_S2, tau_p)
				d = v0 * t_b + 0.5 * AIActionScoring.REVERSAL_BRAKE_DECEL_M_S2 * t_b * t_b
				v0 += AIActionScoring.REVERSAL_BRAKE_DECEL_M_S2 * t_b
				tau_p -= t_b
			v0 = minf(v0, vmax)
			var a_net: float = maxf(accel * AIActionScoring.RAMP_EFFICIENCY, 0.001)
			var t_r: float = (vmax - v0) / a_net
			if tau_p <= t_r:
				d += v0 * tau_p + 0.5 * a_net * tau_p * tau_p
			else:
				d += (vmax * vmax - v0 * v0) / (2.0 * a_net) + vmax * (tau_p - t_r)
	return dist - d - stick


# ── The safety maps: measured strip probability over nominal clearance ────────
# Production contact is a SWEEP standard, not a tip touch: a strip lands when
# the blade segment passes within the puck-contact radius
# (PuckController.PICKUP_RADIUS — mirrored by the duel harness), so nominal
# tip-standard contact actually connects at +POKE_CONTACT_RADIUS_M of
# clearance. The two maps below are the measured CDFs around that boundary for
# the two regimes the #27 probe separated:
#   DWELL (clearance_to_safety) — the puck holds still at the sample (a stand,
#     a carry's arrival, a reception): contact is deterministic — the probe's
#     committed defender ALWAYS strips a dwelling puck it nominally reaches —
#     so the band is just the model's own measured crossing error, ± one blade
#     length around the contact boundary.
#   TRANSIT (transit_clearance_to_safety) — the puck is passing through the
#     sample mid-carry: the defender must MEET a moving target on a
#     reaction-delayed read, and the staged-carry ensemble shows a wide mixed
#     band — every carry at or below TRANSIT_STRIP_CLEAR_M was stripped, none
#     above TRANSIT_SAFE_CLEAR_M was, outcomes mixed between.
const POKE_CONTACT_RADIUS_M: float = 0.5
const DWELL_HALF_BAND_M: float = GameRules.DEFAULT_BLADE_LENGTH_M
const TRANSIT_STRIP_CLEAR_M: float = -0.4
const TRANSIT_SAFE_CLEAR_M: float = 0.6


# Dwelling-puck safety: 0 once the sweep standard is nominally met
# (POKE_CONTACT_RADIUS_M − DWELL_HALF_BAND_M), 1 a blade past it. The map for
# every hold/stand/arrival/reception read.
static func clearance_to_safety(clearance: float) -> float:
	return clampf(
			(clearance - (POKE_CONTACT_RADIUS_M - DWELL_HALF_BAND_M))
					/ (2.0 * DWELL_HALF_BAND_M),
			0.0, 1.0)


# Moving-puck safety: the measured mixed band for a puck traversing the sample
# at stride (see the map doc above). Lenient relative to the dwell map by
# construction — outrunning a reaction-delayed pursuit is real protection.
static func transit_clearance_to_safety(clearance: float) -> float:
	return clampf((clearance - TRANSIT_STRIP_CLEAR_M)
			/ (TRANSIT_SAFE_CLEAR_M - TRANSIT_STRIP_CLEAR_M), 0.0, 1.0)


# Lunge window for a defender's stick redirect onto a carried puck AT ITS
# ARRIVAL SPOT — the maneuver-time bound the carry safety/strip reads apply
# to their END sample only. At the destination the carrier is established and
# protecting (the evade envelope owns that moment — same reasoning as the
# pass-reception read's short window), so the defender gets his real lunge,
# not a full-window t² repositioning that reads every honest-length carry
# destination as covered near any body (the pacified carrier). The MID
# sample deliberately keeps the full-window pursuit read: en route the puck
# traverses the defender's pursuit envelope at stride, where protection is
# weakest — that asymmetry is what prices "thread the gauntlet" carries as
# dangerous while leaving a peel-out to open ice safe. Same value as the
# reception lunge (one poke moment).
const CARRY_LUNGE_WINDOW_S: float = EVADE_HORIZON_S


# Worst reachable clearance along a carry from→to reached at `arrival_time`.
# Samples the mid-point and the destination (each at its own time, defenders
# momentum-projected) and returns the tightest — so a carry that ends in a seam
# but threads a defender mid-route is still penalised. from == to gives the
# static hold read (is this spot clear over the window).
# `apply_escape` turns on reach_clearance's escape-speed gate (see that doc): a
# defender the carrier is out-skating along this carry can't sustain a strip. The
# carry direction and pace come from (from, to, arrival_time) — the carrier drives
# from→to at exactly that pace — so nothing else need be supplied. Default off
# reproduces the prior model for every non-carry caller.
static func carry_clearance(from: Vector3, to: Vector3, arrival_time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [], apply_escape: bool = false) -> float:
	var carry_dir := Vector2.ZERO
	var carry_speed: float = 0.0
	if apply_escape and arrival_time > 0.0:
		var dx: float = to.x - from.x
		var dz: float = to.z - from.z
		var dist: float = sqrt(dx * dx + dz * dz)
		if dist > 0.001:
			carry_dir = Vector2(dx / dist, dz / dist)
			carry_speed = dist / arrival_time
	# MID sample: full-window pursuit (the en-route gauntlet — see
	# CARRY_LUNGE_WINDOW_S). END sample: pursuit bounded to the arrival
	# lunge — the carrier is established and protecting there.
	var c_mid: float = reach_clearance(
			from.lerp(to, 0.5), arrival_time * 0.5, opponents, opponent_vels,
			opponent_caps, -1.0, carry_dir, carry_speed)
	var c_end: float = reach_clearance(to, arrival_time, opponents, opponent_vels,
			opponent_caps, minf(arrival_time, CARRY_LUNGE_WINDOW_S),
			carry_dir, carry_speed)
	return minf(c_mid, c_end)


# ── Crossing sample: the meeting-strip band ──────────────────────────────────
# The mid/end samples can straddle a defender the carry path MEETS between
# them — a pinch wall just past `from`, a forechecker met in the first
# quarter — and the strip lands at the meeting moment neither sample sees.
# The staged-crossing ensemble (probe: committed seeker under the real
# movement / blade / check_poke rules, sweeping pace 3–12.5 m/s relative ×
# miss distance × closing geometry) measured the meeting outcome as a pure
# DISTANCE band on the contact envelope's own radii, NOT a speed effect:
# every naked crossing whose momentum-line miss distance penetrated the
# stick circle by more than the poke contact radius was swept, at every
# tested pace (the presented blade owns that core), while crossings grazing
# the outer poke-slop ring escaped at pace (blade tracking lag misses the
# fringe). A dwell-time gate was hypothesized and REJECTED by the
# measurement — the naked band edges are simply:
#   core = blade_span − POKE_CONTACT_RADIUS_M   → keep 0 (swept)
#   edge = blade_span                            → keep 1 (grazed at pace)
#
# PROTECTION is the second measured half: re-running the ensemble with a
# protecting carrier (puck ridden on the handle envelope away from the
# threat) shifted the whole band by CROSSING_PROTECT_SHIFT_M — a lone
# defender is beaten at almost any crossing geometry (only a tight head-on
# meeting still strips), which is the duel harness's own emergent truth.
# The shift is a SHARED, DIRECTIONAL budget: the puck line can displace one
# way, so threats on one side get the full credit while an OPPOSED pair (the
# pinch wall, the corralling pincer) split it to nothing — the optimal
# lateral shift between the per-side worst crossings, bounded by the
# measured displacement. That single mechanism is why lone containers are
# beatable while walls are genuinely dangerous.
#
# Slow grazes ARE stripped in reality, but by pursuit, not the meeting —
# and pursuit is exactly what the mid/end transit samples already price
# (verified in the ensemble: every slow-graze strip cell reads dead at the
# mid sample). Only the window INTERIOR is sampled here; the endpoints are
# the mid/end samples' job.
const CROSSING_PROTECT_SHIFT_M: float = 0.8


static func carry_crossing_keep(from: Vector3, to: Vector3, arrival_time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = []) -> float:
	var n: int = opponents.size()
	if n == 0 or opponent_vels.size() != n or arrival_time <= 0.0:
		return 1.0
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var seg: float = sqrt(dx * dx + dz * dz)
	if seg < 0.001:
		return 1.0
	var dirx: float = dx / seg
	var dirz: float = dz / seg
	var inv_t: float = 1.0 / arrival_time
	var pvx: float = dx * inv_t   # puck velocity along the carry
	var pvz: float = dz * inv_t
	var pv_len: float = seg * inv_t
	var has_caps: bool = opponent_caps.size() == n
	# Per-side worst crossing, in band units (d_min − span so different builds'
	# spans compose): the shared protect shift then resolves between the sides.
	var worst_l: float = INF
	var worst_r: float = INF
	for i: int in n:
		var span: float = EVADE_STICK_REACH_M
		if has_caps:
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				span = caps.blade_span
		var r0x: float = from.x - opponents[i].x
		var r0z: float = from.z - opponents[i].z
		# PRESCREEN (exact): the meeting can't come nearer than the current
		# separation minus the whole window's relative travel (|rv| ≤ |pv| +
		# |v|, L1-bounded), so margin ≥ |r0| − rv_ub·T − span. A margin at or
		# above the full protect budget is RESULT-identical to absence: the
		# side it would post ≥ SHIFT on either keeps its own worst (min) or,
		# as a lone entry, resolves through the shift to the same clamped
		# keep the single-sided formula gives (the two branches agree once
		# one side's slack covers the whole budget). Squared compare, no sqrt.
		var rv_ub: float = pv_len \
				+ absf(opponent_vels[i].x) + absf(opponent_vels[i].z)
		var far_need: float = span + CROSSING_PROTECT_SHIFT_M + rv_ub * arrival_time
		if r0x * r0x + r0z * r0z >= far_need * far_need:
			continue
		var rvx: float = pvx - opponent_vels[i].x
		var rvz: float = pvz - opponent_vels[i].z
		var rv_sq: float = rvx * rvx + rvz * rvz
		if rv_sq < 0.0001:
			continue   # co-moving: no meeting — endpoints cover it
		var t_star: float = -(r0x * rvx + r0z * rvz) / rv_sq
		if t_star <= 0.0 or t_star >= arrival_time:
			continue   # closest approach outside the window — endpoints cover it
		var mx: float = r0x + rvx * t_star
		var mz: float = r0z + rvz * t_star
		var d_min: float = sqrt(mx * mx + mz * mz)
		# Which side of the carry line the defender crosses on (m is puck −
		# defender at t*, so the defender sits at −m relative to the path).
		var margin: float = d_min - span
		if margin <= -(POKE_CONTACT_RADIUS_M + CROSSING_PROTECT_SHIFT_M):
			# Deeper than the full protect credit can ever recover — swept
			# regardless of the other side's slack.
			return 0.0
		if dirx * (-mz) - dirz * (-mx) >= 0.0:
			if margin < worst_l:
				worst_l = margin
		else:
			if margin < worst_r:
				worst_r = margin
	if worst_l == INF and worst_r == INF:
		return 1.0
	# Optimal shared lateral shift of the puck line between the two sides,
	# bounded by the measured protect displacement (a shift toward the right
	# widens every left-side gap and narrows every right-side one).
	var eff: float
	if worst_l < INF and worst_r < INF:
		var x: float = clampf((worst_r - worst_l) * 0.5,
				-CROSSING_PROTECT_SHIFT_M, CROSSING_PROTECT_SHIFT_M)
		eff = minf(worst_l + x, worst_r - x)
	else:
		eff = (worst_l if worst_l < INF else worst_r) + CROSSING_PROTECT_SHIFT_M
	return clampf((eff + POKE_CONTACT_RADIUS_M) / POKE_CONTACT_RADIUS_M, 0.0, 1.0)


# Possession safety [0, 1] of a carry — the regime-aware map application (see
# the safety-map doc above reach_clearance): the MID sample is a moving puck
# (transit band), the END sample a dwelling one (the carrier arrives there),
# a stand (from == to) dwells at both, and each defender the path MEETS
# between the fixed samples contributes the measured crossing band
# (carry_crossing_keep). Callers use this instead of
# clearance_to_safety(carry_clearance(...)), which forced one map onto both
# regimes.
static func carry_safety(from: Vector3, to: Vector3, arrival_time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [], apply_escape: bool = false) -> float:
	var carry_dir := Vector2.ZERO
	var carry_speed: float = 0.0
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if apply_escape and arrival_time > 0.0 and dist > 0.001:
		carry_dir = Vector2(dx / dist, dz / dist)
		carry_speed = dist / arrival_time
	if dist < 0.001:
		# A stand: the puck dwells the whole window — both samples read dwell.
		var s_mid: float = clearance_to_safety(reach_clearance(
				from, arrival_time * 0.5, opponents, opponent_vels,
				opponent_caps))
		if s_mid <= 0.0:
			return 0.0
		return minf(s_mid, clearance_to_safety(reach_clearance(
				from, arrival_time, opponents, opponent_vels,
				opponent_caps, minf(arrival_time, CARRY_LUNGE_WINDOW_S))))
	# Sequential early-outs — each factor can only lower the min, so any zero
	# skips the remaining defender loops. In a scramble most candidates die at
	# the first read; the hot-path cost of the three-sample honesty is paid
	# only by candidates that are actually alive.
	var crossing: float = carry_crossing_keep(
			from, to, arrival_time, opponents, opponent_vels, opponent_caps)
	if crossing <= 0.0:
		return 0.0
	var t_mid: float = transit_clearance_to_safety(reach_clearance(
			from.lerp(to, 0.5), arrival_time * 0.5, opponents, opponent_vels,
			opponent_caps, -1.0, carry_dir, carry_speed))
	if t_mid <= 0.0:
		return 0.0
	return minf(crossing, minf(t_mid, clearance_to_safety(reach_clearance(
			to, arrival_time, opponents, opponent_vels,
			opponent_caps, minf(arrival_time, CARRY_LUNGE_WINDOW_S),
			carry_dir, carry_speed))))


# WHERE a carry gets stripped, if it does: the EARLIEST covered point on the path.
# The turnover cost of a carry is priced HERE, not at the destination — a strip
# surrenders the puck where you were caught, in the traffic you were skating
# through, not the safe spot you were headed for. Chronological, not tightest: the
# reach balloons with time (maneuver ∝ time²), so a far destination reads as
# "more covered", but a puck stripped mid-route never reaches it — the mid-point
# strip happens first. Mirrors lane_loss_point for passes; from == to is a stand.
static func carry_strip_point(from: Vector3, to: Vector3, arrival_time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [], apply_escape: bool = false) -> Vector3:
	var carry_dir := Vector2.ZERO
	var carry_speed: float = 0.0
	if apply_escape and arrival_time > 0.0:
		var ddx: float = to.x - from.x
		var ddz: float = to.z - from.z
		var ddist: float = sqrt(ddx * ddx + ddz * ddz)
		if ddist > 0.001:
			carry_dir = Vector2(ddx / ddist, ddz / ddist)
			carry_speed = ddist / arrival_time
	# Sample windows must mirror carry_safety exactly so the strip point and
	# the safety read agree on which sample is covered (crossing = the
	# meeting-strip band's SHIFT-ADJUSTED core, mid = full pursuit, end =
	# arrival lunge). The earliest core-hit crossing pre-empts the fixed
	# samples when the meeting happens first — a pinch wall driven into
	# strips at the wall.
	var cross_t: float = INF
	var cross_pt: Vector3 = to
	var seg_x: float = to.x - from.x
	var seg_z: float = to.z - from.z
	var seg_len: float = sqrt(seg_x * seg_x + seg_z * seg_z)
	if arrival_time > 0.0 and seg_len > 0.001 \
			and opponent_vels.size() == opponents.size():
		var dirx: float = seg_x / seg_len
		var dirz: float = seg_z / seg_len
		var inv_t: float = 1.0 / arrival_time
		var pvx: float = seg_x * inv_t
		var pvz: float = seg_z * inv_t
		var has_caps: bool = opponent_caps.size() == opponents.size()
		# Pass 1: per-side worst margins → the shared protect shift, exactly
		# as carry_crossing_keep resolves it.
		var worst_l: float = INF
		var worst_r: float = INF
		for i: int in opponents.size():
			var rvx: float = pvx - opponent_vels[i].x
			var rvz: float = pvz - opponent_vels[i].z
			var rv_sq: float = rvx * rvx + rvz * rvz
			if rv_sq < 0.0001:
				continue
			var r0x: float = from.x - opponents[i].x
			var r0z: float = from.z - opponents[i].z
			var t_star: float = -(r0x * rvx + r0z * rvz) / rv_sq
			if t_star <= 0.0 or t_star >= arrival_time:
				continue
			var mx: float = r0x + rvx * t_star
			var mz: float = r0z + rvz * t_star
			var span: float = EVADE_STICK_REACH_M
			if has_caps:
				var caps: AISkaterCaps = opponent_caps[i]
				if caps != null:
					span = caps.blade_span
			var margin: float = sqrt(mx * mx + mz * mz) - span
			if dirx * (-mz) - dirz * (-mx) >= 0.0:
				worst_l = minf(worst_l, margin)
			else:
				worst_r = minf(worst_r, margin)
		var shift: float = CROSSING_PROTECT_SHIFT_M
		var both: bool = worst_l < INF and worst_r < INF
		if both:
			shift = clampf((worst_r - worst_l) * 0.5,
					-CROSSING_PROTECT_SHIFT_M, CROSSING_PROTECT_SHIFT_M)
		# Pass 2 (earliest crossing whose shift-adjusted margin hits the core)
		# runs only when some crossing could be swept even under the most
		# favourable shift — the common open-ice case skips it entirely.
		if minf(worst_l, worst_r) \
				<= -POKE_CONTACT_RADIUS_M + CROSSING_PROTECT_SHIFT_M:
			for i: int in opponents.size():
				var rvx2: float = pvx - opponent_vels[i].x
				var rvz2: float = pvz - opponent_vels[i].z
				var rv_sq2: float = rvx2 * rvx2 + rvz2 * rvz2
				if rv_sq2 < 0.0001:
					continue
				var r0x2: float = from.x - opponents[i].x
				var r0z2: float = from.z - opponents[i].z
				var t_star2: float = -(r0x2 * rvx2 + r0z2 * rvz2) / rv_sq2
				if t_star2 <= 0.0 or t_star2 >= arrival_time or t_star2 >= cross_t:
					continue
				var mx2: float = r0x2 + rvx2 * t_star2
				var mz2: float = r0z2 + rvz2 * t_star2
				var span2: float = EVADE_STICK_REACH_M
				if has_caps:
					var caps2: AISkaterCaps = opponent_caps[i]
					if caps2 != null:
						span2 = caps2.blade_span
				var margin2: float = sqrt(mx2 * mx2 + mz2 * mz2) - span2
				var left: bool = dirx * (-mz2) - dirz * (-mx2) >= 0.0
				var eff: float = margin2 + CROSSING_PROTECT_SHIFT_M
				if both:
					eff = margin2 + (shift if left else -shift)
				if eff <= -POKE_CONTACT_RADIUS_M:
					cross_t = t_star2
					cross_pt = Vector3(
							from.x + pvx * t_star2, 0.0, from.z + pvz * t_star2)
	var mid: Vector3 = from.lerp(to, 0.5)
	if cross_t < arrival_time * 0.5:
		return cross_pt   # met and swept before the mid sample
	var c_mid: float = reach_clearance(mid, arrival_time * 0.5, opponents,
			opponent_vels, opponent_caps, -1.0, carry_dir, carry_speed)
	if c_mid < 0.0:
		return mid   # covered mid-route — stripped there, before the destination
	if cross_t < arrival_time:
		return cross_pt   # met and swept between the mid and end samples
	var c_end: float = reach_clearance(to, arrival_time, opponents, opponent_vels,
			opponent_caps, minf(arrival_time, CARRY_LUNGE_WINDOW_S),
			carry_dir, carry_speed)
	if c_end < 0.0:
		return to    # clear mid-route, covered at the destination
	# Neither covered (a low strip probability anyway): the tighter of the two.
	return mid if c_mid <= c_end else to



# How far along `bearing` this body can actually get within `horizon_s`.
#
# From the double-integrator reachable set: with bounded acceleration, the
# positions reachable at time T form a disc centred on the MOMENTUM-PROJECTED
# point (pos + v*T) with radius 0.5*a*T^2 — the deviation the thrust can buy
# off the ballistic path. Intersecting the bearing ray with that disc gives the
# farthest point in that direction which is a real destination rather than a
# wish.
#
# Returns a NEGATIVE value when the ray misses the disc entirely: at that speed
# the direction is simply not available. That is the formal statement of
# "travelling quickly forward, the only place you can go is forward", and it
# falls out of the geometry rather than being asserted — at a standstill the
# disc is centred on the body and every bearing reaches 0.5*a*T^2, while at
# pace the centre slides downrange until the rearward and then the lateral
# bearings fall outside it altogether.
static func beat_reach_along(velocity: Vector3, bearing_x: float,
		bearing_z: float, accel_m_s2: float, horizon_s: float) -> float:
	var cx: float = velocity.x * horizon_s
	var cz: float = velocity.z * horizon_s
	var r: float = 0.5 * accel_m_s2 * horizon_s * horizon_s
	# Split the momentum offset into along-bearing and perpendicular parts; the
	# perpendicular part is what can push the ray clear of the disc.
	var along: float = bearing_x * cx + bearing_z * cz
	var perp_sq: float = maxf(0.0, cx * cx + cz * cz - along * along)
	var disc: float = r * r - perp_sq
	if disc <= 0.0:
		return -1.0
	return along + sqrt(disc)

# ── Controlled space: how much room a carrier has to OPERATE ─────────────────
# "How much space do I have" as a measured quantity rather than a corridor test.
#
# THE MODEL. Space is the fraction of the ice ahead that this carrier can
# actually reach WITH THE PUCK. Not "is anyone standing in my lane" — that is a
# geometry question and it has no clock in it — but "of the destinations in
# front of me, how many survive the race?" A fan of carry paths is sampled
# across the forward cone, each priced by the SAME carry_safety the real carry
# candidates use (crossing band + transit mid + arrival lunge, escape gate on),
# reached at the SAME momentum-honest time_to_arrive. The result is the
# area-weighted mean of those keep probabilities, in [0, 1]: 1 = every forward
# destination is mine, 0 = none of them are.
#
# WHY A FAN AND NOT A RAY. A single netward ray is a corridor-occupancy test:
# it cannot tell a defender you will skate past from a wall, it answers the
# same for a man 3 m ahead and one 8 m ahead (no clock), and it has a hard cliff
# at the reach boundary — one measured at 0.556 for a defender 1.0 m off the
# ray and 1.000 at 2.0 m, a 45 cm difference deciding the puck. Sampling an
# AREA cannot cliff: a defender leaving one path still covers its neighbours in
# proportion to how much ice he actually takes away.
#
# WHY PATHS AND NOT POINTS. Each sample is a carry FROM the carrier TO the
# destination, so a defender sitting between two rays is not a blind spot — he
# is met en route by both, and carry_safety's crossing band prices exactly that
# meeting. This is what lets the fan stay coarse (SPACE_SAMPLE_ANGLES) without
# leaking coverage between samples.
#
# WHAT MOMENTUM BUYS, FOR FREE. time_to_arrive is momentum-honest, so a carrier
# in stride reaches the far ring sooner, gives the defenders less window, and
# reads more space than the same carrier standing still — while one skating the
# other way pays the reversal. Nothing here is a momentum term; it falls out of
# using the honest arrival time. The escape gate (apply_escape) is what keeps a
# man the carrier is out-skating from reading as a wall.
#
# WEIGHTING. Each sample carries the area it stands for (polar element ∝ r)
# projected onto the objective direction (max(0, cos θ) — the same
# foreshortening projection position_potential uses, so lateral ice counts for
# what it advances). Samples off the playing surface are DROPPED from both
# sums, not zeroed: a wall does not strip the puck, it removes options, and
# pricing the boards as pressure here would discount a clean wall carry as if
# it were covered. (Boards-as-defender is a real read, but it belongs to the
# option model, not the pressure one.)
#
# FAN DENSITY. Measured against a 5×9 reference fan: ANGULAR resolution buys
# accuracy and radial resolution does not. Three angles alias badly enough to
# miss a defender 3 m off the ray entirely (reads a clean 1.000); dropping the
# middle ring costs almost nothing. So the budget goes to angles: 2×7 is one
# sample cheaper than 3×5 and materially closer to the reference (worst-case
# error 0.076 → 0.043 at rest, and the defender-dead-ahead-at-speed case
# −0.079 → +0.015).
#
# Known residual: a two-man wall met at speed reads ~0.2 high on any fan this
# coarse — the samples thread between the pair. That is the asymmetric model's
# structural blind spot (a min over defenders cannot count bodies), not a
# density problem: the dense reference is only 0.04 better there.
#
# Allocation-free: value-type math over two const tables.
const SPACE_SAMPLE_RINGS: Array[float] = [0.5, 1.0]
# ±70° in 23° steps. Coarse by design — see "why paths and not points".
const SPACE_SAMPLE_ANGLES: Array[float] = [
		-1.2217, -0.8145, -0.4072, 0.0, 0.4072, 0.8145, 1.2217]
# Rings are STAGGERED by half an angular step, so the two rings sample 14
# distinct bearings instead of the same 7 twice. Free anti-aliasing: unstaggered,
# a defender between two rays degrades both of them on both rings, wobbling the
# sweep ±0.07 and reading a man 1.5 m off the ray as taking MORE space than one
# dead centre (dead centre blocks one bearing; off-centre blocks two). The
# half-step offset halves that beat frequency at identical cost.
const SPACE_RING_STAGGER_RAD: float = 0.2036


# One sample: the keep probability of carrying from `from` to `sample`, reached
# at this build's honest momentum-aware arrival time. The per-point control
# read — exported because the carry candidate scoring and the off-puck roles
# want the same number for a single spot.
static func control_at(sample: Vector3, from: Vector3, from_vel: Vector3,
		from_caps: AISkaterCaps, opponents: Array[Vector3],
		opponent_vels: Array[Vector3], opponent_caps: Array = []) -> float:
	var speed: float = AIActionScoring.SKATER_REF_SPEED_M_S
	var accel: float = MANEUVER_ACCEL_M_S2
	var grip: float = 1.0
	if from_caps != null:
		speed = from_caps.max_speed
		accel = from_caps.max_accel
		grip = from_caps.lateral_grip
	var t: float = AIActionScoring.time_to_arrive(from, sample, from_vel, speed, accel, grip)
	return carry_safety(from, sample, t, opponents, opponent_vels,
			opponent_caps, true)


# The area-weighted controlled fraction of the forward cone (see the block
# doc). `toward` is the objective the cone points at (the attacking net for the
# carrier's forward-pressure read); `horizon_m` how far ahead space is felt.
# Returns 1.0 when the objective is degenerate or every sample is off-ice.
# `out_bearing_control`, when sized to SPACE_SAMPLE_ANGLES, is filled with the
# mean control along each BEARING of the fan (averaged over the rings, off-ice
# samples skipped, 1.0 where a bearing has no legal sample). That per-bearing
# profile is the fan's directional shape — which way out of here is open — and
# it is a free by-product of a read the carrier already pays for every re-eval.
# AIRoleCarrier generates its forward carry candidates from it instead of from
# a fixed ring of cardinals; every other caller passes nothing and it costs one
# untaken branch per sample.
static func controlled_space(from: Vector3, from_vel: Vector3,
		from_caps: AISkaterCaps, toward: Vector3, horizon_m: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [],
		out_bearing_control: Array[float] = []) -> float:
	var want_bearings: bool = out_bearing_control.size() == SPACE_SAMPLE_ANGLES.size()
	if want_bearings:
		out_bearing_control.fill(1.0)
	var fx: float = toward.x - from.x
	var fz: float = toward.z - from.z
	var flen: float = sqrt(fx * fx + fz * fz)
	if flen < 0.001 or horizon_m <= 0.0 or opponents.is_empty():
		return 1.0
	fx /= flen
	fz /= flen
	# The cone never reaches past the objective itself — closing on the net, the
	# space that matters is the ice up to it, not behind it.
	var reach: float = minf(horizon_m, flen)
	var weighted: float = 0.0
	var total: float = 0.0
	for bi: int in SPACE_SAMPLE_ANGLES.size():
		var bearing_sum: float = 0.0
		var bearing_n: int = 0
		# PREFIX IMPLICATION. Rings are walked OUTERMOST FIRST, and when the
		# outer path along a bearing comes back fully controlled, the inner
		# samples on that same bearing are credited 1.0 without being priced.
		# They are a strict PREFIX of a path already proven clean: the inner
		# destination lies on the outer route, reached sooner, so every defender
		# has strictly less time to get to it, and the outer read's own mid
		# sample and crossing band already swept the ice between. This is where
		# the fan's cost actually lives — open ice is the expensive case, because
		# nothing there trips carry_safety's zero early-outs — so skipping it is
		# worth more than trimming traffic, where the early-outs already fire.
		# (The one approximation: the outer read's END sample uses the arrival
		# lunge window while a priced inner sample would use its own. It can only
		# make the skip more conservative than the real inner value, never less.)
		var outer_full: bool = false
		for k: int in SPACE_SAMPLE_RINGS.size():
			var ri: int = SPACE_SAMPLE_RINGS.size() - 1 - k
			var r: float = reach * SPACE_SAMPLE_RINGS[ri]
			# Alternate rings ride half an angular step over (see the stagger doc).
			var stagger: float = SPACE_RING_STAGGER_RAD if ri % 2 == 1 else 0.0
			var angle: float = SPACE_SAMPLE_ANGLES[bi] + stagger
			var ca: float = cos(angle)
			# Forward projection: the same cos foreshortening position_potential
			# uses. Straight ahead counts fully, ±70° counts about a third.
			if ca <= 0.0:
				continue
			var sa: float = sin(angle)
			var dir_x: float = fx * ca - fz * sa
			var dir_z: float = fx * sa + fz * ca
			var sample := Vector3(
					from.x + dir_x * r, 0.0, from.z + dir_z * r)
			if absf(sample.x) > GameRules.INNER_HALF_WIDTH \
					or absf(sample.z) > GameRules.INNER_HALF_LENGTH:
				continue   # off the playing surface — see the WEIGHTING note
			# A sample whose straight path runs through a cage is not ice this
			# carrier can take, so it leaves both sums exactly like an off-surface
			# one. Dropping it also keeps the fan off time_to_arrive's around-the-
			# net routing, which prices four waypoints on two legs each — an 8x
			# per-sample cost that fired on the whole fan whenever the carrier
			# worked near a goal line, and was the fan's worst-tick spike.
			if AIActionScoring.carry_path_blocked_by_net(from, sample):
				continue
			var c: float = 1.0
			if not outer_full:
				c = control_at(sample, from, from_vel, from_caps,
						opponents, opponent_vels, opponent_caps)
				if k == 0 and c >= 1.0:
					outer_full = true   # prefix implication — see the block above
			# Polar area element ∝ r, so the outer ring stands for more ice.
			var w: float = r * ca
			total += w
			weighted += w * c
			bearing_sum += c
			bearing_n += 1
		if want_bearings and bearing_n > 0:
			out_bearing_control[bi] = bearing_sum / float(bearing_n)
	if total <= 0.0:
		return 1.0
	return weighted / total


# The carrier's best evasion target — the point in his handling envelope (where he
# can put/protect the puck over EVADE_HORIZON_S) with the most clearance from
# every defender: the SEAM. `handle_reach` is how far he holds the puck off his
# body (Hands-scaled), so a better handler threads a tighter seam. Returned as a
# world point (y = 0); this max-clearance seam is the carrier's honest
# evadability read (reach_clearance at this point = "can I keep the puck at
# all"). Value-type math; allocation-free.
static func best_evade_point(
		carrier_pos: Vector3, carrier_vel: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		handle_reach: float, opponent_caps: Array = []) -> Vector3:
	var env: float = 0.5 * MANEUVER_ACCEL_M_S2 * EVADE_HORIZON_S * EVADE_HORIZON_S \
			+ handle_reach
	return _best_clear_point(
			carrier_pos.x + carrier_vel.x * EVADE_HORIZON_S,
			carrier_pos.z + carrier_vel.z * EVADE_HORIZON_S,
			env, opponents, opponent_vels, opponent_caps)


# The OBJECTIVE-DIRECTED seam: where to put the puck to get PAST the pressure
# toward the spot the carrier actually wants (`objective` — the live carry
# anchor). The pure max-clearance seam above answers "where is the puck safest,"
# which is survival, not playmaking — steered by it alone, a carrier is herded
# wherever the ice happens to be emptiest (usually sideways or backwards) and
# never tries to beat his man. This variant is lexicographic in the same
# grounded currencies: among envelope samples that are genuinely SAFE (outside
# every defender's momentum-reach by EVADE_SAFE_CLEAR_MIN_M — see that const),
# take the one with the most PROGRESS toward the objective; only when no safe
# sample exists does it fall back to pure max clearance (nothing to attack —
# survive first). A defender overplaying one side thus gets beaten to the other
# side ON THE WAY FORWARD, and a committed charger's vacated lane is taken as a
# cut PAST him, not a retreat into open ice.
static func best_evade_point_toward(
		carrier_pos: Vector3, carrier_vel: Vector3, objective: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		handle_reach: float, opponent_caps: Array = []) -> Vector3:
	var env: float = 0.5 * MANEUVER_ACCEL_M_S2 * EVADE_HORIZON_S * EVADE_HORIZON_S \
			+ handle_reach
	return _best_clear_point(
			carrier_pos.x + carrier_vel.x * EVADE_HORIZON_S,
			carrier_pos.z + carrier_vel.z * EVADE_HORIZON_S,
			env, opponents, opponent_vels, opponent_caps, objective)


# WHERE ON THE BLADE to hold the puck under pressure: a point in the carrier's
# handling envelope ALONE (no body-maneuver term — the body keeps doing whatever
# steering wants; this is pure stick work), safe from every defender's
# momentum-reach. Returned as an OFFSET from the body (y = 0), so the consumer
# re-applies it to the live body position every tick — pull the puck off the
# presented forward spot when that spot is covered, and the body becomes the
# shield. The envelope is intersected with the playing surface, so the protected
# side is never through a wall (the escape runs along the boards).
#
# Called TWICE by the carrier, for two different questions, and the distinction
# is the point of the `objective` parameter:
#
#   HOW MUCH to shield reads the MAX-clearance seam (no objective) — the safety
#     the best available shield buys, which is what the consumer's blend weight
#     needs.
#   WHERE to put the puck reads the DIRECTED seam (objective = the presented
#     forward spot), exactly like best_evade_point_toward: among samples with a
#     blade of real air (EVADE_SAFE_CLEAR_MIN_M) take the one CLOSEST to that
#     spot, falling back to max clearance only when nothing in the envelope is
#     safe.
#
# Never AIM with the max-clearance point. It is the point diametrically opposite
# the checker, and a checker only makes shielding necessary by being in FRONT —
# so the puck goes to the BACK hip whenever the shield engages and stays there
# as long as the man is live (measured: 120-180 deg off the carry line at full
# gain against any defender the carrier is skating toward). That is the "slips
# through traffic, then keeps carrying it behind him" look, and a puck on the
# back hip is on neither a shot nor a pass. Directed, the seam grades with the
# checker's bearing (180 -> 90 -> 0 deg as he steps off the line), so the shield
# goes exactly as deep as it must — and under a real jam, where nothing is safe,
# the fallback restores the full far-hip shield.
static func best_handle_protect_point(
		carrier_pos: Vector3, carrier_vel: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		handle_reach: float, opponent_caps: Array = [],
		objective: Vector3 = Vector3.INF) -> Vector3:
	var proj_x: float = carrier_pos.x + carrier_vel.x * EVADE_HORIZON_S
	var proj_z: float = carrier_pos.z + carrier_vel.z * EVADE_HORIZON_S
	var best: Vector3 = _best_clear_point(
			proj_x, proj_z, handle_reach, opponents, opponent_vels, opponent_caps,
			objective)
	return Vector3(best.x - proj_x, 0.0, best.z - proj_z)


# Shared seam sampler: the max-clearance point over the disk of radius `env`
# around the (already projected) center, evaluated at the evasion horizon.
# Coarse rings × angles are fine — the seam is a broad region, not a point.
# The disk is intersected with the playing surface (off-surface samples are
# rejected — the puck can't be handled through a wall), which is what makes a
# wall-pinned carrier's best seam run ALONG the boards and read honestly tight;
# the projected center stays as the fallback even off-surface (the containment
# backstop owns that degenerate case, not the seam search).
#
# With a finite `objective`, the sweep is objective-directed (see
# best_evade_point_toward): among samples clearing EVADE_SAFE_CLEAR_MIN_M the
# one closest to the objective wins; the max-clearance point remains the
# fallback when no sample is safe.
static func _best_clear_point(proj_x: float, proj_z: float, env: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [], objective: Vector3 = Vector3.INF) -> Vector3:
	var directed: bool = objective.is_finite()
	var best: Vector3 = Vector3(proj_x, 0.0, proj_z)
	var best_clear: float = reach_clearance(best, EVADE_HORIZON_S, opponents, opponent_vels, opponent_caps)
	var best_safe: Vector3 = Vector3.INF
	var best_safe_progress: float = INF   # distance to objective; smaller = more progress
	if directed and best_clear >= EVADE_SAFE_CLEAR_MIN_M:
		best_safe = best
		best_safe_progress = Vector2(objective.x - best.x, objective.z - best.z).length()
	for ring: float in EVADE_SAMPLE_RINGS:
		var radius: float = env * ring
		for k: int in EVADE_SAMPLE_ANGLES:
			var ang: float = TAU * float(k) / float(EVADE_SAMPLE_ANGLES)
			var p := Vector3(proj_x + cos(ang) * radius, 0.0, proj_z + sin(ang) * radius)
			if board_gap_m(p) < 0.0:
				continue
			# Exact argmax pruning, two layers. (1) Directed with a safe sample
			# in hand: the fallback argmax is moot (the safe winner returns),
			# so a sample that can't beat the best PROGRESS never needs its
			# clearance at all — skip the defender scan wholesale. (2) A
			# sample only matters if it beats the best clearance so far, or
			# (directed) clears the safe floor — once its running worst drops
			# below both, the exact value is irrelevant and the defender scan
			# aborts early (abort_below).
			var progress: float = 0.0
			if directed:
				progress = Vector2(objective.x - p.x, objective.z - p.z).length()
				if best_safe.is_finite() and progress >= best_safe_progress:
					continue
			var abort: float = best_clear
			if directed:
				abort = minf(abort, EVADE_SAFE_CLEAR_MIN_M)
			var c: float = reach_clearance(p, EVADE_HORIZON_S, opponents,
					opponent_vels, opponent_caps, -1.0, Vector2.ZERO, 0.0, abort)
			if c > best_clear:
				best_clear = c
				best = p
			if directed and c >= EVADE_SAFE_CLEAR_MIN_M \
					and progress < best_safe_progress:
				best_safe_progress = progress
				best_safe = p
	if directed and best_safe.is_finite():
		return best_safe
	return best


# ── Brake check (the committed stop that lets the checker fly by) ────────────
# A brake check is the third answer to pressure, next to the cut and the
# shield: kill all speed so the defender's momentum carries his reach PAST the
# puck, then re-accelerate into the lane he vacated. It is exactly the
# reachable-set model run against a DIFFERENT own-body plan: braked, the puck
# ends at the physical stop point instead of riding downrange to where his poke
# is timed. Worth it only when that braked hold reads meaningfully clearer than
# the cut (killing momentum is a real cost the cut doesn't pay), which is the
# compare `prefers_brake_check` runs.

# How hard the real brake key decelerates the body — same value as
# AISteering.ARRIVAL_BRAKE_DECEL_M_S2 (kept as a local const so the dependency
# between the two domain classes stays one-directional: steering reads the
# evasion consts here, never the reverse).
const BRAKE_DECEL_M_S2: float = 10.0

# The braked-hold read must itself be genuinely safe — the same blade-of-air
# standard the directed seam applies — AND beat the cut by a real margin.
# The margin is tactical, not evaluated: braking surrenders all momentum
# (re-acceleration to top speed takes ~a second), so a marginally clearer stop
# isn't worth planting your feet for. Roughly one more blade of air.
const BRAKE_CHECK_MARGIN_M: float = GameRules.DEFAULT_BLADE_LENGTH_M


# Where the puck comes to rest if the carrier slams the brake NOW: the current
# spot plus the physical stopping distance v²/(2·decel) along the velocity.
static func brake_stop_point(puck_pos: Vector3, carrier_vel: Vector3) -> Vector3:
	var v_xz := Vector2(carrier_vel.x, carrier_vel.z)
	var speed: float = v_xz.length()
	if speed < 0.001:
		return puck_pos
	var stop_dist: float = speed * speed / (2.0 * BRAKE_DECEL_M_S2)
	var inv: float = stop_dist / speed
	return Vector3(puck_pos.x + v_xz.x * inv, 0.0, puck_pos.z + v_xz.y * inv)


# Should the carrier answer this pressure with a brake check instead of the cut
# toward `cut_seam`? Both maneuvers are priced by the same reachable
# carry_clearance over the evasion horizon — the brake as the short braking
# path to the physical stop point (a defender sweeping through it mid-stop is
# caught by the mid-route sample), the cut as the carry to the seam. TRUE iff
# the braked hold is genuinely safe (≥ the blade-of-air floor) and clears the
# cut by BRAKE_CHECK_MARGIN_M. A jockeying defender pacing the carrier stays on
# him through a brake (his projected reach never leaves), so this self-selects
# for genuinely committed pressure — the only kind a brake check beats.
static func prefers_brake_check(
		puck_pos: Vector3, carrier_vel: Vector3, cut_seam: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = []) -> bool:
	var stop: Vector3 = brake_stop_point(puck_pos, carrier_vel)
	var brake_clear: float = carry_clearance(
			puck_pos, stop, EVADE_HORIZON_S, opponents, opponent_vels, opponent_caps)
	if brake_clear < EVADE_SAFE_CLEAR_MIN_M:
		return false
	var cut_clear: float = carry_clearance(
			puck_pos, cut_seam, EVADE_HORIZON_S, opponents, opponent_vels, opponent_caps)
	return brake_clear > cut_clear + BRAKE_CHECK_MARGIN_M


# ── Fake-then-cut deke (manufacturing the opening) ───────────────────────────
# The seam cut and the brake check only EXPLOIT commitment a defender makes on
# his own — a patient jockey who never commits leaves no clearance to cut into
# and the duel stalemates. A real deke MANUFACTURES the commitment: sell one
# side, the defender must match it (gap control), and matching loads him with
# lateral momentum + displacement his reaction then can't unwind before the
# cut passes his plane on the other side.
#
# The whole read is the existing reachable-set model run against the
# defender's POST-BITE state: during the fake he reads for EVADE_REACTION_S,
# then accelerates toward the fake at his real max_accel (per-build caps); at
# the cut his reach starts from that shifted, wrong-way-moving state and is
# reaction-gated AGAIN before he can redirect. GO iff the cut-side point is
# covered NOW (nothing to cut into — otherwise the plain seam owns it) but
# clear of everyone AFTER the bite by the blade-of-air standard. Grounded and
# self-calibrating: an agile defender bites harder — you CAN deke the good
# defender — while a sluggish one barely moves (but him you simply beat).
#
# Durations are the shared contract between this eval and the state machine's
# committed execution (gesture geometry, like the wind-up spans): the fake
# must comfortably exceed the defender's read time or there is nothing to
# bite on; the cut is a single explosive redirect.
const DEKE_FAKE_S: float = 0.3
const DEKE_CUT_S: float = 0.2


# Which side to cut past `deked_idx` after faking the other way: +1 / -1 as
# the sign on `perp` (caller supplies the axis frame: `axis` = unit puck →
# defender-projected line, `perp` = its left-hand perpendicular — the caller
# re-derives the fake/cut directions from the same frame, so eval and
# execution agree by construction). 0 = no manufactured opening (already
# beatable, or the bite doesn't buy enough). Pure float math, no allocation.
static func deke_cut_side(
		puck_pos: Vector3, carrier_vel: Vector3, handle_reach: float,
		axis: Vector3, perp: Vector3, deked_idx: int,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = []) -> int:
	var t_total: float = DEKE_FAKE_S + DEKE_CUT_S
	# The deked man's real build (league defaults when caps are absent).
	var d_pos: Vector3 = opponents[deked_idx]
	var d_vel: Vector3 = opponent_vels[deked_idx]
	var d_accel: float = MANEUVER_ACCEL_M_S2
	var d_span: float = EVADE_STICK_REACH_M
	var d_grip: float = 1.0
	if opponent_caps.size() == opponents.size():
		var caps: AISkaterCaps = opponent_caps[deked_idx]
		if caps != null:
			d_accel = caps.max_accel
			d_span = caps.blade_span
			d_grip = caps.lateral_grip
	# The fake/cut exchange is fought entirely in the defender's LATERAL
	# authority (the bite displaces him perpendicular to his line, the unwind
	# fights that momentum back) — thrust × grip, like the movement core. A
	# power-profile defender bites less but also unwinds less; the rockered
	# one bites hard and recovers hard. Self-calibrating either way.
	var d_accel_lat: float = d_accel * d_grip
	# Where the cut can put the puck: the ballistic ride plus the CUT phase's
	# own handling envelope (the fake spends the earlier effort selling the
	# other way, so only the cut leg's maneuver counts — conservative).
	var cut_env: float = 0.5 * MANEUVER_ACCEL_M_S2 * DEKE_CUT_S * DEKE_CUT_S + handle_reach
	var ride: Vector3 = carrier_vel * t_total
	# Post-fake bite: he reads for EVADE_REACTION_S, then matches the fake.
	var t_bite: float = maxf(0.0, DEKE_FAKE_S - EVADE_REACTION_S)
	var bite_v: float = d_accel_lat * t_bite
	var bite_disp: float = 0.5 * d_accel_lat * t_bite * t_bite
	# His redirect budget during the cut, reaction-gated afresh (he must read
	# the cut before unwinding the bite).
	var cut_maneuver: float = 0.5 * d_accel_lat \
			* pow(maxf(0.0, DEKE_CUT_S - EVADE_REACTION_S), 2.0)
	var best_side: int = 0
	var best_post: float = -INF
	for side_i: int in [-1, 1]:
		var s: float = float(side_i)
		var cut_dir: Vector3 = axis + perp * s
		var cut_len: float = cut_dir.length()
		if cut_len < 0.001:
			continue
		var p: Vector3 = puck_pos + ride + cut_dir * (cut_env / cut_len)
		if board_gap_m(p) < 0.0:
			continue
		# NOW: everyone as-is over the whole window — is the cut side already
		# takeable? Then there is nothing to manufacture (the seam owns it).
		var clear_now: float = reach_clearance(
				p, t_total, opponents, opponent_vels, opponent_caps)
		if clear_now >= EVADE_SAFE_CLEAR_MIN_M:
			continue
		# POST-BITE: the deked man starts the cut displaced toward the fake
		# (−perp·s) and moving that way; everyone else unchanged.
		var fake_dir: Vector3 = perp * (-s)
		var pos1: Vector3 = d_pos + d_vel * DEKE_FAKE_S + fake_dir * bite_disp
		var vel1: Vector3 = d_vel + fake_dir * bite_v
		var proj: Vector3 = pos1 + vel1 * DEKE_CUT_S
		var clear_deked: float = Vector2(p.x - proj.x, p.z - proj.z).length() \
				- (cut_maneuver + d_span)
		var clear_post: float = clear_deked
		# The rest of the defense still plays over the whole window.
		for i: int in opponents.size():
			if i == deked_idx:
				continue
			var other_pos: Vector3 = opponents[i]
			var other_vel: Vector3 = opponent_vels[i]
			var reach: float = 0.5 * MANEUVER_ACCEL_M_S2 \
					* pow(maxf(0.0, t_total - EVADE_REACTION_S), 2.0) + EVADE_STICK_REACH_M
			if opponent_caps.size() == opponents.size():
				var ocaps: AISkaterCaps = opponent_caps[i]
				if ocaps != null:
					reach = 0.5 * ocaps.max_accel \
							* pow(maxf(0.0, t_total - EVADE_REACTION_S), 2.0) + ocaps.blade_span
			var ox: float = p.x - (other_pos.x + other_vel.x * t_total)
			var oz: float = p.z - (other_pos.z + other_vel.z * t_total)
			clear_post = minf(clear_post, sqrt(ox * ox + oz * oz) - reach)
		if clear_post >= EVADE_SAFE_CLEAR_MIN_M and clear_post > best_post:
			best_post = clear_post
			best_side = side_i
	return best_side


# Defender reach for the CARRY-path check below — stick-blade reach plus
# a margin for the defender stepping in as the bot skates past. Distinct
# from the fired-puck lane model (which derives reach from closing time);
# a carry is a slow physical traverse, so it uses a flat poke radius.
const CARRY_PATH_CLEAR_RADIUS_M: float = 1.8

# carry_lane_clearance's "beaten trailer" gate. A defender is dropped from the lane
# only if it's BEHIND the carrier along the drive by more than LANE_BEATEN_BEHIND_M
# AND slower along it by more than LANE_BEATEN_PACE_M_S — i.e. the carrier is
# genuinely pulling away. Both are physical slacks (a body's depth behind; a real
# pace edge), not shape knobs: a man even/ahead or matching pace is never shed, so
# only a beaten trailer is dropped.
const LANE_BEATEN_BEHIND_M: float = 0.1
const LANE_BEATEN_PACE_M_S: float = 0.5

# Public lane-clearance check for CARRY candidates — the bot is
# physically traveling along this segment, not firing a puck through
# it, so the reaction-window math from `lane_clear` doesn't apply.
# A defender anywhere on the path is in the way regardless of flight
# time. Returns 1.0 if no opponent is within CARRY_PATH_CLEAR_RADIUS_M of
# the segment, ramps linearly to 0.0 as defender approaches the line.
# Caller should project opponents forward by the candidate's expected
# arrival time so the check reflects where defenders WILL BE when
# the bot gets there.
static func path_clearance(from: Vector3, to: Vector3,
		projected_opponents: Array[Vector3]) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0
	var min_perp_sq: float = INF
	for p: Vector3 in projected_opponents:
		var pdx: float = p.x - from.x
		var pdz: float = p.z - from.z
		var t: float = (pdx * dx + pdz * dz) / line_len_sq
		if t <= 0.0 or t >= 1.0:
			continue
		var closest_x: float = from.x + t * dx
		var closest_z: float = from.z + t * dz
		var perp_x: float = p.x - closest_x
		var perp_z: float = p.z - closest_z
		var perp_sq: float = perp_x * perp_x + perp_z * perp_z
		if perp_sq < min_perp_sq:
			min_perp_sq = perp_sq
	if min_perp_sq == INF:
		return 1.0
	var perp: float = sqrt(min_perp_sq)
	return clampf(perp / CARRY_PATH_CLEAR_RADIUS_M, 0.0, 1.0)

static func carry_lane_clearance(from: Vector3, to: Vector3, arrival_time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		max_speed: float = 0.0) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var seg_sq: float = dx * dx + dz * dz
	if seg_sq < 0.01 or arrival_time <= 0.0:
		return 1.0
	var dist: float = sqrt(seg_sq)
	var drive_speed: float = dist / arrival_time
	if max_speed > 0.0:
		drive_speed = minf(drive_speed, max_speed)
	var dir_x: float = dx / dist
	var dir_z: float = dz / dist
	# Same proximity read as path_clearance (project each defender to arrival and
	# take the tightest perp to the straight segment) — EXCEPT we first drop a
	# defender the carrier has genuinely BEATEN: one currently behind the carrier
	# along the drive AND slower along it, so the carrier is pulling away and it
	# can't strip a puck driving off. A man AHEAD (a wall, a head-on rush) or one
	# MATCHING the drive pace is never dropped, so path_clearance's coverage of real
	# obstacles — the container duel — is untouched; only the beaten trailer is shed.
	var min_perp_sq: float = INF
	var n: int = opponents.size()
	var has_vels: bool = opponent_vels.size() == n
	for i: int in n:
		var op: Vector3 = opponents[i]
		var ovx: float = opponent_vels[i].x if has_vels else 0.0
		var ovz: float = opponent_vels[i].z if has_vels else 0.0
		var along_now: float = (op.x - from.x) * dir_x + (op.z - from.z) * dir_z
		var opp_drive_speed: float = ovx * dir_x + ovz * dir_z
		if along_now < -LANE_BEATEN_BEHIND_M and drive_speed > opp_drive_speed + LANE_BEATEN_PACE_M_S:
			continue   # behind and out-skated — beaten, shed
		var px: float = op.x + ovx * arrival_time
		var pz: float = op.z + ovz * arrival_time
		var pdx: float = px - from.x
		var pdz: float = pz - from.z
		var t: float = (pdx * dir_x + pdz * dir_z) / dist
		if t <= 0.0 or t >= 1.0:
			continue
		var perp_x: float = px - (from.x + dir_x * t * dist)
		var perp_z: float = pz - (from.z + dir_z * t * dist)
		var perp_sq: float = perp_x * perp_x + perp_z * perp_z
		if perp_sq < min_perp_sq:
			min_perp_sq = perp_sq
	if min_perp_sq == INF:
		return 1.0
	return clampf(sqrt(min_perp_sq) / CARRY_PATH_CLEAR_RADIUS_M, 0.0, 1.0)


# Momentum-aware time to arrive at `dest` from `from_pos` carrying
# `from_velocity`. Two components:
#   1. TRAVEL: dist / (SKATER_REF_SPEED + component of velocity along from→dest) —
#      a skater already moving toward dest closes faster, one moving away slower.
#      Clamped at MIN_TRAVEL_SPEED_M_S so reverse candidates stay finite.
#   2. CROSS-MOMENTUM SHED: |v_perp| / accel — the velocity NOT pointed at dest is
#      wasted speed the skater must first shed (re-accelerate back into line)
#      before it truly closes. Controls are facing-agnostic (no turn arc; the
#      crossover/backward thrust penalties are small), so this is a straight
#      re-acceleration against the thrust budget, not a curve. Without it a 1-D
#      projection prices a lateral fly-by's cut as a fast arrival it cannot
#      actually settle into — the phantom that lets a carrier orbit the slot
#      instead of shooting (see test_real_rush_sim).
#
# Used by AIRoleCarrier._best_carry to price carry candidates (a cut against the
# grain of momentum costs real time, so the goalie reads square and the honest shot
# wins), by AIController chase-intercept lookahead for opponent ETA, and by off-puck
# role behaviors needing a momentum-aware ETA without inventing constants (e.g.,
# SUPPORT's foot-race-home exposure check uses this for the threat opp's ETA home).
#
