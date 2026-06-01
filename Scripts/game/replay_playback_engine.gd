class_name ReplayPlaybackEngine
extends RefCounted

# Stateless interpolation core shared by GoalReplayDriver (in-memory ring
# buffer of recent broadcasts) and FileReplayDriver (frames decoded from a
# .mreplay file). Given two decoded snapshots and a t ∈ [0, 1], applies the
# interpolated pose to every actor the caller passes in.
#
# The two drivers differ only in where their snapshot pairs come from and
# what extra side effects they own (host-side sim freeze, virtual clock
# control, file load). The interpolation math is identical, so it lives here.

# Skaters: Hermite position (velocity as tangent), Hermite angle for facing
# and upper_body_rotation, linear lerp for blade/hand (local-space, no
# derivative). Puck: Hermite position with velocity zeroed so the frozen
# RigidBody doesn't drift between render frames. Goalies: position / rotation
# / five_hole_openness lerp, state_enum is whichever bracket end is closer
# (apply_replay_state sets those then calls _update_body_parts so pad / body
# animations track the recorded pose rather than re-simulating from AI).
# Authoritative pose fields (body lean, pad / glove / blocker / head transforms)
# are also lerped between snapshots so playback reflects the host's actual
# saves, not the client AI's reconstruction.
static func apply_interpolated_snapshot(
		from_snap: Dictionary,
		to_snap: Dictionary,
		t: float,
		dt: float,
		sim_delta: float,
		records: Dictionary,
		puck: Puck,
		goalie_controllers: Array) -> void:
	# `dt` is the bracket span (for Hermite tangent scaling); `sim_delta` is the
	# virtual-clock time advanced this frame — slow-mo-scaled and 0 on a paused
	# scrub. The skater leg gait integrates it; goalies currently ignore it.
	# `records` is peer_id → PlayerRecord. GoalReplayDriver passes
	# PlayerRegistry.all() (the underlying dict); FileReplayDriver builds its
	# own dict from the .mreplay header so the viewer doesn't need to stand
	# up a full registry / state machine just to feed this engine.
	var from_skaters: Dictionary = from_snap.skaters
	var to_skaters: Dictionary = to_snap.skaters
	for peer_id: int in from_skaters:
		if not to_skaters.has(peer_id):
			continue
		var record: PlayerRecord = records.get(peer_id)
		if record == null or record.controller == null:
			continue
		var fs: SkaterNetworkState = from_skaters[peer_id]
		var ts: SkaterNetworkState = to_skaters[peer_id]
		var interp := SkaterNetworkState.new()
		interp.position = BufferedStateInterpolator.hermite(
				fs.position, fs.velocity, ts.position, ts.velocity, t, dt)
		interp.velocity = fs.velocity.lerp(ts.velocity, t)
		var fa: float = BufferedStateInterpolator.hermite_angle(
				atan2(fs.facing.x, fs.facing.y), fs.facing_angular_velocity,
				atan2(ts.facing.x, ts.facing.y), ts.facing_angular_velocity, t, dt)
		interp.facing = Vector2(sin(fa), cos(fa))
		interp.upper_body_rotation_y = BufferedStateInterpolator.hermite_angle(
				fs.upper_body_rotation_y, fs.upper_body_angular_velocity,
				ts.upper_body_rotation_y, ts.upper_body_angular_velocity, t, dt)
		interp.blade_position = fs.blade_position.lerp(ts.blade_position, t)
		interp.top_hand_position = fs.top_hand_position.lerp(ts.top_hand_position, t)
		interp.is_ghost = ts.is_ghost
		record.controller.apply_replay_state(interp, sim_delta)

	var fp: PuckNetworkState = from_snap.puck
	var tp: PuckNetworkState = to_snap.puck
	if puck != null and fp != null and tp != null:
		puck.set_puck_position(BufferedStateInterpolator.hermite(
				fp.position, fp.velocity, tp.position, tp.velocity, t, dt))
		puck.set_puck_velocity(Vector3.ZERO)

	var from_goalies: Array = from_snap.goalies
	var to_goalies: Array = to_snap.goalies
	for i: int in from_goalies.size():
		if i >= goalie_controllers.size() or i >= to_goalies.size():
			break
		var fg: GoalieNetworkState = from_goalies[i]
		var tg: GoalieNetworkState = to_goalies[i]
		var interp := GoalieNetworkState.new()
		interp.position_x = lerpf(fg.position_x, tg.position_x, t)
		interp.position_z = lerpf(fg.position_z, tg.position_z, t)
		interp.rotation_y = lerp_angle(fg.rotation_y, tg.rotation_y, t)
		interp.five_hole_openness = lerpf(fg.five_hole_openness, tg.five_hole_openness, t)
		interp.state_enum = tg.state_enum if t >= 0.5 else fg.state_enum
		# Authoritative pose interpolation. Offsets are linear; rotations use
		# plain lerp because the pose-space ranges are small (no wrap-around
		# from ±π that would need lerp_angle).
		interp.body_pitch = lerpf(fg.body_pitch, tg.body_pitch, t)
		interp.body_roll = lerpf(fg.body_roll, tg.body_roll, t)
		interp.left_pad_offset = fg.left_pad_offset.lerp(tg.left_pad_offset, t)
		interp.left_pad_pitch = lerpf(fg.left_pad_pitch, tg.left_pad_pitch, t)
		interp.left_pad_roll = lerpf(fg.left_pad_roll, tg.left_pad_roll, t)
		interp.right_pad_offset = fg.right_pad_offset.lerp(tg.right_pad_offset, t)
		interp.right_pad_pitch = lerpf(fg.right_pad_pitch, tg.right_pad_pitch, t)
		interp.right_pad_roll = lerpf(fg.right_pad_roll, tg.right_pad_roll, t)
		interp.glove_offset = fg.glove_offset.lerp(tg.glove_offset, t)
		interp.glove_yaw = lerpf(fg.glove_yaw, tg.glove_yaw, t)
		interp.glove_pitch = lerpf(fg.glove_pitch, tg.glove_pitch, t)
		interp.blocker_offset = fg.blocker_offset.lerp(tg.blocker_offset, t)
		interp.blocker_yaw = lerpf(fg.blocker_yaw, tg.blocker_yaw, t)
		interp.blocker_pitch = lerpf(fg.blocker_pitch, tg.blocker_pitch, t)
		interp.head_yaw = lerpf(fg.head_yaw, tg.head_yaw, t)
		goalie_controllers[i].apply_replay_state(interp, sim_delta)
