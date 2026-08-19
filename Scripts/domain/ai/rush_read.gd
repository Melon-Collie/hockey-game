class_name AIRushRead

# The team's shared transition-defense perception — ONE read per brain tick.
# Design: docs/transition-defense-plan.md §4.
#
# Transition defense is ALLOCATED and LAYERED, and the aggression of the whole
# structure is set by one quantity every player on the ice can see: NUMBERS BACK.
# So it is computed once, here, and shared. Everything downstream — gap depth,
# whether the D stands up at the line, whether we play the pass or the shooter,
# whether the team may switch into zone coverage — reads this object rather than
# deriving a private version, which is what lets one defender's read say
# "someone else has that man".
#
# Every field is a quantity a real player perceives: who is coming, who is back,
# how long until someone gets on the carrier's hip, is everyone accounted for.
#
# Cost: one fill per brain tick (6 Hz) over ≤10 skaters, arrays refilled in place
# (never reallocated) — the hot-path discipline the AI dispatch path uses.

enum Mode {
	NONE,      # we possess, or there's no puck — no rush to read
	REGROUP,   # they hold it but aren't coming at us (turning back / stalled)
	RUSH,      # the puck is advancing on our net
}

enum Numbers {
	EVEN_OR_UP,     # we have at least as many back as they have coming
	DOWN_ONE,       # classic odd-man: play the pass, goalie takes the shooter
	DOWN_TWO_PLUS,  # protect the house, funnel middle, concede the perimeter
}

enum Recovery {
	INSIDE,    # already goal-side of the rush — in front of it
	TRACKING,  # behind it, but beats it to the house
	BEATEN,    # behind it and cannot beat it home
}

# ── Grounding constants (physical measurements, not shape parameters) ────────

# A trailer who arrives at our net within this long after the puck is still part
# of the rush — the late man is the most dangerous man on a rush, and a defense
# that only counts bodies already ahead of the puck never accounts for him.
# Beyond it he's arriving into set coverage, not into the rush. Sized on how long
# a rush stays live at the net (shot + rebound sequence).
const LATE_MAN_WINDOW_S: float = 1.5

# How late a recovering defender can reach the house and still be a factor.
# A backchecker skating on the carrier's hip can NEVER "beat the rush home" —
# he is behind it by construction and they are the same speed — but he is
# unquestionably back, and counting him as beaten is how a 2-on-2 gets defended
# as the 2-on-1 it isn't. Sized on what a defender arriving a beat late can
# still do: take away the shooter's hands and time. Past it he is a spectator.
const BACKCHECK_WINDOW_S: float = 0.6

# Recovery-race hysteresis: a peer must make the window by ENTER to newly count
# as TRACKING, and only has to stay within HOLD to keep counting.
# Putting the hysteresis on the CONTINUOUS race — rather than on the integer
# `numbers` it feeds — is what keeps a body drifting across the boundary from
# flipping the whole team's posture mid-rush.
const TRACK_ENTER_MARGIN_S: float = 0.2
const TRACK_HOLD_MARGIN_S: float = 0.35

# Below this closing speed on the threat axis they aren't attacking us — they're
# regrouping, and the answer is to stand up at our line, not to retreat.
const REGROUP_CLOSING_M_S: float = 1.0

# Anticipation for the lead used on attackers (mirrors
# AIRoleHelpers.DEFENSIVE_ANTICIPATION_S / _MAX_M so the read and the roles that
# consume it lead men the same way; duplicated rather than imported to keep
# role_helpers free to depend on this module).
const ANTICIPATION_S: float = 0.3
const ANTICIPATION_MAX_M: float = 2.5

# ── Output (refilled in place each tick) ─────────────────────────────────────

var mode: int = Mode.NONE
# Unit vector from the rush origin toward our net — the axis everything projects on.
var threat_axis: Vector3 = Vector3.ZERO
# Where the rush is coming FROM: the opposing carrier, or the loose puck.
var rush_origin: Vector3 = Vector3.ZERO
var carrier_peer: int = -1
# Time for the rush to reach our net, and to reach our blue line (0 once inside).
var rush_eta_s: float = INF
var entry_eta_s: float = INF

