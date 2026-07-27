extends RefCounted

# ── Bot-vs-bot DUEL HARNESS ──────────────────────────────────────────────────
# Steps full multi-second duels between real bot brains, headlessly, so
# emergent SEQUENCES (deke past a container, escape a pincer, pick a puck up
# blade-first) become pinnable GUT scenarios instead of playtest-only
# observations. Loaded via preload from scenario test files — deliberately no
# class_name (test infrastructure stays out of the global namespace).
#
# What runs REAL:
#   - Decisions: each skater is a live SkaterAgentStateMachine fed
#     WorldSnapshots and emitting InputStates, with a real per-team TeamBrain
#     doing slot assignment — the exact production decision stack.
#   - Body physics: SkaterMovementRules.apply_movement (the pure extraction
#     the live controller runs), at the real 120 Hz tick, with the
#     controller-default MovementConfig.
#   - Puck contacts: PuckInteractionRules.check_pickup / check_poke — the
#     real swept-segment tests at the real pickup radius.
#
# What is APPROXIMATED (keep scenario assertions coarse because of these):
#   - Facing: the pose coordinator's exponential lerp toward the cursor,
#     without the back-wedge IK gate.
#   - Blade: the cursor clamped to the reach ring, rate-limited at the Hands
#     blade speed (no ROM cone, no lift plane).
#   - Strips: a defender's blade sweeping through the carried puck knocks it
#     loose along the sweep (no host restitution detail).
#   - Sprint & stamina: REAL (StaminaRules gate/drain/lockout + the movement
#     model's sprint multipliers at league tuning) — required for parity with
#     the sprint-aware race reads.
#   - Absent entirely: body collisions / checks, boards beyond the analytic
#     clamp+reflect, goalie BEHAVIOR (a static net-center keeper exists per
#     team purely so shot scoring sees someone home).
#
# ASSERTION PHILOSOPHY: scenarios pin THAT a behavior works — "possession
# retained and 5 m of progress within 6 s" — never frame-exact trajectories.
# Frame-exact pins would break on every future feel-tuning change and test
# the approximations instead of the decisions.

const Agent := preload("res://Scripts/ai/skater_agent_state_machine.gd")

const DT: float = 1.0 / 120.0
# Mirrors of live tuning the plant integrates with (SkaterController export
# defaults; PuckController.PICKUP_RADIUS; Agent.BLADE_REACH_M).
const FACING_DRAG: float = 5.0
const MAX_BLADE_SPEED: float = 10.0
const BLADE_REACH: float = 1.8
const PICKUP_RADIUS: float = 0.5
# Relative-frame catchability ceiling for a loose-puck attach — the
# production deflect threshold (Puck.deflect_min_speed, receiver-relative):
# below it every blade contact catches; the harness doesn't model the
# above-threshold deflect spectrum. Must exceed skater top speed (9) or a
# full-stride bot can never pick up the puck it's chasing.
const PICKUP_MAX_REL_SPEED: float = 22.0
# A releaser can't re-catch its own release while the puck departs its blade
# (production has a post-shot pickup cooldown on the controller).
const RELEASE_GRACE_TICKS: int = 36
# A stripped puck squirts along the poking blade's sweep at a capped pace.
const STRIP_SQUIRT_M_S: float = 3.5
# Release pace for a fired pass/shot event (quick-shot scale). The harness
# records release EVENTS for assertions; flight fidelity is not the point.
const RELEASE_SPEED_M_S: float = 15.0
# TeamBrain re-slot cadence (~6 Hz, the production rhythm).
const BRAIN_PERIOD_TICKS: int = 20

# ── Scripted PUPPET container tuning ─────────────────────────────────────────
# A puppet (add_puppet_container) is an agentless defender running a fixed
# containment policy: hold the puck→own-net line at a set gap, never retreat
# past a depth floor, mirror with real skater accel off a reaction-delayed
# puck read, blade presented on the puck line. Real defender bots CHASE a
# carrier one-on-one (and the carrier rightly beats them with speed + the
# cut), so patient containment — the fake-then-cut deke's home regime — has
# to be staged deliberately.
const PUPPET_REACTION_TICKS: int = 18       # ≈ EVADE_REACTION_S at 120 Hz
const PUPPET_ACCEL_M_S2: float = 10.5       # DEFAULT_SKATER_THRUST_M_S2
const PUPPET_MAX_SPEED_M_S: float = 9.0
const PUPPET_GAIN: float = 4.0              # P-control: desired m/s per m of error


