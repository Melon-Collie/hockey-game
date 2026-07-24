class_name PostGameAnalytics
extends CanvasLayer

# Post-game analytics screen (analytics plan §7.1) — the three views, all reading
# the SAME per-game data the sim recorded, so a number and its dot on the map can
# never disagree:
#   1. Team shot map — every attempt plotted at its release point, dot size = xG,
#      goals ringed. Position + team colour is the differential read.
#   2. Tale of the tape — head-to-head bars, the advanced rows (Corsi / Fenwick /
#      xG) tagged as the ones no other hockey game shows.
#   3. Expected-goals flow — cumulative xGF over the game clock, goals marked.
#
# Data is entirely LOCAL: GameManager.get_shot_events() (the host's buffer, or a
# client's pushed copy) plus the broadcast PlayerStats counters. No Supabase, no
# online gate — so this works in offline / Play-vs-Bots exactly as it does online,
# which is where it gets playtested.
#
# Rendered on its own layer above GameOverPopup (which stays the "moment" screen:
# score, stars, what-next). Opened from its Analytics button; Escape closes.

signal closed

const _CREAM := MenuStyle.BROADCAST_CREAM
const _DIM := MenuStyle.BROADCAST_DIM
const _SEP := MenuStyle.BROADCAST_SEP
const _MUTED := MenuStyle.TEXT_MUTED
const _GOLD := MenuStyle.GOLD

# Rink geometry (GameRules mirrors) for the map's coordinate transform.
const _HALF_LEN: float = GameRules.RINK_HALF_LENGTH
const _HALF_WID: float = GameRules.RINK_HALF_WIDTH
const _GOAL_LINE: float = GameRules.GOAL_LINE_Z
const _BLUE_LINE: float = GameRules.BLUE_LINE_Z
const _CORNER_R: float = GameRules.CORNER_RADIUS

var _root: Control = null
var _map: RinkMap = null
var _flow: XGFlow = null
var _tape: VBoxContainer = null
var _subtitle: Label = null
var _team_colors: Array[Color] = [Color(0.85, 0.35, 0.15), Color(0.22, 0.53, 0.90)]


func _ready() -> void:
	layer = 16  # above GameOverPopup (5) and the Tab scoreboard (10)
	_build_ui()
	visible = false


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var scrim := ColorRect.new()
	scrim.color = Color(0.024, 0.039, 0.071, 0.93)  # near-opaque: this is a reading screen
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(scrim)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 24)
	_root.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	col.add_child(_build_header())
	col.add_child(_build_map_panel())
	col.add_child(_build_lower_row())
	col.add_child(_build_footer())


func _build_header() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var title := _lbl("GAME ANALYTICS", 26, _CREAM)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_subtitle = _lbl("", 13, _MUTED)
	_subtitle.add_theme_font_override("font", MenuStyle.UI_FONT)
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_subtitle)
	return box


func _build_map_panel() -> Control:
	var panel := _panel()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)
	col.add_child(_section_title("SHOT MAP", "dot size = expected goals"))

	_map = RinkMap.new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map.custom_minimum_size = Vector2(0, 240)
	col.add_child(_map)

	col.add_child(_build_map_legend())
	return panel


# Outcome is carried by dot STYLE (filled / hollow / faded / ringed), team by
# colour — so neither channel has to do both jobs.
func _build_map_legend() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	for spec: Array in [
			["Goal", RinkMap.LEGEND_GOAL], ["On goal", RinkMap.LEGEND_ON_NET],
			["Missed", RinkMap.LEGEND_MISSED], ["Blocked", RinkMap.LEGEND_BLOCKED]]:
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 5)
		var swatch := LegendDot.new()
		swatch.kind = int(spec[1])
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		item.add_child(swatch)
		var text := _lbl(String(spec[0]), 12, _DIM)
		text.add_theme_font_override("font", MenuStyle.UI_FONT)
		item.add_child(text)
		row.add_child(item)
	return row


