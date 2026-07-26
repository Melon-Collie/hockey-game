extends RefCounted

# ── REAL-goalie shot-outcome instrument ──────────────────────────────────────
# Ground truth for "does the live goalie actually stop this shot." Drives the
# REAL GoalieController (from Goalie.tscn) and the REAL analytic puck→goalie
# save loop — GoalieContactDetector.nearest + GoalieSaveRules.resolve_contact,
# the exact pair Puck._physics_process runs on the host — with the goalie's real
# reaction delay, butterfly drop, lateral push and pose anatomy (glove/pad
# boxes) in the loop. Unlike shot_sim_harness (a lateral-reach BAND model that
# score_shoot is calibrated against), nothing here is a re-derived cover proxy:
# the puck is marched tick-by-tick and tested against the goalie's actual posed
# collision boxes, and the goalie reacts to the real puck motion each tick.
#
# This is the reference the band instrument and score_shoot's HIGH/LOW cover are
# reconciled to — the "measure" half of measure-then-match. No class_name (test
# infra stays out of the global namespace); the nodes are owned by the test
# (add_child_autofree) and handed in via setup().
#
# APPROXIMATION SCOPE: a single, set goalie (no rush backflow), a free shot from
# the release point (no carrier attach), and the puck marched with the real
# frame step (posts/crossbar/net panels) + the real goalie collision. Rebounds
# are terminal — first goalie contact classifies SAVE (a live kick that reverses
# the puck's goalward z is a save-out; a deaden/catch is a save). Read the SAVE
# RATE per (range × loft) as the measurement.

const DT: float = 1.0 / 120.0
const RADIUS: float = GameRules.PUCK_COLLISION_RADIUS
const MAX_STEPS: int = 300          # ~2.5 s flight ceiling — a shot resolves long before

# Outcome enum mirrors shot_sim_harness so callers can compare the two
# instruments cell-for-cell.
enum { GOAL, SAVE, POST, WIDE, NO_SHOT }

var _goalie: Node = null
var _puck: Node = null
var _ctrl: GoalieController = null
var _shooter: Skater = null
var _goal_z: float = -GameRules.GOAL_LINE_Z

# Diagnostics from the last fire() (for probing the instrument).
var last_part: int = -1              # SavePart of the contact that ended it, or -1
var last_contact_pos: Vector3 = Vector3.INF   # where the save contact happened
var last_cross: Vector3 = Vector3.INF         # net-plane crossing (x, y) if it got there
var last_goalie_pos: Vector3 = Vector3.INF    # goalie world pos at the decisive moment
# Puck speed at the moment of goalie contact. Lets a caller ask
# GoalieSaveRules.is_controlled_save whether that save actually ENDED the play
# or kicked a live puck back into the slot — this instrument stops at first
# contact, so without it every rebound goal silently reads as a save.
var last_shot_speed: float = 0.0

# Reused per-march scratch (allocation-free like the production loop).
var _scratch: SweptDiscOBB.Result = SweptDiscOBB.Result.new()
var _contact: GoalieContactDetector.Contact = GoalieContactDetector.Contact.new()
var _frame: PuckGeometryCollision.Result = PuckGeometryCollision.Result.new()
var _tick: PuckAuthorityRules.TickResult = PuckAuthorityRules.TickResult.new()


# Bind the test-owned nodes and wire the controller to a goalie defending the
# -Z net, fed a real opposing Skater shooter (positioned per shot).
func setup(goalie: Node, puck: Node, ctrl: GoalieController, shooter: Skater) -> void:
	_goalie = goalie
	_puck = puck
	_ctrl = ctrl
	_shooter = shooter
	_shooter.set_physics_process(false)
	_shooter.set_process(false)
	_ctrl.set_skater_getter(func() -> Array: return [_shooter])
	_ctrl.setup(_goalie, _puck, _goal_z, true)


