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
# Puck speed at the moment of goalie contact. This instrument stops at first
# contact, so a caller ranking saves by how hard they were hit needs it, and
# without something like it every rebound goal silently reads as a save.
var last_shot_speed: float = 0.0
# Did that first contact END the play — i.e. was it a glove catch? The only save
# outcome that does, now that every other one is a material rebound. A caller
# counting second chances wants this rather than a speed threshold: "hard enough
# to beat the pad" stopped being a thing the model believes.
var last_caught: bool = false
# Was that first contact a chest SMOTHER? Neither a live rebound nor a stoppage:
# the shot is dead and the puck is his to sweep. A caller counting second chances
# must not fold it in with pucks that kicked out live.
var last_trapped: bool = false

# Reused per-march scratch (allocation-free like the production loop).
var _scratch: SweptDiscOBB.Result = SweptDiscOBB.Result.new()
var _contact: GoalieContactDetector.Contact = GoalieContactDetector.Contact.new()
var _frame: PuckGeometryCollision.Result = PuckGeometryCollision.Result.new()
var _tick: PuckAuthorityRules.TickResult = PuckAuthorityRules.TickResult.new()


# A fresh play starts. Stands in for the phase machinery, which is the OTHER
# half of the world the controller lives in and which no instrument runs.
#
# `pickup_locked` is the one that bites: a glove catch sets it (the puck goes
# dead to blades while he holds it) and only the phase machine's PLAYING entry
# clears it, after the faceoff. In an instrument nothing ever clears it, so the
# FIRST catch of a run locks the puck permanently — and `pickup_locked` is a gate
# on the crease sweep, so from that shot onward the goalie can never clear his
# own rebound again. Measured: 1 sweep in 63 chest saves, against 12 of 12 when
# the same cases run before any catch.
func _begin_play() -> void:
	if _puck != null:
		_puck.pickup_locked = false
		_puck.motion_pinned = false


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
	_begin_play()
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	# Carry the puck so the goalie reads a CARRIER threat and sets at the proper
	# challenge depth (a loose puck reads differently — it sits back on the line).
	_puck.set_carrier(_shooter)
	for _i: int in ticks:
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


# ── THE CARRIER WHO IS ACTUALLY MOVING ───────────────────────────────────────
# Every other setup here parks the shooter on a spot. That is a shot nobody
# takes: a player skates in and releases off the drive, and a MOVING carrier
# changes what the goalie is solving — the arc target sweeps under him, the
# carrier lead displaces the threat, and the rush backflow retreats him. None of
# that is exercised by a shooter standing still.
#
# `lane_x` held constant with the drive purely down -Z is the sharpest version:
# the shooter's own lateral velocity is ZERO the whole way, while the angle he
# presents swings the width of the mouth. Anything in the goalie's model keyed to
# the carrier's lateral SPEED is blind to it by construction.
#
# Distances are perpendicular metres out from the goal line. The caller owns the
# starting pose (`settle_ready` at the start spot) so a drive measures tracking
# and not a keeper still walking out. Returns the release position.
#
# `declared_aim` other than Vector3.INF drives him in a published wind-up (the
# human mechanism: hold the trigger through the drive, release at the spot);
# INF drives him in plain SKATING_WITH_PUCK and the release is cold.
func drive_in(lane_x: float, start_dist: float, release_dist: float,
		speed_m_s: float, declared_aim: Vector3 = Vector3.INF,
		loft_level: int = 0, shot_speed_m_s: float = 0.0,
		shot_state: int = SkaterStateMachine.State.WRISTER_AIM) -> Vector3:
	var dir: float = signf(-_goal_z)      # +1 into the rink from this goal line
	var z: float = _goal_z + dir * start_dist
	var end_z: float = _goal_z + dir * release_dist
	var vel := Vector3(0.0, 0.0, -dir * absf(speed_m_s))
	var winding: bool = declared_aim != Vector3.INF
	_shooter.current_shot_state = shot_state if winding \
			else SkaterStateMachine.State.SKATING_WITH_PUCK
	_puck.set_carrier(_shooter)
	var pos := Vector3(lane_x, 0.0, z)
	# The carrier is genuinely moving, so `velocity` must be set: the goalie reads
	# it for the carrier lead and for the rush backflow's closing-speed gate. A
	# drive with velocity left at zero is a teleporting shooter and the goalie
	# solves a different problem.
	for _i: int in MAX_STEPS:
		_shooter.global_position = pos
		_shooter.velocity = vel
		if winding:
			_shooter.predicted_shot_velocity = shot_velocity_at(
					pos, declared_aim, loft_level, shot_speed_m_s, 0.0)
		_puck.global_position = pos
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		if (pos.z - end_z) * dir <= 0.0:
			break
		pos.z += vel.z * DT
	_shooter.global_position = pos
	return pos


