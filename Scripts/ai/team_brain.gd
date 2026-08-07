class_name TeamBrain
extends TeamStrategyView

# Per-team strategy node, v2 (possession-state model). Replaces the
# F1/F2/F3 closest-to-puck role assignment + man-to-man coverage
# assignment with a single positional-slot system driven by team
# possession state.
#
# Driven by GameManager._physics_process (host only) — ticks once
# every TICK_PERIOD seconds (~6 Hz).
#
# Blackboard:
#   state              — AIPossessionState.State enum (DZONE / OZONE /
#                        TRANS_DO / TRANS_OD / NEUTRAL).
#   slot_assignments   — Dictionary[peer_id, AIRoleSlots.Slot].
#
# Roles assigned by current geometry per brain tick — no SPRINT_BY
# locking; the bot whose body is in the right place gets the role.
# Hysteresis (1.5 m) prevents flicker from small position changes.
#
# `team_id_by_peer` is `Dictionary[int, int]` — live reference owned
# by PlayerRegistry, mutated when players spawn / leave / slot-swap.
# Read via `dict.get(pid, -1)`. Used to be a Callable; downgraded to
# a Dictionary because AI hot loops eat Callable.call overhead.

const TICK_PERIOD: float = 1.0 / 6.0
# Strong-side X is sign(puck.x) but with a hysteresis band so the
# strong/weak side doesn't flip every tick when the puck cycles
# through center. Once we've picked +1, only flip to -1 when puck.x
# crosses below -STRONG_SIDE_HYSTERESIS_M, and vice versa. Without this,
# every strong/weak-sided role's geometry flips on a corner-to-corner cycle
# and bots try to switch sides every brain tick.
const STRONG_SIDE_HYSTERESIS_M: float = 1.5

var team_id: int = 0
# Latched match team size (3 or 5). Selects the role-slot path: 3 → the
# legacy AIRoleSlots election (verbatim), 5 → AIRoleSlots5's position-aware
# group-scoped election. Set once at construction from the state machine.
var team_size: int = GameRules.DEFAULT_TEAM_SIZE
# Latched match ruleset — the shared read needs it for the offside-aware attacker
# filter (an illegally-positioned opponent is not a counter threat). Set by
# GameManager alongside the agents' own copy.
var rule_set: int = GameRules.DEFAULT_RULE_SET
var state: int = AIPossessionState.State.DZONE
# Live smart-ping directives for this team's bots (host-only AI bookkeeping,
# same shape as _one_timer_ready_by_peer). GameManager routes a validated
# ping in via apply_ping; slot/threat overrides land in _compute_tick and the
# per-bot queries are read through RoleContext every AI dispatch.
var ping_directives := AIPingDirectives.new()
var slot_assignments: Dictionary[int, int] = {}      # peer_id -> AIRoleSlots.Slot
# Central man-on-threat partition: backline defender peer_id -> the opponent
# (carrier's receiver) it should cover. Computed per tick in defensive states
# so the MARK defenders each focus on a DISTINCT man instead of all collapsing on
# the single most dangerous opponent. Empty in offensive / neutral states.
var threat_assignments: Dictionary[int, int] = {}    # defender peer -> opp peer
# Shared per-opponent shoot-threat bases for MARK's unassigned fallback (the
# TeamBrain-shared threat memo, ARCHITECTURE Known Issues): opp peer_id -> the
# threat_surface_shoot of his current spot against our net/goalie/full team.
# Each unassigned marker used to recompute these near-identical surfaces every
# ~30 Hz re-eval; the brain computes them once per ~6 Hz tick and the markers
# consume them via RoleContext as ordering / pruning bounds. APPROXIMATE by
# design: the memo's defender set is the full team (a marker's exact read
# excludes its own hypothetical self — one body in a 4-defender surface), its
# opponents are raw positions (the marker leads them by its anticipation
# scale), and the read is up to a brain tick stale. All of that only perturbs
# the unassigned fallback's candidate ordering — never an assigned-man cover.
# Empty whenever no MARK slot is live, so consumers fall back to the exact
# local computation (tests / brainless contexts included).
var threat_shoot_base_by_opp: Dictionary[int, float] = {}
# Scratch defender list + index-matched caps for the memo fill (reused per
# tick, no allocation).
var _memo_defenders: Array[Vector3] = []
var _memo_defender_caps: Array[AISkaterCaps] = []

