class_name NetworkDebugOverlay
extends CanvasLayer

# F3 network debug overlay. Reads NetworkTelemetry + NetworkManager and renders a
# role-aware, color-coded health readout. Design notes:
#   • Each metric is colored green / yellow / red by comparing the live value to
#     the healthy ranges documented in network_telemetry.gd. The colored dot is
#     the at-a-glance "expected vs unexpected" signal the raw numbers never gave.
#   • The header verdict (OK / WATCH / PROBLEM) must mean "something is actually
#     WRONG" — so only ACTUAL-PROBLEM metrics drive it (via _metric). Connection
#     FACTS (ping, jitter, delay spread) are colored for context but verdict-
#     neutral (via _context): a far/jittery link is expected and compensated, so
#     it shows red on its own line while the header stays green. The real damage a
#     bad link does surfaces through its own driving metrics (loss, Guessing
#     ahead, Corrections). Glance at the header to know if anything's wrong.
#   • Every line carries an inline plain-English hint (what it means + the target
#     range) so the overlay is self-explanatory without a separate cheat sheet.
#   • Sections are gated by role (SOLO / HOST / CLIENT): a client never sees
#     host-frame stats that would read as misleading zeros, and vice-versa.
#   • "Watch" metrics (stick jumps, puck snaps, reorders, reconcile match) stay
#     hidden while healthy and surface only when they cross a threshold, so the
#     overlay stays calm until something actually needs attention. They are
#     calibrated to NOT fire on normal play (e.g. fast stickhandling is not a
#     "stick jump") — a visible flag means a real anomaly, not a false alarm.
# Thresholds below are derived from the "Expected ranges" comments in
# network_telemetry.gd — keep the two in sync if either moves.

enum Health { OK, WARN, BAD }

const COL_OK := "9ad27c"
const COL_WARN := "e6cf52"
const COL_BAD := "e87060"
const COL_HEAD := "8fb3d9"
const COL_DIM := "8a93a0"
const COL_VAL := "ececec"
const DOT := "●"

var _rt: RichTextLabel
var _panel: PanelContainer
var _showing: bool = false

# Felt-lag toast: a transient confirmation shown when a tester presses F4 to
# flag "this felt laggy." Rendered independently of the F3 panel (the panel may
# be hidden), so the layer stays visible and only the panel toggles.
var _toast: Label
var _toast_timer: float = 0.0
const TOAST_SECONDS: float = 2.0

# Always-on diagnostics row, top-right: [FPS: 144] [●]. The health dot is a
# small green/yellow/red ● live at all times so a tester sees link state without
# opening the F3 panel; the FPS readout (Options → Video → Show FPS) slots in to
# its LEFT so the two never overlap and the dot keeps one consistent corner spot
# whether or not FPS is shown. While the panel is closed the verdict is
# re-evaluated on a throttle (telemetry refreshes at 1 Hz, so 2 Hz keeps the dot
# current without per-frame string building); the row hides while the panel is
# open — they share the corner and the header carries the verdict.
var _diag_row: HBoxContainer
var _dot: Label
var _fps_label: Label
var _dot_timer: float = 0.0
const DOT_REFRESH_SECONDS: float = 0.5

# Frame-cost measurement (the "what is capping my FPS?" section). Splitting the
# frame into GPU / render-thread CPU / script time is the only way to tell a
# fill-rate problem from a draw-call problem from a per-tick simulation
# regression — they all present identically as "FPS dropped".
#
# viewport_set_measure_render_time inserts GPU timestamp queries around the
# viewport's passes, which is not free, so it is armed only while the F3 panel
# is open and disarmed on close (and on exit). The measured numbers cover the
# ROOT viewport; SubViewports (ice scratch map, jersey decals, jumbotron) are
# measured separately by the engine and are NOT included here — their cost
# still shows in the draw-call and primitive counts, which are engine-wide.
var _vp_rid: RID
var _measuring: bool = false
# Exponential moving averages — raw per-frame GPU/CPU times are far too noisy to
# read off a screen. The time constant is a readability choice: fast enough that
# toggling a video option shows its effect within a beat, slow enough that the
# digits hold still.
const FRAME_COST_EMA_TAU: float = 0.30
var _ema_gpu_ms: float = 0.0
var _ema_cpu_render_ms: float = 0.0
var _ema_process_ms: float = 0.0
var _ema_physics_ms: float = 0.0
var _ema_frame_ms: float = 0.0
# A term has to own this much of the frame before it is named as the bound. A
# frame is not a clean sum of its parts (GPU and CPU overlap by a frame, the
# render thread pipelines), so "the biggest term is 40% of the frame" means
# nothing is saturated — the cap is vsync or the FPS limiter.
const FRAME_COST_BOUND_FRACTION: float = 0.60