# ── THE WALKOUT, continued from wherever `drive_in` left him ─────────────────
# The move the retreat EXISTS for, in the shape it actually takes: the BODY keeps
# driving straight at the net while the PUCK is dragged across the crease faster
# than the goalie can push. A goalie held too far out has a longer arc to travel
# to stay in front of it, so this is the measurement that prices depth in the
# other direction — every metre of challenge is a metre of exposure here, and any
# change that buys angle has to be checked against it or it has only been checked
# against the half of the trade it helps.
#
# Deliberately does NOT give the body a lateral velocity: a forehand-to-backhand
# beat on a rush is a shooter coming STRAIGHT at the goalie who moves the puck,
# which is exactly the case a body-velocity read scores as "not a drive".
#
# Returns the PUCK's final position — the release point, which is not the body's.
func sweep_across(to_x: float, seconds: float, drive_speed: float) -> Vector3:
	var ticks: int = maxi(int(seconds / DT), 1)
	var from_x: float = _puck.global_position.x
	var dir: float = signf(-_goal_z)
	var body: Vector3 = _shooter.global_position
	var vel := Vector3(0.0, 0.0, -dir * absf(drive_speed))
	var puck: Vector3 = _puck.global_position
	for i: int in ticks:
		body.z += vel.z * DT
		_shooter.global_position = body
		_shooter.velocity = vel
		puck = Vector3(lerpf(from_x, to_x, float(i + 1) / float(ticks)), 0.0, body.z)
		_puck.global_position = puck
		_ctrl._physics_process(DT)
	return puck


# ── THE DEKE: the BODY goes around him too ──────────────────────────────────
# `sweep_across` moves only the puck, which is the right shape for a
# forehand-backhand beat but cannot see the failure the retreat actually exists
# to prevent — a carrier who skates ACROSS the crease face and past the goalie.
# The difference is not cosmetic: with the body moving, `carrier.velocity.x` is
# finally non-zero, so the lateral tracking cap engages, the carrier lead swings
# the tracked threat, and the beaten-wide seal has a genuine drive to read. A
# depth change can only be judged against this, because "he is deep so he has a
# short arc to travel" is a claim about a body going around him.
#
# The puck LEADS the body laterally, which is what separates a deke from a turn:
# the blade takes the puck across first and the body follows into the space.
# Forward pace is the caller's, and should be lower than the straight-line drive
# — the lateral component is bought out of the same legs.
#
# `last_deke_commit_s` is the seconds into the move at which the goalie first
# dropped into a committed slide (COILING/SLIDING), or INF if he never did. Read
# it beside the goal count: sealing late and sealing never are different
# failures, and the shot map alone cannot tell them apart.
var last_deke_commit_s: float = INF
var last_deke_went_down: bool = false