# The team's shared transition-defense read (docs/transition-defense-plan.md
# §4): who is genuinely attacking, who is back, the numbers, backpressure, and
# whether coverage is accounted for. Computed ONCE per brain tick and consumed
# by every transition-facing role, in place of each defender independently
# racing a worst-case counter and independently concluding it is the last man
# back. Refilled in place, never reallocated.
var rush_read := AIRushRead.new()
# Last tick's recovery classification, threaded back in for the enter/hold
# hysteresis on the recovery race (see AIRushRead.TRACK_ENTER_MARGIN_S).
var _prev_recovery: Dictionary[int, int] = {}

# Internal — sticky possession for loose-puck handling.
var _last_carrier_team: int = -1
# Hysteretic strong-side X. Updated per brain tick from puck.x.
var _strong_x: float = 1.0

var _accumulator: float = 0.0

# ── Coverage readiness state (docs/transition-defense-plan.md §9) ────────────
# Whether the team is currently running D-zone COVERAGE rather than the rush /
# recovery shape, and how many consecutive ticks the readiness read has disagreed
# with that posture (the leave-coverage hysteresis).
var _coverage_was_set: bool = false
var _coverage_unready_ticks: int = 0
# Published for instrumentation only (AIPossessionShapeTally): true while the
# raw read said DZONE but this brain held the rush shape instead because the
# backcheck wasn't home. Nothing reads it back into a decision — without it,
# a suppressed D-zone coverage is indistinguishable from an ordinary rush.
var coverage_downgraded: bool = false
# Cadence phase offset (seconds): team 1's natural ticks run half a period
# out of phase with team 0's, so the two brains' per-tick computes never land
# on the same physics frame (host FPS is set by the worst tick, and the two
# ~200-300 µs brain ticks stacking is a recurring spike for free). Both
# brains are force-reticked together on possession events — which would
# re-phase-lock them — so the offset is re-applied at every forced-tick
# accumulator reset, not just at construction. Forced ticks themselves still
# fire same-frame by design (they're event-driven); only the natural 6 Hz
# cadence is staggered.
var _cadence_offset_s: float = 0.0
# Set by force_retick(); next tick() call bypasses the rate-limit and
# computes immediately. Used for event-driven re-evaluation when a
# puck-carrier change makes the current slot assignment stale.
var _force_tick_pending: bool = false
# Set of peer_ids that should NOT receive a slot assignment. Used by the
# tutorial to puppet a bot in scripted mode — the puppeted bot's slot would
# otherwise have its role behavior steering it each brain tick. Kept as a
# Dictionary[int, bool] for O(1) `has()` lookups.
var _excluded_peers: Dictionary = {}
var _team_id_by_peer: Dictionary = {}
# Live per-peer AISkaterCaps from PlayerRegistry (memoized), so man-marking reads
# each defender's real top speed. Empty when unwired (tests) → league default.
var _caps_by_peer: Dictionary = {}
# Live peer_id → lobby team_slot (0–4) from PlayerRegistry. 5v5 only: feeds
# the F/D group split and the home-side rest bias in AIRoleSlots5. Empty in
# 3v3 / tests (the legacy path never reads it).
var _position_by_peer: Dictionary = {}
# Live set of BOT peers from PlayerRegistry. The coverage-readiness read gates on
# whether the bodies the shape depends on are home, and a human is not one the
# bots can wait on (see AIRushRead._coverage_ready). Empty when unwired (tests) →
# every teammate counts, which is the stricter reading.
var _bot_peers: Dictionary = {}
# Cached own-goal Z derived from team_id at construction. Team 0
# defends +GOAL_LINE_Z, Team 1 defends -GOAL_LINE_Z.
var _own_goal_z: float = 0.0


