class_name AICoordinator
extends RefCounted

# Drives the host's bot-AI decisions off the physics thread (AI threading; design
# in docs/ai-threading-plan.md).
#
# The expensive decide() runs on a persistent worker thread while the main thread
# does the rest of the physics tick. The main thread NEVER blocks on the worker:
# each frame it harvests a finished batch if one is ready, else it reuses last
# frame's decision (bots coast on their retained move intent). So the frame rate
# is decoupled from the AI cost — a heavy AI tick lets the worker fall a frame or
# two behind instead of stalling the host. Decisions are applied a frame or more
# late; a bot's 6-60 Hz decision cadence already tolerates that.
#
# Why this is safe to thread (see the plan): decide() reads only the frozen
# WorldSnapshot + the frozen TeamBrainView + agent-local state and writes only
# the agent's own InputState — no scene nodes, no autoloads, no shared team
# state (the one residual brain write, one-timer readiness, is collected on the
# main thread here after the worker finishes). A tiny mutex guards only the
# worker's "batch ready" flag; the decisions themselves need no lock because the
# main thread reads a bot's InputState only while the worker is idle (between a
# harvested batch and the next kick), never while it is being written.
#
# The TeamBrain tick runs on the worker too, at the head of each batch (tick →
# build_view → decide), preserving the order those three had when the first two
# were on main. Brains are only 6 Hz, but force_retick() fires them off-cadence
# on every carrier flip, so their spikes cluster in scrums — exactly the worst
# ticks. That makes them worth moving even though their mean is small.
#
# Moving them means the main thread can no longer touch a live brain whenever it
# likes. Two rules keep that sound, and both are structural rather than lock-
# based:
#   • Every host-raised brain mutation (pings, carrier-flip re-ticks, tutorial
#     spawn/despawn) is parked in the queues below and applied BY THE MAIN THREAD
#     in the idle window just before the next kick. Nothing is written across the
#     thread boundary; the only cost is a deferral of a frame or two, which is
#     the staleness Model A already accepts.
#   • The two live brain fields main still reads every frame — the ping-elected
#     chaser and the possession state / coverage flag — are published into plain
#     mirrors at kick time and read from there.
#
# The threaded path can't be exercised by the headless test suite (which bypasses
# the coordinator), so it's validated in game.

# ── Worker plumbing ──────────────────────────────────────────────────────────
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

# The live TeamBrains the worker ticks. Assigned (not copied) at kick time while
# the worker is idle. GameManager only ever replaces the whole team_brains array
# — never mutates its contents mid-match — so holding the reference across a
# batch keeps the brains alive even if the host tears the match down underneath.
var _worker_brains: Array[TeamBrain] = []

# Elapsed host time since the last kick, handed to TeamBrain.tick as its delta.
# NOT the frame delta: kicks are skipped while the worker is still busy, and a
# brain that only saw kick frames would age its 6 Hz accumulator — and its ping
# expiry, which is real-time — slow by exactly the frames it missed. Summing
# across the skip keeps brain cadence correct under worker overrun.
var _brain_delta_accum: float = 0.0
var _worker_brain_delta: float = 0.0

# Diagnostics: wall-clock µs of the most recent worker batch, and of the brain
# tick nested inside it. Written by the worker, read by the main thread for
# telemetry — a benign torn-int read.
var last_worker_us: int = 0
var last_brain_us: int = 0

# ── Deferred brain mutations (main thread only) ──────────────────────────────
# Parked here by the host and drained onto the live brains in the idle window
# before the next kick. Every one of these is event-rate — a key press, a puck
# pickup, a tutorial spawn — never per-tick, so the allocations they make never
# reach the hot path. The per-tick cost is iterating empty arrays.
class PendingPing:
	var team: int = 0
	var type: int = 0
	var pinger_peer: int = 0
	var target_peer: int = 0
	var obeyer_peer: int = 0
	var world_pos: Vector3 = Vector3.ZERO

var _pending_pings: Array[PendingPing] = []
# Idempotent: n force_retick requests inside one window are one re-tick, which
# is also what n direct calls produced (the brain just sets a pending flag).
var _pending_force_retick: bool = false
# (team_id, peer_id) pairs — Vector2i keeps them typed without an object each.
var _pending_exclude: Array[Vector2i] = []
var _pending_include: Array[Vector2i] = []

