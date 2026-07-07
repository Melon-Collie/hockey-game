class_name NetworkTelemetry
extends RefCounted

# Owned by GameManager. Created at world spawn, freed on scene exit.
# Call sites use static methods so they're null-safe outside a game session.
static var instance: NetworkTelemetry = null

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")

# Session-long aggregation of the per-second metrics below, folded once per 1 s
# window in tick(). Read by NetworkSessionReporter at game-over. Fresh per
# session (NetworkTelemetry itself is rebuilt each world spawn).
var session := NetworkSessionSummary.new()
# Live connection facts the overlay reads from NetworkManager directly but that
# aren't pushed through the static record_* path. GameManager refreshes these
# each frame so the session fold can sample them at window rollover.
var current_rtt_ms: float = 0.0
var current_peer_count: int = 0

# ── Window counters (reset each second) ──────────────────────────────────────
var _world_state_count: int = 0
var _input_count: int = 0
var _reconcile_count: int = 0
var _extrapolation_count: int = 0
# Frames observed this window (one per observe_actors call = one per rendered
# frame). Denominator for the framerate-INDEPENDENT extrapolation fraction:
# _extrapolation_count is sampled once per rendered frame, so its raw per-sec
# rate scales with the client's fps (a 240fps client counts 4x a 60fps client
# for the same buffer health). extrapolation_pct normalizes that out.
var _frame_count: int = 0
var _reconcile_mag_sum: float = 0.0
var _reconcile_mag_n: int = 0
var _reconcile_lookup_count: int = 0
var _reconcile_match_count: int = 0
var _recon_pos_trips: int = 0
var _recon_vel_trips: int = 0
var _recon_ubody_trips: int = 0
var _pos_offset_ticks_sum: float = 0.0
var _pos_offset_ticks_n: int = 0
var _post_replay_residual_sum: float = 0.0
var _post_replay_residual_n: int = 0
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
# the value reflects payload bytes only (excludes the Steam transport + UDP/IP
# framing, and SDR relay overhead when not directly connected — none of which is
# visible from inside the engine).
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
# Fraction of reconcile lookups that found the client's own prediction for the
# server's ack timestamp. <100% = find_at missing, so reconcile falls back to
# live-vs-server (which includes prediction lead) and fires false corrections —
# the single most diagnostic number for "why am I reconciling on a clean LAN."
var reconcile_match_pct: float = 100.0
# Per-channel reconcile trip rates (Hz): which threshold fired the snap. At rest,
# pos/vel are ~0, so a non-zero rot rate isolates pose/aim (upper-body)
# divergence as the reconcile trigger rather than a position desync.
var recon_pos_per_sec: float = 0.0
var recon_vel_per_sec: float = 0.0
var recon_ubody_per_sec: float = 0.0
# Same-timestamp position offset in units of one tick of travel, signed by
# lead(+)/lag(-) along velocity. ~+/-1.0 = a clean one-tick capture/integration
# phase mismatch; near 0 or noisy = something else.
var pos_offset_ticks_avg: float = 0.0
# Distance from the server AFTER snap+replay (m). ~0 = the snap converged; a
# persistent value = the replay leaves the body off-server (offset rebuilds).
var post_replay_residual_avg: float = 0.0
var extrapolation_per_sec: float = 0.0   # bracket extrapolation count; expect <1/s. RAW rate — scales with fps.
# Framerate-independent version of the above: what SHARE of rendered frames were
# dead-reckoning a remote entity past its buffer. Comparable across machines with
# different render rates (extrapolation_per_sec is not — see _frame_count). This
# is the honest "how dry is the remote buffer" signal.
var extrapolation_pct: float = 0.0       # 0..100
# Effective client render rate (frames observed / window). Surfaces the framerate
# that otherwise silently confounds every per-frame-sampled rate here
# (extrapolation, reconcile). Lower is worse for felt smoothness.
var client_fps: float = 0.0
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
# receive volume. Payload bytes only — Steam transport + UDP/IP framing (plus
# SDR relay overhead when not directly connected) add to this on the wire beyond
# what we count here. Goalie overhaul target: snapshot stays under 500 B/tick at
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
# World-state inter-arrival gap histogram (client-only; empty on host). Buckets
# in ms by upper edge; the published string is percentages per bucket over the
# 1s window. Bimodal (mass in <4ms AND >12ms, little at 8ms) = Steam Nagle
# clumping → no_nagle should flatten it. A spread centred on ~8ms = path/relay
# jitter that only a deeper interpolation buffer can absorb.
const WS_GAP_EDGES_MS: Array[float] = [4.0, 8.0, 12.0, 16.0, 24.0]
const WS_GAP_LABELS: Array[String] = ["<4", "4-8", "8-12", "12-16", "16-24", "24+"]
var _ws_gap_counts: Array[int] = [0, 0, 0, 0, 0, 0]
var ws_gap_histogram: String = "—"

