class_name NetworkTelemetry
extends RefCounted

# Owned by GameManager. Created at world spawn, freed on scene exit.
# Call sites use static methods so they're null-safe outside a game session.
static var instance: NetworkTelemetry = null

# ── Window counters (reset each second) ──────────────────────────────────────
var _world_state_count: int = 0
var _input_count: int = 0
var _reconcile_count: int = 0
var _extrapolation_count: int = 0
var _reconcile_mag_sum: float = 0.0
var _reconcile_mag_n: int = 0
var _blade_jump_count: int = 0
var _blade_jump_mag_sum: float = 0.0
var _blade_jump_n: int = 0
var _blade_reconcile_mag_sum: float = 0.0
var _blade_reconcile_n: int = 0
var _prediction_divergence_sum: float = 0.0
var _prediction_divergence_n: int = 0
var _ooo_drop_count: int = 0
var _input_lead_sum: float = 0.0
var _input_lead_n: int = 0
var _starvation_count: int = 0
# Bandwidth: bytes seen this window. Counted at the NetworkManager boundary so
# the value reflects payload bytes only (excludes ENet/UDP/IP headers — those
# add ~28 B per packet but aren't visible from inside the engine).
var _bytes_sent_window: int = 0
var _bytes_received_window: int = 0
# Puck trajectory three-zone correction counters. Each broadcast during
# trajectory prediction picks one zone based on client-vs-server divergence:
# 0=soft blend (<0.3m), 1=velocity-only (0.3-1.5m), 2=hard snap (>1.5m).
# Healthy: mostly zone 0, occasional zone 1, zone 2 only on real physics
# divergence (wall/goalie bounce). Zone 2 firing every shot indicates a
# trajectory math bug; zones 0+1 oscillating frame-to-frame indicates RTT
# jitter exceeding the bounded velocity-only band.
var _puck_traj_soft_count: int = 0
var _puck_traj_vel_only_count: int = 0
var _puck_traj_hard_snap_count: int = 0
var _window_timer: float = 0.0

# ── Published metrics (read by overlay) ──────────────────────────────────────
# Expected ranges below assume healthy network (RTT < 100ms, loss < 1%) and
# steady-state gameplay (no phase transitions, no body checks in flight).
# Spike-rate-during-normal-play is the universal latent-bug detector: anything
# rate-based that's listed as "near-zero" but trends non-zero indicates a
# structural problem (non-determinism, divergence channel, wire-format bug)
# regardless of whether the symptom is visible on screen yet.
var world_state_hz: float = 0.0          # ~120/s on host, matches send rate on clients
var input_hz: float = 0.0                # ~60/s — input batch send rate
# reconcile_per_sec: how often the threshold check actually snapped the skater.
# Expected: <1/s during normal play. Sustained higher rate means either real
# non-determinism in _process_input or a divergence channel the threshold
# check is structurally blind to (the class of bug that motivated trajectory-
# based reconciliation in the first place).
var reconcile_per_sec: float = 0.0
# reconcile_magnitude_avg: average distance snapped per reconcile, in meters.
# Expected: <0.05m on healthy network. Larger values mean threshold check is
# letting big divergences accumulate before firing — or, if rate is high too,
# the predicted-vs-server lookup is missing and falling back to live position.
var reconcile_magnitude_avg: float = 0.0
var extrapolation_per_sec: float = 0.0   # bracket extrapolation count; expect <1/s
var buffer_depth_skater: int = 0
var buffer_depth_puck: int = 0
var buffer_depth_goalie: int = 0
var blade_jump_per_sec: float = 0.0
var blade_jump_mag_avg: float = 0.0
var blade_reconcile_mag_avg: float = 0.0
var prediction_divergence_avg: float = 0.0
var ooo_drops_per_sec: float = 0.0       # expect 0; non-zero means UDP reordering
# Bandwidth (KB/s). Host sees bytes_sent_per_sec as sum across all peers (1×
# snapshot bytes per recipient per broadcast); clients see only their own
# receive volume. Payload bytes only — ENet/UDP/IP headers add ~28 B/packet
# beyond this. Goalie overhaul target: snapshot stays under 500 B/tick at
# 120Hz, so per-recipient bytes_sent_per_sec should stay under ~60 KB/s.
var bytes_sent_per_sec: float = 0.0
var bytes_received_per_sec: float = 0.0
# Puck trajectory three-zone correction rates (Hz). All three sum to roughly
# (post-shot broadcast rate ≈ 120/s) DURING trajectory prediction only — they're
# zero when puck is carried or interpolated. Mostly soft, occasional vel-only,
# hard-snap only on real divergence. Hard-snap firing every shot is a bug.
var puck_traj_soft_per_sec: float = 0.0
var puck_traj_vel_only_per_sec: float = 0.0
var puck_traj_hard_snap_per_sec: float = 0.0
var input_queue_depth_median: int = 0
var input_lead_avg_ms: float = 0.0
var input_starvations_per_sec: float = 0.0
var _queue_depth_window: Array[int] = []
var packet_loss_pct: float = 0.0
var jitter_p95_ms: float = 0.0
var puck_mode: String = "—"

