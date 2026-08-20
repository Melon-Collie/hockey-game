extends GutTest

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const DT: float = 1.0 / 120.0
const PART := ["STICK", "PAD", "BLOCK", "CHEST", "GLOVE", "MASK"]

var _goalie: Node
var _puck: Node
var _shooter: Skater
var _ctrl: GoalieController
var _h: RefCounted


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_h = Harness.new()
	_h.setup(_goalie, _puck, _ctrl, _shooter)


func test_report_chest_cases_through_the_real_call() -> void:
	var max_aim: float = GameRules.NET_HALF_WIDTH \
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	var spots: Array[Vector3] = [
		Vector3(0.0, 0.0, 3.0), Vector3(0.0, 0.0, 6.4), Vector3(0.0, 0.0, 10.0),
		Vector3(5.5, 0.0, 8.0), Vector3(8.5, 0.0, 4.0)]
	var n: int = 0
	for spot: Vector3 in spots:
		for loft: int in [1, 2, 3]:
			for frac: float in [-0.5, 0.0, 0.5]:
				for mph: float in [65.0, 85.0]:
					if n >= 12:
						return
					var from := Vector3(spot.x, 0.0, GOAL_Z + spot.z)
					_ctrl.reset_to_crease()
					_h.settle(from, 90)
					var o: int = _h.fire_tracking_rebound(from,
							Vector3(frac * max_aim, 0.0, GOAL_Z), loft,
							mph * 0.44704, 0.0)
					if o != Harness.SAVE or _h.last_part != GoalieSaveRules.SavePart.CHEST:
						continue
					n += 1
					gut.p("  %.0fm loft%d aim%.1f %.0fmph -> swept=%s held=%s v=%.2f dist=%.2f"
							% [spot.z, loft, frac, mph, _h.rebound_swept,
							_h.rebound_held, _h.rebound_speed,
							_goalie.global_position.distance_to(_h.rebound_pos)])
	assert_true(true, "report")


func test_report_after_the_smother() -> void:
	var from := Vector3(0.0, 0.0, GOAL_Z + 6.4)
	_ctrl.reset_to_crease()
	_h.settle(from, 90)
	var vel: Vector3 = _h.shot_velocity_at(
			from, Vector3(0.0, 0.0, GOAL_Z), 3, 33.0, 0.0)
	_puck.clear_carrier()
	var pos: Vector3 = from
	pos.y = _puck.ice_height
	var scratch := SweptDiscOBB.Result.new()
	var contact := GoalieContactDetector.Contact.new()
	var frame := PuckGeometryCollision.Result.new()
	var tick := PuckAuthorityRules.TickResult.new()
	var res := GoalieSaveRules.ContactResult.new()
	var since: float = 0.0
	var touched: bool = false
	for step: int in 400:
		var prev: Vector3 = pos
		_puck.global_position = pos
		_puck.linear_velocity = vel
		_ctrl._physics_process(DT)
		if _puck.motion_pinned:
			gut.p("  t=%.2f PINNED state=%d" % [since, _ctrl._sm.current])
			break
		if _puck.linear_velocity.distance_to(vel) > 0.01:
			gut.p("  t=%.2f SWEPT to %.2f" % [since, _puck.linear_velocity.length()])
			break
		vel = _puck.linear_velocity
		tick.touched_post = false
		tick.touched_net = false
		PuckAuthorityRules.step_frame_substep(pos, vel, DT,
				GameRules.PUCK_COLLISION_RADIUS, _puck.max_speed, _puck.ice_height,
				_puck.max_height, frame, tick)
		pos = tick.position
		vel = tick.velocity
		if GoalieContactDetector.nearest([_goalie], prev, pos,
				GameRules.PUCK_COLLISION_RADIUS, scratch, contact):
			var part: int = _h._classify_part(contact.part as Node3D)
			var g3: Node3D = contact.goalie as Node3D
			GoalieSaveRules.resolve_contact(vel, part, contact.normal, res,
					-g3.global_transform.basis.z)
			vel = res.velocity
			if res.trapped:
				pos = Vector3(contact.point.x, _puck.ice_height, contact.point.z)
			else:
				pos = contact.point + contact.normal * contact.depth
			if not touched:
				touched = true
				since = 0.0
				gut.p("  SMOTHER %s -> %.2f m/s, placed at dist %.2f"
						% [PART[part], vel.length(),
						_goalie.global_position.distance_to(pos)])
		if not touched:
			continue
		since += DT
		if step % 15 == 0:
			gut.p("    t=%.2f v=%.2f dist=%.2f state=%d dwell=%.2f cool=%.2f windup=%.2f"
					% [since, vel.length(),
					_goalie.global_position.distance_to(pos), _ctrl._sm.current,
					_ctrl._clear.dwell_timer, _ctrl._clear.clear_cooldown_timer,
					_ctrl._clear.windup_timer])
		if since > 2.4:
			break
	assert_true(true, "report")
