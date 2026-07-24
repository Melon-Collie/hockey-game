class_name AICoordinator
extends RefCounted

# Drives the host's bot-AI decisions, optionally off the physics thread (AI
# threading Phase 3c; design in docs/ai-threading-plan.md).
#
# Two paths, selected by THREADED_AI:
#   OFF — decisions run inline on the main thread, exactly like Phase 3b:
#     begin_tick -> decide -> apply per bot, then collect one-timer readiness.
#   ON — the expensive decide() runs on a persistent worker thread while the main
#     thread does the rest of the physics tick. The main thread NEVER blocks on
#     the worker: each frame it harvests a finished batch if one is ready, else
#     it reuses last frame's decision (bots coast on their retained move intent).
#     So the frame rate is decoupled from the AI cost — a heavy AI tick lets the
#     worker fall a frame or two behind instead of stalling the host. Decisions
#     are applied a frame or more late; a bot's 6-60 Hz decision cadence already
#     tolerates that.
#
# Why this is safe to thread (see the plan): decide() reads only the frozen
# WorldSnapshot + the frozen TeamBrainView + agent-local state and writes only
# the agent's own InputState — no scene nodes, no autoloads, no shared team
# state (the one residual brain write, one-timer readiness, is collected on the
# main thread here after the worker finishes). The main thread mutates the live
# brains (pings / retick / spawns) during the worker window, but the worker only
# reads the frozen view, so there is no race. A tiny mutex guards only the
# worker's "batch ready" flag; the decisions themselves need no lock because the
# main thread reads a bot's InputState only while the worker is idle (between a
# harvested batch and the next kick), never while it is being written.
#
# Set THREADED_AI to false to fall back to the single-threaded path if the worker
# ever misbehaves in game. The threaded path can't be exercised by the headless
# test suite (which bypasses the coordinator), so it's validated in game.

const THREADED_AI := true

# ── Worker plumbing (only used when THREADED_AI) ─────────────────────────────
var _thread: Thread = null
var _wake := Semaphore.new()       # main -> worker: "decide the current batch"
var _mutex := Mutex.new()          # guards _result_ready only
var _result_ready := false         # worker -> main: current batch is decided
var _running := false              # cleared to signal the worker to exit
var _thread_started := false
var _run_in_flight := false        # a batch has been kicked and not yet harvested

# The batch the worker decides + the snapshot/delta captured at kick time. The
# worker reads _worker_bots only between a kick and its completion; the main
# thread swaps a freshly-built _next_bots into it only while the worker is idle,
# so neither is ever touched concurrently. Both are reused (no per-frame alloc).
var _worker_bots: Array[AIController] = []
var _next_bots: Array[AIController] = []
# The stable snapshot the worker reads for its whole batch. Fields the host
# rebuilds fresh each frame are shared by reference; fields it mutates in place
# (the accel-tracker dicts, the reused carrier-debounce puck) are copied into the
# reused buffers below at kick time so the worker never reads them mid-mutation.
var _worker_snapshot: WorldSnapshot = WorldSnapshot.new()
var _worker_puck: PuckNetworkState = PuckNetworkState.new()
var _worker_delta: float = 0.0

# Diagnostics: wall-clock µs of the most recent worker batch. Written by the
# worker, read by the main thread for telemetry — a benign torn-int read.
var last_worker_us: int = 0


# Host per-frame entry: brains have already ticked + built their views on the
# main thread; `bots` is the live AIController list; `snapshot` is this frame's
# enriched snapshot.
func dispatch(bots: Array[AIController], brains: Array[TeamBrain],
		snapshot: WorldSnapshot, delta: float) -> void:
	if THREADED_AI:
		_dispatch_threaded(bots, brains, snapshot, delta)
	else:
		_dispatch_inline(bots, brains, snapshot, delta)


# ── Inline (single-threaded) path — identical to Phase 3b ────────────────────
func _dispatch_inline(bots: Array[AIController], brains: Array[TeamBrain],
		snapshot: WorldSnapshot, delta: float) -> void:
	for brain: TeamBrain in brains:
		brain.build_view(snapshot)
	for b: AIController in bots:
		b.tick_agent(snapshot, delta)
	for b: AIController in bots:
		b.collect_one_timer_ready()