func _init(t: int, team_id_by_peer: Dictionary, caps_by_peer: Dictionary = {},
		p_team_size: int = GameRules.DEFAULT_TEAM_SIZE,
		position_by_peer: Dictionary = {},
		bot_peers: Dictionary = {}) -> void:
	team_id = t
	_team_id_by_peer = team_id_by_peer
	_caps_by_peer = caps_by_peer
	team_size = p_team_size
	_position_by_peer = position_by_peer
	_bot_peers = bot_peers
	_own_goal_z = GameRules.GOAL_LINE_Z if t == 0 else -GameRules.GOAL_LINE_Z
	_cadence_offset_s = TICK_PERIOD * 0.5 if t == 1 else 0.0
	_accumulator = _cadence_offset_s


# Called every host physics frame from GameManager. Snapshot is the freshest
# captured world state (delay 0). Internally rate-limited to TICK_PERIOD,
# unless `_force_tick_pending` was set by force_retick() — then this tick
# computes regardless of the accumulator.
func tick(delta: float, snapshot: WorldSnapshot) -> void:
	# Ping directives age in real host time, not brain-tick time — advance
	# before the rate-limit gate so expiry never stretches with the cadence.
	ping_directives.advance(delta)
	_accumulator += delta
	if _accumulator < TICK_PERIOD and not _force_tick_pending:
		return
	# Natural cadence: drain one tick's worth of accumulator. Forced
	# tick: reset the accumulator to this brain's cadence phase, so the next
	# natural tick fires a comfortable fraction of a period out (a full
	# TICK_PERIOD for team 0, half for team 1 — never the back-to-back
	# forced+natural double-rate burst) and the two teams' cadences come out
	# of the shared force-retick de-phased instead of locked (see
	# _cadence_offset_s — both brains are force-reticked together on
	# possession events).
	if _force_tick_pending:
		_accumulator = _cadence_offset_s
		_force_tick_pending = false
	else:
		_accumulator -= TICK_PERIOD
	_compute_tick(snapshot)


# Schedules an immediate re-tick on the next physics frame, bypassing
# the TICK_PERIOD rate-limit. Called from GameManager when an event
# (puck-carrier change) makes the role assignment immediately stale —
# the natural 6 Hz cadence would leave it stale for up to ~166 ms,
# during which the new carrier still has the previous assignment.
# Both team brains should be force-reticked together since a carrier
# change affects both possession states symmetrically.
func force_retick() -> void:
	_force_tick_pending = true


# Exclude a peer from slot assignment. Used by the tutorial when a bot is
# put into scripted/puppet mode — without this the brain would assign it a
# role and its behavior module would steer it each tick. Include is the
# inverse.
func exclude_skater(peer_id: int) -> void:
	_excluded_peers[peer_id] = true
	slot_assignments.erase(peer_id)


func include_skater(peer_id: int) -> void:
	_excluded_peers.erase(peer_id)