# Opponents genuinely involved (see _fill_attackers). Their stay-home D is not a
# rush threat and must not appear in anyone's math.
var attackers: Array[int] = []
# Velocity-led positions, index-aligned with `attackers`.
var attacker_leads: Array[Vector3] = []

var inside: Array[int] = []
var tracking: Array[int] = []
var beaten: Array[int] = []
var recovery_by_peer: Dictionary[int, int] = {}

# True once fill() has run against a real snapshot. Consumers must distinguish
# "no attackers, because nobody is a threat" from "no attackers, because nobody
# has told me anything" — an unwired context (tests, a brainless agent) reads
# the inert instance, and treating that as "the coast is clear" would silently
# disable every last-man bound in the game.
var is_live: bool = false
var numbers: int = Numbers.EVEN_OR_UP
# ETA of the nearest peer coming from BEHIND onto the carrier's hip. The repo's
# own doctrine (docs/5v5-ai-plan.md:548): a backchecker within ~1-2 s lets the D
# tighten the gap and stand up. INF = no backpressure, default conservative.
var backpressure_s: float = INF
# The structure is manned — as many of our bodies have arrived in our defensive
# zone as there are attackers to cover (capped at the bodies we have). What the
# DZONE readiness gate consumes; see _coverage_ready for why parity and not
# everybody.
var coverage_ready: bool = false
# Seconds until the puck is CONTESTED — the nearest opponent's momentum-aware ETA
# to it (docs/transition-defense-plan.md §13). 0.0 when it is already theirs or
# loose; INF when nobody can get to it.
#
# This is the offensive counterpart of everything above, and the coaching read is
# the SAME quantity for two different jobs — "the only time a defenseman should be
# standing on the offensive blue line is when his team has complete control of the
# puck", and "give close support to a teammate if they are under heavy pressure" —
# so it is computed once here rather than derived twice and allowed to disagree.
#
# Published as a TIME on purpose, and never as a 0..1 probability: `1 -
# carry_safety` measures as a step function, because it answers the CARRIER's
# question (can I be poked right now) over a 0.4 s horizon. There is no gradient
# in it to threshold, and it is far too late for a defenseman 40 m away who needs
# a head start to back off. A time lets each station compare against its own
# notice period, which is where that threshold belongs.
var pressure_eta_s: float = 0.0


# Fills this read from the snapshot. `prev` is last tick's read (may be null /
# self on the first tick) — consulted only for the recovery-race hysteresis.
func fill(snapshot: WorldSnapshot, team_id: int, own_goal_z: float,
		team_id_by_peer: Dictionary, caps_by_peer: Dictionary,
		prev_recovery: Dictionary, offsides_enforced: bool = true,
		bot_peers: Dictionary = {}) -> void:
	_reset()
	if snapshot == null or snapshot.puck_state == null:
		return

	var our_net := Vector3(0.0, 0.0, own_goal_z)
	var own_dir: float = signf(own_goal_z)
	var puck_pos: Vector3 = snapshot.puck_state.position
	var pid_carrier: int = snapshot.puck_state.carrier_peer_id
	var opp_carries: bool = pid_carrier != -1 \
			and team_id_by_peer.get(pid_carrier, -1) != team_id \
			and snapshot.skater_states.has(pid_carrier)
	# WE possess → there is no rush to defend, but there is still a counter to
	# price: the pinch/activation stations ask "if I lose it HERE, who burns me?",
	# and that hypothesis is exactly a turnover at the puck. So `attackers` stays
	# well-defined (the same premise counter_rush_cost uses) while everything
	# about defending a live rush — recovery, numbers, backpressure, coverage —
	# does not apply and is left at its inert default.
	var we_carry: bool = pid_carrier != -1 \
			and team_id_by_peer.get(pid_carrier, -1) == team_id
	is_live = true
	# Possession security (see pressure_eta_s). Only OUR carrier can be "secure";
	# anything else is already contested by definition.
	pressure_eta_s = 0.0
	if we_carry:
		pressure_eta_s = _pressure_eta(
				snapshot, team_id, team_id_by_peer, caps_by_peer,
				snapshot.skater_states[pid_carrier].position)

	carrier_peer = pid_carrier if opp_carries else -1
	var origin_vel := Vector3.ZERO
	if opp_carries:
		var cs: SkaterNetworkState = snapshot.skater_states[pid_carrier]
		rush_origin = cs.position
		origin_vel = cs.velocity
	else:
		rush_origin = puck_pos
		origin_vel = snapshot.puck_state.velocity

	var to_net: Vector3 = our_net - rush_origin
	var axis_len: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
	if axis_len < 0.001:
		return
	threat_axis = Vector3(to_net.x / axis_len, 0.0, to_net.z / axis_len)

	# How fast the rush is actually coming at us, along its own attack line.
	# Lateral drift buys no threat — the turn radius pays for that conversion
	# before it becomes a danger (the same read the rush gap's pace term makes).
	var closing: float = maxf(
			origin_vel.x * threat_axis.x + origin_vel.z * threat_axis.z, 0.0)

	rush_eta_s = _origin_eta(snapshot, team_id, team_id_by_peer, caps_by_peer,
			our_net, opp_carries, pid_carrier)
	entry_eta_s = _entry_eta(own_dir, axis_len, closing)

	_fill_attackers(snapshot, team_id, team_id_by_peer, caps_by_peer, our_net,
			offsides_enforced and own_dir * puck_pos.z <= GameRules.BLUE_LINE_Z,
			own_dir)
	if we_carry:
		# Turnover hypothesis only — see the `we_carry` note above.
		return
	_fill_recovery(snapshot, team_id, team_id_by_peer, caps_by_peer,
			our_net, axis_len, prev_recovery)
	_fill_numbers()
	_fill_backpressure(snapshot, caps_by_peer)
	coverage_ready = _coverage_ready(snapshot, team_id, team_id_by_peer,
			own_dir, bot_peers)

	# In our own zone the attack is on regardless of an instantaneous stall (a
	# cycle is not a regroup). Outside it, closing speed is the honest read.
	var in_our_dz: bool = own_dir * rush_origin.z > GameRules.BLUE_LINE_Z
	mode = Mode.RUSH if (in_our_dz or closing > REGROUP_CLOSING_M_S) else Mode.REGROUP


