extends Node

# Music playback — one looping bed at a time, crossfaded on switch, on its own
# "Music" bus so the Options slider is independent of SFX / UI / arena
# atmosphere. SoundManager stays one-shot-only; the long streams live here,
# mirroring how CrowdAudioController owns the looping crowd ambient.
#
# Every entry point is a no-op when the track's file is absent, so the game runs
# unscored: dropping an .ogg into res://Sounds/music/ under the name in the
# registry below is the entire install step. See Sounds/music/README.md.

enum Track {
	TITLE,
}

const _TRACK_PATHS: Dictionary = {
	Track.TITLE: "res://Sounds/music/title.ogg",
}

const _MUSIC_BUS: StringName = &"Music"
# Crossfade floor. -60 dB is inaudible at any master setting, and fading to it
# rather than to linear zero keeps the curve in the same units as the rest of
# the mix, so a fade sounds even end to end.
const _SILENT_DB: float = -60.0
const _NO_TRACK: int = -1

# Two players so a switch crossfades rather than cuts; _active indexes the one
# currently rising or held.
var _players: Array[AudioStreamPlayer] = []
var _active: int = 0
var _current_track: int = _NO_TRACK
var _fade: Tween = null


func _ready() -> void:
	# Fades must survive a paused tree — the pause menu and the game-over popup
	# are both places a track change can be requested from, and a tween bound to
	# a PROCESS_MODE_INHERIT node would stall mid-crossfade there.
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i: int in 2:
		var p := AudioStreamPlayer.new()
		p.bus = _MUSIC_BUS
		p.volume_db = _SILENT_DB
		add_child(p)
		_players.append(p)


# Crossfade to `track`. Idempotent — re-requesting the playing track does
# nothing, so a screen can call this from _ready() without guarding against
# being rebuilt. `volume_db` trims a track mastered hot or quiet relative to the
# rest; the player's Music slider scales the bus on top of that.
func play(track: Track, fade_s: float = 1.5, volume_db: float = 0.0) -> void:
	if track == _current_track and _players[_active].playing:
		return
	var stream: AudioStream = _load_track(track)
	if stream == null:
		return
	_current_track = track
	var outgoing: AudioStreamPlayer = _players[_active]
	_active = 1 - _active
	var incoming: AudioStreamPlayer = _players[_active]
	incoming.stream = stream
	incoming.volume_db = _SILENT_DB
	incoming.play()
	_crossfade(incoming, volume_db, outgoing, fade_s)


func stop(fade_s: float = 1.0) -> void:
	if _current_track == _NO_TRACK:
		return
	_current_track = _NO_TRACK
	_crossfade(null, 0.0, _players[_active], fade_s)


# One tween drives both sides so they can't drift apart, and killing it on each
# call means a rapid switch picks up from wherever the last fade reached instead
# of snapping back to full.
func _crossfade(incoming: AudioStreamPlayer, target_db: float,
		outgoing: AudioStreamPlayer, fade_s: float) -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
		_fade = null
	var fading_out: bool = outgoing != null and outgoing.playing
	if incoming == null and not fading_out:
		return
	# A tween with zero duration errors; a zero fade is a legitimate request
	# (hard cut), so floor it at one frame's worth instead.
	var duration: float = maxf(fade_s, 0.01)
	_fade = create_tween()
	_fade.set_parallel(true)
	if incoming != null:
		_fade.tween_property(incoming, "volume_db", target_db, duration)
	if fading_out:
		_fade.tween_property(outgoing, "volume_db", _SILENT_DB, duration)
		# chain() breaks out of the parallel group, so the stop lands after both
		# legs finish rather than immediately.
		_fade.chain().tween_callback(outgoing.stop)


func _load_track(track: Track) -> AudioStream:
	var path: String = _TRACK_PATHS.get(track, "")
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var stream: AudioStream = load(path)
	# Looping is a property of the imported resource, not of the player. Force
	# it here so a track dropped in without a trip to the import dock still
	# loops instead of playing once and leaving the screen silent.
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	return stream