class SimSkater:
	var peer_id: int
	var team_id: int
	var pos: Vector3
	var vel: Vector3 = Vector3.ZERO
	var facing: Vector2 = Vector2(0, -1)
	var blade: Vector3
	var prev_blade: Vector3
	var agent: SkaterAgentStateMachine
	var input: InputState = InputState.new()
	var profile: BotSkillProfile = null
	var was_holding_shot: bool = false
	var was_holding_slap: bool = false
	# Live sprint pool (StaminaRules): the plant runs real sprint physics so
	# the sprint-aware race reads and the harness bodies agree — a read that
	# prices sprint against a plant that can't sprint recreates the
	# treadmill class of artifact.
	var stamina: float = 1.0
	var sprint_locked: bool = false
	# ≥ 0 marks a scripted puppet container (no agent); the gap it holds.
	var puppet_hold_gap: float = -1.0
	var puppet_depth_floor_z: float = 0.0


var skaters: Array[SimSkater] = []
var team_map: Dictionary = {}
var brains: Dictionary = {}
# Match team size for the brains (3 = legacy path, 5 = position-aware) and
# the peer_id → lobby-slot position map the 5v5 election reads. Set before
# start(); defaults reproduce the original 3v3 harness behavior.
var team_size: int = GameRules.DEFAULT_TEAM_SIZE
var positions: Dictionary = {}

# ── Perf instrumentation (benchmarks/) ───────────────────────────────────────
# When collect_perf is on, step() accumulates wall-clock µs for the brain
# ticks and each agent's dispatch, so the AI benchmark can attribute host
# cost per subsystem/slot. Off by default — scenario tests pay one branch.
var collect_perf: bool = false
var perf_brain_us: int = 0
var perf_dispatch_us: Dictionary = {}     # peer_id -> accumulated µs
var perf_dispatch_calls: Dictionary = {}  # peer_id -> dispatch() call count
# Per-tick AI cost distribution (brain + all dispatches on that tick), for
# frame-pacing analysis: FPS is set by the WORST tick, not the average.
var perf_tick_us: Array[int] = []
var puck_pos: Vector3 = Vector3.ZERO
var puck_vel: Vector3 = Vector3.ZERO
var carrier_id: int = -1
# Airborne CHIP support: while > 0 the puck is in the air — constant ground
# velocity (ballistic track), no ice friction, no pickups (no bot volunteers
# a deflect) — then it lands, keeping LANDING_SPEED_KEEP of its pace (the
# bounce/skid loss). Scenario harnesses set this to hang_time / DT when
# staging a lofted dump; 0 (the default) is the ordinary ice puck.
var airborne_ticks: int = 0
const LANDING_SPEED_KEEP: float = 0.6
var ticks: int = 0
var move_cfg: SkaterMovementRules.MovementConfig
var _stamina_cfg: StaminaRules.StaminaConfig
# Rolling puck positions for the puppets' reaction-delayed read.
var _puck_history: Array[Vector3] = []
# peer_id -> tick until which that peer can't re-catch its own release.
var _release_grace: Dictionary = {}
# Per-team incumbent for the snapshot's chase election (hysteresis feed).
var _prev_chase_by_team: Dictionary = {}
# Loose-puck board bounce restitution (the harness's coarse boards — flight
# fidelity is still not the point; containment is).
const BOARD_RESTITUTION: float = 0.5

# ── Outcome telemetry (scenario assertions read these) ──────────────────────
var deke_fired: bool = false
# peer_id -> true for every skater that fired a fake-then-cut deke (attributes
# deke_fired when a strip swaps who's carrying mid-duel). NOTE: the deke's live
# regime is narrow by design — slow jockeying against ONE patient container.
# At approach speed the poke-evade routes to the committed cut instead
# (|closing| > the contain cap), and the cut + speed genuinely beats a lone
# defender — so expect most duels to resolve via evades_by_peer, not dekes.
var dekes_by_peer: Dictionary = {}
# peer_id -> true once ANY committed evade window fired (cut / brake check /
# deke). Easy's closed protect gate means it never commits one — the live
# tier-gate control.
var evades_by_peer: Dictionary = {}
var strips: int = 0
# One entry per fired release: { "tick": int, "peer": int } — pass/shot
# events; the puck goes loose along the shooter's aim at RELEASE_SPEED_M_S.
var releases: Array[Dictionary] = []
# Ticks each peer spent as the carrier.
var carry_ticks: Dictionary = {}

