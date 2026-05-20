class_name NetworkDebugOverlay
extends CanvasLayer

var _label: Label
var _showing: bool = false

func _ready() -> void:
	layer = 100
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.position = Vector2(-8, 8)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.72)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8.0)
	panel.add_theme_stylebox_override("panel", style)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1.0))
	panel.add_child(_label)
	add_child(panel)
	hide()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_F3 and event.pressed and not event.echo:
		_showing = not _showing
		visible = _showing

func _process(_delta: float) -> void:
	if not _showing or NetworkTelemetry.instance == null:
		return
	var t: NetworkTelemetry = NetworkTelemetry.instance
	var sim_label: String
	if NetworkSimManager.enabled:
		var rtt_est: float = NetworkSimManager.delay_ms * 2.0
		var jitter_max: float = NetworkSimManager.jitter_ms * 2.0
		sim_label = "preset %d  (~%.0fms RTT  +0-%.0fms jitter  %.0f%% loss)" % [
			NetworkSimManager.current_preset,
			rtt_est,
			jitter_max,
			NetworkSimManager.loss_pct,
		]
	else:
		sim_label = "off  (keys 0-6 to set preset)"
	var rtt_avg: float = NetworkManager.get_rtt_ms()
	var rtt_last: float = NetworkManager.get_latest_rtt_ms()
	var offset_ms: float = NetworkManager.get_clock_offset_ms()
	var clock_suffix: String = "" if NetworkManager.is_clock_ready() else " (syncing)"
	var offset_str: String = ("+%.0f ms" % offset_ms) if offset_ms >= 0.0 else ("%.0f ms" % offset_ms)
	_label.text = (
		"-- Net Debug (F3 to close) ------\n"
		+ "RTT:       avg %.0f ms   last %.0f ms   offset: %s%s\n" % [rtt_avg, rtt_last, offset_str, clock_suffix]
		+ "Sim:       %s\n" % sim_label
		+ "Reconcile: %.1f/s   avg %.3f m\n" % [t.reconcile_per_sec, t.reconcile_magnitude_avg]
		+ "Extrap:    %.1f/s   buf: skater=%d  puck=%d  goalie=%d\n" % [t.extrapolation_per_sec, t.buffer_depth_skater, t.buffer_depth_puck, t.buffer_depth_goalie]
		+ "Puck:      %s\n" % t.puck_mode
		+ "Queue:     %d frames (2s median)   loss: %.1f%%\n" % [t.input_queue_depth_median, t.packet_loss_pct]
		+ "InBuf:     lead %.1f ms   starved %.0f/s\n" % [t.input_lead_avg_ms, t.input_starvations_per_sec]
		+ "Host:      tick p95 %.1f / p99 %.1f / max %.1f ms   bcast p95 %.1f ms\n" % [t.host_physics_tick_p95_ms, t.host_physics_tick_p99_ms, t.host_physics_tick_max_ms, t.broadcast_interval_p95_ms]
		+ "Jitter P95: %.1f ms   interp delay: %.0f ms" % [t.jitter_p95_ms, NetworkManager.get_target_interpolation_delay() * 1000.0]
	)
