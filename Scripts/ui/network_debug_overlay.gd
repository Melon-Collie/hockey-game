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

# Built fresh each frame: collected metric lines + the worst health seen, which
# rolls up into the header verdict.
var _lines: PackedStringArray = []
var _worst: Health = Health.OK

func _ready() -> void:
	layer = 100
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
	elif event.keycode == KEY_F4:
		_log_felt_lag()

# A tester pressing F4 flags "this felt laggy right now." We snapshot the most
# diagnostic LIVE values and append a marker to the session summary so the
# subjective moment lands in the same Supabase row as the objective numbers —
# the single best signal for "bad netcode experiences" that raw rates miss.
func _log_felt_lag() -> void:
	var t: NetworkTelemetry = NetworkTelemetry.instance
	if t == null or NetworkManager.is_offline_mode:
		return
	var snapshot: Dictionary = {
		"rtt_ms": NetworkManager.get_rtt_ms(),
		"packet_loss_pct": t.packet_loss_pct,
		"jitter_p95_ms": t.jitter_p95_ms,
		"reconcile_per_sec": t.reconcile_per_sec,
		"extrapolation_per_sec": t.extrapolation_per_sec,
		"buffer_depth_skater": t.buffer_depth_skater,
		"buffer_depth_puck": t.buffer_depth_puck,
		"puck_mode": t.puck_mode,
	}
	t.session.record_felt_lag(float(t.session.seconds), snapshot)
	_toast.text = "✓ Lag report logged (#%d) — thanks!" % t.session.felt_lag_count
	_toast.show()
	_toast_timer = TOAST_SECONDS