# ── Main-thread mirrors of live brain fields ─────────────────────────────────
# Indexed by team_id. Two host paths read a brain every frame from OUTSIDE the
# idle window: snapshot enrichment (the GET_PUCK ping's elected chaser) and the
# F6 shape tally (possession state + coverage downgrade). Both sources are
# mutated by the worker's brain tick — ping directives are advanced and expired
# in place — so main reads a published copy refreshed at each kick instead.
# One frame stale: enrichment already saw last frame's value back when the brain
# tick ran after it on main, and the tally is accumulating time against a state
# that only changes at 6 Hz.
var _ping_chase_by_team: PackedInt32Array = PackedInt32Array()
var _state_by_team: PackedInt32Array = PackedInt32Array()
var _coverage_downgraded_by_team: Array[bool] = []


# Host per-frame entry: `bots` is the live AIController list, `brains` the live
# TeamBrains (ticked by the worker), `snapshot` this frame's enriched snapshot.
func dispatch(bots: Array[AIController], brains: Array[TeamBrain],
		snapshot: WorldSnapshot, delta: float) -> void:
	if not _thread_started:
		_start_thread()
	# Accrue every frame, not just kick frames — see _brain_delta_accum.
	_brain_delta_accum += delta

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
	# Recorded HERE, not after dispatch returns: by then the kick below has set
	# the in-flight flag, so a healthy tick would read as a late worker.
	HostCostProbe.note_worker_busy(not worker_idle)
	var t_half: int = Time.get_ticks_usec()
	_next_bots.clear()
	for b: AIController in bots:
		if b.begin_tick(delta):
			_next_bots.append(b)
			if worker_idle:
				b.apply_decision(delta)
	HostCostProbe.record(HostCostProbe.Section.AI_APPLY, Time.get_ticks_usec() - t_half)

	# D. Kick a fresh batch only when the worker is idle. Swap this frame's normal
	#    list into _worker_bots (the worker reads it until it signals ready; we
	#    don't touch it again until the next harvest), and hand over the frozen
	#    snapshot. If the worker is still busy we skip the kick and try again next
	#    frame — it keeps working on the in-flight batch.
	if worker_idle:
		t_half = Time.get_ticks_usec()
		# Every brain write the host raised since the last kick lands here, on the
		# main thread, with the worker provably idle.
		_drain_brain_commands(brains)
		# Republish what main reads off the live brains between now and the next
		# kick — after the drain, so a ping applied this frame is visible at once.
		_publish_brain_mirrors(brains)
		var tmp: Array[AIController] = _worker_bots
		_worker_bots = _next_bots
		_next_bots = tmp
		_worker_brains = brains
		# Stamp rule set + host time now (worker idle) so decide() reads no
		# autoloads and nothing the worker reads is mutated mid-batch.
		for b: AIController in _worker_bots:
			b.prep_for_decide()
		_stabilize_snapshot(snapshot)
		_worker_delta = delta
		_worker_brain_delta = _brain_delta_accum
		_brain_delta_accum = 0.0
		_run_in_flight = true
		_wake.post()
		HostCostProbe.record(HostCostProbe.Section.AI_KICK, Time.get_ticks_usec() - t_half)


# ── Deferred brain mutation API (host, main thread) ──────────────────────────
# Mirrors the TeamBrain methods the host used to call directly. Each takes
# effect at the next kick; see the queue declarations for why that is sound.

func queue_ping(team_id: int, type: int, pinger_peer: int, target_peer: int,
		obeyer_peer: int, world_pos: Vector3) -> void:
	var p := PendingPing.new()
	p.team = team_id
	p.type = type
	p.pinger_peer = pinger_peer
	p.target_peer = target_peer
	p.obeyer_peer = obeyer_peer
	p.world_pos = world_pos
	_pending_pings.append(p)


func queue_force_retick() -> void:
	_pending_force_retick = true


func queue_exclude_skater(team_id: int, peer_id: int) -> void:
	_pending_exclude.append(Vector2i(team_id, peer_id))


func queue_include_skater(team_id: int, peer_id: int) -> void:
	_pending_include.append(Vector2i(team_id, peer_id))