# Body of the per-tick computation. Extracted from tick() so
# force_retick() can drive it without going through the accumulator
# rate-limit.
func _compute_tick(snapshot: WorldSnapshot) -> void:
	# 1. Possession state.
	var possession: AIPossessionState.Result = AIPossessionState.compute(
			snapshot, team_id, _own_goal_z, _team_id_by_peer, _last_carrier_team)
	_last_carrier_team = possession.carrier_team
	state = possession.state


	# 1.75 The shared transition read. Computed before the slot elections so
	#      everything downstream — the offensive stations' counter-threat set
	#      today, the transition roles and the DZONE readiness gate as the
	#      later phases land — reads ONE answer instead of each bot deriving
	#      its own. Cheap: one pass over ≤10 skaters at the 6 Hz brain tick.
	_prev_recovery.clear()
	for pid: int in rush_read.recovery_by_peer:
		_prev_recovery[pid] = rush_read.recovery_by_peer[pid]
	rush_read.fill(snapshot, team_id, _own_goal_z, _team_id_by_peer,
			_caps_by_peer, _prev_recovery, rule_set != GameRules.RuleSet.OFF,
			_bot_peers)

	# 1.85 COVERAGE READINESS (docs/transition-defense-plan.md §9). DZONE is a
	#      shape, not a location: the raw table flips to it the moment the puck
	#      crosses our blue line, which used to re-slot three still-backchecking
	#      forwards onto zone posts and dissolve the backcheck at the line. Hold
	#      the rush/recovery shape until the coverage we'd switch into actually
	#      makes sense. An upgrade seam on the raw table, same shape as this one.
	#
	#      BOTH TEAM SIZES. The gate does not create a shape that under-covers:
	#      it holds the rush shape exactly while somebody is still on the way home,
	#      and in that state the zone's nominal coverage is a fiction anyway — MARK
	#      computes a cover position from 20 m up-ice and escorts. Sprinting home
	#      strictly beats walking to a post. And the shapes converge by
	#      construction: RUSH_D1 is home already, TRACK_PUCK chases to the net,
	#      the mid trackers stop at the circle tops — so the rush roles themselves
	#      bring everyone home, satisfy the predicate, and hand off. That
	#      convergence is why no fallback timer is needed: the predicate is
	#      monotone in the recovery it is waiting on.
	#
	#      Only while an OPPONENT actually carries: a loose or dead puck in our
	#      zone is not a rush being defended, it's DZONE's
	#      business, and holding the rush shape over it would just stop the team
	#      setting up around a puck nobody has.
	if state == AIPossessionState.State.DZONE \
			and rush_read.carrier_peer != -1:
		if rush_read.coverage_ready:
			_coverage_unready_ticks = 0
		else:
			_coverage_unready_ticks += 1
		var set_now: bool = AIPossessionState.coverage_read(
				rush_read.coverage_ready, _coverage_unready_ticks,
				_coverage_was_set)
		_coverage_was_set = set_now
		coverage_downgraded = not set_now
		if not set_now:
			state = AIPossessionState.State.TRANS_OD
	else:
		# Left the zone (or we got it back): the next entry starts fresh, so a
		# stale "we were set" can't wave a new rush straight into coverage.
		_coverage_was_set = false
		_coverage_unready_ticks = 0
		coverage_downgraded = false

	# 2. Strong-side X with hysteresis (see STRONG_SIDE_HYSTERESIS_M).
	if snapshot != null and snapshot.puck_state != null:
		var puck_x: float = snapshot.puck_state.position.x
		if _strong_x > 0.0 and puck_x < -STRONG_SIDE_HYSTERESIS_M:
			_strong_x = -1.0
		elif _strong_x < 0.0 and puck_x > STRONG_SIDE_HYSTERESIS_M:
			_strong_x = 1.0

	# 3. Slot assignment by current kinematics (momentum-aware soonest-to-
	#    arrive elections at each peer's real Speed cap). CARRIER is fixed
	#    to the puck holder; everything else falls out of the per-state
	#    elections with hysteresis. No locking needed. 5v5 routes through
	#    the position-aware group-scoped election; 3v3 keeps the legacy
	#    path verbatim (plan §"Guiding constraint").
	var prev_assignments: Dictionary = slot_assignments
	if team_size >= 5:
		slot_assignments = AIRoleSlots5.assign(
				snapshot, team_id, _own_goal_z, state, _team_id_by_peer,
				prev_assignments, _strong_x, _caps_by_peer, _position_by_peer)
	else:
		slot_assignments = AIRoleSlots.assign(
				snapshot, team_id, _own_goal_z, state, _team_id_by_peer,
				prev_assignments, _strong_x, _caps_by_peer)
	# Drop excluded peers (puppeted tutorial bots) so neither they nor any
	# downstream consumer of get_slot steers them. AIRoleSlots.assign already
	# may have given them a slot — erase after the fact rather than touching
	# the call signature.
	for excluded_pid: int in _excluded_peers:
		slot_assignments.erase(excluded_pid)

	# 4. Man-on-threat partition for the backline (defensive states only).
	#    Passes the prior assignment so AIThreatAssignment can apply switch
	#    hysteresis; cleared to {} in non-defensive states so re-entry starts
	#    fresh. Excluded peers are already absent from slot_assignments, so
	#    they're never picked as defenders here.
	threat_assignments = _compute_threat_assignments(snapshot, threat_assignments)

	# 4.5 Shared threat memo for the markers (see threat_shoot_base_by_opp).
	_refresh_threat_base_memo(snapshot)

	# 5. Smart-ping obedience: force-slot the obeying bots (COVER_HIM also
	#    pins its man into the threat partition, the house-pin shape). Applied
	#    last so a live human order wins over the geometric assignment.
	var ping_carrier: int = -1
	if snapshot != null and snapshot.puck_state != null:
		ping_carrier = snapshot.puck_state.carrier_peer_id
	ping_directives.apply_overrides(slot_assignments, threat_assignments, ping_carrier)


