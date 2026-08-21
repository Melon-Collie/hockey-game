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
#   the PADS steer wide — +/-55 standing, +/-72 in butterfly, which is the
#   toe-out doing its job;
#   the BLADE now steers with them, +89 standing and +100 in butterfly, off
#   GoalieStickRules.BLADE_CURVE_FACE_DEG. Before that angle existed the butterfly
#   blade sat at +2.4 — square to the shooter, which is a mirror;
#   the BLOCKER still has no lateral cant, so standing it fires the puck 87
#   degrees UP and dead straight back up the slot, and in butterfly its normal has
#   swung past lateral to -120.
#
# THE STICK'S CANT CANNOT BE A LOCAL ROLL, which is worth recording because it is
# the obvious fix and it does not work. Rolling the stick about its own Y turns
# the face laterally only while the shaft is upright; in butterfly the assembly is
# pitched flat, so that same rotation is a roll about a near-horizontal axis and
# tilts the face up and down instead. What steers in every stance is the BLADE's
# own face rotation, in plan — the flat-box stand-in for a blade CURVE, which
# unlike the assembly yaw does not move the blade an inch while it steers.
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
		_pose(stance)
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
				var best: Vector3 = _up_ice_face(cs)
				# Bearing of the rebound for a puck arriving straight down -Z.
				var inc := Vector3(0.0, 0.0, -25.0)
				var out: Vector3 = PuckCollisionRules.deflect_velocity_3d(
						inc, best, 0.35, 0.15, 0.8, 30.0)
				gut.p("   %-22s n=(%5.2f,%5.2f,%5.2f) -> bearing %+6.1f deg, %+5.1f up"
						% [cs.name, best.x, best.y, best.z,
						rad_to_deg(atan2(out.x, out.z)), rad_to_deg(asin(
							clampf(out.normalized().y, -1.0, 1.0)))])
	assert_true(true, "report")


# ── WHERE THE BLADE SITS ───────────────────────────────────────────────────
# The companion to the normals above, and the half real doctrine can be held
# against. Coaching puts the blade roughly a foot (0.30 m) ahead of the skates,
# flat on the ice, tilted so it ramps a shot UP into the body — and names our
# exact symptom as the sign it is too close: if pucks hit the stick and stop, or
# bounce off it into the pads, the stick belongs further in front of the pads.
#
# So report the three quantities that claim is about: how far up-ice of the pad
# faces the stick reaches, how high off the ice its low edge is, and how far the
# up-ice face is tilted back (leaning back ramps the puck up; leaning forward
# wedges it down and into him).
func test_report_where_the_blade_sits() -> void:
	for stance: String in ["READY", "BUTTERFLY"]:
		_pose(stance)
		var pad_z: float = -INF
		for pad_name: String in ["LeftPad", "RightPad"]:
			var pad := _goalie.get_node_or_null(pad_name) as Node3D
			if pad == null:
				continue
			for ch in pad.get_children():
				var cs := ch as CollisionShape3D
				if cs == null or (cs.shape as BoxShape3D) == null:
					continue
				pad_z = maxf(pad_z, _up_ice_extent(cs, (cs.shape as BoxShape3D).size))
		var arm := _goalie.get_node_or_null("BlockArm") as Node3D
		gut.p("--- %s  goalie root y=%+.3f  wrist y=%+.3f  pad face z=%+.3f"
				% [stance, _goalie.global_position.y, arm.global_position.y, pad_z])
		# Does the blade cover the FIVE-HOLE? An overhead render reads like it
		# sits outboard of a pad, and a 512 px software tile cannot resolve 15 cm
		# of lateral placement, so the gap and the blade's span across it are
		# reported as numbers instead.
		var gap_lo: float = -INF
		var gap_hi: float = INF
		for pad_name: String in ["LeftPad", "RightPad"]:
			var pad := _goalie.get_node_or_null(pad_name) as Node3D
			for ch in pad.get_children():
				var cs2 := ch as CollisionShape3D
				if cs2 == null or (cs2.shape as BoxShape3D) == null:
					continue
				var e: float = _lateral_extent(cs2, (cs2.shape as BoxShape3D).size)
				var cx: float = cs2.global_transform.origin.x
				if cx < 0.0:
					gap_lo = maxf(gap_lo, cx + e)
				else:
					gap_hi = minf(gap_hi, cx - e)
		var blade := _goalie.get_node("BlockArm/Stick/StickBladeCollider") as CollisionShape3D
		var bx: float = blade.global_transform.origin.x
		var be: float = _lateral_extent(blade, (blade.shape as BoxShape3D).size)
		gut.p("     five-hole gap x %+.3f .. %+.3f | blade spans %+.3f .. %+.3f"
				% [gap_lo, gap_hi, bx - be, bx + be])
		var stick := _goalie.get_node_or_null("BlockArm/Stick") as Node3D
		if stick == null:
			continue
		for ch in stick.get_children():
			var cs := ch as CollisionShape3D
			if cs == null:
				continue
			var box := cs.shape as BoxShape3D
			if box == null:
				continue
			var c: Vector3 = cs.global_transform.origin
			var axis: int = _up_ice_axis(cs)
			var lr: Vector3 = cs.rotation_degrees
			gut.p("     local rot=(%+.1f,%+.1f,%+.1f) local pos=(%+.2f,%+.2f,%+.2f)"
					% [lr.x, lr.y, lr.z, cs.position.x, cs.position.y, cs.position.z])
			var face: Vector3 = _up_ice_face(cs)
			gut.p("   %-18s box=%.2fx%.2fx%.2f reaches %+.3f m past the pads, "
					% [cs.name, box.size.x, box.size.y, box.size.z,
					_up_ice_extent(cs, box.size) - pad_z]
					+ "low edge %+.3f m, presents %s face (%.3f m2) at %+.1f deg back"
					% [c.y - _half_span_y(cs, box.size), "XYZ"[axis],
					_face_area(box.size, axis),
					rad_to_deg(asin(clampf(face.y, -1.0, 1.0)))])
	assert_true(true, "report")