# ── Attackers ────────────────────────────────────────────────────────────────

# An opponent is IN the rush when he can be at our net within the late-man
# window of the puck itself. Time, not position: it keeps the hard-charging
# trailer (who is behind the puck but joining) and drops the stay-home D (who is
# level with nothing and arriving in five seconds).
func _fill_attackers(snapshot: WorldSnapshot, team_id: int,
		team_id_by_peer: Dictionary, caps_by_peer: Dictionary,
		our_net: Vector3, offside_reads: bool, own_dir: float) -> void:
	var bar: float = rush_eta_s + LATE_MAN_WINDOW_S
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) == team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		# Offside-positioned bodies are not attackers. An opponent already inside
		# his attacking zone (our defensive zone) while the puck is not there
		# cannot legally receive where he stands — ARCADE ghosts him, NHL whistles
		# the touch. Counting him is how an illegal cherry-picker drags a station
		# out of the play.
		if offside_reads and pid != carrier_peer \
				and own_dir * s.position.z > GameRules.BLUE_LINE_Z:
			continue
		if pid == carrier_peer:
			attackers.append(pid)
			attacker_leads.append(_lead(s.position, s.velocity))
			continue
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var accel: float = caps.max_accel if caps != null \
				else AIActionScoring.SHED_ACCEL_DEFAULT_M_S2
		var t: float = AIActionScoring.time_to_arrive(
				s.position, our_net, s.velocity,
				_race_speed(s, caps, our_net), accel)
		if t <= bar:
			attackers.append(pid)
			attacker_leads.append(_lead(s.position, s.velocity))


# ── Recovery classification ──────────────────────────────────────────────────

# Where the rush becomes genuinely dangerous: the top of the circles, measured
# along the threat axis from our net. The research names this depth explicitly
# as where backcheckers stop ("F2 and F3 come back through mid ice and stop just
# inside the tops of the circles"), so it is also the honest finish line for
# "did I get back in time?".
func house_gate(our_net: Vector3) -> Vector3:
	return our_net - threat_axis * AIZoneCoverage.HOUSE_TOP_DEPTH_M


