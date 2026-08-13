class_name GoalClipExporter
extends Node

# Owns the "save this goal as a GIF" feature end to end: when to capture, what
# the player's press means, and handing the result to the encoder.
#
# Two places a clip can be saved, one mechanism behind both:
#   - the in-game goal cinematic (GoalReplayDriver), and
#   - the post-game highlight reel behind the final-score screen
#     (PostGameReplayDriver), which loops every goal of the match.
#
# Both are segment-shaped: a segment opens, frames accumulate for its whole
# length, and it closes. The player's press ARMS the open segment rather than
# starting a capture, because a press two thirds of the way through a goal
# still means "save the goal," not "save the last two seconds." The cost of
# that is capturing speculatively on every replay — see ClipFrameCapture.
#
# Entirely local. Every peer runs its own replay drivers off its own recorder,
# so a save touches no RPC, needs no host, and never has to agree with anyone.
#
# Owned by GameManager, which forwards the player's press to request_export().

enum State {
	IDLE,      ## nothing armed; a segment may or may not be capturing
	ARMED,     ## press registered, waiting for the current segment to close
	ENCODING,  ## segment closed, worker thread is encoding
}

signal state_changed(state: State)
## Whether a segment is open to be saved. Separate from state_changed because
## a segment opening and closing is not a state transition — IDLE spans both —
## and it is what decides whether the HUD shows a prompt at all.
signal availability_changed(available: bool)
## ok = false on any failure; path is empty in that case.
signal export_finished(path: String, ok: bool)

var _capture: ClipFrameCapture = null
var _exporter: GifExporter = null
var _state: State = State.IDLE
# Scorer of the segment currently being captured, for the filename.
var _segment_label: String = ""
# Supplies the scorer for the live cinematic (the reel carries its own per-clip
# meta). A Callable rather than a GameManager reach-up, per the layering rule.
var _goal_label_provider: Callable = Callable()


func _ready() -> void:
	_capture = ClipFrameCapture.new()
	add_child(_capture)
	_exporter = GifExporter.new()
	_exporter.export_finished.connect(_on_export_finished)
	add_child(_exporter)


func setup(goal_driver: GoalReplayDriver, reel_driver: PostGameReplayDriver) -> void:
	if goal_driver != null:
		goal_driver.replay_started.connect(_on_goal_replay_started)
		goal_driver.replay_stopped.connect(_close_segment)
	if reel_driver != null:
		# The reel has no per-clip "ended" edge — clip_started IS the boundary,
		# so each one closes the clip that just finished and opens the next.
		# start() emits clip_started for clip 0 before reel_started, so there is
		# no separate open to wire.
		reel_driver.clip_started.connect(_on_reel_clip_started)
		reel_driver.reel_stopped.connect(_close_segment)


func state() -> State:
	return _state


# True when a press would do something — a segment is capturing and we aren't
# already busy. Drives the HUD prompt's visibility.
func can_export() -> bool:
	return _state == State.IDLE and _capture != null and _capture.is_capturing()


# The player pressed save. Arms the open segment; the export itself fires when
# that segment closes and its frames are complete.
func request_export() -> void:
	if not can_export():
		return
	_set_state(State.ARMED)


func set_goal_label_provider(provider: Callable) -> void:
	_goal_label_provider = provider


func _on_goal_replay_started() -> void:
	var label: String = ""
	if _goal_label_provider.is_valid():
		label = String(_goal_label_provider.call())
	_open_segment(label)


func _on_reel_clip_started(clip: Dictionary) -> void:
	_close_segment()
	_open_segment(String(clip.get("scorer_name", "")))


func _open_segment(label: String) -> void:
	# Without the extension there is no encode to feed, so don't pay the
	# capture cost either.
	if _capture == null or not GifExporter.is_available():
		return
	_segment_label = label
	_capture.start()
	availability_changed.emit(true)


# End of a segment: hand it to the encoder if the player armed it, otherwise
# throw the frames away.
func _close_segment() -> void:
	if _capture == null or not _capture.is_capturing():
		return
	if _state != State.ARMED:
		_capture.discard()
		availability_changed.emit(false)
		return
	_capture.stop()
	availability_changed.emit(false)
	var frames: Array[Image] = _capture.take()
	if not _exporter.export_frames(frames, _capture.fps(), _segment_label):
		_set_state(State.IDLE)
		export_finished.emit("", false)
		return
	_set_state(State.ENCODING)


# World teardown (match end, quit to free play, kicked). Drops any segment in
# progress; an encode already handed to the worker thread is left to finish and
# land its file, since the frames it holds are complete and no longer depend on
# anything being torn down.
func abort() -> void:
	if _capture != null and _capture.is_capturing():
		_capture.discard()
		availability_changed.emit(false)
	if _state == State.ARMED:
		_set_state(State.IDLE)


func _on_export_finished(path: String, ok: bool) -> void:
	_set_state(State.IDLE)
	export_finished.emit(path, ok)


func _set_state(next: State) -> void:
	if _state == next:
		return
	_state = next
	state_changed.emit(_state)