# The seating solve's whole purpose, asserted rather than merely reported. Every
# stance whose hand is low enough for the lever to reach must put the blade's low
# edge ON the ice — not floating, and not through it. Both failures have happened
# and neither announced itself: a 12 cm float when the tilt was authored, and a
# 5.7 cm burial when the span ignored the assembly roll.
#
# The tolerance is a puck's half-thickness. Tighter would be pinning float noise;
# looser would admit a gap a puck can cross.
func test_the_blade_is_seated_on_the_ice() -> void:
	for stance: String in ["READY", "BUTTERFLY"]:
		_pose(stance)
		var cs := _goalie.get_node("BlockArm/Stick/StickBladeCollider") as CollisionShape3D
		var box := cs.shape as BoxShape3D
		var low: float = cs.global_transform.origin.y - _half_span_y(cs, box.size)
		assert_almost_eq(low, 0.0, 0.013,
				"%s seats the blade's low edge at %+.4f m, not on the ice" % [stance, low])

func _pose(stance: String) -> void:
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


# The face a shooter out at +Z (up-ice of this goal) meets: whichever local
# axis's world direction points most up-ice.
func _up_ice_face(cs: CollisionShape3D) -> Vector3:
	var b: Basis = cs.global_transform.basis
	var a: int = _up_ice_axis(cs)
	var n: Vector3 = b[a].normalized()
	return n if n.z >= 0.0 else -n


func _up_ice_axis(cs: CollisionShape3D) -> int:
	var b: Basis = cs.global_transform.basis
	var best: int = 0
	var best_d: float = -INF
	for a: int in 3:
		var d: float = absf(b[a].normalized().z)
		if d > best_d:
			best_d = d
			best = a
	return best


# The area of the face whose normal is `axis` — the two OTHER extents. A box
# presents very different targets on its broad face and on its edge, and the
# direction pick alone cannot tell them apart.
func _face_area(size: Vector3, axis: int) -> float:
	if axis == 0:
		return size.y * size.z
	if axis == 1:
		return size.x * size.z
	return size.x * size.y


# World z of the box's up-ice-most corner: the OBB's support point along +Z.
func _up_ice_extent(cs: CollisionShape3D, size: Vector3) -> float:
	var b: Basis = cs.global_transform.basis
	var h: Vector3 = size * 0.5
	return cs.global_transform.origin.z + absf(b.x.z) * h.x \
			+ absf(b.y.z) * h.y + absf(b.z.z) * h.z


# Half the box's LATERAL span, the x-axis twin of _half_span_y.
func _lateral_extent(cs: CollisionShape3D, size: Vector3) -> float:
	var b: Basis = cs.global_transform.basis
	var h: Vector3 = size * 0.5
	return absf(b.x.x) * h.x + absf(b.y.x) * h.y + absf(b.z.x) * h.z


func _half_span_y(cs: CollisionShape3D, size: Vector3) -> float:
	var b: Basis = cs.global_transform.basis
	var h: Vector3 = size * 0.5
	return absf(b.x.y) * h.x + absf(b.y.y) * h.y + absf(b.z.y) * h.z