func _process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.hide()
	if not _showing:
		return
	_lines.clear()
	_worst = Health.OK

	var t: NetworkTelemetry = NetworkTelemetry.instance
	if t == null:
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

	# Header is built last so the verdict reflects the worst line above it.
	var verdict: String = ["● OK", "● WATCH", "● PROBLEM"][int(_worst)]
	var felt: String = ""
	if t.session.felt_lag_count > 0:
		felt = "   [color=#%s]%d lag report(s)[/color]" % [COL_WARN, t.session.felt_lag_count]
	var header := "[b]Network Debug[/b]   [color=#%s]%s[/color]   [color=#%s]%s[/color]%s   [color=#%s](F3 close · F4 report lag)[/color]" % [
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
	var offset := NetworkManager.get_clock_offset_ms()
	_info("Clock offset", ("%+.0f ms" % offset), "your clock vs host's; just informational")
	_metric(_band(t.packet_loss_pct, 1.0, 5.0), "Packet loss", "%.1f%%" % t.packet_loss_pct,
		"dropped packets; <1% great, >5% causes rubber-banding")
	_context(_band(t.jitter_p95_ms, 8.0, 20.0), "Jitter", "%.1f ms" % t.jitter_p95_ms,
		"unevenness of packet ARRIVAL GAPS; the buffer absorbs it (real overruns show as Guessing ahead), so context only")
	var pdv := NetworkManager.get_packet_delay_spread_ms()
	_context(_band(pdv, 8.0, 20.0), "Delay spread", "%.1f ms (floor %.0f)" % [pdv, NetworkManager.get_packet_delay_floor_ms()],
		"jitter measured vs the host CLOCK, ignores clumping; if Jitter is high but this is low, packets are clumping, not the path being jittery")
	_info("Updates in", "%.0f/s" % t.world_state_hz, "world snapshots received; matches host send rate")
	_sim_line(t)

	_section("Prediction (your view of remote players & puck)")
	var rec := _worse(_band(t.reconcile_per_sec, 1.0, 5.0), _band(t.reconcile_magnitude_avg, 0.05, 0.2))
	_metric(rec, "Corrections", "%.1f/s, %.3f m avg" % [t.reconcile_per_sec, t.reconcile_magnitude_avg],
		"server snapping your prediction back; want <1/s and <5 cm")
	if t.reconcile_per_sec > 0.5:
		_info("Reconcile cause", "pos %.0f · vel %.0f · rot %.0f /s · off %+.1ft · resid %.0fcm" % [t.recon_pos_per_sec, t.recon_vel_per_sec, t.recon_ubody_per_sec, t.pos_offset_ticks_avg, t.post_replay_residual_avg * 100.0],
			"resid = distance from server AFTER the snap+replay. At rest it should be ~0; if resid stays ~9cm the replay isn't converging (offset rebuilds), vs ~0 = rebuild is in normal physics")
	_metric(_band(t.extrapolation_per_sec, 1.0, 5.0), "Guessing ahead", "%.1f/s" % t.extrapolation_per_sec,
		"frames guessed past the buffer; want <1/s. If this climbs on a clumpy link, the jitter cushion is too thin — see Smoothing delay")
	_info("Puck mode", t.puck_mode, "interp = smoothed, trajectory = predicted flight, carried = on a stick")

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
	_info("Snapshots out", "%.0f/s" % t.world_state_hz, "world states broadcast per tick (varies by phase)")
	_sim_line(t)

	if not peers.is_empty():
		_section("Client input queue")
		_metric(_queue_health(t.input_queue_depth_median), "Queue depth", "%d frames" % t.input_queue_depth_median,
			"client inputs waiting to apply; ~1-3 healthy, 0 = starving, high = backed up")
		_metric(_band(t.input_lead_avg_ms, 10.0, 30.0), "Input lead", "%.1f ms" % t.input_lead_avg_ms,
			"how late inputs arrive vs schedule; want near 0")
		_metric(_band(t.input_starvations_per_sec, 0.5, 5.0), "Starvations", "%.1f/s" % t.input_starvations_per_sec,
			"ticks with no client input (reused last); want 0")

	_section("Host frame health")
	_frame_health(t)
	# The host throttles the broadcast rate to 5Hz during dead-puck phases
	# (faceoff prep, goal, period breaks), so judge the gap against the live
	# target interval rather than a fixed 120Hz, or every stoppage reads red.
	var bcast_target_ms := NetworkManager.state_delta * 1000.0
	_metric(_band(t.broadcast_interval_p95_ms, bcast_target_ms * 1.4, bcast_target_ms * 2.0),
		"Broadcast gap", "p95 %.1f ms (target ~%.0f)" % [t.broadcast_interval_p95_ms, bcast_target_ms],
		"gap between snapshots; tracks the current send rate, which drops to 5Hz during stoppages")

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
# real-time?"), the worst stall (max gap), and render FPS for context.
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
		"physics keeping real-time; well below target = host overloaded, sim runs slow-motion")
	_info("Render FPS", "%d" % int(Engine.get_frames_per_second()),
		"your draw rate; physics ticks land on render frames, so a tick spacing of 1-2 frames is normal")
	_metric(_band(t.host_physics_tick_max_ms, 33.0, 66.0), "Worst stall", "%.0f ms" % t.host_physics_tick_max_ms,
		"longest pause between ticks in the last second; under ~33ms is fine, a big spike = a hitch everyone feels")

# Watch metrics: shown only when they leave the healthy band, so the client view
# stays quiet until something is actually wrong. When all clear, one calm line.
func _render_watch(t: NetworkTelemetry) -> void:
	var any := false
	any = _watch(_when_positive(t.blade_jump_per_sec, 10.0), "Stick jumps", "%.1f/s (%.2f m avg)" % [t.blade_jump_per_sec, t.blade_jump_mag_avg],
		"a reconcile teleported the blade >5 cm; want 0 (normal fast stickhandling no longer counts)") or any
	any = _watch(_band(t.puck_traj_hard_snap_per_sec, 2.0, 10.0), "Puck hard-snaps", "%.1f/s" % t.puck_traj_hard_snap_per_sec,
		"puck flight snapped hard; expected only on real bounces, not every shot") or any
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