func deke_across(to_x: float, seconds: float, forward_speed: float,
		puck_lead_x: float = 0.35) -> Vector3:
	last_deke_commit_s = INF
	last_deke_went_down = false
	var ticks: int = maxi(int(seconds / DT), 1)
	var dir: float = signf(-_goal_z)
	var body: Vector3 = _shooter.global_position
	var from_x: float = body.x
	var side: float = signf(to_x - from_x)
	var lateral_rate: float = (to_x - from_x) / maxf(seconds, 0.0001)
	var vel := Vector3(lateral_rate, 0.0, -dir * absf(forward_speed))
	var puck: Vector3 = _puck.global_position
	for i: int in ticks:
		var t: float = float(i + 1) / float(ticks)
		body.x = lerpf(from_x, to_x, t)
		body.z += vel.z * DT
		_shooter.global_position = body
		_shooter.velocity = vel
		# Blade out ahead of the body across the direction of travel. Held to the
		# destination so the puck arrives at the tuck point rather than overrunning
		# it — past the post there is no shot left to take.
		var px: float = body.x + side * puck_lead_x
		puck = Vector3(px, 0.0, body.z)
		_puck.global_position = puck
		_ctrl._physics_process(DT)
		if not _ctrl._sm.is_upright():
			last_deke_went_down = true
		var st: int = _ctrl._sm.current
		if is_inf(last_deke_commit_s) \
				and (st == GoalieStateMachine.State.COILING
						or st == GoalieStateMachine.State.SLIDING):
			last_deke_commit_s = float(i + 1) * DT
	return puck


# Speed-explicit twin of `publish_windup`, for wind-ups whose power band is not
# the wrister's — a slapper charge fires 20-40 m/s, so publishing its declared
# velocity through the wrister band would have the goalie reading a shot nobody
# is about to take.
func publish_windup_at(shooter: Vector3, declared_aim: Vector3, loft_level: int,
		speed_m_s: float, ticks: int,
		shot_state: int = SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK) -> void:
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	_shooter.current_shot_state = shot_state
	_shooter.predicted_shot_velocity = shot_velocity_at(
			shooter, declared_aim, loft_level, speed_m_s, 0.0)
	_puck.set_carrier(_shooter)
	for _i: int in ticks:
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


# ── THE REFERENCE POSE ───────────────────────────────────────────────────────
# Settle the goalie to a REPEATABLE, comparable starting state: square, converged
# on his challenge depth, and still on his feet. Use this instead of `settle` with
# a hand-picked tick count whenever two measurements need to be compared, because
# a fixed count does not mean the same thing at every spot or after every prior
# trial.
#
# Two things it fixes over a raw `settle`:
#
#   CONVERGENCE IS DETECTED, NOT ASSUMED. Recovery from the goal line to challenge
#   depth takes ~1.7 s, so any fixed count below ~200 ticks silently measures a
#   keeper still on his way out (radius 0.54 at 0.2 s vs 1.75 settled). This ticks
#   until the challenge radius and lateral position both stop moving.
#
#   THE SHOOTER IS PUT IN A NON-WINDUP STATE FIRST. `settle` leaves
#   `current_shot_state` at whatever the previous trial set, and a wind-up left
#   published makes the goalie read a shot threat during the settle — he decides
#   to block, drops to butterfly, and then stops reading the wind-up entirely
#   (`_is_reading_shot_threat` is upright-only). That is real behaviour, but it is
#   not a reference pose, and inheriting it from the previous trial is a
#   test-order dependency.
#
# Returns the ticks used. Sets `last_settle_went_down` if he dropped anyway —
# check it rather than assuming, since a spot that blocks on its own is a finding.
var last_settle_went_down: bool = false