# Built fresh each frame: collected metric lines + the worst health seen, which
# rolls up into the header verdict.
var _lines: PackedStringArray = []
var _worst: Health = Health.OK

func _ready() -> void:
	layer = 100
	_vp_rid = get_viewport().get_viewport_rid()
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.position = Vector2(-8, 8)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.78)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8.0)
	_panel.add_theme_stylebox_override("panel", style)
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true
	_rt.fit_content = true
	_rt.scroll_active = false
	_rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rt.custom_minimum_size = Vector2(580, 0)
	_rt.add_theme_font_size_override("normal_font_size", 13)
	_rt.add_theme_font_size_override("bold_font_size", 13)
	_panel.add_child(_rt)
	add_child(_panel)
	_panel.hide()
	_build_toast()
	_build_diag_row()

func _build_diag_row() -> void:
	_diag_row = HBoxContainer.new()
	_diag_row.anchor_left = 1.0
	_diag_row.anchor_right = 1.0
	_diag_row.anchor_top = 0.0
	_diag_row.anchor_bottom = 0.0
	_diag_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_diag_row.position = Vector2(-8, 4)
	_diag_row.add_theme_constant_override("separation", 6)
	_diag_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_diag_row)

	_fps_label = Label.new()
	_fps_label.add_theme_font_override("font", MenuStyle.UI_FONT)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", MenuStyle.BROADCAST_CREAM)
	_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_fps_label.add_theme_constant_override("outline_size", 4)
	_fps_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_diag_row.add_child(_fps_label)
	_fps_label.hide()

	# Last child = rightmost slot, so the dot holds the same corner position
	# whether the FPS readout is on or off.
	_dot = Label.new()
	_dot.text = DOT
	_dot.add_theme_font_size_override("font_size", 18)
	_dot.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_dot.add_theme_constant_override("outline_size", 4)
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_diag_row.add_child(_dot)
	_dot.hide()

func _build_toast() -> void:
	_toast = Label.new()
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.anchor_top = 1.0
	_toast.anchor_bottom = 1.0
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.position = Vector2(0, -48)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", 15)
	_toast.add_theme_color_override("font_color", Color(0.60, 0.82, 0.49))
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_toast.add_theme_constant_override("outline_size", 4)
	add_child(_toast)
	_toast.hide()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F3:
		_showing = not _showing
		_panel.visible = _showing
		_set_measuring(_showing)
	elif event.keycode == KEY_F4:
		_log_felt_lag()
	elif event.keycode == KEY_C and _showing:
		# Only while the F3 panel is open, so a bare C keypress in gameplay
		# never gets swallowed here.
		_copy_session_digest()

# A tester pressing F4 flags "this felt laggy right now." We snapshot the most
# diagnostic LIVE values and append a marker to the session summary so the
# subjective moment lands in the same Supabase row as the objective numbers —
# the single best signal for "bad netcode experiences" that raw rates miss.
# The pre-history ring rides along: the press comes AFTER the felt moment, so
# the seconds leading up to it matter more than the instant of the press.
func _log_felt_lag() -> void:
	var t: NetworkTelemetry = NetworkTelemetry.instance
	if t == null or NetworkManager.is_offline_mode:
		return
	var snapshot: Dictionary = {
		"rtt_ms": NetworkManager.get_rtt_ms(),
		"packet_loss_pct": t.packet_loss_pct,
		"jitter_p95_ms": t.jitter_p95_ms,
		"reconcile_per_sec": t.reconcile_per_sec,
		"recon_pos_per_sec": t.recon_pos_per_sec,
		"recon_vel_per_sec": t.recon_vel_per_sec,
		"recon_ubody_per_sec": t.recon_ubody_per_sec,
		"extrapolation_per_sec": t.extrapolation_per_sec,
		"extrapolation_pct": t.extrapolation_pct,
		"client_fps": t.client_fps,
		"buffer_depth_skater": t.buffer_depth_skater,
		"buffer_depth_puck": t.buffer_depth_puck,
		"puck_mode": t.puck_mode,
	}
	t.session.record_felt_lag(float(t.session.seconds), snapshot, t.recent_samples())
	_toast.text = "✓ Lag report logged (#%d) — thanks!" % t.session.felt_lag_count
	_toast.show()
	_toast_timer = TOAST_SECONDS