# ── Host-frame health (host only; clients leave these at 0) ──────────────────
# Inter-tick gap. The MEAN gap gives the effective tick rate (`host_effective_tick_hz`):
# ≈ the target tick rate means physics is keeping real-time; well below means the host
# is overloaded and the sim is dilating (slow-motion). The MAX gap is the worst stall
# (CPU steal, GC pause, OS hitch). Note the gap does NOT sit at a clean 1/tick_rate:
# physics steps run inside the main loop, so consecutive ticks are quantized to whole
# render frames — at a render FPS above the tick rate the per-tick gap alternates 1-2
# frames, which is exactly why we report the mean (rate) and max (stall), not raw
# percentiles of the gap. Broadcast interval is wall-clock between `_broadcast_state()`.
var host_effective_tick_hz: float = 0.0    # mean inter-tick rate; ≈ target = real-time, below = dilating
var host_physics_tick_max_ms: float = 0.0  # worst inter-tick gap in the window = worst stall
var broadcast_interval_p95_ms: float = 0.0
var _phys_tick_samples_us: Array[int] = []
var _bcast_interval_samples_us: Array[int] = []
const PHYS_TICK_WINDOW: int = _PhysicsConstants.PHYSICS_TICK   # 1 s of samples
const BCAST_INTERVAL_WINDOW: int = 120  # 1s at 120Hz

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

const QUEUE_DEPTH_WINDOW: int = 240  # 2 s at the 120 Hz broadcast rate

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

# Bucket one world-state inter-arrival gap (ms) into the histogram window.
static func record_ws_arrival_gap(gap_ms: float) -> void:
	if instance == null:
		return
	var idx: int = WS_GAP_EDGES_MS.size()  # overflow (last) bucket
	for i: int in WS_GAP_EDGES_MS.size():
		if gap_ms < WS_GAP_EDGES_MS[i]:
			idx = i
			break
	instance._ws_gap_counts[idx] += 1

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

# blade_jump: a reconcile teleported the blade > 5 cm (a real visible pop).
# Recorded ONLY from the reconcile path now — the old per-tick live check also
# fired here, but normal fast stickhandling legitimately moves the blade > 5 cm
# in a 8.3ms tick (= 6 m/s), so it flagged "stick jumps" during ordinary play.
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

# prediction_divergence: distance from the server's last known position measured
# before the input replay, each time a reconcile fires. NOTE this is the natural
# prediction LEAD (grows with RTT × speed) — NOT a non-determinism signal — so it
# is no longer surfaced as a health flag on F3 (it cried wolf at speed). Kept as a
# raw diagnostic; the real divergence signal is reconcile_per_sec + magnitude.
static func record_prediction_divergence(meters: float) -> void:
	if instance == null:
		return
	instance._prediction_divergence_sum += meters
	instance._prediction_divergence_n += 1

# Whether a reconcile's find_at located a prediction snapshot for the ack ts.
static func record_reconcile_match(matched: bool) -> void:
	if instance == null:
		return
	instance._reconcile_lookup_count += 1
	if matched:
		instance._reconcile_match_count += 1

# Which reconcile channel(s) tripped the snap this time (diagnostic attribution).
static func record_reconcile_cause(pos: bool, vel: bool, ubody: bool) -> void:
	if instance == null:
		return
	if pos:
		instance._recon_pos_trips += 1
	if vel:
		instance._recon_vel_trips += 1
	if ubody:
		instance._recon_ubody_trips += 1

# Signed same-timestamp position offset, in units of one tick of travel.
static func record_pos_offset_ticks(ticks: float) -> void:
	if instance == null:
		return
	instance._pos_offset_ticks_sum += ticks
	instance._pos_offset_ticks_n += 1

# Distance from server after the reconcile's snap+replay completes (meters).
static func record_post_replay_residual(meters: float) -> void:
	if instance == null:
		return
	instance._post_replay_residual_sum += meters
	instance._post_replay_residual_n += 1

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
# host. Should track the ~8.3ms (120Hz) physics-driven cadence.
static func record_broadcast_interval_us(us: int) -> void:
	if instance == null:
		return
	instance._bcast_interval_samples_us.append(us)
	if instance._bcast_interval_samples_us.size() > BCAST_INTERVAL_WINDOW:
		instance._bcast_interval_samples_us.pop_front()

# Nearest-rank percentile index into a sorted-ascending array of size n.
# int(n*p) over-shoots (e.g. n=40, p=0.95 -> index 38 ~ p97.5); ceil(n*p)-1 is
# the correct 0-based nearest-rank index (-> 37 = true p95). Callers guard n>0.
static func percentile_index(n: int, p: float) -> int:
	return clampi(int(ceil(n * p)) - 1, 0, n - 1)