func _build_lower_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(0, 210)

	var tape_panel := _panel()
	tape_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tape_panel.size_flags_stretch_ratio = 1.0
	var tape_col := VBoxContainer.new()
	tape_col.add_theme_constant_override("separation", 6)
	tape_panel.add_child(tape_col)
	tape_col.add_child(_section_title("TALE OF THE TAPE", ""))
	_tape = VBoxContainer.new()
	_tape.add_theme_constant_override("separation", 8)
	tape_col.add_child(_tape)
	row.add_child(tape_panel)

	var flow_panel := _panel()
	flow_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow_panel.size_flags_stretch_ratio = 1.15
	var flow_col := VBoxContainer.new()
	flow_col.add_theme_constant_override("separation", 6)
	flow_panel.add_child(flow_col)
	flow_col.add_child(_section_title("EXPECTED-GOALS FLOW", "cumulative xG · ● = goal"))
	_flow = XGFlow.new()
	_flow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	flow_col.add_child(_flow)
	row.add_child(flow_panel)
	return row


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(150, 38)
	close_btn.add_theme_font_size_override("font_size", 16)
	MenuStyle.wire_hover_scale(close_btn)
	SoundManager.wire_button(close_btn)
	MenuStyle.apply_focus_ring(close_btn)
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	return row


# ── Presentation ─────────────────────────────────────────────────────────────

func present() -> void:
	_refresh()
	visible = true
	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.18)


func close() -> void:
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	_team_colors = _resolve_team_colors()
	var events: Array[ShotEvent] = GameManager.get_shot_events()
	var totals: Array[Dictionary] = _team_totals()

	totals[0]["xg_base"] = XGBaseline.team_total(events, 0)
	totals[1]["xg_base"] = XGBaseline.team_total(events, 1)

	_map.configure(events, _team_colors)
	_flow.configure(events, _team_colors,
			GameManager.get_period_duration(), GameManager.get_num_periods())
	_build_tape_rows(totals)

	var attempts: int = int(totals[0]["corsi"]) + int(totals[1]["corsi"])
	_subtitle.text = "%d shot attempts · every coordinate recorded by the sim" % attempts


# Per-team aggregates, summed from the broadcast PlayerStats counters — the same
# numbers the scoreboard and career screen show, so the tape can't drift from
# them. (The map/flow read the event list; both derive from the same shots.)
func _team_totals() -> Array[Dictionary]:
	var out: Array[Dictionary] = [
		{"goals": 0, "sog": 0, "corsi": 0, "fenwick": 0, "xg": 0.0, "xg_base": 0.0},
		{"goals": 0, "sog": 0, "corsi": 0, "fenwick": 0, "xg": 0.0, "xg_base": 0.0},
	]
	var players: Dictionary[int, PlayerRecord] = GameManager.get_players()
	for peer_id: int in players:
		var rec: PlayerRecord = players[peer_id]
		if rec == null or rec.team == null or rec.stats == null:
			continue
		var t: int = rec.team.team_id
		if t < 0 or t > 1:
			continue
		out[t]["goals"] = int(out[t]["goals"]) + rec.stats.goals
		out[t]["corsi"] = int(out[t]["corsi"]) + rec.stats.shot_attempts
		out[t]["fenwick"] = int(out[t]["fenwick"]) \
				+ (rec.stats.shot_attempts - rec.stats.shot_attempts_blocked)
		out[t]["xg"] = float(out[t]["xg"]) + rec.stats.xg_for
	for t: int in 2:
		out[t]["sog"] = GameManager.get_team_shots(t)
	return out


func _build_tape_rows(totals: Array[Dictionary]) -> void:
	for child: Node in _tape.get_children():
		child.queue_free()
	_add_tape_row("Goals", float(totals[0]["goals"]), float(totals[1]["goals"]),
			"%d", false)
	_add_tape_row("Shots on goal", float(totals[0]["sog"]), float(totals[1]["sog"]),
			"%d", false)
	_add_tape_row("Shot attempts (Corsi)", float(totals[0]["corsi"]),
			float(totals[1]["corsi"]), "%d", true)
	_add_tape_row("Fenwick", float(totals[0]["fenwick"]), float(totals[1]["fenwick"]),
			"%d", true)
	_add_tape_row("Expected goals", float(totals[0]["xg"]), float(totals[1]["xg"]),
			"%.2f", true)
	# The location-only cross-check (XGBaseline). Shown alongside the goalie-aware
	# number while the two are being reconciled: the geometric model matches this
	# closely against a SET goalie but runs several times hot once the goalie has
	# been pulled off his line, because it prices the open net without pricing how
	# hard the shot is to finish. Seeing both makes that gap visible per game.
	_add_tape_row("xG (location model)", float(totals[0]["xg_base"]),
			float(totals[1]["xg_base"]), "%.2f", true)