func _fill_recovery(snapshot: WorldSnapshot, team_id: int,
		team_id_by_peer: Dictionary, caps_by_peer: Dictionary,
		our_net: Vector3, origin_along: float,
		prev_recovery: Dictionary) -> void:
	var gate: Vector3 = house_gate(our_net)
	# Time for the rush itself to reach the house gate — the clock a recovering
	# defender is racing. Split off the calibrated whole-trip ETA by the fraction
	# of DISTANCE remaining: slightly optimistic for the rush (its ramp is
	# front-loaded in time), which errs conservative for the defender.
	var t_rush_gate: float = maxf(
			rush_eta_s * (1.0 - AIZoneCoverage.HOUSE_TOP_DEPTH_M
					/ maxf(origin_along, 0.001)), 0.0)
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) != team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		# Goal-side = nearer our net than the rush is, measured RADIALLY. Not in
		# Z: for a rush coming up a wall, "behind him in Z" and "between him and
		# the net" point different ways (the same correction cover_man_target
		# makes). Not as an attack-axis projection either — that collapses the
		# lateral offset and credits a body on the far boards as being in front
		# of a rush he is nowhere near.
		if _xz_dist(s.position, our_net) < origin_along:
			inside.append(pid)
			recovery_by_peer[pid] = Recovery.INSIDE
			continue
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var accel: float = caps.max_accel if caps != null \
				else AIActionScoring.SHED_ACCEL_DEFAULT_M_S2
		var t: float = AIActionScoring.time_to_arrive(
				s.position, gate, s.velocity,
				_race_speed(s, caps, gate), accel)
		# Enter/hold hysteresis on the race (see TRACK_ENTER_MARGIN_S).
		var was_counted: bool = prev_recovery.get(pid, Recovery.BEATEN) \
				!= Recovery.BEATEN
		var window: float = t_rush_gate + BACKCHECK_WINDOW_S
		var bar: float = window + TRACK_HOLD_MARGIN_S if was_counted \
				else window - TRACK_ENTER_MARGIN_S
		if t <= bar:
			tracking.append(pid)
			recovery_by_peer[pid] = Recovery.TRACKING
		else:
			beaten.append(pid)
			recovery_by_peer[pid] = Recovery.BEATEN


func _fill_numbers() -> void:
	# A beaten body is not a defender for counting purposes — he still sprints
	# home (that's tracking mode), he just can't be relied on to be there.
	var deficit: int = attackers.size() - (inside.size() + tracking.size())
	if deficit <= 0:
		numbers = Numbers.EVEN_OR_UP
	elif deficit == 1:
		numbers = Numbers.DOWN_ONE
	else:
		numbers = Numbers.DOWN_TWO_PLUS


# Nearest peer coming from BEHIND the rush onto the carrier's hip. A body already
# goal-side is the gap defender, not backpressure — the whole point of the read
# is "is help arriving from behind him?".
func _fill_backpressure(snapshot: WorldSnapshot,
		caps_by_peer: Dictionary) -> void:
	if carrier_peer == -1:
		return
	var hip: Vector3 = _lead(rush_origin,
			snapshot.skater_states[carrier_peer].velocity)
	for pid: int in tracking:
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var speed: float = _race_speed(s, caps, hip)
		var accel: float = caps.max_accel if caps != null \
				else AIActionScoring.SHED_ACCEL_DEFAULT_M_S2
		var t: float = AIActionScoring.time_to_arrive(
				s.position, hip, s.velocity, speed, accel)
		if t < backpressure_s:
			backpressure_s = t


# ── Coverage accounting (drives the DZONE gate — plan §9) ────────────────────

# Envelope inside which a defender OWNS a man: the goal-side cover stand plus a
# stick. Promoted verbatim from AIRoleContain._teammate_home_on, which used it
# for the same question ("is a teammate already home on this man?").
static func cover_envelope_m() -> float:
	return AIThreatAssignment.COVER_DEPTH_M + SkaterAgentStateMachine.BLADE_REACH_M