# ── Host-frame health (host only; clients leave these at 0) ──────────────────
# Inter-tick gap captures any stall regardless of cause (CPU steal, GC pause,
# heavy Jolt frame, etc.). Steady state at 240Hz is ~4.17ms; a real stall shows
# up as a single large `tick max` sample with subsequent catch-up ticks at
# near-zero gap. Broadcast interval is wall-clock between consecutive
# `_broadcast_state()` calls — should track the physics-driven 25ms cadence.
var host_physics_tick_p95_ms: float = 0.0
var host_physics_tick_p99_ms: float = 0.0
var host_physics_tick_max_ms: float = 0.0
var broadcast_interval_p95_ms: float = 0.0
var _phys_tick_samples_us: Array[int] = []
var _bcast_interval_samples_us: Array[int] = []
const PHYS_TICK_WINDOW: int = 240   # 1s at 240Hz
const BCAST_INTERVAL_WINDOW: int = 40  # 1s at 40Hz

# ── Static call sites (no-op when not in a game session) ─────────────────────
static func record_world_state() -> void:
	if instance: instance._world_state_count += 1

static func record_input_sent() -> void:
	if instance: instance._input_count += 1

# Bandwidth: bytes ferried over the wire for this session. Recorded at
# NetworkManager send/receive boundaries. Host calls record_bytes_sent once
# per recipient per broadcast (so host upload load = bytes_sent_per_sec
# reflects total upstream); clients call record_bytes_received once per
# incoming snapshot.
static func record_bytes_sent(n: int) -> void:
	if instance: instance._bytes_sent_window += n

static func record_bytes_received(n: int) -> void:
	if instance: instance._bytes_received_window += n

const QUEUE_DEPTH_WINDOW: int = 80  # 2 s at 40 Hz

static func record_queue_depth(depth: int) -> void:
	if instance == null:
		return
	instance._queue_depth_window.append(depth)
	if instance._queue_depth_window.size() > QUEUE_DEPTH_WINDOW:
		instance._queue_depth_window.pop_front()

static func record_packet_loss(pct: float) -> void:
	if instance: instance.packet_loss_pct = pct

static func record_jitter_p95(ms: float) -> void:
	if instance: instance.jitter_p95_ms = ms

# reconcile: count + trajectory divergence magnitude (predicted-vs-server at the
# confirmed host_timestamp). Prediction lead is subtracted out by the timestamp
# match, so the magnitude reflects true non-determinism (body-check mis-replay,
# contested collisions). Falls back to post-replay residual when the prediction
# snapshot isn't available (history capped, post-teleport, session warmup).
static func record_reconcile(delta_m: float) -> void:
	if instance == null:
		return
	instance._reconcile_count += 1
	instance._reconcile_mag_sum += delta_m
	instance._reconcile_mag_n += 1

# blade_jump: any physics frame where blade world pos moved > 5 cm (teleport-class).
static func record_blade_jump(magnitude: float) -> void:
	if instance == null:
		return
	instance._blade_jump_count += 1
	instance._blade_jump_mag_sum += magnitude
	instance._blade_jump_n += 1

# blade_reconcile: how much the blade world pos moved as a direct result of reconcile.
static func record_blade_reconcile(magnitude: float) -> void:
	if instance == null:
		return
	instance._blade_reconcile_mag_sum += magnitude
	instance._blade_reconcile_n += 1

# prediction_divergence: position error between client prediction and server state
# measured before the input replay, each time a reconcile fires. Average over the
# window surfaces non-determinism — a healthy connection should see near-zero drift.
static func record_prediction_divergence(meters: float) -> void:
	if instance == null:
		return
	instance._prediction_divergence_sum += meters
	instance._prediction_divergence_n += 1

# ooo_drop: a world-state packet arrived out of order and was silently discarded.
static func record_ooo_drop() -> void:
	if instance: instance._ooo_drop_count += 1

# puck_trajectory_zone: which three-zone branch fired for this broadcast during
# trajectory prediction. 0=soft (<0.3m), 1=velocity-only (0.3-1.5m), 2=hard snap
# (>1.5m + buffer clear). Used to detect oscillation around zone boundaries and
# to flag hard-snap rates that should only ever fire on real physics divergence.
static func record_puck_trajectory_zone(zone: int) -> void:
	if instance == null:
		return
	match zone:
		0: instance._puck_traj_soft_count += 1
		1: instance._puck_traj_vel_only_count += 1
		2: instance._puck_traj_hard_snap_count += 1

# input_lead: estimated_host_time() - input.host_timestamp at the moment an
# input is popped from the host queue. Near-zero means inputs are processed
# right on schedule; consistently high means the queue is backing up.
static func record_input_lead(lead_sec: float) -> void:
	if instance == null:
		return
	instance._input_lead_sum += lead_sec
	instance._input_lead_n += 1

# input_starvation: the input queue was empty so the host fell back to the
# last known input for this physics tick.
static func record_input_starvation() -> void:
	if instance: instance._starvation_count += 1