func observe_actors(skater_buf: int, puck_buf: int, goalie_buf: int, extrapolating: bool) -> void:
	buffer_depth_skater = skater_buf
	buffer_depth_puck = puck_buf
	buffer_depth_goalie = goalie_buf
	_frame_count += 1
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
	client_fps = _frame_count / _window_timer
	extrapolation_pct = (100.0 * _extrapolation_count / _frame_count) if _frame_count > 0 else 0.0
	reconcile_magnitude_avg = _reconcile_mag_sum / _reconcile_mag_n if _reconcile_mag_n > 0 else 0.0
	reconcile_match_pct = (100.0 * _reconcile_match_count / _reconcile_lookup_count) if _reconcile_lookup_count > 0 else 100.0
	recon_pos_per_sec = _recon_pos_trips / _window_timer
	recon_vel_per_sec = _recon_vel_trips / _window_timer
	recon_ubody_per_sec = _recon_ubody_trips / _window_timer
	pos_offset_ticks_avg = _pos_offset_ticks_sum / _pos_offset_ticks_n if _pos_offset_ticks_n > 0 else 0.0
	post_replay_residual_avg = _post_replay_residual_sum / _post_replay_residual_n if _post_replay_residual_n > 0 else 0.0
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
	var gap_total: int = 0
	for c: int in _ws_gap_counts:
		gap_total += c
	if gap_total > 0:
		var parts: Array[String] = []
		for i: int in _ws_gap_counts.size():
			parts.append("%s:%d%%" % [WS_GAP_LABELS[i], roundi(100.0 * _ws_gap_counts[i] / gap_total)])
		ws_gap_histogram = " ".join(parts)
	for i: int in _ws_gap_counts.size():
		_ws_gap_counts[i] = 0
	if not _phys_tick_samples_us.is_empty():
		# Mean → effective rate (the real "are we keeping real-time?" signal);
		# max → worst stall. Single pass, no sort needed.
		var sum_us: int = 0
		var max_us: int = 0
		for s: int in _phys_tick_samples_us:
			sum_us += s
			if s > max_us:
				max_us = s
		var mean_us: float = float(sum_us) / _phys_tick_samples_us.size()
		host_effective_tick_hz = (1000000.0 / mean_us) if mean_us > 0.0 else 0.0
		host_physics_tick_max_ms = max_us / 1000.0
		_phys_tick_samples_us.clear()
	else:
		host_effective_tick_hz = 0.0
		host_physics_tick_max_ms = 0.0
	if not _bcast_interval_samples_us.is_empty():
		var bis := _bcast_interval_samples_us.duplicate()
		bis.sort()
		var b95_i: int = percentile_index(bis.size(), 0.95)
		broadcast_interval_p95_ms = bis[b95_i] / 1000.0
		_bcast_interval_samples_us.clear()
	else:
		broadcast_interval_p95_ms = 0.0
	_fold_session_sample()
	_world_state_count = 0
	_input_count = 0
	_reconcile_count = 0
	_extrapolation_count = 0
	_frame_count = 0
	_reconcile_mag_sum = 0.0
	_reconcile_mag_n = 0
	_reconcile_lookup_count = 0
	_reconcile_match_count = 0
	_recon_pos_trips = 0
	_recon_vel_trips = 0
	_recon_ubody_trips = 0
	_pos_offset_ticks_sum = 0.0
	_pos_offset_ticks_n = 0
	_post_replay_residual_sum = 0.0
	_post_replay_residual_n = 0
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

# Fold this window's published metrics into the session summary. Keys here are
# the column prefixes the network_sessions table expects (see
# network_session_summary.gd). Role-degenerate metrics (e.g. loss/jitter on a
# host, reconciles on a host) fold as their natural 0/100 — the row's `role`
# disambiguates them at query time. sim_rate is the one exception: it's only
# meaningful when ticks were sampled (host/solo), so a client's structural 0 is
# omitted to keep its session-min honest.
func _fold_session_sample() -> void:
	var sample: Dictionary = {
		"rtt_ms": current_rtt_ms,
		"packet_loss_pct": packet_loss_pct,
		"jitter_p95_ms": jitter_p95_ms,
		"reconcile_per_sec": reconcile_per_sec,
		"reconcile_mag_m": reconcile_magnitude_avg,
		"reconcile_match_pct": reconcile_match_pct,
		"extrapolation_per_sec": extrapolation_per_sec,
		"extrapolation_pct": extrapolation_pct,
		"client_fps": client_fps,
		"ooo_drops_per_sec": ooo_drops_per_sec,
		"bytes_recv_per_sec": bytes_received_per_sec,
		"bytes_sent_per_sec": bytes_sent_per_sec,
		"input_starvations_per_sec": input_starvations_per_sec,
		"input_queue_depth": float(input_queue_depth_median),
		"input_lead_ms": input_lead_avg_ms,
		"worst_stall_ms": host_physics_tick_max_ms,
		"peer_count": float(current_peer_count),
	}
	if host_effective_tick_hz > 0.0:
		sample["sim_rate_hz"] = host_effective_tick_hz
	session.observe(sample)
