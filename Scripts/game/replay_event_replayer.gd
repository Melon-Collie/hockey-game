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
# sound matches the replay's sound exactly. Kept in sync if the live formula
# changes.
const _PUCK_SPEED_VOL_MIN_DB: float = -10.0
const _PUCK_SPEED_VOL_MAX_DB: float = 0.0
const _PUCK_SPEED_MIN: float = 1.0
const _PUCK_SPEED_RANGE: float = 20.0


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
			SoundManager.play_world(SoundManager.Sound.PUCK_DEFLECTION, pos, volume_db, 0.06)
		"puck_body_block":
			SoundManager.play_world(SoundManager.Sound.PUCK_BODY_BLOCK, pos, volume_db, 0.07)
		"puck_strip":
			SoundManager.play_world(SoundManager.Sound.PUCK_STRIP, pos, volume_db, 0.06)
		"puck_goalie":
			SoundManager.play_world(SoundManager.Sound.PUCK_GOALIE, pos, volume_db, 0.05)
		"puck_post":
			SoundManager.play_world(SoundManager.Sound.PUCK_POST, pos, volume_db, 0.04)
		"puck_pickup":
			SoundManager.play_world(SoundManager.Sound.PUCK_PICKUP, pos, 0.0, 0.05)
		"shot":
			var is_slapper: bool = bool(event.get("is_slapper", false))
			var sound: SoundManager.Sound = SoundManager.Sound.SHOT_SLAPPER if is_slapper else SoundManager.Sound.SHOT_WRISTER
			SoundManager.play_world(sound, pos, 0.0, 0.04)
		"body_check":
			SoundManager.play_world(SoundManager.Sound.BODY_CHECK, pos, 0.0, 0.08)
			# Drive the burst directly (not via body_checked_player) so we don't
			# re-trigger GameManager's hit-landed / sound / replay-record
			# closures — the third one would recursively record a new event.
			var checker_peer_id: int = int(event.get("checker_peer_id", -1))
			var victim_peer_id: int = int(event.get("victim_peer_id", -1))
			var checker_rec: PlayerRecord = records.get(checker_peer_id)
			var victim_rec: PlayerRecord = records.get(victim_peer_id)
			if checker_rec != null and checker_rec.skater != null \
					and victim_rec != null and victim_rec.skater != null:
				var vfx: SkaterVFX = checker_rec.skater.get_node_or_null("VFX") as SkaterVFX
				if vfx != null:
					var hit_dir: Vector3 = _pos_from_array(event.get("hit_dir", []))
					vfx.fire_body_check_burst(
							victim_rec.skater, float(event.get("speed", 0.0)), hit_dir)
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