# Builds the backline man-on-threat partition for the current tick. Defensive
# states only (DZONE + TRANS_OD); every other state returns {} so no defender
# carries a stale assignment.
#
# Backline = our peers slotted MARK (DZONE and TRANS_OD).
#
# The men are every opponent who is not already owned: while an opponent
# CARRIES he is PRESSURE's, so he is excluded and the men are his potential
# receivers; with the puck loose nobody owns anybody and every opponent is a
# man, the ex-carrier included. Each man's value is the raw pass-threat surface
# from the feed source (no defenders in the view), so AIThreatAssignment pairs
# the most dangerous men with the best-positioned defenders. `prev` is last
# tick's partition, threaded through for switch hysteresis — which is also what
# carries a marker across a pass without re-shuffling the whole coverage.
func _compute_threat_assignments(snapshot: WorldSnapshot,
		prev: Dictionary) -> Dictionary[int, int]:
	var empty: Dictionary[int, int] = {}
	if state != AIPossessionState.State.DZONE \
			and state != AIPossessionState.State.TRANS_OD:
		return empty
	if snapshot == null or snapshot.puck_state == null:
		return empty
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id
	# We have it — this is not a coverage problem.
	if carrier_pid != -1 and _team_id_by_peer.get(carrier_pid, -1) == team_id:
		return empty
	# THE FEED SOURCE — where the next pass would come from. An opponent carrier
	# when one holds the puck, otherwise the puck itself: exactly the resolution
	# AIRoleHelpers.resolve_defensive_play_ref already makes for the roles that
	# consume this partition, so the brain and the marker read one play.
	#
	# Requiring a live carrier was measured at 36% of D-zone time with NO man
	# assigned to ANY marker — and all-or-nothing, because the condition is
	# team-wide. Every pass, shot, rebound and dump dissolved the whole coverage
	# for its flight and dropped both markers into the unassigned fallback. A
	# man is dangerous because of where he stands relative to our net, which is
	# true whether or not anybody is holding the puck; the carrier only sharpens
	# WHICH man matters most. With the puck standing in, the matcher's own
	# hysteresis then keeps each marker on the man he already had, and the
	# ex-carrier joins the men as the extra body — which is what a defence does
	# when the puck leaves his stick.
	var play_ref: Vector3 = snapshot.puck_state.position
	if carrier_pid != -1 and snapshot.skater_states.has(carrier_pid):
		play_ref = snapshot.skater_states[carrier_pid].position

	# Backline man-markers (MARK, in DZONE and TRANS_OD) and their kinematics.
	var defenders: Array[int] = []
	var defender_pos: Dictionary = {}
	var defender_vel: Dictionary = {}
	var defender_caps: Dictionary = {}
	for pid: int in slot_assignments:
		var slot: int = slot_assignments[pid]
		if slot != AIRoleSlots.Slot.MARK:
			continue
		if not snapshot.skater_states.has(pid):
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		defenders.append(pid)
		defender_pos[pid] = s.position
		defender_vel[pid] = s.velocity
		var caps: AISkaterCaps = _caps_by_peer.get(pid)
		if caps != null:
			defender_caps[pid] = caps
	if defenders.is_empty():
		return empty

	# Men = every opponent PRESSURE does not already own (see the header).
	var our_net := Vector3(0.0, 0.0, _own_goal_z)
	var our_goalie_pos: Vector3 = _resolve_our_goalie_pos(snapshot)
	var no_defenders: Array[Vector3] = []
	var men: Array[int] = []
	var man_pos: Dictionary = {}
	var man_value: Dictionary = {}
	var man_danger: Dictionary = {}
	for pid: int in snapshot.skater_states:
		if _team_id_by_peer.get(pid, -1) == team_id:
			continue
		if pid == carrier_pid:
			continue
		var mp: Vector3 = snapshot.skater_states[pid].position
		men.append(pid)
		man_pos[pid] = mp
		man_value[pid] = AIActionScoring.threat_surface_pass(
				play_ref, mp, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, no_defenders)
		# Finish danger if fed: shot value from his spot with the goalie
		# PREDICTED OVER THE FEED'S FLIGHT (he starts tracking the carrier;
		# a short doorstep feed arrives before he traverses — lethal — while
		# a long perimeter feed hands him the whole flight to re-square), no
		# field defenders. Feeds the net-front override (drops the lane
		# factor man_value folds in: a contested feed still becomes a
		# tap-in if it arrives).
		var feed_speed: float = AIActionScoring.expected_pass_speed(play_ref, mp)
		var feed_flight: float = play_ref.distance_to(mp) / maxf(feed_speed, 1.0)
		# Predicted post-seal for the man's spot (derive_post_seal_x_sign): a
		# sharp-angle man fires into the wall a competent keeper adopts, so he
		# is not a finish threat the assignment must chase.
		var man_seal: float = AIActionScoring.derive_post_seal_x_sign(mp, our_net)
		# Pre-armed feed keeper: our goalie's backdoor depth cap already
		# guards this man, so the threat partition weighs him at the
		# merely-strong danger the real keeper concedes.
		#
		# Deliberately WITHOUT the coverage term the other three callers pass.
		# Coverage is what this scan is SOLVING FOR — feeding the current marker
		# positions back in would make a covered man read as less dangerous, free
		# his marker, raise his danger, and pull the marker back. The partition
		# reads raw danger; who covers whom is its output, not its input.
		var g_state: GoalieNetworkState = snapshot.goalie_states.get(team_id)
		AIActionScoring.resolve_feed_keeper(
				our_goalie_pos, our_net, feed_flight, mp, play_ref,
				g_state.hands_read(our_net.z) if g_state != null else Vector4.INF,
				feed_speed)
		man_danger[pid] = AIActionScoring.score_shoot(
				mp, our_net,
				AIActionScoring.feed_keeper_pos,
				GameRules.NET_HALF_WIDTH, no_defenders,
				AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				AIActionScoring.feed_keeper_unsettled,
				[], -1.0, false, man_seal, man_seal != 0.0, 0.0, [],
				AIActionScoring.feed_keeper_hands)
	if men.is_empty():
		return empty

	return AIThreatAssignment.assign(
			defenders, defender_pos, defender_vel,
			men, man_pos, man_value, our_net, prev, defender_caps, man_danger)


