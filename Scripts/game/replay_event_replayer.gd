class_name ReplayEventReplayer
extends RefCounted

# Dispatches a recorded transient event (audio + body-check VFX) at replay
# time. Shared by GoalReplayDriver (in-memory recorder) and FileReplayDriver
# (.mreplay file events) so both replay paths fire the same sound/VFX with
# consistent payload handling.
#
# Events have shape:
#   { "kind": String, "pos": [x, y, z], "speed": float, ...kind-specific... }
# Position is stored as a 3-tuple Array so the file (JSON) and in-memory
# (Dictionary) producers can share one schema.
#
# Sound volume is recomputed from the recorded `speed` rather than reading
# puck.linear_velocity, which is zero during replay (apply_interpolated_snapshot
# writes velocity=ZERO to the frozen RigidBody).
#
# Pass `registry` for body_check events so the dispatcher can find the
# checker and victim skaters and drive SkaterVFX.fire_body_check_burst
# directly. We deliberately do NOT re-emit body_checked_player: that signal
# is wired to GameManager closures (sound, hit-landed stats, replay-event
# recording) that should not run during playback — the third would recurse.
# File-viewer callers pass a peer_id → PlayerRecord Dictionary via
# dispatch_with_records when no PlayerRegistry is available.


# Volume curve mirrors GameManager._puck_speed_volume so the host's live
# sound matches the replay's sound exactly. test_replay_audio_mirrors fails
# when the two drift.
const _PUCK_SPEED_VOL_MIN_DB: float = -10.0
const _PUCK_SPEED_VOL_MAX_DB: float = 0.0
const _PUCK_SPEED_MIN: float = 1.0
const _PUCK_SPEED_RANGE: float = 20.0

# Save-cue base bumps and post pitch, mirrored from GameManager so replayed
# saves sound like the live ones (test_replay_audio_mirrors holds them equal).
const _POST_SAVE_VOLUME_BUMP_DB: float = 4.0
const _PAD_SAVE_VOLUME_BUMP_DB: float = 2.0


static func dispatch(event: Dictionary, registry: PlayerRegistry) -> void:
	dispatch_with_records(event, _registry_to_records(registry))