# Optional real-goalie hook (default off → static keepers, existing scenarios
# unchanged). When set, called once per team per tick as
# `goalie_provider.call(team_id: int, puck_pos: Vector3) -> Variant`; a Vector3
# return overwrites that net's keeper position in the snapshot (a real
# GoalieController the test owns and ticks), anything else keeps the static one.
var goalie_provider: Callable = Callable()


func _init() -> void:
	move_cfg = SkaterMovementRules.MovementConfig.new()
	move_cfg.thrust = GameRules.DEFAULT_SKATER_THRUST_M_S2
	move_cfg.friction = 0.8
	move_cfg.max_speed = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
	move_cfg.move_deadzone = 0.1
	move_cfg.brake_multiplier = 4.0
	move_cfg.puck_carry_speed_multiplier = 0.86
	move_cfg.backward_thrust_multiplier = 0.80
	move_cfg.crossover_thrust_multiplier = 0.90
	move_cfg.friction_drag = 0.27
	# Sprint plant (SkaterController league export defaults) — see the
	# SimSkater stamina comment.
	move_cfg.sprint_thrust_multiplier = 1.20
	move_cfg.sprint_max_speed_multiplier = AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
	move_cfg.sprint_carry_penalty_bypass = 0.6
	_stamina_cfg = StaminaRules.StaminaConfig.new()


func add_skater(peer_id: int, team_id: int, pos: Vector3,
		profile: BotSkillProfile = null, vel: Vector3 = Vector3.ZERO) -> void:
	var s := SimSkater.new()
	s.peer_id = peer_id
	s.team_id = team_id
	s.pos = pos
	s.vel = vel
	s.blade = pos
	s.prev_blade = pos
	s.profile = profile
	skaters.append(s)
	team_map[peer_id] = team_id


# A scripted patient container (see the PUPPET_* block). `depth_floor_z` is
# the deepest own-net z it will retreat to (0.0 = hold the spawn line).
func add_puppet_container(peer_id: int, team_id: int, pos: Vector3,
		hold_gap: float = 2.3, depth_floor_z: float = 0.0) -> void:
	add_skater(peer_id, team_id, pos)
	var s: SimSkater = _skater(peer_id)
	s.puppet_hold_gap = hold_gap
	s.puppet_depth_floor_z = depth_floor_z if depth_floor_z != 0.0 else pos.z


# Build brains + agents and hand the puck to `carrier_peer` (-1 = loose at
# `loose_puck_pos`). Call once, after every add_skater.
func start(carrier_peer: int, loose_puck_pos: Vector3 = Vector3.ZERO) -> void:
	for tid: int in [0, 1]:
		brains[tid] = TeamBrain.new(tid, team_map, {}, team_size, positions)
	for s: SimSkater in skaters:
		carry_ticks[s.peer_id] = 0
		if s.puppet_hold_gap >= 0.0:
			continue
		s.agent = Agent.new()
		s.agent.setup(s.peer_id, s.team_id, brains[s.team_id], team_map, false)
		if s.profile != null:
			s.agent.apply_profile(s.profile)
	carrier_id = carrier_peer
	if carrier_peer == -1:
		puck_pos = loose_puck_pos
	else:
		puck_pos = _skater(carrier_peer).pos


func run(seconds: float) -> void:
	var n: int = int(seconds / DT)
	for i: int in n:
		step()