# Copy the whole session's aggregates + markers to the clipboard as JSON — the
# self-serve paste unit for a bug report or an LLM diagnosis, no Supabase
# round-trip needed. Same payload shape the reporter POSTs (and dumps locally),
# so docs/telemetry_dictionary.md reads all three identically.
func _copy_session_digest() -> void:
	var t: NetworkTelemetry = NetworkTelemetry.instance
	if t == null:
		return
	var digest: Dictionary = {
		"game_version": BuildInfo.VERSION,
		"platform": OS.get_name(),
		"role": "host" if NetworkManager.is_host else "client",
		"net_sim_active": NetworkSimManager.enabled,
		"game_id": GameManager.get_game_id(),
		# Local frame cost rides along so a pasted digest can answer "GPU or CPU?"
		# on its own. Live EMAs, not session aggregates — the digest is copied from
		# the open panel, so they describe the moment the tester chose to capture.
		# Skater count makes the digest self-describing about roster size, which
		# every per-actor cost scales with.
		"frame_cost": {
			"skaters": get_tree().get_nodes_in_group("skaters").size(),
			"frame_ms": _ema_frame_ms,
			"gpu_ms": _ema_gpu_ms,
			"cpu_render_ms": _ema_cpu_render_ms,
			"process_ms": _ema_process_ms,
			"physics_ms": _ema_physics_ms,
			"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
			"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		},
		"metrics": t.session.to_dict(),
	}
	DisplayServer.clipboard_set(JSON.stringify(digest, "\t"))
	_toast.text = "✓ Session digest copied to clipboard"
	_toast.show()
	_toast_timer = TOAST_SECONDS

func _process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.hide()
	# FPS readout, gated by the Options → Video pref. Hidden while the F3 panel
	# is open (the panel owns the corner and reports Render FPS itself).
	var fps_on: bool = PlayerPrefs.show_fps and not _showing
	if _fps_label.visible != fps_on:
		_fps_label.visible = fps_on
	if fps_on:
		_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	# Panel open: rebuild every frame. Panel closed: still evaluate the verdict
	# (for the always-on dot) but only on a throttle, since the full-text build
	# isn't needed and telemetry only changes at 1 Hz.
	if _showing:
		_sample_frame_cost(delta)
		_refresh()
	else:
		_dot_timer -= delta
		if _dot_timer <= 0.0:
			_dot_timer = DOT_REFRESH_SECONDS
			_refresh()

# GPU timestamp queries cost something to collect, so the measurement only runs
# while someone is looking at the panel.
func _set_measuring(on: bool) -> void:
	if on == _measuring or not _vp_rid.is_valid():
		return
	_measuring = on
	RenderingServer.viewport_set_measure_render_time(_vp_rid, on)
	if not on:
		return
	# Start each arming from a clean slate — stale averages from the last time
	# the panel was open would blend into the first seconds of the new reading.
	_ema_gpu_ms = 0.0
	_ema_cpu_render_ms = 0.0
	_ema_process_ms = 0.0
	_ema_physics_ms = 0.0
	_ema_frame_ms = 0.0


func _exit_tree() -> void:
	_set_measuring(false)


func _sample_frame_cost(delta: float) -> void:
	if not _measuring:
		return
	# Frame-rate-independent EMA: a fixed per-frame weight would smooth over a
	# different real duration at 60 fps than at 240.
	var a: float = 1.0 - exp(-delta / FRAME_COST_EMA_TAU)
	_ema_gpu_ms = lerpf(_ema_gpu_ms,
			RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid), a)
	_ema_cpu_render_ms = lerpf(_ema_cpu_render_ms,
			RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid), a)
	_ema_process_ms = lerpf(_ema_process_ms,
			float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0, a)
	_ema_physics_ms = lerpf(_ema_physics_ms,
			float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0, a)
	_ema_frame_ms = lerpf(_ema_frame_ms, delta * 1000.0, a)