# Wall-clock microseconds between consecutive host physics ticks. Steady state
# ≈ 4170us; a stall produces one large sample followed by near-zero catch-up
# samples. Host-only.
static func record_host_physics_tick_us(us: int) -> void:
	if instance == null:
		return
	instance._phys_tick_samples_us.append(us)
	if instance._phys_tick_samples_us.size() > PHYS_TICK_WINDOW:
		instance._phys_tick_samples_us.pop_front()

# Wall-clock microseconds between consecutive `_broadcast_state()` calls on the
# host. Should track the 25ms (40Hz) physics-driven cadence.
static func record_broadcast_interval_us(us: int) -> void:
	if instance == null:
		return
	instance._bcast_interval_samples_us.append(us)
	if instance._bcast_interval_samples_us.size() > BCAST_INTERVAL_WINDOW:
		instance._bcast_interval_samples_us.pop_front()

func observe_actors(skater_buf: int, puck_buf: int, goalie_buf: int, extrapolating: bool) -> void:
	buffer_depth_skater = skater_buf
	buffer_depth_puck = puck_buf
	buffer_depth_goalie = goalie_buf
	if extrapolating:
		_extrapolation_count += 1

# ── Tick — called by GameManager._process each frame ─────────────────────────
func tick(delta: float) -> void:
	_window_timer += delta
	if _window_timer < 1.0:
		return
	world_state_hz = _world_state_count / _window_timer
	input_hz = _input_count / _window_timer
	reconcile_per_sec = _reconcile_count / _window_timer
	extrapolation_per_sec = _extrapolation_count / _window_timer
	reconcile_magnitude_avg = _reconcile_mag_sum / _reconcile_mag_n if _reconcile_mag_n > 0 else 0.0
	blade_jump_per_sec = _blade_jump_count / _window_timer
	blade_jump_mag_avg = _blade_jump_mag_sum / _blade_jump_n if _blade_jump_n > 0 else 0.0
	blade_reconcile_mag_avg = _blade_reconcile_mag_sum / _blade_reconcile_n if _blade_reconcile_n > 0 else 0.0
	prediction_divergence_avg = _prediction_divergence_sum / _prediction_divergence_n if _prediction_divergence_n > 0 else 0.0
	ooo_drops_per_sec = _ooo_drop_count / _window_timer
	bytes_sent_per_sec = _bytes_sent_window / _window_timer
	bytes_received_per_sec = _bytes_received_window / _window_timer
	puck_traj_soft_per_sec = _puck_traj_soft_count / _window_timer
	puck_traj_vel_only_per_sec = _puck_traj_vel_only_count / _window_timer
	puck_traj_hard_snap_per_sec = _puck_traj_hard_snap_count / _window_timer
	input_lead_avg_ms = (_input_lead_sum / _input_lead_n * 1000.0) if _input_lead_n > 0 else 0.0
	input_starvations_per_sec = _starvation_count / _window_timer
	if not _queue_depth_window.is_empty():
		var sorted := _queue_depth_window.duplicate()
		sorted.sort()
		input_queue_depth_median = sorted[sorted.size() >> 1]
	if not _phys_tick_samples_us.is_empty():
		var pts := _phys_tick_samples_us.duplicate()
		pts.sort()
		var p95_i: int = mini(int(pts.size() * 0.95), pts.size() - 1)
		var p99_i: int = mini(int(pts.size() * 0.99), pts.size() - 1)
		host_physics_tick_p95_ms = pts[p95_i] / 1000.0
		host_physics_tick_p99_ms = pts[p99_i] / 1000.0
		host_physics_tick_max_ms = pts[pts.size() - 1] / 1000.0
		_phys_tick_samples_us.clear()
	else:
		host_physics_tick_p95_ms = 0.0
		host_physics_tick_p99_ms = 0.0
		host_physics_tick_max_ms = 0.0
	if not _bcast_interval_samples_us.is_empty():
		var bis := _bcast_interval_samples_us.duplicate()
		bis.sort()
		var b95_i: int = mini(int(bis.size() * 0.95), bis.size() - 1)
		broadcast_interval_p95_ms = bis[b95_i] / 1000.0
		_bcast_interval_samples_us.clear()
	else:
		broadcast_interval_p95_ms = 0.0
	_world_state_count = 0
	_input_count = 0
	_reconcile_count = 0
	_extrapolation_count = 0
	_reconcile_mag_sum = 0.0
	_reconcile_mag_n = 0
	_blade_jump_count = 0
	_blade_jump_mag_sum = 0.0
	_blade_jump_n = 0
	_blade_reconcile_mag_sum = 0.0
	_blade_reconcile_n = 0
	_prediction_divergence_sum = 0.0
	_prediction_divergence_n = 0
	_ooo_drop_count = 0
	_bytes_sent_window = 0
	_bytes_received_window = 0
	_puck_traj_soft_count = 0
	_puck_traj_vel_only_count = 0
	_puck_traj_hard_snap_count = 0
	_input_lead_sum = 0.0
	_input_lead_n = 0
	_starvation_count = 0
	_window_timer = 0.0
