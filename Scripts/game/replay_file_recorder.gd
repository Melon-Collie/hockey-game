class_name ReplayFileRecorder
extends RefCounted

# Streams a match to user://replays/<game_id>.mreplay: opening the file, the
# frame throttle, and the event stream. Lives on every peer (host + client +
# spectator) for any session with a non-empty game id and
# PlayerPrefs.replay_recording_enabled.
#
# A whole subsystem rather than a slice of the orchestrator: nothing here
# adjudicates anything, and nothing reads it back. It is one-way I/O, which is
# why it can be lifted out of GameManager without touching the claim routing
# next to it. GameManager keeps the file's CONTENT — the header and footer are
# built from the roster, the state machine and the shot log it owns — and hands
# them over; this owns the writer's lifecycle and the recording policy.
#
# Everything below is deliberately null-safe on a closed recorder: a session
# with recording off never opens one and every call is expected to no-op.

# The recording exists to be played back at a sane size, so ordinary frames are
# throttled to Constants.REPLAY_FILE_RATE. Two things bypass that: the first
# frame of a new phase (a keyframe — the faceoff snap, the resume after a
# movement-locked gap) and the goal moment, which comes through force_frame.
var _writer: ReplayFileWriter = null
var _last_frame_ts: float = -INF
# Phase of the most recent frame written, so a movement-locked phase records its
# transition frame and skips the duplicate static frames after it. -1 = nothing
# recorded yet this game.
var _last_phase: int = -1

# Game IDs are UUIDs minted by PlayerPrefs.generate_uuid (hex + dashes). This
# guard runs on the path concatenation surface so a malicious host can't ship
# `../etc/passwd` via notify_game_reset and have a client write outside the
# replays folder. Belt-and-braces: the only legitimate source is already
# UUIDs, but the wire format permits arbitrary strings.
const _MAX_GAME_ID_LEN: int = 64


static func is_valid_game_id(s: String) -> bool:
	if s.is_empty() or s.length() > _MAX_GAME_ID_LEN:
		return false
	for i: int in s.length():
		var c: String = s.substr(i, 1)
		if not (c >= "a" and c <= "z") \
				and not (c >= "A" and c <= "Z") \
				and not (c >= "0" and c <= "9") \
				and c != "-" and c != "_":
			return false
	return true


# One player as the .mreplay carries them — shared by the file header's
# initial roster and the mid-game `player_joined` event so the two descriptions
# of a skater can't drift apart (the viewer spawns from either through the same
# path). Callers add the field their own record needs on top ("is_local" /
# "kind").
static func roster_entry(record: PlayerRecord) -> Dictionary:
	return {
		"peer_id": record.peer_id,
		"player_name": record.player_name,
		"jersey_number": record.jersey_number,
		"team_id": record.team.team_id if record.team != null else 0,
		"team_slot": record.team_slot,
		"is_left_handed": record.is_left_handed,
		# Build (height / weight / gear) so the viewer can re-apply the
		# player's attributes — otherwise replay skaters render at the
		# neutral frame and their re-derived lean/reach no longer matches
		# the host's lean-compensated blade positions (stick off the ice).
		"build": record.attributes.to_dict() if record.attributes != null else {},
		# Cosmetics, packed exactly as the join / spawn wire carries them, so
		# the viewer dresses each skater in the look they actually played in
		# rather than the stock kit.
		"tape_code": record.tape_code,
		"skin_tone": record.skin_tone,
		"gear_style_code": record.gear_style_code,
	}


# ── Lifecycle ────────────────────────────────────────────────────────────────

# Opened once per game, after the registry has been populated from lobby
# assignments / sync_existing_players. Idempotent — safe to call repeatedly from
# both the host and client setup paths; the second call short-circuits.
func open(game_id: String, header: Dictionary) -> void:
	if _writer != null:
		return
	if game_id.is_empty():
		return  # free play / tutorial / drill
	if not PlayerPrefs.replay_recording_enabled:
		return
	# Purge oldest first so the new file is never the one we delete next game.
	# keep_count - 1 because we're about to add a new file.
	ReplayFileIndex.purge_oldest(ReplayFileIndex.REPLAY_DIR,
			maxi(PlayerPrefs.replay_keep_count - 1, 0))
	var path: String = ReplayFileIndex.REPLAY_DIR.path_join(
			game_id + ReplayFileIndex.REPLAY_EXT)
	var writer := ReplayFileWriter.new()
	if not writer.open(path, header):
		return
	_writer = writer
	_last_frame_ts = -INF