func settle_ready(shooter: Vector3, max_ticks: int = 400, tol: float = 0.0015) -> int:
	last_settle_went_down = false
	_begin_play()
	_ctrl.reset_to_crease()
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	# Carrying, but not winding up: nothing for the goalie to read as a threat.
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_puck.set_carrier(_shooter)
	var prev_depth: float = -1.0
	var prev_x: float = INF
	var stable: int = 0
	for i: int in max_ticks:
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		if not _ctrl._sm.is_upright():
			last_settle_went_down = true
			return i + 1
		var d: float = _ctrl._current_depth
		var x: float = _ctrl._current_x
		if absf(d - prev_depth) < tol and absf(x - prev_x) < tol:
			stable += 1
			if stable >= 10:
				return i + 1
		else:
			stable = 0
		prev_depth = d
		prev_x = x
	return max_ticks


# Publish a wind-up for `ticks` WITHOUT resetting or settling — the caller owns
# the starting pose (use `settle_ready`). This is the composable half of
# `hold_windup`, which bundles a reset and is documented as a trap.
func publish_windup(shooter: Vector3, declared_aim: Vector3, loft_level: int,
		power_t: float, ticks: int,
		shot_state: int = SkaterStateMachine.State.WRISTER_AIM) -> void:
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	_shooter.current_shot_state = shot_state
	_shooter.predicted_shot_velocity = shot_velocity(
			shooter, declared_aim, loft_level, power_t, 0.0)
	_puck.set_carrier(_shooter)
	for _i: int in ticks:
		_puck.global_position = shooter
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


# Launch velocity for a shot from `shooter` toward the net-plane `aim`:
# horizontal heading toward the aim (+ scatter), pace split by the level's SET
# ANGLE (ShotMechanics.shot_loft_y, league-neutral M92 ladder — same model as
# the live release and shot_sim_harness, so the instruments are comparable).
# Vector3.ZERO if the aim is degenerate.
func shot_velocity(shooter: Vector3, aim: Vector3, loft_level: int, power_t: float,
		err_rad: float) -> Vector3:
	var speed: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S \
			+ clampf(power_t, 0.0, 1.0) * (GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
					- GameRules.DEFAULT_WRISTER_POWER_MIN_M_S)
	return shot_velocity_at(shooter, aim, loft_level, speed, err_rad)


# Launch velocity at an EXPLICIT speed (m/s) rather than a power fraction, so an
# instrument can sweep the speeds people actually shoot instead of a normalized
# band. Same contact-point split as shot_velocity.
func shot_velocity_at(shooter: Vector3, aim: Vector3, loft_level: int,
		speed_m_s: float, err_rad: float) -> Vector3:
	var to_aim := Vector2(aim.x - shooter.x, aim.z - shooter.z)
	if to_aim.length() < 0.001:
		return Vector3.ZERO
	var ang: float = to_aim.angle() + err_rad
	var hdir := Vector2(cos(ang), sin(ang))
	var y_ratio: float = ShotMechanics.shot_loft_y(loft_level,
			GameRules.DEFAULT_LOFT_TAN_LOW, GameRules.DEFAULT_LOFT_TAN_MID,
			GameRules.DEFAULT_LOFT_TAN_HIGH)
	var inv_norm: float = 1.0 / sqrt(1.0 + y_ratio * y_ratio)
	var v_h: float = maxf(speed_m_s * inv_norm, 1.0)
	return Vector3(hdir.x * v_h, speed_m_s * y_ratio * inv_norm, hdir.y * v_h)