func _refresh() -> void:
	_lines.clear()
	_worst = Health.OK

	var t: NetworkTelemetry = NetworkTelemetry.instance
	if t == null:
		_dot.hide()
		if _showing:
			_rt.text = (
				"[b]Network Debug[/b]   [color=#%s](F3 to close)[/color]\n" % COL_DIM
				+ "[color=#%s]Not in a session — start a game to see live metrics.[/color]" % COL_DIM
			)
		return

	var role: String
	if NetworkManager.is_offline_mode:
		role = "SOLO (offline)"
		_render_solo(t)
	elif NetworkManager.is_host:
		role = "HOST"
		_render_host(t)
	else:
		role = "CLIENT"
		_render_client(t)

	if _showing:
		_render_frame_cost()

	# Verdict is known once all lines are collected; drive the always-on dot.
	# Hide it while the F3 panel is open — they share the top-right corner and the
	# panel header already carries the verdict.
	_dot.add_theme_color_override("font_color", Color("#" + _col(_worst)))
	_dot.visible = not _showing
	if not _showing:
		return

	# Header is built last so the verdict reflects the worst line above it.
	var verdict: String = ["● OK", "● WATCH", "● PROBLEM"][int(_worst)]
	var felt: String = ""
	if t.session.felt_lag_count > 0:
		felt = "   [color=#%s]%d lag report(s)[/color]" % [COL_WARN, t.session.felt_lag_count]
	var header := "[b]Network Debug[/b]   [color=#%s]%s[/color]   [color=#%s]%s[/color]%s   [color=#%s](F3 close · F4 report lag · C copy digest)[/color]" % [
		_col(_worst), verdict, COL_HEAD, role, felt, COL_DIM]
	_rt.text = header + "\n" + "\n".join(_lines)

# ── Role renderers ───────────────────────────────────────────────────────────

