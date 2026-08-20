extends GutTest

# ── WHERE DOES EACH SAVE SURFACE AIM? ────────────────────────────────────────
# The rebound model resolves a contact through the struck face's real normal, so
# WHERE a rebound goes is decided by the POSE, not by any constant. This reads
# the live posed colliders and reports, per stance, the world-space normal of the
# face a shooter up-ice actually meets — and the bearing a square 25 m/s shot
# comes off it at.
#
# Bearings are about the goal's own axis: 0 = straight back at the shooter,
# +/-90 = pure lateral (the corners), beyond +/-90 = back toward his own end.
#
# WHAT IT SHOWS TODAY:
#   the PADS already steer wide — +/-55 standing, +/-72 in butterfly, which is
#   the toe-out doing its job;
#   the BLOCKER has no lateral cant at all, so standing it fires the puck 82
#   degrees UP and dead straight back up the slot, and in butterfly its normal has
#   swung past lateral to -109, i.e. angled back toward his own end;
#   the STICK's shaft and paddle sit at +4.6 degrees of lateral in butterfly,
#   which is straight back at the shooter — and they are the tall surfaces, 0.66 m
#   of paddle against 0.07 m of blade, so they take nearly every stick save.
#
# THE STICK'S CANT CANNOT BE A LOCAL ROLL, which is worth recording because it is
# the obvious fix and it does not work. Rolling the stick about its own Y turns
# the face laterally only while the shaft is upright; in butterfly the assembly is
# pitched flat, so that same rotation is a roll about a near-horizontal axis and
# tilts the face up and down instead. Measured at 18 degrees: READY moved from
# +0 to +113 (itself an overshoot, past lateral), butterfly did not move at all,
# and the stick's back-at-the-shooter rate was unchanged at 53% with the pads
# slightly worse. The lever that steers in every stance is the ASSEMBLY YAW,
# about the goalie's own up axis — where active_blade_max_yaw_deg already lives.
#
# TWO CAVEATS on reading it. The face is picked by DIRECTION alone (whichever
# local axis points most up-ice), not weighted by face AREA, so for a part whose
# largest face is not the one facing the shooter it reports the face he presents
# rather than the one he is most likely to be hit on. And it reports EVERY
# collider on a part: an earlier version took only the first, which described the
# stick's SHAFT while the blade — the piece with the lie on it — went unreported.
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const DT: float = 1.0 / 120.0

var _goalie: Node
var _puck: Node
var _shooter: Skater
var _ctrl: GoalieController


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_shooter.set_physics_process(false)
	_ctrl.set_skater_getter(func() -> Array: return [_shooter])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


func test_report_where_each_surface_aims() -> void:
	for stance: String in ["READY", "BUTTERFLY"]:
		_ctrl.reset_to_crease()
		var spot := Vector3(0.0, 0.0, GOAL_Z + 6.0)
		_shooter.global_position = spot
		_shooter.velocity = Vector3.ZERO
		_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
		_puck.set_carrier(_shooter)
		for _i: int in 220:
			_puck.global_position = spot
			_puck.linear_velocity = Vector3.ZERO
			if stance == "BUTTERFLY":
				_ctrl._sm.transition_to(GoalieStateMachine.State.BUTTERFLY)
			_ctrl._physics_process(DT)
		gut.p("--- %s (goalie at %.2f, %.2f, state %d)" % [
			stance, _goalie.global_position.x, _goalie.global_position.z,
			_ctrl._sm.current])
		for path: String in ["LeftPad", "RightPad", "Body", "BlockArm/Blocker",
				"Glove", "BlockArm/Stick"]:
			var body := _goalie.get_node_or_null(path) as Node3D
			if body == null:
				continue
			# EVERY collider on the part, not the first. The stick carries three —
			# shaft, paddle, blade — and reporting only the first described the
			# shaft while the blade is the surface a low shot actually meets.
			for ch in body.get_children():
				var cs := ch as CollisionShape3D
				if cs == null:
					continue
				var box := cs.shape as BoxShape3D
				if box == null:
					continue
			# The face a shooter out at +Z (up-ice of this goal) meets: whichever
			# local axis's world direction points most up-ice.
				var b: Basis = cs.global_transform.basis
				var up_ice := Vector3(0.0, 0.0, 1.0)
				var best := Vector3.ZERO
				var best_d: float = -INF
				for axis: int in 3:
					for sign: float in [1.0, -1.0]:
						var n: Vector3 = (b[axis] * sign).normalized()
						if n.dot(up_ice) > best_d:
							best_d = n.dot(up_ice)
							best = n
				# Bearing of the rebound for a puck arriving straight down -Z.
				var inc := Vector3(0.0, 0.0, -25.0)
				var out: Vector3 = PuckCollisionRules.deflect_velocity_3d(
						inc, best, 0.35, 0.15, 0.8, 30.0)
				gut.p("   %-22s n=(%5.2f,%5.2f,%5.2f) -> bearing %+6.1f deg, %+5.1f up"
						% [cs.name, best.x, best.y, best.z,
						rad_to_deg(atan2(out.x, out.z)), rad_to_deg(asin(
							clampf(out.normalized().y, -1.0, 1.0)))])
	assert_true(true, "report")