# One head-to-head row: centred label (advanced rows carry a small tag), the two
# values, and a proportional two-segment bar. The leading side's value takes its
# team colour; the trailing value stays neutral ink.
func _add_tape_row(label_text: String, home: float, away: float,
		fmt: String, advanced: bool) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)

	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override("separation", 6)
	var lbl := _lbl(label_text.to_upper(), 11, _MUTED)
	lbl.add_theme_font_override("font", MenuStyle.UI_FONT)
	head.add_child(lbl)
	if advanced:
		var tag := _lbl("ADVANCED", 9, _GOLD)
		tag.add_theme_font_override("font", MenuStyle.UI_FONT)
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tag)
	row.add_child(head)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)

	var home_leads: bool = home >= away
	var home_lbl := _lbl(fmt % home, 17, _team_colors[0] if home_leads else _DIM)
	home_lbl.custom_minimum_size = Vector2(56, 0)
	home_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	body.add_child(home_lbl)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.custom_minimum_size = Vector2(0, 9)
	var total: float = maxf(home + away, 0.0001)
	bar.add_child(_bar_segment(_team_colors[0], maxf(home / total, 0.02), home_leads))
	bar.add_child(_bar_segment(_team_colors[1], maxf(away / total, 0.02), not home_leads))
	body.add_child(bar)

	var away_lbl := _lbl(fmt % away, 17, _team_colors[1] if not home_leads else _DIM)
	away_lbl.custom_minimum_size = Vector2(56, 0)
	away_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	body.add_child(away_lbl)

	row.add_child(body)
	_tape.add_child(row)


func _bar_segment(color: Color, ratio: float, leading: bool) -> Control:
	var seg := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color if leading else Color(color.r, color.g, color.b, 0.42)
	style.set_corner_radius_all(3)
	seg.add_theme_stylebox_override("panel", style)
	seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seg.size_flags_stretch_ratio = ratio
	return seg


func _resolve_team_colors() -> Array[Color]:
	var out: Array[Color] = [_team_colors[0], _team_colors[1]]
	for t: int in 2:
		if GameManager.teams.size() > t and GameManager.teams[t] != null:
			var slot: int = GameManager.teams[t].color_slot
			var colors: Dictionary = TeamColorRegistry.get_colors(slot, t)
			out[t] = colors.jersey
	return out


# ── Shared builders ──────────────────────────────────────────────────────────

func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = _SEP
	style.set_content_margin_all(12)
	p.add_theme_stylebox_override("panel", style)
	return p


func _section_title(title: String, note: String) -> Control:
	var row := HBoxContainer.new()
	var t := _lbl(title, 13, _CREAM)
	t.add_theme_font_override("font", MenuStyle.UI_FONT)
	row.add_child(t)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	if not note.is_empty():
		var n := _lbl(note, 11, _MUTED)
		n.add_theme_font_override("font", MenuStyle.UI_FONT)
		n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(n)
	return row