func _render_client(t: NetworkTelemetry) -> void:
	_section("Connection")
	var rtt_avg := NetworkManager.get_rtt_ms()
	var rtt_last := NetworkManager.get_latest_rtt_ms()
	if not NetworkManager.is_clock_ready():
		_metric(Health.WARN, "Ping (RTT)", "syncing clock…",
			"round-trip to host; waiting for the clock to lock in")
	else:
		_context(_band(rtt_avg, 80.0, 150.0), "Ping (RTT)", "%.0f ms avg, %.0f ms last" % [rtt_avg, rtt_last],
			"round-trip to host; <80 great, 80-150 playable, >150 laggy — distance, not a bug (doesn't flag the header)")
	var clock_offset := NetworkManager.get_clock_offset_ms()
	_info("Clock offset", ("%+.0f ms" % clock_offset), "your clock vs host's; just informational")
	_metric(_band(t.packet_loss_pct, 1.0, 5.0), "Packet loss", "%.1f%%" % t.packet_loss_pct,
		"dropped packets; <1% great, >5% causes rubber-banding")
	_context(_band(t.jitter_p95_ms, 8.0, 20.0), "Jitter", "%.1f ms" % t.jitter_p95_ms,
		"unevenness of packet ARRIVAL GAPS; the buffer absorbs it (real overruns show as Guessing ahead), so context only")
	var pdv := NetworkManager.get_packet_delay_spread_ms()
	_context(_band(pdv, 8.0, 20.0), "Delay spread", "%.1f ms (floor %.0f)" % [pdv, NetworkManager.get_packet_delay_floor_ms()],
		"jitter measured vs the host CLOCK, ignores clumping; if Jitter is high but this is low, packets are clumping, not the path being jittery")
	_info("Updates in", "%.0f/s" % t.world_state_hz, "world snapshots received; matches host send rate")
	_sim_line(t)

	# End-to-end latency decomposed into its named terms, so a netcode change
	# is judged by numbers instead of "does it feel snappier". All facts
	# (_info): each term is either by-design or already colored elsewhere.
	if NetworkManager.is_clock_ready():
		_section("Latency budget (action → screen)")
		var lead_ms := NetworkManager.INPUT_LEAD_SEC * 1000.0
		var interp_ms := NetworkManager.get_interpolation_delay() * 1000.0
		var bcast_ms := NetworkManager.state_delta * 1000.0
		_info("You → host sim", "%.0f ms" % lead_ms,
			"input stamp lead, by design — your input is scheduled this far ahead so it's on the host before its tick (transit rides inside the synced clock); host-side overdue shows on the host's Input lead line")
		_info("Host → your screen", "%.0f ms (½rtt %.0f · tick %.0f · cushion %.0f)" % [interp_ms, rtt_avg / 2.0, bcast_ms, pdv],
			"render age of the authoritative world (remote skaters, loose puck, goalie) — the live smoothing delay; decomposition shows its target terms")
		_info("Round trip you → you", "%.0f ms" % (lead_ms + interp_ms),
			"your action reaching the host + its authoritative result reaching your screen. Your own skater feels instant (prediction) — this is the staleness of the world you're reacting to")
	var rec := _worse(_band(t.reconcile_per_sec, 1.0, 5.0), _band(t.reconcile_magnitude_avg, 0.05, 0.2))
	_metric(rec, "Corrections", "%.1f/s, %.3f m avg" % [t.reconcile_per_sec, t.reconcile_magnitude_avg],
		"server snapping your prediction back; want <1/s and <5 cm")
	if t.reconcile_per_sec > 0.5:
		_info("Reconcile cause", "pos %.0f · vel %.0f · rot %.0f /s · off %+.1ft · resid %.0fcm" % [t.recon_pos_per_sec, t.recon_vel_per_sec, t.recon_ubody_per_sec, t.pos_offset_ticks_avg, t.post_replay_residual_avg * 100.0],
			"resid = distance from server AFTER the snap+replay. At rest it should be ~0; if resid stays ~9cm the replay isn't converging (offset rebuilds), vs ~0 = rebuild is in normal physics")
	_metric(_band(t.extrapolation_pct, 25.0, 60.0), "Guessing ahead", "%.0f%% of frames (%.0f fps)" % [t.extrapolation_pct, t.client_fps],
		"share of rendered frames dead-reckoning a remote past the buffer (framerate-independent). If high on a clumpy link, the jitter cushion is too thin — see Smoothing delay")
	_info("Puck mode", t.puck_mode, "predicted = shared-sim to present, predicted_seed = own release pre-confirm, predicted_hold = held at goalie, interp = stale-data fallback, carried = on a stick")
	_metric(_band(t.puck_predict_residual_avg_m * 100.0, 15.0, 50.0), "Puck predict err",
		"%.1f cm avg · %.0f cm peak" % [t.puck_predict_residual_avg_m * 100.0, t.puck_predict_residual_max_m * 100.0],
		"pre-damp error between the shared-sim prediction and the render; ~0 = agreeing, peaks = host events (deflects/saves) folding in")
	_metric(_band(t.remote_correction_avg_m * 100.0, 10.0, 30.0), "Remote predict err",
		"%.1f cm avg · %.0f cm peak" % [t.remote_correction_avg_m * 100.0, t.remote_correction_max_m * 100.0],
		"same pre-damp error on remote skater bodies; steady growth = intent decay / hard cuts outrunning the prediction")

	_section("Smoothing buffers")
	_info("Interp depth", "skater %d · puck %d · goalie %d" % [t.buffer_depth_skater, t.buffer_depth_puck, t.buffer_depth_goalie],
		"frames queued to smooth motion; ~2-4 healthy, 0-1 risks stutter")
	_info("Smoothing delay", "%.0f ms" % (NetworkManager.get_target_interpolation_delay() * 1000.0),
		"intentional delay to hide jitter; sized off Delay spread (de-clumped path jitter), grows with RTT. If Guessing ahead climbs, this is under-cushioning")
	if t.ws_gap_histogram != "—":
		_info("Packet spacing", t.ws_gap_histogram,
			"% of updates by gap (ms); steady ~8ms is smooth, split low+high = clumping")

	_info("Bandwidth", "%.1f KB/s down" % (t.bytes_received_per_sec / 1024.0),
		"game data received per second (payload only, excludes Steam framing)")

	_render_watch(t)