# Last published value of a field the host reads off a live brain every frame.
# Defaults match what a missing/unticked brain returned before: no ping-elected
# chaser, and the brain's own DZONE / not-downgraded starting state.
func ping_chase_peer(team_id: int) -> int:
	if team_id < 0 or team_id >= _ping_chase_by_team.size():
		return -1
	return _ping_chase_by_team[team_id]


func brain_state(team_id: int) -> int:
	if team_id < 0 or team_id >= _state_by_team.size():
		return AIPossessionState.State.DZONE
	return _state_by_team[team_id]


func brain_coverage_downgraded(team_id: int) -> bool:
	if team_id < 0 or team_id >= _coverage_downgraded_by_team.size():
		return false
	return _coverage_downgraded_by_team[team_id]


func _drain_brain_commands(brains: Array[TeamBrain]) -> void:
	for pair: Vector2i in _pending_exclude:
		if pair.x >= 0 and pair.x < brains.size():
			brains[pair.x].exclude_skater(pair.y)
	_pending_exclude.clear()
	for pair: Vector2i in _pending_include:
		if pair.x >= 0 and pair.x < brains.size():
			brains[pair.x].include_skater(pair.y)
	_pending_include.clear()
	for p: PendingPing in _pending_pings:
		if p.team >= 0 and p.team < brains.size():
			# apply_ping force_reticks the pinged team's brain itself.
			brains[p.team].apply_ping(p.type, p.pinger_peer, p.target_peer,
					p.obeyer_peer, p.world_pos)
	_pending_pings.clear()
	if _pending_force_retick:
		_pending_force_retick = false
		for brain: TeamBrain in brains:
			brain.force_retick()


func _publish_brain_mirrors(brains: Array[TeamBrain]) -> void:
	var n: int = brains.size()
	if _ping_chase_by_team.size() != n:
		_ping_chase_by_team.resize(n)
		_state_by_team.resize(n)
		_coverage_downgraded_by_team.resize(n)
	for i: int in n:
		var brain: TeamBrain = brains[i]
		_ping_chase_by_team[i] = brain.ping_chase_peer()
		_state_by_team[i] = brain.state
		_coverage_downgraded_by_team[i] = brain.coverage_downgraded


# Fill _worker_snapshot with a race-safe view of this frame's snapshot. Three
# different safety arguments, one per field class — don't collapse them:
#
#  1. Genuinely fresh each frame: the teammate caches (GameManager._enrich_snapshot_for_ai
#     clears + refills dicts that belong to that frame's own WorldSnapshot) and the
#     scalars. Sharing by reference is safe — next frame builds a new object.
#  2. Reused ring slots: skater_states / goalie_states entries. StateBufferManager
#     hands back the LIVE ring slot by reference on its no-interpolation path
#     (_interpolate_skater's `t < 0.0` branch), and capture() overwrites ring slots
#     in place. These are safe only because the ring is BUFFER_SIZE = 3 s deep and
#     capture advances one slot per frame, so the host cannot wrap back onto the
#     worker's slot until the worker is ~360 frames behind. That margin — NOT object
#     freshness — is what makes the by-reference share sound. Shrinking BUFFER_SIZE,
#     or pointing the AI query at a delayed timestamp, would narrow it.
#  3. Mutated in place every frame: the accel-tracker dicts shared onto the snapshot
#     and the reused carrier-debounce puck scratch. No margin at all, so these are
#     copied into reused buffers below.
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
		# Team strategy first, then freeze it, then the agents that read the
		# frozen view — the order these three ran in when the first two were on
		# main, so cross-agent effects (one-timer readiness, slot assignment)
		# resolve exactly as before.
		for brain: TeamBrain in _worker_brains:
			brain.tick(_worker_brain_delta, snap)
		for brain: TeamBrain in _worker_brains:
			brain.build_view(snap)
		last_brain_us = Time.get_ticks_usec() - t0
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
	# Drop the joined worker's references and any brain writes the torn-down
	# match queued but never reached a kick — the next match brings new brains,
	# and replaying a dead match's pings onto them would be a ghost directive.
	_worker_brains = []
	_pending_pings.clear()
	_pending_exclude.clear()
	_pending_include.clear()
	_pending_force_retick = false
	_brain_delta_accum = 0.0
	_ping_chase_by_team.clear()
	_state_by_team.clear()
	_coverage_downgraded_by_team.clear()
