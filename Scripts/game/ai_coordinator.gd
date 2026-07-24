class_name AICoordinator
extends RefCounted

# Drives the host's bot-AI decisions, optionally off the physics thread (AI
# threading Phase 3c; design in docs/ai-threading-plan.md).
#
# Two paths, selected by THREADED_AI:
#   OFF (default) — decisions run inline on the main thread, exactly like Phase
#     3b: begin_tick -> decide -> apply per bot, then collect one-timer readiness.
#   ON — the expensive decide() runs on a persistent worker thread while the main
#     thread does the rest of the physics tick. Decisions are applied ONE tick
#     later (the delay is what lets the worker overlap the full physics step);
#     a bot's throttled cadence already tolerates reusing an input for a tick.
#
# Why this is safe to thread (see the plan): decide() reads only the frozen
# WorldSnapshot + the frozen TeamBrainView + agent-local state and writes only
# the agent's own InputState — no scene nodes, no autoloads, no shared team
# state (the one residual brain write, one-timer readiness, is collected on the
# main thread here after the worker finishes). The main thread mutates the live
# brains (pings / retick / spawns) during the worker window, but the worker only
# reads the frozen view, so there is no race. No mutex / double-buffer is needed:
# main reads each result only after waiting on _done and before the next kick.
#
# Flip THREADED_AI to true (and rebuild) to enable the worker. Default off so the
# shipped path is the validated single-threaded one; the threaded path can't be
# exercised by the headless test suite and needs an in-game playtest.

const THREADED_AI := false

# ── Worker plumbing (only used when THREADED_AI) ─────────────────────────────
var _thread: Thread = null
var _wake := Semaphore.new()       # main -> worker: "decide the current batch"
var _done := Semaphore.new()       # worker -> main: "batch decided"
var _running := false              # cleared to signal the worker to exit
var _thread_started := false
var _run_in_flight := false        # a batch is being (or was) decided since the last harvest

# The batch the worker decides: this frame's normal-gameplay bots + the snapshot
# and delta captured at kick time. Cleared-and-refilled each frame (reused, no
# per-frame allocation) — the worker only reads it between a wake and its done,
# and the main thread only rewrites it after waiting on _done, so no lock.
var _worker_bots: Array[AIController] = []
var _worker_snapshot: WorldSnapshot = null
var _worker_delta: float = 0.0


# Host per-frame entry: brains have already ticked + built their views on the
# main thread; `bots` is the live AIController list; `snapshot` is this frame's
# enriched snapshot.
func dispatch(bots: Array[AIController], snapshot: WorldSnapshot, delta: float) -> void:
	if THREADED_AI:
		_dispatch_threaded(bots, snapshot, delta)
	else:
		_dispatch_inline(bots, snapshot, delta)


# ── Inline (single-threaded) path — identical to Phase 3b ────────────────────
func _dispatch_inline(bots: Array[AIController], snapshot: WorldSnapshot, delta: float) -> void:
	for b: AIController in bots:
		b.tick_agent(snapshot, delta)
	for b: AIController in bots:
		b.collect_one_timer_ready()


# ── Threaded path ────────────────────────────────────────────────────────────
# Per frame: harvest last frame's decisions, resolve modes + apply, then kick the
# worker to decide this frame's batch for next frame.
func _dispatch_threaded(bots: Array[AIController], snapshot: WorldSnapshot, delta: float) -> void:
	if not _thread_started:
		_start_thread()

	# A. Harvest the batch decided since the last kick. After _done the worker is
	#    idle, so reading each bot's _pending_input and its one-timer flag is safe.
	if _run_in_flight:
		_done.wait()
		_run_in_flight = false
		for b: AIController in _worker_bots:
			b.collect_one_timer_ready()

	# B+C. Resolve each bot's mode on the main thread (begin_tick does the special
	#      non-agent modes' node writes and nulls a stale pending input), rebuild
	#      the normal batch, and apply last frame's decision to each normal bot.
	#      _worker_bots still holds last frame's batch until this clear — the
	#      harvest above already consumed it.
	_worker_bots.clear()
	for b: AIController in bots:
		if b.begin_tick(delta):
			_worker_bots.append(b)
			b.apply_decision(delta)

	# D. Kick the worker to decide this frame's batch against this frame's frozen
	#    snapshot (applied next frame). The worker reads _worker_bots / _snapshot /
	#    _delta only until it posts _done, and we don't touch them again until the
	#    next frame's harvest, so no lock is needed.
	_worker_snapshot = snapshot
	_worker_delta = delta
	_wake.post()
	_run_in_flight = true


func _start_thread() -> void:
	_running = true
	_thread = Thread.new()
	_thread.start(_worker_loop)
	_thread_started = true


func _worker_loop() -> void:
	while true:
		_wake.wait()
		if not _running:
			return
		var snap: WorldSnapshot = _worker_snapshot
		var d: float = _worker_delta
		for b: AIController in _worker_bots:
			b.decide(snap, d)
		_done.post()


# Cleanly stop and join the worker. Safe to call more than once (idempotent);
# called on match/world teardown and again from GameManager's app-exit
# notification (a live Thread must be joined before it is freed or Godot errors).
# After it, a later dispatch lazily restarts the worker for the next match.
func shutdown() -> void:
	if not _thread_started:
		return
	if _run_in_flight:
		_done.wait()
		_run_in_flight = false
	_running = false
	_wake.post()
	_thread.wait_to_finish()
	_thread = null
	_thread_started = false