# The caller must flush anything it has queued for the event stream FIRST —
# queued-but-undrained events (final horn, OS window close) have to reach the
# writer before its worker drains for the last time.
func close(footer: Dictionary) -> void:
	if _writer == null:
		return
	_writer.close_async(footer)
	_writer = null


func is_open() -> bool:
	return _writer != null


# Forget the last recorded phase, so the next frame counts as a transition. Part
# of a rematch rollover and of scene exit, where the file the phase belonged to
# is gone.
func reset_phase() -> void:
	_last_phase = -1


# ── Recording ────────────────────────────────────────────────────────────────

# Whether the live phase should be recorded at all. `phase` is
# GameStateMachine.current_phase, or -1 when there is no state machine (the
# recording predates one, so record everything).
func should_record(phase: int) -> bool:
	return not NetworkManager.is_replay_mode() and phase_admits(phase, _last_phase)


# The phase half of that, as a pure predicate over the two phases so the rule
# can be exercised without a writer, a match, or a file on disk.
static func phase_admits(phase: int, last_phase: int) -> bool:
	if phase < 0:
		return true
	# FACEOFF_PREP is movement-locked for INPUT, but the skaters actively skate in
	# to the dot over the "2 → 1 → DROP" countdown (PhaseCoordinator.begin_approach).
	# Record it at the normal throttled rate so the replay plays the walk-up —
	# capturing only the first (pre-approach) frame made the viewer teleport
	# straight from there to the drop. The crossing bracket into FACEOFF_PREP is
	# still a clean cut in FileReplayDriver (_is_faceoff_reset_bracket), so the
	# puck's reset-to-dot doesn't smear; the intra-prep brackets interpolate.
	if phase == GamePhase.Phase.FACEOFF_PREP:
		return true
	if PhaseRules.is_movement_locked(phase):
		# Capture only the first frame of each movement-locked phase. Goal:
		# the puck-in-net moment on GOAL_SCORED entry — without this, the
		# last recorded frame before the gap is the previous PLAYING tick,
		# which usually shows the puck still approaching the net rather
		# than inside it. Subsequent ticks at 5 Hz are duplicate static
		# state and add nothing.
		return phase != last_phase
	return true


# The throttle half, also pure: a phase transition is a keyframe and bypasses
# it, everything else waits out REPLAY_FILE_RATE.
static func admits_frame(host_ts: float, last_frame_ts: float, phase: int,
		last_phase: int) -> bool:
	if phase >= 0 and phase != last_phase:
		return true
	return host_ts - last_frame_ts >= 1.0 / float(Constants.REPLAY_FILE_RATE)


# A broadcast frame, throttled to REPLAY_FILE_RATE. A phase-transition frame
# bypasses the throttle: the first frame of a new phase is a keyframe and must
# never be dropped.
func record_frame(host_ts: float, data: PackedByteArray, phase: int) -> void:
	if _writer == null or not should_record(phase):
		return
	if not admits_frame(host_ts, _last_frame_ts, phase, _last_phase):
		return
	_writer.enqueue_frame(host_ts, data)
	_last_frame_ts = host_ts
	if phase >= 0:
		_last_phase = phase


# The goal moment, at full rate. Without it the first dead-puck broadcast (the
# only frame should_record admits while movement-locked) is what represents
# "goal" in the file — a tick after the actual entry. Advancing the phase here
# is what stops the natural broadcast pipeline duplicating this frame on its
# next tick.
func force_frame(host_ts: float, data: PackedByteArray, phase: int) -> void:
	if _writer == null or not should_record(phase):
		return
	_writer.enqueue_frame(host_ts, data)
	if phase >= 0:
		_last_phase = phase


func record_event(host_ts: float, payload: PackedByteArray) -> void:
	if _writer == null:
		return
	_writer.enqueue_event(host_ts, payload)