# ── Coverage readiness (the DZONE handoff gate — plan §9) ────────────────────
#
# "Get back, get set, THEN take your man." This answers the FIRST clause only:
# is the structure manned? It must NOT also ask whether men are already covered.
# That is a MAN-coverage test gating entry into a ZONE, which covers ice rather
# than bodies by definition, and a correctly executed zone fails it: measured
# against AIZoneCoverage's own anchors for a settled cycle, ZONE_W_WEAK sags to
# the high slot ~8 m off the weak-side winger (4 m envelope) and the strong-side
# pressure comes from up-ice of the puck. Correct hockey, and not "goal-side" —
# so the gate can never be satisfied by the shape it gates, and only a time floor
# is left doing the real work.
#
# TWO PARTS, and doctrine sets each one.
#
# WHERE: the blue line. "The transition from backcheck to defensive zone coverage
# happens at the blue line — as you enter your defensive zone, you identify your
# coverage responsibility." It is also the structure's own footprint (every zone
# anchor sits ≤11 m off the goal line, well inside our zone's ~19 m), so a correct
# shape satisfies it by construction rather than by tuning.
#
# HOW MANY: parity, not everybody. Doctrine keys the end of backcheck urgency on
# NUMBERS — F2 "backchecks aggressively until numerical parity is achieved, and then
# protects the house"; F3 "skates hard to even the numbers if the team is
# outnumbered". Requiring EVERY body was the mirror image of the bug this whole read
# was written to fix: instead of five bots each deciding it was the last man back, it
# made four home bots wait on a fifth who was late. A team-level all-or-nothing
# driven by the worst individual, either way. Once the numbers are even the home
# bodies set up and the late man joins as a layer — which the soonest-to-arrive
# election delivers for free, since the bodies already home win the important jobs
# and the straggler inherits the leftover.
#
# The requirement is capped at the bodies we HAVE (`mini`): you cannot be asked to
# produce a defender that does not exist. Without the cap, being genuinely a man
# short — a human who will not backcheck, a ghosted bot — makes parity unreachable
# and the predicate permanently false. With it, a short-handed team reads "set"
# once everyone it controls is home, and defends with layers instead of
# scrambling forever.
#
# So the read stays MONOTONE in the recovery it waits on — arrivals only raise the
# count, and the bar never rises — which is what makes a fallback timer unnecessary
# rather than load-bearing.
#
# BOTS ONLY (`bot_peers`; empty = count every teammate). This is load-bearing in
# BOTH terms: a loafing human must not inflate the requirement he is not going to
# satisfy, and must not count toward the bodies-we-have cap either. Gating the bots'
# shape on a body they cannot steer is the same "wait on someone else" reasoning
# this whole read replaced; their structure is ready when THEIR bodies are home.
func _coverage_ready(snapshot: WorldSnapshot, team_id: int,
		team_id_by_peer: Dictionary, own_dir: float,
		bot_peers: Dictionary) -> bool:
	var check_all: bool = bot_peers.is_empty()
	var home: int = 0
	var ours: int = 0
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) != team_id:
			continue
		if not check_all and not bot_peers.has(pid):
			continue
		ours += 1
		if own_dir * snapshot.skater_states[pid].position.z >= GameRules.BLUE_LINE_Z:
			home += 1
	return home >= mini(attackers.size(), ours)


# ── Helpers ──────────────────────────────────────────────────────────────────

# The rush's own time to our net. With a carrier it's his carry; with a loose
# puck it's the best opponent's collect plus the carry from where he gets it.
func _origin_eta(snapshot: WorldSnapshot, team_id: int,
		team_id_by_peer: Dictionary, caps_by_peer: Dictionary,
		our_net: Vector3, opp_carries: bool, pid_carrier: int) -> float:
	if opp_carries:
		var cs: SkaterNetworkState = snapshot.skater_states[pid_carrier]
		return AIActionScoring.time_to_arrive(cs.position, our_net, cs.velocity,
				_race_speed(cs, caps_by_peer.get(pid_carrier), our_net))
	var best_collect: float = INF
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) == team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		var t: float = AIActionScoring.time_to_arrive(
				s.position, rush_origin, s.velocity,
				_race_speed(s, caps_by_peer.get(pid), rush_origin))
		if t < best_collect:
			best_collect = t
	if best_collect == INF:
		return INF
	# Carry from the pickup, restarting from rest — the gather costs the momentum.
	return best_collect + AIActionScoring.time_to_arrive(
			rush_origin, our_net, Vector3.ZERO, AIActionScoring.SKATER_REF_SPEED_M_S)