# fire() at an explicit speed. Mirrors fire()'s bookkeeping exactly.
func fire_at(shooter: Vector3, aim: Vector3, loft_level: int, speed_m_s: float,
		err_rad: float) -> int:
	var vel: Vector3 = shot_velocity_at(shooter, aim, loft_level, speed_m_s, err_rad)
	if vel == Vector3.ZERO:
		return WIDE
	_shooter.global_position = shooter
	_puck.clear_carrier()
	last_part = -1
	last_caught = false
	last_trapped = false
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
	last_caught = false
	last_trapped = false
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
			var fwd: Vector3 = -g3.global_transform.basis.z if g3 != null else Vector3.ZERO
			var presented: bool = GoalieSaveRules.is_face_presented(_contact.normal, fwd)
			last_caught = last_part == GoalieSaveRules.SavePart.GLOVE and presented
			last_trapped = last_part == GoalieSaveRules.SavePart.CHEST and presented
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
		"Body":
			return GoalieSaveRules.SavePart.CHEST
		"Head":
			return GoalieSaveRules.SavePart.MASK
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
# A SAVE IS NOT OVER WHEN THE PUCK LEAVES THE PAD. The goalie's own next beat is
# part of it: a puck that dies in front of him is one he sweeps to the corner
# (GoalieCreaseClear — inside `reach` of him, on the ice, under `max_puck_speed`,
# after a dwell), and a puck he gets a glove on is one he holds. So this keeps
# the CONTROLLER ticking for the whole window and reads the puck back from it
# each tick, rather than marching over the goalie's own actions with its own
# integration. Measuring the rebound alone scores "dead at his feet" as a
# second chance in the slot, when it is the setup for the clear.
#
# Fills `last_part` with the FIRST contact as usual, plus:
#   rebound_pos     where the puck ended the window
#   rebound_speed   its speed there
#   rebound_goal    it went in (first shot OR rebound)
#   rebound_caught  he closed a glove on it
#   rebound_held    he pinned it (glove hold or a cover smother)
#   rebound_swept   he played it away with the stick
#
# The return value is the FIRST-shot verdict — SAVE once the goalie touched it,
# whatever happened next. Read `rebound_goal` beside it: SAVE with rebound_goal
# is a second chance buried, and a caller counting only the return value scores
# that as a stop.
var rebound_pos: Vector3 = Vector3.INF
var rebound_speed: float = 0.0
var rebound_goal: bool = false
# The save ENDED the play — the goalie holds the puck. Not a rebound at all, and
# a caller that folds it into rebound statistics reports a frozen puck as a
# second chance sitting in the crease (`rebound_pos` is the goalie's glove).
var rebound_caught: bool = false
# He pinned it (glove hold or cover smother) — the goalie owns the transform.
var rebound_held: bool = false
# He played it away with the stick: the crease sweep fired and changed the puck's
# velocity out from under the integration.
var rebound_swept: bool = false
# Every goalie part the puck met, in order, for the whole tracked flight — not
# just the first. The save is a SEQUENCE, and what a rebound touches on its way
# out is a different question from what stopped it: a chest smother that then
# finds his own stick is a dead play that came back to life.
var contact_parts: Array[int] = []
# Closest the rebound ever came to the SHOOTER, in metres. The direction-
# sensitive half of "was that dangerous": a rebound to the corner and a rebound
# straight back up the slot can settle the same distance from the net, and only
# one of them lands on the stick of the man who just shot it.
var rebound_min_dist_to_shooter: float = INF
# Seconds the rebound spent inside danger_radius_m of the goal.
var rebound_danger_dwell_s: float = 0.0
# Radius from the goal centre that counts as the danger area. The caller owns the
# definition; the harness only needs it to know when a rebound has LEFT.
var danger_radius_m: float = 6.1
var _save_res: GoalieSaveRules.ContactResult = GoalieSaveRules.ContactResult.new()

# Long enough for the whole sequence: the puck has to settle, the clear's dwell
# has to elapse, the windup has to run, and the swept puck has to get somewhere.
const REBOUND_TRACK_S: float = 2.5
const PLAYABLE_SPEED_M_S: float = 8.0   # slow enough for a skater to actually play it
# A rebound this slow has stopped being a rebound and become a loose puck sitting
# in the paint. Deliberately far below PLAYABLE: the question here is not "could
# somebody touch it" — a 6 m/s puck crossing the slot qualifies for that and is
# gone a third of a second later — it is "is it still there".
const REBOUND_REST_M_S: float = 1.0