func _render_host(t: NetworkTelemetry) -> void:
	_section("Connection (you are the authority / clock)")
	var peers := NetworkManager.connected_peer_ids()
	if peers.is_empty():
		_info("Peers", "none connected", "no clients are joined yet")
	else:
		for pid: int in peers:
			var ping := NetworkManager.get_peer_ping_ms(pid)
			_context(_band(float(ping), 80.0, 150.0), NetworkManager.get_peer_name(pid),
				"%d ms" % ping, "this client's round-trip to you — distance, not a bug (doesn't flag the header)")
	_info("Snapshots out", "%.0f/s" % t.world_state_hz, "world states broadcast per tick (constant 120/s in every phase)")
	_sim_line(t)

	if not peers.is_empty():
		_section("Client input queue")
		_metric(_queue_health(t.input_queue_depth_median), "Queue depth", "%d frames" % t.input_queue_depth_median,
			"client inputs waiting to apply; ~1-3 healthy, 0 = starving, high = backed up")
		_metric(_band(t.input_lead_avg_ms, 10.0, 30.0), "Input lead", "%.1f ms" % t.input_lead_avg_ms,
			"how late inputs arrive vs schedule; want near 0")
		_metric(_band(t.input_starvations_per_sec, 0.5, 5.0), "Starvations", "%.1f/s" % t.input_starvations_per_sec,
			"ticks with no client input (reused last); want 0")
		_metric(_band(t.input_drains_per_sec, 0.5, 5.0), "Backlog drains", "%.1f/s" % t.input_drains_per_sec,
			"stale inputs dropped by the overdue drain; want 0, bursts after jitter are the fix working")

	_section("Host frame health")
	_frame_health(t)
	# Judge the gap against the live target interval (state_delta) rather than
	# a hardcoded 120Hz, so a future runtime rate change (congestion response)
	# doesn't read red by default. The per-phase dead-puck downshift is gone —
	# the rate is constant across stoppages now.
	var bcast_target_ms := NetworkManager.state_delta * 1000.0
	_metric(_band(t.broadcast_interval_p95_ms, bcast_target_ms * 1.4, bcast_target_ms * 2.0),
		"Broadcast gap", "p95 %.1f ms (target ~%.0f)" % [t.broadcast_interval_p95_ms, bcast_target_ms],
		"gap between snapshots vs the send-rate target; sustained high = host stalling or send path backed up")

	_info("Bandwidth", "%.1f KB/s up" % (t.bytes_sent_per_sec / 1024.0),
		"total game data sent to all clients (payload only, excludes Steam framing)")

func _render_solo(t: NetworkTelemetry) -> void:
	_info("Mode", "offline — no network", "metrics below reflect your local sim only")
	_sim_line(t)
	if t.host_effective_tick_hz > 0.0:
		_section("Frame health")
		_frame_health(t)

# Honest host-frame health. The raw gap between physics ticks is quantized onto render
# frames (steps run inside the main loop), so its percentiles read high even when the
# sim is perfectly real-time — at >tick-rate FPS the gap alternates 1-2 frames. So we
# report what actually matters: the effective rate (mean gap → Hz; "are we keeping
# real-time?") and the worst stall (max gap). What this pair CANNOT tell you is how
# EXPENSIVE the sim is: a tick that eats most of the frame budget still reports a
# perfect rate right up until it overruns. "Frame cost → Script" is that number.
func _frame_health(t: NetworkTelemetry) -> void:
	if t.host_effective_tick_hz <= 0.0:
		return
	var target_hz: int = Constants.PHYSICS_TICK
	var ratio: float = t.host_effective_tick_hz / float(target_hz)
	var sim_h: Health = Health.OK
	if ratio < 0.90:
		sim_h = Health.BAD
	elif ratio < 0.97:
		sim_h = Health.WARN
	_metric(sim_h, "Sim rate", "%.0f Hz (target %d)" % [t.host_effective_tick_hz, target_hz],
		"physics keeping real-time; well below target = host overloaded, sim runs slow-motion. Says nothing about tick COST — see Frame cost → Script")
	_metric(_band(t.host_physics_tick_max_ms, 33.0, 66.0), "Worst stall", "%.0f ms" % t.host_physics_tick_max_ms,
		"longest pause between ticks in the last second; ticks land on render frames so 1-2 frames' spacing is normal, but a big spike = a hitch everyone feels")