func step() -> void:
	ticks += 1
	_puck_history.append(puck_pos)
	if _puck_history.size() > PUPPET_REACTION_TICKS + 2:
		_puck_history.pop_front()
	var snapshot: WorldSnapshot = _build_snapshot()
	var tick_ai_us: int = 0
	if ticks % BRAIN_PERIOD_TICKS == 1:
		var brain_t0: int = Time.get_ticks_usec() if collect_perf else 0
		for tid: int in brains:
			brains[tid].tick(BRAIN_PERIOD_TICKS * DT, snapshot)
		if collect_perf:
			var brain_us: int = Time.get_ticks_usec() - brain_t0
			perf_brain_us += brain_us
			tick_ai_us += brain_us
	# Freeze each brain's strategy view every step (per-frame anchors), matching
	# GameManager, so the dispatch exercises the same frozen-view path production
	# uses rather than the live-brain fallback.
	for tid: int in brains:
		brains[tid].build_view(snapshot)
	# Decide.
	for s: SimSkater in skaters:
		if s.agent == null:
			continue
		s.was_holding_shot = s.input.shoot_held
		s.was_holding_slap = s.input.slap_held
		s.input.shoot_pressed = false
		s.input.slap_pressed = false
		s.input.quick_pass_pressed = false
		s.input.stick_lift_pressed = false
		if collect_perf:
			var t0: int = Time.get_ticks_usec()
			s.agent.dispatch(s.input, snapshot)
			var us: int = Time.get_ticks_usec() - t0
			perf_dispatch_us[s.peer_id] = int(perf_dispatch_us.get(s.peer_id, 0)) + us
			perf_dispatch_calls[s.peer_id] = int(perf_dispatch_calls.get(s.peer_id, 0)) + 1
			tick_ai_us += us
		else:
			s.agent.dispatch(s.input, snapshot)
		if s.agent._poke_evade_deking:
			deke_fired = true
			dekes_by_peer[s.peer_id] = true
		if s.agent._poke_evade_active_ticks > 0:
			evades_by_peer[s.peer_id] = true
	# Collect one-timer readiness into the brains after dispatch — the write moved
	# off _set_one_timer_ready for threading (AICoordinator does the same on the
	# host), so the frozen view reflects it next frame.
	for s: SimSkater in skaters:
		if s.agent != null:
			s.agent.push_one_timer_ready()
	if collect_perf:
		perf_tick_us.append(tick_ai_us)
	# Releases (pass/shot fired by the carrier): quick-shot edge, or a held
	# charge dropping. The puck leaves along the shooter's aim.
	if carrier_id != -1:
		var c: SimSkater = _skater(carrier_id)
		var released: bool = c.input.quick_pass_pressed \
				or (c.was_holding_shot and not c.input.shoot_held) \
				or (c.was_holding_slap and not c.input.slap_held)
		if released:
			# The release record carries the DECISION CONTEXT alongside the
			# event (all additive keys — older consumers read tick/peer only):
			# the carrier's intent and its compete debug scores at the moment
			# of firing, so scenario harnesses can trace WHY a release
			# happened and, later, compare scored completion odds against the
			# actual outcome (the calibration-probe loop).
			var rec: Dictionary = {"tick": ticks, "peer": c.peer_id,
					"team": c.team_id, "pos": c.pos}
			if c.agent != null and c.agent._carrier != null:
				rec["decision"] = c.agent.debug_last_decision
				rec["intent"] = c.agent._carrier.intended_action
				rec["pass_peer"] = c.agent._carrier.debug_pass_peer_id
				rec["pass_score"] = c.agent._carrier.debug_pass_score
				rec["carry_score"] = c.agent._carrier.debug_carry_score
				rec["dump_score"] = c.agent._carrier.debug_dump_score
			releases.append(rec)
			_release_grace[c.peer_id] = ticks + RELEASE_GRACE_TICKS
			var aim: Vector3 = c.input.mouse_world_pos - c.pos
			aim.y = 0.0
			if aim.length_squared() < 0.0001:
				aim = Vector3(c.facing.x, 0.0, c.facing.y)
			puck_vel = aim.normalized() * RELEASE_SPEED_M_S
			carrier_id = -1
	# Integrate bodies + blades.
	for s: SimSkater in skaters:
		if s.agent == null:
			_puppet_step(s)
			continue
		var to_mouse := Vector2(s.input.mouse_world_pos.x - s.pos.x,
				s.input.mouse_world_pos.z - s.pos.z)
		if to_mouse.length() > move_cfg.move_deadzone:
			s.facing = s.facing.lerp(to_mouse.normalized(), FACING_DRAG * DT).normalized()
		var rot_y: float = atan2(-s.facing.x, -s.facing.y)
		# Real sprint physics + stamina pool, from the agent's own sprint
		# input — the same gate/drain/lockout chain the controller runs.
		var is_moving: bool = s.input.move_vector.length() > move_cfg.move_deadzone
		var sprint_on: bool = StaminaRules.sprint_active(
				s.stamina, s.input.sprint_held, is_moving, s.sprint_locked)
		s.vel = SkaterMovementRules.apply_movement(
				s.vel, s.input.move_vector, rot_y, carrier_id == s.peer_id,
				s.input.brake, DT, move_cfg, sprint_on)
		s.stamina = StaminaRules.next_stamina(
				s.stamina, sprint_on, carrier_id == s.peer_id, DT, _stamina_cfg)
		s.sprint_locked = StaminaRules.next_locked(
				s.sprint_locked, s.stamina, sprint_on, _stamina_cfg)
		s.pos += s.vel * DT
		s.prev_blade = s.blade
		var to_cursor: Vector3 = s.input.mouse_world_pos - s.pos
		to_cursor.y = 0.0
		var desired: Vector3 = s.pos + to_cursor.limit_length(BLADE_REACH)
		var max_step: float = (MAX_BLADE_SPEED + s.vel.length()) * DT
		s.blade = s.blade + (desired - s.blade).limit_length(max_step)
	# Puck.
	var prev_puck: Vector3 = puck_pos
	if carrier_id != -1:
		var c2: SimSkater = _skater(carrier_id)
		puck_pos = c2.blade
		puck_vel = c2.vel
		carry_ticks[carrier_id] += 1
		# Strips: an opponent's blade sweeping through the carried puck.
		for s: SimSkater in skaters:
			if s.team_id == c2.team_id:
				continue
			if PuckInteractionRules.check_poke(
					prev_puck, puck_pos, s.prev_blade, s.blade, PICKUP_RADIUS):
				strips += 1
				carrier_id = -1
				var sweep: Vector3 = (s.blade - s.prev_blade) / DT
				sweep.y = 0.0
				puck_vel = sweep.limit_length(STRIP_SQUIRT_M_S)
				break
	elif airborne_ticks > 0:
		# In the air: ballistic ground track, untouchable, lands with a
		# bounce/skid speed loss. Rink clamp still applies (a chip into the
		# glass drops at the boards).
		airborne_ticks -= 1
		puck_pos += puck_vel * DT
		var clamped_air: Vector2 = GameRules.clamp_to_rink_inner(
				Vector2(puck_pos.x, puck_pos.z))
		if clamped_air.x != puck_pos.x or clamped_air.y != puck_pos.z:
			airborne_ticks = 0
			var outward_air := Vector2(puck_pos.x - clamped_air.x, puck_pos.z - clamped_air.y)
			puck_vel = PuckCollisionRules.board_rescue_velocity(
					puck_vel, outward_air, BOARD_RESTITUTION)
			puck_pos = Vector3(clamped_air.x, puck_pos.y, clamped_air.y)
		if airborne_ticks == 0:
			puck_vel *= LANDING_SPEED_KEEP
	else:
		var speed: float = Vector2(puck_vel.x, puck_vel.z).length()
		if speed > 0.0:
			var drop: float = GameRules.PUCK_ICE_DECEL_M_S2 * DT
			var scale: float = maxf(speed - drop, 0.0) / speed
			puck_vel *= scale
		puck_pos += puck_vel * DT
		# Boards: clamp to the rink and reflect the outward component (the
		# same analytic backstop the real Puck runs). Without this a dumped
		# or rimmed puck sailed out of the world and every loose-puck
		# scenario beyond a few metres was unwinnable by construction —
		# and rims can't wrap corners a harness doesn't have.
		var clamped: Vector2 = GameRules.clamp_to_rink_inner(
				Vector2(puck_pos.x, puck_pos.z))
		if clamped.x != puck_pos.x or clamped.y != puck_pos.z:
			var outward := Vector2(puck_pos.x - clamped.x, puck_pos.z - clamped.y)
			puck_vel = PuckCollisionRules.board_rescue_velocity(
					puck_vel, outward, BOARD_RESTITUTION)
			puck_pos = Vector3(clamped.x, puck_pos.y, clamped.y)
		for s: SimSkater in skaters:
			if s.agent == null:
				continue   # a puppet contains and pokes; it never carries
			if ticks < int(_release_grace.get(s.peer_id, 0)):
				continue   # own release still departing the blade
			var rel: Vector3 = puck_vel - s.vel
			if Vector2(rel.x, rel.z).length() > PICKUP_MAX_REL_SPEED:
				continue
			if PuckInteractionRules.check_pickup(
					prev_puck, puck_pos, s.prev_blade, s.blade, PICKUP_RADIUS):
				carrier_id = s.peer_id
				puck_pos = s.blade
				puck_vel = s.vel
				break