# Time until the rush reaches our blue line; 0 once it's already inside.
func _entry_eta(own_dir: float, origin_along: float, closing: float) -> float:
	var ice_to_line: float = GameRules.BLUE_LINE_Z - own_dir * rush_origin.z
	if ice_to_line <= 0.0:
		return 0.0
	if closing <= 0.01:
		return INF
	# Along the attack axis rather than straight down Z, so a wide rush isn't
	# credited with arriving sooner than it can.
	var frac: float = minf(ice_to_line / maxf(origin_along, 0.001), 1.0)
	return origin_along * frac / closing


# The rush sprints, and so does the backcheck — a cruise-priced race under-clocks
# both sides. Stamina/lockout ride the peer's own replicated pool, same seam
# AIRoleHelpers.self_race_vmax and the counter channels use.
func _race_speed(s: SkaterNetworkState, caps: AISkaterCaps,
		dest: Vector3) -> float:
	var speed: float = caps.max_speed if caps != null \
			else AIActionScoring.SKATER_REF_SPEED_M_S
	var mult: float = caps.sprint_speed_mult if caps != null \
			else AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
	var dx: float = dest.x - s.position.x
	var dz: float = dest.z - s.position.z
	return BotSprintRules.race_speed(speed, mult, s.stamina, s.sprint_locked,
			sqrt(dx * dx + dz * dz))


# Velocity lead, clamped — cover where he's cutting, not the freeze-frame. Shrinks
# to nothing as he slows, so there's no phantom to overshoot.
func _lead(pos: Vector3, vel: Vector3) -> Vector3:
	var dx: float = vel.x * ANTICIPATION_S
	var dz: float = vel.z * ANTICIPATION_S
	var d: float = sqrt(dx * dx + dz * dz)
	if d > ANTICIPATION_MAX_M:
		var k: float = ANTICIPATION_MAX_M / d
		dx *= k
		dz *= k
	return Vector3(pos.x + dx, 0.0, pos.z + dz)


func copy_from(other: AIRushRead) -> void:
	mode = other.mode
	is_live = other.is_live
	pressure_eta_s = other.pressure_eta_s
	threat_axis = other.threat_axis
	rush_origin = other.rush_origin
	carrier_peer = other.carrier_peer
	rush_eta_s = other.rush_eta_s
	entry_eta_s = other.entry_eta_s
	numbers = other.numbers
	backpressure_s = other.backpressure_s
	coverage_ready = other.coverage_ready
	attackers.clear()
	attackers.append_array(other.attackers)
	attacker_leads.clear()
	attacker_leads.append_array(other.attacker_leads)
	inside.clear()
	inside.append_array(other.inside)
	tracking.clear()
	tracking.append_array(other.tracking)
	beaten.clear()
	beaten.append_array(other.beaten)
	recovery_by_peer.clear()
	for pid: int in other.recovery_by_peer:
		recovery_by_peer[pid] = other.recovery_by_peer[pid]


# Time until the nearest opponent is on our carrier — momentum-aware, at his real
# Speed cap, so a body already skating at the puck registers sooner than a nearer
# one standing still. INF with no opponents on the ice (nothing can contest it).
func _pressure_eta(snapshot: WorldSnapshot, team_id: int,
		team_id_by_peer: Dictionary, caps_by_peer: Dictionary,
		carrier_pos: Vector3) -> float:
	var best: float = INF
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) == team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var t: float = AIActionScoring.time_to_arrive(
				s.position, carrier_pos, s.velocity,
				caps.max_speed if caps != null else AIActionScoring.SKATER_REF_SPEED_M_S)
		if t < best:
			best = t
	return best


func _xz_dist(a: Vector3, b: Vector3) -> float:
	var dx: float = b.x - a.x
	var dz: float = b.z - a.z
	return sqrt(dx * dx + dz * dz)


func _reset() -> void:
	mode = Mode.NONE
	is_live = false
	pressure_eta_s = 0.0
	threat_axis = Vector3.ZERO
	rush_origin = Vector3.ZERO
	carrier_peer = -1
	rush_eta_s = INF
	entry_eta_s = INF
	attackers.clear()
	attacker_leads.clear()
	inside.clear()
	tracking.clear()
	beaten.clear()
	recovery_by_peer.clear()
	numbers = Numbers.EVEN_OR_UP
	backpressure_s = INF
	coverage_ready = false