# THE REPLICATED GOALIE READ the shot model is fed in gameplay — the same fields
# carrier.gd assembles into its _shot_env_* (post seal, stance family, five-hole
# gap, hand/pad pose). Instruments MUST score through this rather than leaning on
# score_shoot's defaults: the defaults describe a DEGRADED keeper (no seal, no
# pose, no measured five-hole), so scoring against them measures a code path the
# bots never execute while the puck meets the full live goalie. Every
# disagreement found that way is partly instrument error.
func shot_env() -> Dictionary:
	var gs := GoalieNetworkState.new()
	_ctrl.fill_state(gs)
	var down: bool = gs.is_down()
	return {
		"down": down,
		"five": GoalieBehaviorRules.five_hole_gap_m(down, gs.five_hole_openness),
		"seal_x": gs.post_seal_x_sign(_goal_z),
		"seal_tall": gs.is_post_seal_tall(),
		"hands": gs.hands_read(_goal_z),
		"pads": gs.pads_read(_goal_z),
	}


# Drive the goalie to its set pose for a shooter at `shooter`, holding the puck
# there. `ticks` long enough to settle (challenge depth + square-up).
func settle(shooter: Vector3, ticks: int) -> void:
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	# Carry the puck so the goalie reads a CARRIER threat and sets at the proper
	# challenge depth (a loose puck reads differently — it sits back on the line).
	_puck.set_carrier(_shooter)
	for _i: int in ticks:
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


# Launch velocity for a shot from `shooter` toward the net-plane `aim`: horizontal
# heading toward the aim (+ scatter), pace split into the horizontal component and
# the loft's fixed vertical launch (same model as ShotMechanics / shot_sim_harness
# so the two instruments are comparable). Vector3.ZERO if the aim is degenerate.
func shot_velocity(shooter: Vector3, aim: Vector3, loft_level: int, power_t: float,
		err_rad: float) -> Vector3:
	var to_aim := Vector2(aim.x - shooter.x, aim.z - shooter.z)
	if to_aim.length() < 0.001:
		return Vector3.ZERO
	var ang: float = to_aim.angle() + err_rad
	var hdir := Vector2(cos(ang), sin(ang))
	var speed: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S \
			+ clampf(power_t, 0.0, 1.0) * (GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
					- GameRules.DEFAULT_WRISTER_POWER_MIN_M_S)
	var loft_vy: float = ShotMechanics._loft_vy(loft_level,
			GameRules.DEFAULT_LOFT_VY_LOW_M_S, GameRules.DEFAULT_LOFT_VY_HIGH_M_S)
	var v_h: float = sqrt(maxf(speed * speed - loft_vy * loft_vy, 1.0))
	return Vector3(hdir.x * v_h, loft_vy, hdir.y * v_h)


# Launch velocity at an EXPLICIT speed (m/s) rather than a power fraction, so an
# instrument can sweep the speeds people actually shoot instead of a normalized
# band. Same loft split as shot_velocity: the loft's fixed vertical launch comes
# out of the total, the rest is horizontal.
func shot_velocity_at(shooter: Vector3, aim: Vector3, loft_level: int,
		speed_m_s: float, err_rad: float) -> Vector3:
	var to_aim := Vector2(aim.x - shooter.x, aim.z - shooter.z)
	if to_aim.length() < 0.001:
		return Vector3.ZERO
	var ang: float = to_aim.angle() + err_rad
	var hdir := Vector2(cos(ang), sin(ang))
	var loft_vy: float = ShotMechanics._loft_vy(loft_level,
			GameRules.DEFAULT_LOFT_VY_LOW_M_S, GameRules.DEFAULT_LOFT_VY_HIGH_M_S)
	var v_h: float = sqrt(maxf(speed_m_s * speed_m_s - loft_vy * loft_vy, 1.0))
	return Vector3(hdir.x * v_h, loft_vy, hdir.y * v_h)


# fire() at an explicit speed. Mirrors fire()'s bookkeeping exactly.
func fire_at(shooter: Vector3, aim: Vector3, loft_level: int, speed_m_s: float,
		err_rad: float) -> int:
	var vel: Vector3 = shot_velocity_at(shooter, aim, loft_level, speed_m_s, err_rad)
	if vel == Vector3.ZERO:
		return WIDE
	_shooter.global_position = shooter
	_puck.clear_carrier()
	last_part = -1
	last_contact_pos = Vector3.INF
	last_cross = Vector3.INF
	last_goalie_pos = Vector3.INF
	return _march(shooter, vel)