# Refills threat_shoot_base_by_opp (see its doc). Runs only while at least one
# of our peers holds MARK — the one slot whose unassigned fallback consumes the
# memo — and leaves it empty otherwise so nothing reads a stale surface.
func _refresh_threat_base_memo(snapshot: WorldSnapshot) -> void:
	threat_shoot_base_by_opp.clear()
	if snapshot == null:
		return
	var have_mark: bool = false
	for pid: int in slot_assignments:
		if slot_assignments[pid] == AIRoleSlots.Slot.MARK:
			have_mark = true
			break
	if not have_mark:
		return
	var our_net := Vector3(0.0, 0.0, _own_goal_z)
	var our_goalie_pos: Vector3 = _resolve_our_goalie_pos(snapshot)
	_memo_defenders.clear()
	_memo_defender_caps.clear()
	for pid: int in snapshot.skater_states:
		if _team_id_by_peer.get(pid, -1) == team_id:
			_memo_defenders.append(snapshot.skater_states[pid].position)
			_memo_defender_caps.append(_caps_by_peer.get(pid))
	for pid: int in snapshot.skater_states:
		if _team_id_by_peer.get(pid, -1) == team_id:
			continue
		threat_shoot_base_by_opp[pid] = AIActionScoring.threat_surface_shoot(
				snapshot.skater_states[pid].position, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, _memo_defenders, _memo_defender_caps)