func _lbl(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


# ── Rink shot map ────────────────────────────────────────────────────────────

class RinkMap extends Control:
	const LEGEND_GOAL: int = 0
	const LEGEND_ON_NET: int = 1
	const LEGEND_MISSED: int = 2
	const LEGEND_BLOCKED: int = 3

	const _ICE := Color(0.075, 0.098, 0.141, 1.0)
	const _BOARDS := Color(0.24, 0.27, 0.33, 1.0)
	const _RED := Color(0.69, 0.31, 0.35, 0.75)
	const _BLUE := Color(0.23, 0.44, 0.69, 0.75)
	# Goal marker ring — the accent, never a jersey colour (see _draw_shot).
	const _GOAL_RING := MenuStyle.GOLD
	# Dot radius in rink metres: floor + xG-scaled growth.
	const _DOT_MIN_M: float = 0.18
	const _DOT_XG_M: float = 0.55

	var _events: Array[ShotEvent] = []
	var _colors: Array[Color] = [Color.ORANGE, Color.SKY_BLUE]
	var _scale: float = 1.0
	var _origin := Vector2.ZERO

	func configure(events: Array[ShotEvent], colors: Array[Color]) -> void:
		_events = events
		_colors = colors
		queue_redraw()

	# Rink (z along the length) → control-local pixels, letterboxed to fit.
	func _p(rz: float, rx: float) -> Vector2:
		return _origin + Vector2(rz * _scale, rx * _scale)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 4.0 or h <= 4.0:
			return
		_scale = minf(w / (_HALF_LEN * 2.0 + 1.0), h / (_HALF_WID * 2.0 + 1.0))
		_origin = Vector2(w * 0.5, h * 0.5)
		_draw_ice()
		_draw_markings()
		_draw_shots()

	func _draw_ice() -> void:
		var tl: Vector2 = _p(-_HALF_LEN, -_HALF_WID)
		var br: Vector2 = _p(_HALF_LEN, _HALF_WID)
		draw_rect(Rect2(tl, br - tl), _ICE, true)
		draw_rect(Rect2(tl, br - tl), _BOARDS, false, 1.5)

	func _draw_markings() -> void:
		# Goal lines, blue lines, centre line — vertical in this orientation.
		for z: float in [-_GOAL_LINE, _GOAL_LINE]:
			draw_line(_p(z, -_HALF_WID), _p(z, _HALF_WID), _RED, 1.0)
		for z: float in [-_BLUE_LINE, _BLUE_LINE]:
			draw_line(_p(z, -_HALF_WID), _p(z, _HALF_WID), _BLUE, 2.0)
		draw_line(_p(0.0, -_HALF_WID), _p(0.0, _HALF_WID), _RED, 2.0)
		# Creases: a half-disc opening toward centre ice at each goal line.
		for z: float in [-_GOAL_LINE, _GOAL_LINE]:
			var inward: float = 1.0 if z < 0.0 else -1.0
			var start: float = -PI * 0.5
			draw_arc(_p(z, 0.0), 1.8 * _scale,
					start, start + PI, 24, _BLUE, 1.0)
			# Net footprint just outside the goal line.
			var mouth_a: Vector2 = _p(z - inward * 1.0, -0.915)
			var mouth_b: Vector2 = _p(z, 0.915)
			draw_rect(Rect2(mouth_a, mouth_b - mouth_a), _BOARDS, false, 1.0)
		# Faceoff dots (4 end-zone + centre).
		for z: float in [-20.0, 20.0]:
			for x: float in [-6.5, 6.5]:
				draw_arc(_p(z, x), 4.5 * _scale, 0.0, TAU, 32, _RED, 0.8)
				draw_circle(_p(z, x), maxf(1.5, 0.18 * _scale), _RED)
		draw_arc(_p(0.0, 0.0), 4.5 * _scale, 0.0, TAU, 32, _BLUE, 0.8)
		draw_circle(_p(0.0, 0.0), maxf(1.5, 0.18 * _scale), _BLUE)

	# Dot size carries xG; outcome carries the style. Drawn attempts-first so the
	# goals (ringed, brightest) land on top of the clutter.
	func _draw_shots() -> void:
		for pass_idx: int in 2:
			for e: ShotEvent in _events:
				var is_goal: bool = e.outcome == ShotEvent.Outcome.GOAL
				if (pass_idx == 0) == is_goal:
					continue
				_draw_shot(e)

	func _draw_shot(e: ShotEvent) -> void:
		var team: int = clampi(e.team_id, 0, 1)
		var col: Color = _colors[team]
		var at: Vector2 = _p(e.z, e.x)
		# Radius is sized in RINK METRES, then scaled — so the dots keep the same
		# on-ice footprint at any resolution. (Deriving it from pixel scale made
		# the slot one blob on a wide screen.)
		var r: float = maxf(2.0, (_DOT_MIN_M + e.xg * _DOT_XG_M) * _scale)
		match e.outcome:
			ShotEvent.Outcome.GOAL:
				draw_circle(at, r * 1.8, Color(col.r, col.g, col.b, 0.26))
				draw_circle(at, r, col)
				# Gold, not white: one team's kit IS white, and a white ring on a
				# white dot made their goals unreadable.
				draw_arc(at, r + 2.0, 0.0, TAU, 24, _GOAL_RING, 1.8)
			ShotEvent.Outcome.SAVED:
				draw_circle(at, r, Color(col.r, col.g, col.b, 0.92))
			ShotEvent.Outcome.MISSED:
				draw_arc(at, r, 0.0, TAU, 20, col, 1.4)
			_:  # BLOCKED
				draw_circle(at, r * 0.85, Color(col.r, col.g, col.b, 0.34))


# One legend swatch, drawn in the same styles the map uses.
class LegendDot extends Control:
	var kind: int = 0

	func _draw() -> void:
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		var col := Color(0.78, 0.80, 0.85, 1.0)
		var r: float = 4.5
		match kind:
			RinkMap.LEGEND_GOAL:
				draw_circle(c, r, col)
				draw_arc(c, r + 1.6, 0.0, TAU, 20, RinkMap._GOAL_RING, 1.6)
			RinkMap.LEGEND_ON_NET:
				draw_circle(c, r, col)
			RinkMap.LEGEND_MISSED:
				draw_arc(c, r, 0.0, TAU, 20, col, 1.4)
			_:
				draw_circle(c, r * 0.85, Color(col.r, col.g, col.b, 0.34))


# ── Cumulative expected-goals flow ───────────────────────────────────────────

class XGFlow extends Control:
	const _GRID := Color(0.165, 0.175, 0.22, 1.0)
	const _AXIS := Color(0.28, 0.30, 0.36, 1.0)
	const _LABEL := MenuStyle.TEXT_MUTED

	var _events: Array[ShotEvent] = []
	var _colors: Array[Color] = [Color.ORANGE, Color.SKY_BLUE]
	var _period_s: float = 300.0
	var _periods: int = 3

	func configure(events: Array[ShotEvent], colors: Array[Color],
			period_s: float, periods: int) -> void:
		_events = events
		_colors = colors
		_period_s = maxf(period_s, 1.0)
		_periods = maxi(periods, 1)
		queue_redraw()

	# Absolute elapsed seconds for an event (period is 1-based, clock counts down).
	func _elapsed(e: ShotEvent) -> float:
		return float(maxi(e.period - 1, 0)) * _period_s + (_period_s - e.clock_s)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 8.0 or h <= 8.0:
			return
		var ml: float = 26.0
		var mr: float = 34.0
		var mt: float = 8.0
		var mb: float = 18.0
		var total_s: float = maxf(float(_periods) * _period_s, 1.0)
		# Series: cumulative xG per team, in chronological order. Blocked shots
		# carry no xG (Fenwick convention), matching the xGF counter.
		var series: Array = [[], []]
		var order: Array[ShotEvent] = _events.duplicate()
		order.sort_custom(func(a: ShotEvent, b: ShotEvent) -> bool:
				return _elapsed(a) < _elapsed(b))
		var acc: Array[float] = [0.0, 0.0]
		for e: ShotEvent in order:
			var t: int = clampi(e.team_id, 0, 1)
			if e.outcome == ShotEvent.Outcome.BLOCKED:
				continue
			acc[t] += e.xg
			(series[t] as Array).append([_elapsed(e), acc[t],
					e.outcome == ShotEvent.Outcome.GOAL])
		var peak: float = maxf(maxf(acc[0], acc[1]), 1.0)
		var top: float = ceilf(peak)

		var px := func(t: float) -> float:
			return ml + (w - ml - mr) * clampf(t / total_s, 0.0, 1.0)
		var py := func(v: float) -> float:
			return h - mb - (h - mt - mb) * clampf(v / top, 0.0, 1.0)

		# Horizontal value gridlines + baseline, with the xG value on each — the
		# gridlines were unlabelled, so the curve had no readable magnitude.
		var font: Font = MenuStyle.UI_FONT
		var steps: int = int(top)
		for i: int in range(1, steps + 1):
			var y: float = py.call(float(i))
			draw_line(Vector2(ml, y), Vector2(w - mr, y), _GRID, 1.0)
			if font != null:
				draw_string(font, Vector2(2.0, y + 3.5), str(i),
						HORIZONTAL_ALIGNMENT_LEFT, ml - 6.0, 10, _LABEL)
		draw_line(Vector2(ml, py.call(0.0)), Vector2(w - mr, py.call(0.0)), _AXIS, 1.0)
		# Period dividers.
		for p: int in range(1, _periods):
			var x: float = px.call(float(p) * _period_s)
			draw_line(Vector2(x, mt), Vector2(x, h - mb), _GRID, 1.0)

		for t: int in 2:
			var pts: Array = series[t] as Array
			if pts.is_empty():
				continue
			var line := PackedVector2Array()
			line.append(Vector2(px.call(0.0), py.call(0.0)))
			for row: Array in pts:
				line.append(Vector2(px.call(float(row[0])), py.call(float(row[1]))))
			# Hold the final value to the end of the game.
			line.append(Vector2(px.call(total_s), py.call(acc[t])))
			if line.size() >= 2:
				draw_polyline(line, _colors[t], 2.0, true)
			for row: Array in pts:
				if bool(row[2]):
					var at := Vector2(px.call(float(row[0])), py.call(float(row[1])))
					draw_circle(at, 3.6, _colors[t])
					draw_arc(at, 3.6, 0.0, TAU, 18, Color(1, 1, 1, 0.9), 1.2)