func fire(shooter: Vector3, aim: Vector3, loft_level: int, power_t: float,
		err_rad: float) -> int:
	var vel: Vector3 = shot_velocity(shooter, aim, loft_level, power_t, err_rad)
	if vel == Vector3.ZERO:
		return WIDE
	_shooter.global_position = shooter
	# Release: the puck leaves the blade and flies as a shot.
	_puck.clear_carrier()
	last_part = -1
	last_contact_pos = Vector3.INF
	last_cross = Vector3.INF
	last_goalie_pos = Vector3.INF
	return _march(shooter, vel)


# March a released puck against the live goalie until it resolves. Shared by the
# plain `fire` path and the windup/release path below.
func _march(shooter: Vector3, vel_in: Vector3) -> int:
	var goal := Vector3(0.0, 0.0, _goal_z)
	var vel: Vector3 = vel_in
	var pos: Vector3 = shooter
	pos.y = _puck.ice_height
	var goal_dir: float = signf(goal.z - shooter.z)   # sign of z travel toward the net
	for _step: int in MAX_STEPS:
		var prev: Vector3 = pos
		# The goalie sees the puck's real motion this tick and reacts.
		_puck.global_position = pos
		_puck.linear_velocity = vel
		_ctrl._physics_process(DT)
		# Advance the puck with the real frame step (posts / crossbar / net).
		_tick.touched_post = false
		_tick.touched_net = false
		PuckAuthorityRules.step_frame_substep(pos, vel, DT, RADIUS,
				_puck.max_speed, _puck.ice_height, _puck.max_height, _frame, _tick)
		pos = _tick.position
		vel = _tick.velocity
		# Real goalie collision over this tick's swept segment (posed goalie). The
		# instrument counts FIRST goalie contact as the outcome: a deaden/catch is
		# plainly a save, and a live kick (pad/blocker/stick) is the goalie
		# stopping the initial shot — the second-chance rebound is a separate event
		# out of this instrument's scope (mirrors shot_sim_harness's terminal-save
		# scope). So any contact classifies SAVE.
		if GoalieContactDetector.nearest([_goalie], prev, pos, RADIUS, _scratch, _contact):
			last_shot_speed = vel.length()
			var g3: Node3D = _contact.goalie as Node3D
			last_part = _classify_part(_contact.part as Node3D)
			last_contact_pos = _contact.point
			last_goalie_pos = g3.global_position if g3 != null else Vector3.INF
			return SAVE
		# Reached/passed the goal-line plane this tick (started in front, so the
		# first tick with (pos.z − goal.z)·goal_dir ≥ 0 is the goalward crossing)?
		# Interpolate to z = goal.z and read the on/off-net verdict there.
		if (pos.z - goal.z) * goal_dir >= 0.0:
			var seg: float = pos.z - prev.z
			var f: float = clampf((goal.z - prev.z) / seg, 0.0, 1.0) if absf(seg) > 1e-6 else 1.0
			var cx: float = prev.x + (pos.x - prev.x) * f
			var cy: float = prev.y + (pos.y - prev.y) * f
			last_cross = Vector3(cx, cy, goal.z)
			last_goalie_pos = _goalie.global_position
			return _net_verdict(cx, cy)
	return WIDE