# `records`: peer_id → PlayerRecord. Both GoalReplayDriver (via registry.all())
# and FileReplayDriver (via its own peer_id → PlayerRecord map) can feed this.
static func dispatch_with_records(event: Dictionary, records: Dictionary) -> void:
	var kind: String = event.get("kind", "")
	var pos: Vector3 = _pos_from_array(event.get("pos", []))
	var speed: float = float(event.get("speed", 0.0))
	var volume_db: float = _puck_speed_volume(speed)

	match kind:
		"puck_boards":
			SoundManager.play_world(SoundManager.Sound.PUCK_BOARDS, pos, volume_db, 0.05)
		"puck_goal_body":
			SoundManager.play_world(SoundManager.Sound.PUCK_GOAL_BODY, pos, volume_db, 0.06)
		"puck_deflection":
			SoundManager.play_world(SoundManager.Sound.PUCK_DEFLECTION, pos, volume_db, 0.06, 1.2)
		"puck_body_block":
			SoundManager.play_world(SoundManager.Sound.PUCK_BODY_BLOCK, pos, volume_db, 0.07)
		"puck_strip":
			SoundManager.play_world(SoundManager.Sound.PUCK_STRIP, pos, volume_db, 0.06)
		"stick_lift":
			SoundManager.play_world(SoundManager.Sound.STICK_LIFT, pos, volume_db, 0.06)
		"nudge":
			# Own event kind so the cue can diverge later; quick-shot (wrister)
			# sound at a soft fixed volume matches live play (a nudge is a quiet tap).
			SoundManager.play_world(SoundManager.Sound.SHOT_WRISTER, pos, -6.0, 0.04)
		"puck_goalie":
			SoundManager.play_world(SoundManager.Sound.PUCK_GOALIE, pos, volume_db + _PAD_SAVE_VOLUME_BUMP_DB, 0.05)
		"puck_post":
			SoundManager.play_world(SoundManager.Sound.PUCK_POST, pos, volume_db + _POST_SAVE_VOLUME_BUMP_DB, 0.04, _post_pitch(speed))
		"puck_pickup":
			SoundManager.play_world(SoundManager.Sound.PUCK_PICKUP, pos, 0.0, 0.05)
		"shot":
			var is_slapper: bool = bool(event.get("is_slapper", false))
			var sound: SoundManager.Sound = SoundManager.Sound.SHOT_SLAPPER if is_slapper else SoundManager.Sound.SHOT_WRISTER
			SoundManager.play_world(sound, pos, 0.0, 0.04)
		"body_check":
			# "speed" carries the recorded impact_force; scale sound + burst by it
			# the same way live play does (SkaterVFX.check_*). The thud is gated to
			# stagger-class-or-harder hits (bumps/rubs stay silent), matching live play.
			var check_force: float = float(event.get("speed", 0.0))
			if SkaterVFX.check_sound_audible(check_force):
				SoundManager.play_world(SoundManager.Sound.BODY_CHECK, pos,
						SkaterVFX.check_sound_volume_db(check_force), 0.08,
						SkaterVFX.check_sound_pitch_scale(check_force))
			# Drive the burst directly (not via body_checked_player) so we don't
			# re-trigger GameManager's hit-landed / replay-record closures — the
			# latter would recursively record a new event.
			var checker_peer_id: int = int(event.get("checker_peer_id", -1))
			var victim_peer_id: int = int(event.get("victim_peer_id", -1))
			var checker_rec: PlayerRecord = records.get(checker_peer_id)
			var victim_rec: PlayerRecord = records.get(victim_peer_id)
			if checker_rec != null and checker_rec.skater != null \
					and victim_rec != null and victim_rec.skater != null:
				var hit_dir: Vector3 = _pos_from_array(event.get("hit_dir", []))
				var vfx: SkaterVFX = checker_rec.skater.get_node_or_null("VFX") as SkaterVFX
				if vfx != null:
					vfx.fire_body_check_burst(victim_rec.skater, check_force, hit_dir)
				# The hitter's check-delivery body pose, driven directly for the
				# same reason as the burst — the replayed actor's gait runs via
				# apply_replay_state, so the drive plays out in playback too.
				if checker_rec.controller != null:
					checker_rec.controller.start_check_drive(
							hit_dir, SkaterVFX.check_intensity(check_force))
		"goal":
			# Goal horn fires only via the file-replay path. The in-game goal
			# cinematic relies on the live goal_scored closure that already
			# played the horn before the replay started — we deliberately
			# don't record "goal" into the in-memory ring buffer, so this
			# case never fires from GoalReplayDriver. File replay does have
			# goal entries in the .mreplay event stream (GameManager.
			# _on_goal_for_replay_event), so they wake the horn here.
			SoundManager.play_crowd(SoundManager.Sound.GOAL_HORN, -6.0)
		_:
			pass  # unknown kind — silently skip so future schema additions don't crash old viewers


static func _registry_to_records(registry: PlayerRegistry) -> Dictionary:
	if registry == null:
		return {}
	return registry.all()


static func _pos_from_array(arr: Variant) -> Vector3:
	if arr is Array and (arr as Array).size() >= 3:
		var a := arr as Array
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


static func _puck_speed_volume(speed: float) -> float:
	var t: float = clampf((speed - _PUCK_SPEED_MIN) / _PUCK_SPEED_RANGE, 0.0, 1.0)
	return lerpf(_PUCK_SPEED_VOL_MIN_DB, _PUCK_SPEED_VOL_MAX_DB, t)


# Mirrors GameManager._post_pitch so a replayed post rings like the live one.
static func _post_pitch(speed: float) -> float:
	return lerpf(0.9, 1.12, clampf((speed - 5.0) / 25.0, 0.0, 1.0))