# ── Threaded path (non-blocking) ─────────────────────────────────────────────
func _dispatch_threaded(bots: Array[AIController], brains: Array[TeamBrain],
		snapshot: WorldSnapshot, delta: float) -> void:
	if not _thread_started:
		_start_thread()

	# A. Harvest — only if the worker has finished. Never blocks: if the batch is
	#    still cooking we leave _run_in_flight set and reuse last frame's decision.
	if _run_in_flight:
		_mutex.lock()
		var ready: bool = _result_ready
		if ready:
			_result_ready = false
		_mutex.unlock()
		if ready:
			_run_in_flight = false
			for b: AIController in _worker_bots:
				b.collect_one_timer_ready()

	# B+C. Resolve each bot's mode on the main thread (begin_tick does the special
	#      non-agent modes' node writes) and rebuild this frame's normal batch.
	#      Apply a decision ONLY while the worker is idle — then _pending_input is
	#      stable (last completed batch). While the worker is in flight we skip the
	#      apply; the bot coasts on its retained move intent until the next batch.
	var worker_idle: bool = not _run_in_flight
	_next_bots.clear()
	for b: AIController in bots:
		if b.begin_tick(delta):
			_next_bots.append(b)
			if worker_idle:
				b.apply_decision(delta)

	# D. Kick a fresh batch only when the worker is idle. Swap this frame's normal
	#    list into _worker_bots (the worker reads it until it signals ready; we
	#    don't touch it again until the next harvest), and hand over the frozen
	#    snapshot. If the worker is still busy we skip the kick and try again next
	#    frame — it keeps working on the in-flight batch.
	if worker_idle:
		# Freeze the brain views now, while the worker is idle — the worker reads
		# them during the batch, so they must not be rebuilt mid-flight.
		for brain: TeamBrain in brains:
			brain.build_view(snapshot)
		var tmp: Array[AIController] = _worker_bots
		_worker_bots = _next_bots
		_next_bots = tmp
		# Stamp rule set + host time now (worker idle) so decide() reads no
		# autoloads and nothing the worker reads is mutated mid-batch.
		for b: AIController in _worker_bots:
			b.prep_for_decide()
		_stabilize_snapshot(snapshot)
		_worker_delta = delta
		_run_in_flight = true
		_wake.post()


# Fill _worker_snapshot with a race-safe view of this frame's snapshot. Fields
# the host builds fresh each frame (skater_states, goalie_states, the teammate
# caches, the scalars) are shared by reference — a new snapshot object next frame
# leaves this one untouched. Fields the host mutates IN PLACE every frame — the
# accel-tracker dicts shared onto the snapshot, and the reused carrier-debounce
# puck scratch — are copied into reused buffers, since the worker reads them
# across the frame while the host would otherwise overwrite them.
func _stabilize_snapshot(src: WorldSnapshot) -> void:
	var ws: WorldSnapshot = _worker_snapshot
	ws.skater_states = src.skater_states
	ws.goalie_states = src.goalie_states
	ws.teammate_ids_by_team = src.teammate_ids_by_team
	ws.closest_to_puck_by_team = src.closest_to_puck_by_team
	ws.real_puck_carrier_peer_id = src.real_puck_carrier_peer_id
	ws.host_timestamp = src.host_timestamp
	if src.puck_state != null:
		_worker_puck.copy_from(src.puck_state)
		ws.puck_state = _worker_puck
	else:
		ws.puck_state = null
	_copy_accel(src.accel_by_peer, ws.accel_by_peer)
	_copy_omega(src.heading_omega_by_peer, ws.heading_omega_by_peer)


func _copy_accel(src: Dictionary, dst: Dictionary[int, Vector3]) -> void:
	dst.clear()
	for k: int in src:
		dst[k] = src[k]


func _copy_omega(src: Dictionary, dst: Dictionary[int, float]) -> void:
	dst.clear()
	for k: int in src:
		dst[k] = src[k]


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
		var t0: int = Time.get_ticks_usec()
		var snap: WorldSnapshot = _worker_snapshot
		var d: float = _worker_delta
		for b: AIController in _worker_bots:
			b.decide(snap, d)
		last_worker_us = Time.get_ticks_usec() - t0
		_mutex.lock()
		_result_ready = true
		_mutex.unlock()


# Cleanly stop and join the worker. Safe to call more than once (idempotent);
# called on match/world teardown and again from GameManager's app-exit
# notification (a live Thread must be joined before it is freed or Godot errors).
# After it, a later dispatch lazily restarts the worker for the next match.
func shutdown() -> void:
	if not _thread_started:
		return
	_running = false
	_wake.post()               # wake the (possibly idle) worker so it sees _running
	_thread.wait_to_finish()   # blocks until the worker finishes any live batch + exits
	_thread = null
	_thread_started = false
	_run_in_flight = false
	_mutex.lock()
	_result_ready = false
	_mutex.unlock()