# Our goalie's current world position, or the goal mouth as a first-frame
# fallback. Mirrors AIRoleHelpers.resolve_our_goalie_pos for the brain's own
# threat scoring (the brain has no RoleContext).
func _resolve_our_goalie_pos(snapshot: WorldSnapshot) -> Vector3:
	var goalie: GoalieNetworkState = snapshot.goalie_states.get(team_id)
	if goalie == null:
		return Vector3(0.0, 0.0, _own_goal_z)
	return Vector3(goalie.position_x, 0.0, goalie.position_z)


# Returns the slot a peer is currently assigned to, or NONE if not
# assigned (e.g., peer_id isn't on this team, or the brain hasn't
# ticked yet).
func get_slot(peer_id: int) -> int:
	return slot_assignments.get(peer_id, AIRoleSlots.Slot.NONE)


# The opponent a given backline defender is assigned to cover, or -1 if it has
# no man-coverage assignment this tick (offensive/neutral state, or the peer
# isn't a backline defender). Read by MARK via RoleContext.
func assigned_threat(peer_id: int) -> int:
	return threat_assignments.get(peer_id, -1)


# Hysteretic strong-side sign (+1 = +X, -1 = -X), updated per brain
# tick from puck.x. Role behaviors (BREAKOUT outlets) read this so
# their strong/weak split matches the brain's slot assignment instead
# of recomputing a raw sign that would thrash near center ice.
func strong_x() -> float:
	return _strong_x


# This peer's lobby position (team_slot 0–4; see PlayerRules.POSITION_NAMES).
# 0 (C) when unknown — tests / 3v3, where nothing reads it.
func position_of(peer_id: int) -> int:
	return _position_by_peer.get(peer_id, 0)


# ── One-timer readiness signaling ───────────────────────────────────────────
# Off-puck bots in the FINISHER role publish "I'm camped + pre-aimed,
# fire me a pass and I'll one-time it" via set_one_timer_ready(true).
# The carrier reads via is_one_timer_ready(peer_id) when scoring
# passes — a ready receiver gets a no-charge goalie prediction (since
# they fire on contact, the goalie can't react to a wind-up), which
# leaves the goalie less settled in the seven-hole geometry and naturally
# rewards passes to them.
# Stored host-side on the brain, not in SkaterNetworkState — this is
# pure AI bookkeeping that the network doesn't need to see.
var _one_timer_ready_by_peer: Dictionary = {}   # peer_id -> bool


func set_one_timer_ready(peer_id: int, ready: bool) -> void:
	if ready:
		_one_timer_ready_by_peer[peer_id] = true
	else:
		_one_timer_ready_by_peer.erase(peer_id)


func is_one_timer_ready(peer_id: int) -> bool:
	return _one_timer_ready_by_peer.get(peer_id, false)