# Local frame cost — the answer to "why is my FPS down?", which the network
# metrics above cannot give. Three costs can independently cap the frame rate and
# they present identically as lost FPS:
#   • GPU        — pixels and shading. Moves with resolution, MSAA, shadow map
#                  count, transparent overdraw, post-processing.
#   • CPU render — the render thread turning the visible scene into draw
#                  commands. Moves with the NUMBER of visible mesh instances,
#                  not their size, and every shadow-casting light re-submits the
#                  casters in its range. A hundred small MeshInstance3Ds cost
#                  here, not on the GPU.
#   • Script     — _process + _physics_process on the main thread. At a 120 Hz
#                  sim, roughly one physics tick runs inside every rendered
#                  frame, so per-tick work is charged straight to frame time.
#                  Note this stays invisible to "Sim rate": the sim can hold a
#                  perfect 120 Hz while still eating half the frame budget.
# Verdict-neutral throughout (_context / _info) — the header verdict is about the
# NETWORK, and a GPU-bound frame is not a network problem.
func _render_frame_cost() -> void:
	_section("Frame cost (your machine)")
	if _ema_frame_ms <= 0.0:
		_info("Measuring", "…", "sampling starts when this panel opens; give it a second")
		return
	var frame_ms: float = _ema_frame_ms
	var script_ms: float = _ema_process_ms + _ema_physics_ms
	_info("Frame", "%.2f ms (%.0f fps)" % [frame_ms, 1000.0 / maxf(frame_ms, 0.001)],
		"wall-clock per rendered frame; the costs below are slices of it, and they overlap (GPU and CPU run a frame apart)")
	_context(_band(_frac(_ema_gpu_ms, frame_ms), 0.60, 0.85), "GPU",
		"%.2f ms (%.0f%% of frame)" % [_ema_gpu_ms, _frac(_ema_gpu_ms, frame_ms) * 100.0],
		"drawing cost — resolution, MSAA, shadow maps, transparent overdraw, post FX")
	_context(_band(_frac(_ema_cpu_render_ms, frame_ms), 0.60, 0.85), "CPU render",
		"%.2f ms (%.0f%% of frame)" % [_ema_cpu_render_ms, _frac(_ema_cpu_render_ms, frame_ms) * 100.0],
		"render thread building draw commands; scales with the draw-call count below, not with pixels")
	_context(_band(_frac(script_ms, frame_ms), 0.60, 0.85), "Script",
		"%.2f ms (process %.2f · physics %.2f)" % [script_ms, _ema_process_ms, _ema_physics_ms],
		"your _process + _physics_process; physics is per-tick work charged to the frame it ran in")
	_info("Scene", "%d draws · %d objects · %.1f M prims" % [
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1_000_000.0],
		"what the frame submits, engine-wide (includes shadow passes and every SubViewport); draw calls are the CPU render driver")
	_info("Skaters on ice", "%d" % get_tree().get_nodes_in_group("skaters").size(),
		"3v3 is 6, 5v5 is 10 — the multiplier on every per-skater mesh, particle system and shadow caster")
	_info("Bound by", _frame_bound_verdict(frame_ms, script_ms),
		"the cost that is actually capping the frame rate — optimize this one, the others are free wins on paper only")


# Names the cost that owns the frame, or says nothing does. A frame is not a sum
# of its parts (the render thread pipelines a frame behind, GPU overlaps CPU), so
# a term has to clear FRAME_COST_BOUND_FRACTION before it can be called the
# bound. Below that the frame is idle-waiting and the ceiling is vsync or the FPS
# cap — reporting a "bound" there would send tuning after the wrong number.
func _frame_bound_verdict(frame_ms: float, script_ms: float) -> String:
	var worst: float = maxf(_ema_gpu_ms, maxf(_ema_cpu_render_ms, script_ms))
	if worst < frame_ms * FRAME_COST_BOUND_FRACTION:
		var cap: String = "vsync" if DisplayServer.window_get_vsync_mode() \
				!= DisplayServer.VSYNC_DISABLED else "the FPS cap"
		if Engine.max_fps > 0 and 1000.0 / maxf(frame_ms, 0.001) >= float(Engine.max_fps) * 0.95:
			cap = "the %d fps cap" % Engine.max_fps
		return "nothing is saturated — waiting on %s, or on main-thread work outside _process" % cap
	if is_equal_approx(worst, _ema_gpu_ms):
		return "GPU — cut resolution / MSAA / shadow-casting lights / transparent overdraw"
	if is_equal_approx(worst, _ema_cpu_render_ms):
		return "CPU render — cut VISIBLE MESH COUNT (draws), not polygons; shadow-casting lights multiply it"
	return "Script — per-tick simulation cost; profile _physics_process"


func _frac(part: float, whole: float) -> float:
	return part / maxf(whole, 0.001)


