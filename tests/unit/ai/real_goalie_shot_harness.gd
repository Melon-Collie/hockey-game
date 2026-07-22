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


# Fire one shot from `shooter` toward the net-plane `aim` at `loft_level` /
# `power_t` with `err_rad` of aim scatter, and march it against the live goalie.
# Returns the outcome enum. The goalie keeps reacting to the real puck motion
# throughout the flight (release read → drop/push/glove deploy).
func fire(shooter: Vector3, aim: Vector3, loft_level: int, power_t: float,
		err_rad: float) -> int:
	var goal := Vector3(0.0, 0.0, _goal_z)
	# Launch: horizontal heading toward the aim (+ scatter), pace split into the
	# horizontal component and the loft's fixed vertical launch (same model as
	# ShotMechanics / shot_sim_harness so the two instruments are comparable).
	var to_aim := Vector2(aim.x - shooter.x, aim.z - shooter.z)
	if to_aim.length() < 0.001:
		return WIDE
	var ang: float = to_aim.angle() + err_rad
	var hdir := Vector2(cos(ang), sin(ang))
	var speed: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S \
			+ clampf(power_t, 0.0, 1.0) * (GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
					- GameRules.DEFAULT_WRISTER_POWER_MIN_M_S)
	var loft_vy: float = ShotMechanics._loft_vy(loft_level,
			GameRules.DEFAULT_LOFT_VY_LOW_M_S, GameRules.DEFAULT_LOFT_VY_HIGH_M_S)
	var v_h: float = sqrt(maxf(speed * speed - loft_vy * loft_vy, 1.0))
	var vel := Vector3(hdir.x * v_h, loft_vy, hdir.y * v_h)

	_shooter.global_position = shooter
	# Release: the puck leaves the blade and flies as a shot.
	_puck.clear_carrier()
	last_part = -1
	last_contact_pos = Vector3.INF
	last_cross = Vector3.INF
	last_goalie_pos = Vector3.INF
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