# One containment tick: P-control (accel-limited, speed-capped) toward the
# hold point on the [seen puck → own net] line, clamped at the depth floor;
# facing and blade play the reaction-delayed puck (the presented blade is a
# live poke threat — check_poke strips a puck carried into it).
func _puppet_step(s: SimSkater) -> void:
	var seen: Vector3 = _puck_history[maxi(0, _puck_history.size() - 1 - PUPPET_REACTION_TICKS)]
	var own_net_z: float = (1.0 if s.team_id == 0 else -1.0) * GameRules.GOAL_LINE_Z
	var to_net := Vector3(-seen.x, 0.0, own_net_z - seen.z)
	var target: Vector3 = seen
	if to_net.length() > 0.001:
		target = seen + to_net.normalized() * s.puppet_hold_gap
	if s.team_id == 0:
		target.z = minf(target.z, s.puppet_depth_floor_z)
	else:
		target.z = maxf(target.z, s.puppet_depth_floor_z)
	var err := Vector3(target.x - s.pos.x, 0.0, target.z - s.pos.z)
	var desired: Vector3 = (err * PUPPET_GAIN).limit_length(PUPPET_MAX_SPEED_M_S)
	s.vel += (desired - s.vel).limit_length(PUPPET_ACCEL_M_S2 * DT)
	s.pos += s.vel * DT
	var to_puck := Vector2(seen.x - s.pos.x, seen.z - s.pos.z)
	if to_puck.length() > 0.05:
		s.facing = s.facing.lerp(to_puck.normalized(), FACING_DRAG * DT).normalized()
	s.prev_blade = s.blade
	var reach := Vector3(to_puck.x, 0.0, to_puck.y).limit_length(BLADE_REACH * 0.8)
	var max_step: float = (MAX_BLADE_SPEED + s.vel.length()) * DT
	s.blade = s.blade + (s.pos + reach - s.blade).limit_length(max_step)