# ── Smart-ping directives ───────────────────────────────────────────────────
# GameManager (host) routes a validated smart ping here; the slot/threat
# overrides apply on the next brain tick (force_retick makes that the next
# physics frame) and the per-bot queries below are read every AI dispatch
# via RoleContext, so obedience is frame-tight while the directive lives.

func apply_ping(type: int, pinger_peer: int, target_peer: int,
		obeyer_peer: int, world_pos: Vector3) -> void:
	ping_directives.add(type, pinger_peer, target_peer, obeyer_peer,
			world_pos, PingRules.directive_duration_s(type))
	force_retick()


func ping_move_target(peer_id: int) -> Vector3:
	return ping_directives.move_target_for(peer_id)


func ping_chase_peer() -> int:
	return ping_directives.chase_peer()


func ping_shoot(peer_id: int) -> bool:
	return ping_directives.shoot_ping_for(peer_id)


func ping_pass_target(peer_id: int) -> int:
	return ping_directives.pass_target_for(peer_id)


# TeamStrategyView interface: expose the two fields the role context reads so the
# frozen TeamBrainView can mirror them behind the same method surface.
func get_team_size() -> int:
	return team_size


func get_threat_shoot_base_by_opp() -> Dictionary[int, float]:
	return threat_shoot_base_by_opp


func get_rush_read() -> AIRushRead:
	return rush_read


# ── Frozen strategy view (AI threading, Phase 3a) ────────────────────────────
# A plain-data snapshot of this brain's outputs, rebuilt every host frame by
# GameManager (and the duel harness) AFTER the brain tick, and read by the agent
# dispatch instead of the live brain — so Phase 3c can run that dispatch off the
# physics thread while the main thread keeps mutating the live brain (pings,
# force_retick, spawns). Reused across frames (refilled, not reallocated). Freezes
# every peer this brain currently assigns a slot, plus the shared threat memo.
var _view: TeamBrainView = null


func get_view() -> TeamBrainView:
	return _view


func build_view() -> void:
	if _view == null:
		_view = TeamBrainView.new()
	var v: TeamBrainView = _view
	v.strong_x_val = _strong_x
	v.team_size_val = team_size
	# Team-scoped, so it freezes here rather than in the per-peer loop below.
	v.ping_chase_peer_val = ping_directives.chase_peer()
	_freeze_int_dict(slot_assignments, v.slot_by_peer)
	_freeze_int_dict(threat_assignments, v.assigned_threat_by_peer)
	_freeze_int_dict(_position_by_peer, v.position_by_peer)
	_freeze_bool_dict(_one_timer_ready_by_peer, v.one_timer_ready_by_peer)
	_freeze_float_dict(threat_shoot_base_by_opp, v.threat_shoot_base)
	v.rush.copy_from(rush_read)
	# Per-slotted-peer reads: the resolved ping directives.
	v.ping_move_by_peer.clear()
	v.ping_shoot_by_peer.clear()
	v.ping_pass_by_peer.clear()
	for pid: int in slot_assignments:
		v.ping_move_by_peer[pid] = ping_directives.move_target_for(pid)
		v.ping_shoot_by_peer[pid] = ping_directives.shoot_ping_for(pid)
		v.ping_pass_by_peer[pid] = ping_directives.pass_target_for(pid)


# Clear-and-refill helpers: reuse the destination dict's backing rather than
# allocating a fresh one each frame (hot-path allocation discipline).
func _freeze_int_dict(src: Dictionary, dst: Dictionary[int, int]) -> void:
	dst.clear()
	for k: int in src:
		dst[k] = src[k]


func _freeze_bool_dict(src: Dictionary, dst: Dictionary[int, bool]) -> void:
	dst.clear()
	for k: int in src:
		dst[k] = src[k]


func _freeze_float_dict(src: Dictionary, dst: Dictionary[int, float]) -> void:
	dst.clear()
	for k: int in src:
		dst[k] = src[k]