func fire_tracking_rebound(shooter: Vector3, aim: Vector3, loft_level: int,
		speed_m_s: float, err_rad: float) -> int:
	var vel: Vector3 = shot_velocity_at(shooter, aim, loft_level, speed_m_s, err_rad)
	if vel == Vector3.ZERO:
		return WIDE
	last_part = -1
	rebound_pos = Vector3.INF
	rebound_speed = 0.0
	rebound_goal = false
	rebound_caught = false
	rebound_held = false
	rebound_swept = false
	last_trapped = false
	contact_parts = []
	rebound_min_dist_to_shooter = INF
	rebound_danger_dwell_s = 0.0
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
		# READ THE GOALIE BACK before integrating. He plays the puck through the
		# same API the host drive honours — apply_goalie_sweep writes
		# linear_velocity, cover and the glove hold set motion_pinned — so an
		# instrument that re-imposes its own `vel` every tick simply deletes the
		# clear and then reports that the puck sat in the crease.
		if _puck.motion_pinned:
			rebound_held = true
			rebound_pos = _puck.global_position
			rebound_speed = 0.0
			return outcome if touched else SAVE
		if _puck.linear_velocity.distance_to(vel) > 0.01:
			rebound_swept = true
			vel = _puck.linear_velocity
		_tick.touched_post = false
		_tick.touched_net = false
		PuckAuthorityRules.step_frame_substep(pos, vel, DT, RADIUS,
				_puck.max_speed, _puck.ice_height, _puck.max_height, _frame, _tick)
		pos = _tick.position
		vel = _tick.velocity
		if GoalieContactDetector.nearest([_goalie], prev, pos, RADIUS, _scratch, _contact):
			var part: int = _classify_part(_contact.part as Node3D)
			contact_parts.append(part)
			if not touched:
				last_part = part
				last_shot_speed = vel.length()
				touched = true
				outcome = SAVE
			var g3: Node3D = _contact.goalie as Node3D
			# Mirror Puck._physics_process exactly, facing included — the catch is
			# gated on the face he is presenting.
			var fwd: Vector3 = -g3.global_transform.basis.z if g3 != null else Vector3.ZERO
			GoalieSaveRules.resolve_contact(
					vel, part, _contact.normal, _save_res, fwd)
			if contact_parts.size() == 1:
				last_trapped = _save_res.trapped
			vel = _save_res.velocity
			# Mirror Puck._drive_analytic: a smothered puck is PLACED on the ice.
			if _save_res.trapped:
				pos = Vector3(_contact.point.x, _puck.ice_height, _contact.point.z)
			else:
				pos = _contact.point + _contact.normal * _contact.depth
			# A caught puck is dead and held — the play stops there.
			if _save_res.caught:
				rebound_pos = pos
				rebound_speed = 0.0
				rebound_caught = true
				return SAVE
		elif (pos.z - goal.z) * goal_dir >= 0.0:
			var seg: float = pos.z - prev.z
			var f: float = clampf((goal.z - prev.z) / seg, 0.0, 1.0) if absf(seg) > 1e-6 else 1.0
			var verdict: int = _net_verdict(prev.x + (pos.x - prev.x) * f,
					prev.y + (pos.y - prev.y) * f)
			# BEFORE any contact the crossing IS the outcome. AFTER one the shot is
			# already a save, and only a GOAL is terminal — a rebound crossing the
			# goal-line plane wide of the posts is a puck going behind the net, which
			# keeps playing. Gating this whole branch on `not touched` (as it was)
			# made the second chance unobservable: the loop ran on to the speed cut
			# and reported a settle point that could be inside the cage.
			if not touched:
				outcome = verdict
				rebound_goal = verdict == GOAL
				rebound_pos = pos
				rebound_speed = vel.length()
				return outcome
			if verdict == GOAL:
				rebound_goal = true
				rebound_pos = pos
				rebound_speed = vel.length()
				return GOAL
		if not touched:
			continue
		# ── Where did the rebound GO? ────────────────────────────────────────
		# Tracked to the moment it LEAVES the danger area, or comes to rest in it,
		# rather than sampled at the first tick a skater could technically reach
		# it. Those are different questions and the second one cannot answer the
		# first: a pad rebound exits at ~6 m/s, which is already under the playable
		# ceiling, so sampling there reported it a metre and a half from the goalie
		# — inside the danger area by construction, whichever way it was heading.
		# Every surface then scored the same regardless of where it aimed.
		rebound_min_dist_to_shooter = minf(
				rebound_min_dist_to_shooter, pos.distance_to(_shooter.global_position))
		var from_goal: float = Vector2(pos.x - goal.x, pos.z - goal.z).length()
		if from_goal > danger_radius_m:
			rebound_pos = pos
			rebound_speed = vel.length()
			return outcome
		rebound_danger_dwell_s += DT
		# At rest in the danger area, and not the goalie's to take: a real second
		# chance, sitting there.
		if pos.y <= _ctrl.clear_max_height and vel.length() <= REBOUND_REST_M_S \
				and (rebound_swept or not _goalie_can_still_play(pos, vel)):
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
	last_caught = false
	last_trapped = false
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
#
# ⚠️ `ticks` SELECTS WHICH GOALIE YOU MEASURE. This resets to the crease first
# (see below) and does NOT settle, so the hold is also his entire recovery from
# the goal line — and that recovery takes ~1.7 s. Measured challenge radius by
# hold length, centred shooter at 5 m:
#
#     0.10 s -> 0.32    0.20 s -> 0.54    0.40 s -> 0.98
#     0.60 s -> 1.38    1.00 s -> 1.68    1.67 s -> 1.75 (settled)
#
# So a 24-tick hold fires at a keeper 31% of the way out to his depth, and two
# tests holding for different lengths are not comparing the same keeper at all.
# Numbers from this path are about a goalie STILL COMING OUT unless the hold is
# long — which is a legitimate thing to measure, but say which one you meant.
#
# SETTLING FIRST IS NOT A FREE FIX, so it is deliberately not done here: against
# a stationary carrier he drops to idle BUTTERFLY at ~1.0 s of hold, and while
# down he stops reading the wind-up entirely (`_is_reading_shot_threat` is
# upright-only) — the shot-read timer resets, the slapper aim shade switches off,
# and he re-centres. Measured with a slapper wind-up declared at a corner from
# 6 m: shade 0.38 m held at 0.75 s, exactly 0.00 by 1.0 s. There is a usable
# window around 0.25-0.75 s and cliffs on both sides of it.
#
# The sibling `hold_windup_at` does NOT reset, and its callers do reset+settle by
# hand. The two are not interchangeable.
func hold_windup(shooter: Vector3, declared_aim: Vector3, loft_level: int,
		power_t: float, ticks: int,
		shot_state: int = SkaterStateMachine.State.WRISTER_AIM) -> void:
	# Clean slate. Without this the goalie carries pose, depth, reaction and
	# butterfly state from the PREVIOUS shot, so consecutive trials are not
	# comparable — the dominant error term when sweeping arms against each other.
	_ctrl.reset_to_crease()
	_shooter.global_position = shooter
	_shooter.velocity = Vector3.ZERO
	_shooter.current_shot_state = shot_state
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
	last_caught = false
	last_trapped = false
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


# Is the puck still the GOALIE's to play — inside the crease sweep's window? The
# same geometry GoalieCreaseClear gates on, so the instrument stops crediting a
# skater with a second chance the keeper is about to take away.
func _goalie_can_still_play(puck_pos: Vector3, puck_vel: Vector3) -> bool:
	if puck_pos.y > _ctrl.clear_max_height:
		return false
	if puck_vel.length() > _ctrl.clear_max_puck_speed:
		return false
	return _goalie.global_position.distance_to(puck_pos) <= _ctrl.clear_reach