func carrier() -> int:
	return carrier_id


func _skater(peer_id: int) -> SimSkater:
	for s: SimSkater in skaters:
		if s.peer_id == peer_id:
			return s
	return null


func skater_pos(peer_id: int) -> Vector3:
	return _skater(peer_id).pos


func skater_facing(peer_id: int) -> Vector2:
	return _skater(peer_id).facing


func _build_snapshot() -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	for s: SimSkater in skaters:
		var st := SkaterNetworkState.new()
		st.position = s.pos
		st.velocity = s.vel
		st.facing = s.facing
		st.blade_contact_world = s.blade
		st.stamina = s.stamina
		st.sprint_locked = s.sprint_locked
		snap.skater_states[s.peer_id] = st
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = puck_pos
	snap.puck_state.velocity = puck_vel
	snap.puck_state.carrier_peer_id = carrier_id
	snap.real_puck_carrier_peer_id = carrier_id
	# The AI enrichment GameManager publishes in production
	# (_enrich_snapshot_for_ai): team rosters + the hysteretic loose-puck
	# chase election. Without these no bot can ever be the elected chaser
	# (the CHASE_PUCK gate reads the election) and the brain's RETRIEVAL
	# read can't see a playable race — loose-puck scenarios silently played
	# without the production loose-puck machinery.
	for s: SimSkater in skaters:
		var arr: Array = snap.teammate_ids_by_team.get_or_add(s.team_id, [])
		arr.append(s.peer_id)
	for tid: int in snap.teammate_ids_by_team:
		# The camper filter is part of that enrichment too: a one-timer-ready
		# bot has opted out of loose-puck work, so electing him froze the whole
		# team (he refuses the chase, nobody else is elected). Omitting it here
		# ran every loose-puck scenario on an election production never makes.
		var camped: Array = []
		for pid: int in snap.teammate_ids_by_team[tid]:
			if brains[tid].is_one_timer_ready(pid):
				camped.append(pid)
		var elected: int = AILoosePuckChase.elect(
				snap.skater_states, snap.teammate_ids_by_team[tid],
				puck_pos, puck_vel, int(_prev_chase_by_team.get(tid, -1)),
				{}, true, [], camped)
		snap.closest_to_puck_by_team[tid] = elected
		_prev_chase_by_team[tid] = elected
	# Static home keepers so shot scoring sees someone in each net (goalie
	# BEHAVIOR is out of scope — this only keeps "empty net!" from dominating
	# every carrier compete).
	for tid: int in [0, 1]:
		var g := GoalieNetworkState.new()
		g.position_x = 0.0
		g.position_z = (1.0 if tid == 0 else -1.0) * (GameRules.GOAL_LINE_Z - 0.8)
		# Real-goalie override (see goalie_provider): a Vector3 replaces the static
		# keeper for this net with the live controller's tracked position.
		if goalie_provider.is_valid():
			var real: Variant = goalie_provider.call(tid, puck_pos)
			if real is Vector3:
				g.position_x = real.x
				g.position_z = real.z
		snap.goalie_states[tid] = g
	return snap