# Watch metrics: shown only when they leave the healthy band, so the client view
# stays quiet until something is actually wrong. When all clear, one calm line.
func _render_watch(t: NetworkTelemetry) -> void:
	var any := false
	any = _watch(_when_positive(t.blade_jump_per_sec, 10.0), "Stick jumps", "%.1f/s (%.2f m avg)" % [t.blade_jump_per_sec, t.blade_jump_mag_avg],
		"a reconcile teleported the blade >5 cm; want 0 (normal fast stickhandling no longer counts)") or any
	any = _watch(_band(t.puck_hard_snap_per_sec, 2.0, 10.0), "Puck hard-snaps", "%.1f/s" % t.puck_hard_snap_per_sec,
		"a moving puck's render teleported; genuine prediction divergence only — want ~0") or any
	any = _watch(_band(t.ooo_drops_per_sec, 2.0, 10.0), "Out-of-order drops", "%.1f/s" % t.ooo_drops_per_sec,
		"packets arrived reordered and were discarded; occasional is normal UDP, a steady stream is a problem") or any
	any = _watch(_band(100.0 - t.reconcile_match_pct, 5.0, 30.0), "Reconcile match", "%.0f%% matched" % t.reconcile_match_pct,
		"client found its prediction for the server's ack timestamp; <100% = find_at missing, so it reconciles on lag not real error") or any
	if not any:
		_lines.append("[color=#%s]%s Internals nominal[/color] [color=#%s](stick jumps, puck snaps, reorders, reconcile match all healthy)[/color]" % [
			COL_OK, DOT, COL_DIM])

# ── Line builders ────────────────────────────────────────────────────────────

func _section(title: String) -> void:
	_lines.append("[color=#%s]── %s ──[/color]" % [COL_HEAD, title])

func _metric(h: Health, label: String, value: String, hint: String) -> void:
	if int(h) > int(_worst):
		_worst = h
	_lines.append("[color=#%s]%s[/color] %s: [color=#%s]%s[/color]  [color=#%s]%s[/color]" % [
		_col(h), DOT, label, COL_VAL, value, COL_DIM, hint])

# Like _metric but VERDICT-NEUTRAL: colors the line so you can read link quality
# at a glance, but never escalates the header. For connection FACTS (ping,
# jitter, delay spread) — a far or jittery link is expected and the netcode
# compensates for it, so it must not make the header read PROBLEM. The actual
# problems a bad link can cause surface through their own verdict-driving
# metrics: loss (rubber-banding), Guessing ahead (buffer overrun), Corrections.
func _context(h: Health, label: String, value: String, hint: String) -> void:
	_lines.append("[color=#%s]%s[/color] %s: [color=#%s]%s[/color]  [color=#%s]%s[/color]" % [
		_col(h), DOT, label, COL_VAL, value, COL_DIM, hint])

func _info(label: String, value: String, hint: String) -> void:
	_lines.append("[color=#%s]·[/color] %s: [color=#%s]%s[/color]  [color=#%s]%s[/color]" % [
		COL_DIM, label, COL_VAL, value, COL_DIM, hint])

# Appends a metric only if it's not healthy; returns whether it was shown.
func _watch(h: Health, label: String, value: String, hint: String) -> bool:
	if h == Health.OK:
		return false
	_metric(h, label, value, hint)
	return true

func _sim_line(_t: NetworkTelemetry) -> void:
	if NetworkSimManager.enabled:
		var rtt_est: float = NetworkSimManager.delay_ms * 2.0
		var jitter_max: float = NetworkSimManager.jitter_ms * 2.0
		_lines.append("[color=#%s]%s[/color] Sim: [color=#%s]preset %d — ~%.0fms RTT, +0-%.0fms jitter, %.0f%% loss[/color]  [color=#%s]artificial lag is ON (keys 0-6)[/color]" % [
			COL_WARN, DOT, COL_VAL, NetworkSimManager.current_preset, rtt_est, jitter_max, NetworkSimManager.loss_pct, COL_DIM])
	elif BuildInfo.VERSION == "dev":
		_info("Sim", "off", "press keys 0-6 to inject fake lag for testing")

# ── Health helpers ───────────────────────────────────────────────────────────

# Higher value is worse (the common case).
func _band(value: float, warn: float, bad: float) -> Health:
	if value >= bad:
		return Health.BAD
	if value >= warn:
		return Health.WARN
	return Health.OK

# Anything above zero is a yellow flag; past `bad` it's red.
func _when_positive(value: float, bad: float) -> Health:
	if value >= bad:
		return Health.BAD
	if value > 0.0:
		return Health.WARN
	return Health.OK

# Input queue: starving (0) and backed up (high) are both bad; ~1-3 is healthy.
func _queue_health(depth: int) -> Health:
	if depth == 0 or depth > 12:
		return Health.BAD
	if depth > 6:
		return Health.WARN
	return Health.OK

func _worse(a: Health, b: Health) -> Health:
	return a if int(a) >= int(b) else b

func _col(h: Health) -> String:
	match h:
		Health.OK:
			return COL_OK
		Health.WARN:
			return COL_WARN
		_:
			return COL_BAD