# Run `samples` scatter draws of one aim/loft/power triple from a settled goalie,
# re-settling between shots so each sample fires at the set pose. Returns a counts
# dict keyed by the outcome enum plus "shots".
func run_spot(shooter: Vector3, aim: Vector3, loft_level: int, power_t: float,
		spread: float, samples: int, resettle_ticks: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var counts := {GOAL: 0, SAVE: 0, POST: 0, WIDE: 0, "shots": 0}
	for _i: int in samples:
		settle(shooter, resettle_ticks)
		var err: float = rng.randf_range(-spread, spread)
		var outcome: int = fire(shooter, aim, loft_level, power_t, err)
		counts[outcome] += 1
		counts["shots"] += 1
	return counts


# Classify a save surface by node name, mirroring Puck._classify_save_part.
func _classify_part(part_body: Node3D) -> int:
	if part_body == null:
		return GoalieSaveRules.SavePart.PAD
	match part_body.name:
		"Glove":
			return GoalieSaveRules.SavePart.GLOVE
		"Body", "Head":
			return GoalieSaveRules.SavePart.CHEST
		"Blocker":
			return GoalieSaveRules.SavePart.BLOCKER
		"Stick":
			return GoalieSaveRules.SavePart.STICK
	return GoalieSaveRules.SavePart.PAD


# On/off-net verdict at the goal-line crossing (mirror of shot_sim_harness).
func _net_verdict(cross_x: float, cross_y: float) -> int:
	var hw: float = GameRules.NET_HALF_WIDTH
	var bar: float = GameRules.NET_HEIGHT
	if absf(cross_x) > hw - RADIUS or cross_y > bar - RADIUS:
		if absf(cross_x) <= hw + GameRules.NET_POST_RADIUS + RADIUS \
				and cross_y <= bar + GameRules.NET_POST_RADIUS:
			return POST
		return WIDE
	return GOAL


# ── REBOUND tracking ─────────────────────────────────────────────────────────
# `fire`/`fire_at` stop at first contact, which is right for measuring reach but
# silently scores every rebound goal as a save. This variant applies the REAL
# save response (GoalieSaveRules.resolve_contact + the flush eject, the exact
# pair Puck._physics_process runs) and keeps marching, so it can answer the
# question that actually matters: where does the puck END UP.
#
# "Live vs deadened" is NOT that question. A hard shot off a toed-out pad is
# live AND safe — the pose angle sends it to the corner. A chest save is
# deadened and DANGEROUS — GoalieSaveRules zeroes its goalward and vertical
# motion so it settles dead in front of him, in the paint. Destination is the
# measurement; restitution is not.
#
# Fills `last_part` with the FIRST contact as usual, plus:
#   rebound_pos    where the puck was when it settled / left the danger area
#   rebound_speed  its speed there
#   rebound_goal   true if it eventually went in (first shot OR rebound)
var rebound_pos: Vector3 = Vector3.INF
var rebound_speed: float = 0.0
var rebound_goal: bool = false
var _deaden: GoalieSaveRules.DeadenConfig = null
var _save_res: GoalieSaveRules.ContactResult = GoalieSaveRules.ContactResult.new()

const REBOUND_TRACK_S: float = 1.5
const PLAYABLE_SPEED_M_S: float = 8.0   # slow enough for a skater to actually play it


func fire_tracking_rebound(shooter: Vector3, aim: Vector3, loft_level: int,
		speed_m_s: float, err_rad: float) -> int:
	if _deaden == null:
		_deaden = GoalieSaveRules.DeadenConfig.new()
		_deaden.pad_max_incoming_speed = _puck.save_deaden_pad_max_speed
		_deaden.drop_speed = _puck.save_deaden_drop_speed
		_deaden.glove_retain = _puck.save_deaden_glove_retain
		_deaden.chest_retain = _puck.save_deaden_chest_retain
		_deaden.pad_steer_speed = _puck.save_steer_speed
		_deaden.steer_lateral_weight = _puck.save_steer_lateral_weight
		_deaden.steer_forward_weight = _puck.save_steer_forward_weight
	var vel: Vector3 = shot_velocity_at(shooter, aim, loft_level, speed_m_s, err_rad)
	if vel == Vector3.ZERO:
		return WIDE
	last_part = -1
	rebound_pos = Vector3.INF
	rebound_speed = 0.0
	rebound_goal = false
	_shooter.global_position = shooter
	_puck.clear_carrier()
	var goal := Vector3(0.0, 0.0, _goal_z)
	var pos: Vector3 = shooter
	pos.y = _puck.ice_height
	var goal_dir: float = signf(goal.z - shooter.z)
	var touched: bool = false
	var outcome: int = WIDE
	var steps: int = int(REBOUND_TRACK_S / DT)
	for _step: int in steps:
		var prev: Vector3 = pos
		_puck.global_position = pos
		_puck.linear_velocity = vel
		_ctrl._physics_process(DT)
		_tick.touched_post = false
		_tick.touched_net = false
		PuckAuthorityRules.step_frame_substep(pos, vel, DT, RADIUS,
				_puck.max_speed, _puck.ice_height, _puck.max_height, _frame, _tick)
		pos = _tick.position
		vel = _tick.velocity
		if GoalieContactDetector.nearest([_goalie], prev, pos, RADIUS, _scratch, _contact):
			var part: int = _classify_part(_contact.part as Node3D)
			if not touched:
				last_part = part
				last_shot_speed = vel.length()
				touched = true
				outcome = SAVE
			var g3: Node3D = _contact.goalie as Node3D
			var side: float = signf(pos.x - g3.global_position.x) if g3 != null else 0.0
			var dir_sign: int = int(signf(-g3.global_position.z)) if g3 != null else 0
			GoalieSaveRules.resolve_contact(
					vel, part, _contact.normal, side, dir_sign, _deaden, _save_res)
			vel = _save_res.velocity
			pos = _contact.point + _contact.normal * _contact.depth
			# A caught puck is dead and held — the play stops there.
			if _save_res.caught:
				rebound_pos = pos
				rebound_speed = 0.0
				return SAVE
		elif (pos.z - goal.z) * goal_dir >= 0.0 and not touched:
			var seg: float = pos.z - prev.z
			var f: float = clampf((goal.z - prev.z) / seg, 0.0, 1.0) if absf(seg) > 1e-6 else 1.0
			outcome = _net_verdict(prev.x + (pos.x - prev.x) * f,
					prev.y + (pos.y - prev.y) * f)
			if outcome == GOAL:
				rebound_goal = true
			rebound_pos = pos
			rebound_speed = vel.length()
			return outcome
		# After a save, the first moment it is slow enough to be played is where
		# the second chance lives.
		if touched and vel.length() <= PLAYABLE_SPEED_M_S:
			rebound_pos = pos
			rebound_speed = vel.length()
			return outcome
	rebound_pos = pos
	rebound_speed = vel.length()
	return outcome


# ── Windup → release path (the DISGUISE instrument) ──────────────────────────
# `settle` + `fire` above never exercise the RELEASE event: the puck simply
# appears in flight and the goalie picks it up through the universal-reaction
# path, which explicitly grants no pre-arm. That is the right scope for raw
# reach measurement, but it cannot see anything about what the goalie READ
# before the shot — so it cannot measure disguise.
#
# This pair drives the real read pipeline instead:
#   hold_windup()  — the carrier sits in WRISTER_AIM with the puck pinned,
#                    publishing `declared_aim` as predicted_shot_velocity. This is
#                    the aim the goalie fixates on: it feeds the pre-lean, the
#                    pinned-windup squaring, and the quiet-eye pre-arm timer.
#   fire_release() — clears the carry and emits puck_released with the ACTUAL
#                    shot velocity, so GoalieController._on_puck_released runs
#                    (consuming any pre-arm) exactly as it does in a real game.
#
# Pointing `declared_aim` and the release aim at the SAME corner is a telegraphed
# shot; pointing them at OPPOSITE corners is a late swing — the disguised,
# against-the-grain release. The save-rate delta between those two arms is the
# measurement.


# Speed-explicit windup/release pair — the HUMAN mechanism. A player skates in,
# holds LMB (which freezes the blade and publishes predicted_shot_velocity, so
# the goalie pre-leans and builds his pre-arm read), then releases at the target.
# `fire`/`fire_at` model none of that: the puck simply appears in flight and the
# keeper picks it up cold. Any sweep that wants to match what a human actually
# executes has to come through here.
# NOTE: no reset_to_crease here, deliberately. A human skates in and sets up
# BEFORE pulling the trigger, so the keeper is already square and at challenge
# depth when the windup starts. Resetting inside the windup measures a keeper
# caught mid-transition, which reads as "the pre-arm made him worse" when really
# he never got set. Callers do reset + settle first, then hold.
func hold_windup_at(shooter: Vector3, declared_aim: Vector3, loft_level: int,
		speed_m_s: float, ticks: int) -> void:
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	_shooter.current_shot_state = SkaterStateMachine.State.WRISTER_AIM
	_shooter.predicted_shot_velocity = shot_velocity_at(
			shooter, declared_aim, loft_level, speed_m_s, 0.0)
	_puck.set_carrier(_shooter)
	for _i: int in ticks:
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


func fire_release_at(shooter: Vector3, aim: Vector3, loft_level: int,
		speed_m_s: float, err_rad: float) -> int:
	var vel: Vector3 = shot_velocity_at(shooter, aim, loft_level, speed_m_s, err_rad)
	if vel == Vector3.ZERO:
		return WIDE
	last_part = -1
	last_contact_pos = Vector3.INF
	last_cross = Vector3.INF
	last_goalie_pos = Vector3.INF
	_shooter.current_shot_state = SkaterStateMachine.State.FOLLOW_THROUGH
	_puck.clear_carrier()
	var pos: Vector3 = shooter
	pos.y = _puck.ice_height
	_puck.global_position = pos
	_puck.apply_release_velocity(vel)
	_puck.puck_released.emit()
	return _march(shooter, vel)


# Hold a wrister windup aimed at `declared_aim` for `ticks`, with the goalie
# tracking it live. Puck stays pinned on the carrier (the body-local freeze).
func hold_windup(shooter: Vector3, declared_aim: Vector3, loft_level: int,
		power_t: float, ticks: int) -> void:
	# Clean slate. Without this the goalie carries pose, depth, reaction and
	# butterfly state from the PREVIOUS shot, so consecutive trials are not
	# comparable — the dominant error term when sweeping arms against each other.
	_ctrl.reset_to_crease()
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	_shooter.current_shot_state = SkaterStateMachine.State.WRISTER_AIM
	# What the goalie can read off the windup: the shot that would fire right now.
	_shooter.predicted_shot_velocity = shot_velocity(
			shooter, declared_aim, loft_level, power_t, 0.0)
	_puck.set_carrier(_shooter)
	for _i: int in ticks:
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


# Hold a wrister windup that SWEEPS: `hold_ticks` parked on `from_aim`, then
# `sweep_ticks` walking the declared aim linearly to `to_aim`. This is the
# human-executable look-off — hold LMB, coil toward the decoy, drag the cursor
# across, release — and it is the only shape that separates a goalie reading the
# LIVE aim from one reading a stale sample. `hold_windup`'s step-at-release
# disguise cannot: an aim that never moves during the wind-up makes stale and
# live identical by construction.
func sweep_windup(shooter: Vector3, from_aim: Vector3, to_aim: Vector3,
		loft_level: int, power_t: float, hold_ticks: int,
		sweep_ticks: int) -> void:
	hold_windup(shooter, from_aim, loft_level, power_t, hold_ticks)
	for i: int in sweep_ticks:
		var t: float = float(i + 1) / float(maxi(sweep_ticks, 1))
		_shooter.predicted_shot_velocity = shot_velocity(
				shooter, from_aim.lerp(to_aim, t), loft_level, power_t, 0.0)
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


# Release toward `aim` through the real puck_released event and march it.
func fire_release(shooter: Vector3, aim: Vector3, loft_level: int,
		power_t: float, err_rad: float) -> int:
	var vel: Vector3 = shot_velocity(shooter, aim, loft_level, power_t, err_rad)
	if vel == Vector3.ZERO:
		return WIDE
	last_part = -1
	last_contact_pos = Vector3.INF
	last_cross = Vector3.INF
	last_goalie_pos = Vector3.INF
	_shooter.current_shot_state = SkaterStateMachine.State.FOLLOW_THROUGH
	_puck.clear_carrier()
	var pos: Vector3 = shooter
	pos.y = _puck.ice_height
	_puck.global_position = pos
	# The real release read: apply_release_velocity queues the launch the way
	# release() does, so the goalie's get_release_velocity() sees the true shot on
	# the signal frame.
	_puck.apply_release_velocity(vel)
	_puck.puck_released.emit()
	return _march(shooter, vel)


# One windup→release trial. `declared_aim == aim` is telegraphed; a different
# `declared_aim` is a late swing. Returns the outcome enum.
func windup_shot(shooter: Vector3, declared_aim: Vector3, aim: Vector3,
		loft_level: int, power_t: float, windup_ticks: int) -> int:
	hold_windup(shooter, declared_aim, loft_level, power_t, windup_ticks)
	return fire_release(shooter, aim, loft_level, power_t, 0.0)
