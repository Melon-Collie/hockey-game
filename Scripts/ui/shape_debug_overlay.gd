class_name ShapeDebugOverlay
extends CanvasLayer

# F6 bot-shape debug overlay. Renders GameManager.shape_tally — how much of
# live play each team's brain spends in each AIPossessionState shape.
#
# Why this exists: the shapes are the top-level control flow of the bot AI —
# they decide which roles exist and which evaluators run — and their relative
# weight was never measured, so "is this shape worth the code it costs?" had no
# answer. Spectate a bot-vs-bot match with this open and it does.
#
# Reading it:
#   • SHARE is the headline, but read it WITH n. A shape at 5% over 200 spells
#     is one the team flickers through; 5% over 2 spells is one that happens
#     rarely and lasts. Those are different problems with opposite fixes.
#   • MEAN is share/n made legible — seconds per visit. A mean spell under
#     CHURN_MEAN_SPELL_S in a shape with real role behavior means bots are
#     being re-slotted faster than they can skate to the new job, so it is
#     flagged.
#   • DOWNGRADE is the share of live play where the raw read wanted D-zone
#     coverage but the brain held the rush shape because the backcheck wasn't
#     home. It is counted INSIDE TRANS_OD's share, not alongside it.
#
# Host-only by nature: the tally samples the team brains, which exist only
# where the bots are simulated. A client sees the "no brains" notice.
#
# The sampling itself is OFF until this panel is first opened (F6 latches
# GameManager.shape_tally_armed) and the overlay is only built in a debug build,
# so an ordinary match pays nothing for it. Cost of being wrong here is real:
# the tally ticks at 120 Hz per team off the host's physics step.
#
# Debug surface — strings are deliberately not routed through tr(), matching
# NetworkDebugOverlay. Built entirely in code (no .tscn) so it stays a
# Claude-editable file. Laid out as a bbcode [table] rather than space-padded
# columns because RichTextLabel renders a proportional font, in which padded
# columns do not line up.

const COL_HEAD := "8fb3d9"
const COL_DIM := "8a93a0"
const COL_VAL := "ececec"
const COL_HOME := "9ad27c"
const COL_AWAY := "e6cf52"
const COL_FLAG := "e87060"

# A shape held for less than this per visit is flagged: the bots are being
# re-slotted faster than they can act on the assignment. Sized on the brain's
# own re-tick cadence (6 Hz ≈ 0.17 s) times a few ticks — long enough to have
# started skating somewhere.
const CHURN_MEAN_SPELL_S: float = 0.5

# Downgrade share above which the D-zone suppression line turns red — it is
# meant to be a transient handoff, so a sustained slice is the interesting case.
const DOWNGRADE_FLAG_SHARE: float = 0.05

# Refresh cadence while open. The tally moves at 120 Hz but a human reads it at
# reading speed, and rebuilding the bbcode every frame is pure waste.
const REFRESH_SECONDS: float = 0.25

var _rt: RichTextLabel
var _panel: PanelContainer
var _showing: bool = false
var _refresh_timer: float = 0.0

var _toast: Label
var _toast_timer: float = 0.0
const TOAST_SECONDS: float = 2.0

# Result of the last F7 dump, rendered IN THE PANEL rather than only as a
# toast. A toast is gone in two seconds and never reaches a screenshot, so a
# dump that silently no-ops is indistinguishable from a keypress that never
# arrived. In the panel the distinction is visible: text here means the handler
# ran and this is what happened; no text means the key never got through.
var _dump_status: String = ""


func _ready() -> void:
	layer = 99   # just under NetworkDebugOverlay so the two never fight
	_panel = PanelContainer.new()
	_panel.position = Vector2(8, 8)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.80)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8.0)
	_panel.add_theme_stylebox_override("panel", style)
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true
	_rt.fit_content = true
	_rt.scroll_active = false
	_rt.custom_minimum_size = Vector2(520, 0)
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
	_toast.position = Vector2(0, -72)
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
	if event.keycode == KEY_F6:
		_showing = not _showing
		_panel.visible = _showing
		if _showing:
			# Arm the host-side sampling on first open. It is a 120 Hz tick cost,
			# so it does not run in a match nobody asked to measure — and it
			# stays armed once latched, because a gap in the sampling would skew
			# every share the panel then reports.
			GameManager.shape_tally_armed = true
			_refresh()
		get_viewport().set_input_as_handled()
		return
	if not _showing:
		return
	# Both actions are claimed only while the panel is open, and both sit on
	# FUNCTION keys: every letter key is a candidate gameplay binding (C is the
	# default `block`), so a letter shortcut on a spectate overlay fires a real
	# input at the same time.
	if event.keycode == KEY_F7:
		_dump()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F8:
		GameManager.shape_tally.reset()
		GameManager.breakout_episodes.reset()
		_flash("✓ Tallies reset")
		get_viewport().set_input_as_handled()


# Writes the tally to THREE sinks, because a debug dump that fails silently is
# worse than no dump: the clipboard (fastest to paste, but can no-op depending
# on platform/session), stdout (survives in the console log), and a file under
# user:// whose absolute path the toast reports so it can be opened directly.
func _dump() -> void:
	var json: String = JSON.stringify(GameManager.shape_tally.to_dict(), "\t")
	# Each sink is reported on its own, so a partial failure names itself.
	DisplayServer.clipboard_set(json)
	var clip_ok: bool = DisplayServer.clipboard_get() == json
	print("[shape tally] ", json)
	var path: String = "user://shape_tally.json"
	var file_ok: bool = false
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(json)
		f.close()
		file_ok = true
	_dump_status = "%d chars · clipboard %s · console yes · file %s" % [
			json.length(),
			"yes" if clip_ok else "NO",
			ProjectSettings.globalize_path(path) if file_ok else "FAILED"]
	_flash("✓ Dump: " + _dump_status)
	_refresh()


func _flash(msg: String) -> void:
	_toast.text = msg
	_toast.show()
	_toast_timer = TOAST_SECONDS


func _process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.hide()
	if not _showing:
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_SECONDS
		_refresh()


func _refresh() -> void:
	var header := "[b]Bot Shapes[/b]   [color=#%s](F6 close · F7 dump · F8 reset)[/color]" % COL_DIM
	var tally: AIPossessionShapeTally = GameManager.shape_tally
	if tally == null or GameManager.team_brains.is_empty():
		_rt.text = header + "\n[color=#%s]No team brains on this peer — the tally samples the host's bot AI.[/color]" % COL_DIM
		return
	if tally.total_seconds(0) <= 0.0 and tally.total_seconds(1) <= 0.0:
		_rt.text = header + "\n[color=#%s]Waiting for live play — the tally only samples during PLAYING.[/color]" % COL_DIM
		return

	var rows: PackedStringArray = []
	rows.append(_head_cell("shape") + _head_cell("H share") + _head_cell("H n")
			+ _head_cell("H mean") + _head_cell("A share") + _head_cell("A n")
			+ _head_cell("A mean"))
	for state: int in _shapes_by_weight(tally):
		if tally.entries(0, state) == 0 and tally.entries(1, state) == 0:
			continue
		rows.append(
				_cell(AIPossessionShapeTally.state_name(state), COL_VAL)
				+ _team_cells(tally, 0, state, COL_HOME)
				+ _team_cells(tally, 1, state, COL_AWAY))

	var d0: float = tally.downgrade_share(0)
	var d1: float = tally.downgrade_share(1)
	var dcol: String = COL_FLAG if maxf(d0, d1) > DOWNGRADE_FLAG_SHARE else COL_DIM
	# The two SUMMARY lines sit ABOVE the table, not below it: RichTextLabel's
	# fit_content under-measures a [table], so anything after one can be clipped
	# off the bottom of the panel — and these are the numbers most worth reading.
	# Only the legend is allowed to live down there, where losing it costs
	# nothing.
	var summary: PackedStringArray = [
		"[color=#%s]· live play sampled — HOME %.0f s · AWAY %.0f s[/color]"
				% [COL_DIM, tally.total_seconds(0), tally.total_seconds(1)],
		"[color=#%s]· DZONE suppressed, backcheck not home — HOME %.1f%% · AWAY %.1f%%[/color]"
				% [dcol, d0 * 100.0, d1 * 100.0],
	]
	# Top transitions: which shape pairs the churn is actually between. Spell
	# counts say a shape is churning; only this says what against, and the two
	# have opposite implications (a pair whose slot sets are identical costs
	# nothing; a pair that swaps every role is the expensive kind).
	for team_id: int in AIPossessionShapeTally.TEAM_COUNT:
		var parts: PackedStringArray = []
		for t: Vector3i in tally.top_transitions(team_id, 4):
			parts.append("%s→%s %d" % [
					AIPossessionShapeTally.state_name(t.x),
					AIPossessionShapeTally.state_name(t.y), t.z])
		if not parts.is_empty():
			summary.append("[color=#%s]· %s churn — %s[/color]" % [
					COL_HOME if team_id == 0 else COL_AWAY,
					"HOME" if team_id == 0 else "AWAY",
					" · ".join(parts)])
	# The breakout-outcome block: the live counterpart of the harness's
	# clean/clear/cough/timeout columns, so the two can be compared directly.
	var eps: AIBreakoutEpisodeTracker = GameManager.breakout_episodes
	if eps != null:
		for team_id: int in AIBreakoutEpisodeTracker.TEAM_COUNT:
			var n: int = eps.total(team_id)
			if n == 0:
				continue
			var parts: PackedStringArray = []
			for outcome: int in AIBreakoutEpisodeTracker.OUTCOME_COUNT:
				var c: int = eps.count(team_id, outcome)
				if c == 0:
					continue
				parts.append("%s %d (%.0f%%)" % [
						AIBreakoutEpisodeTracker.outcome_name(outcome), c,
						eps.share(team_id, outcome) * 100.0])
			summary.append("[color=#%s]· %s breakouts (n=%d) — %s[/color]" % [
					COL_HOME if team_id == 0 else COL_AWAY,
					"HOME" if team_id == 0 else "AWAY",
					n, " · ".join(parts)])
	if _dump_status != "":
		summary.append("[color=#%s]· last dump — %s[/color]" % [
				COL_DIM, _dump_status])
	var legend: String = (
			"[color=#%s]  share = %% of live play · n = spells · mean = s per spell · a [/color]"
			+ "[color=#%s]red mean[/color][color=#%s] re-slots faster than a bot can act (< %.2f s)[/color]"
	) % [COL_DIM, COL_FLAG, COL_DIM, CHURN_MEAN_SPELL_S]
	_rt.text = "%s\n%s\n[table=7]%s[/table]\n%s" % [
			header, "\n".join(summary), "".join(rows), legend]


# Shape enum values ordered by the busier team's share, descending — so what
# matters sorts to the top instead of sitting in enum order.
func _shapes_by_weight(tally: AIPossessionShapeTally) -> Array[int]:
	var order: Array[int] = []
	for state: int in AIPossessionShapeTally.STATE_COUNT:
		order.append(state)
	order.sort_custom(func(a: int, b: int) -> bool:
			return maxf(tally.share(0, a), tally.share(1, a)) \
					> maxf(tally.share(0, b), tally.share(1, b)))
	return order


# One team's three numbers for a shape, as three table cells.
func _team_cells(tally: AIPossessionShapeTally, team_id: int, state: int,
		col: String) -> String:
	if tally.entries(team_id, state) == 0:
		return _cell("—", COL_DIM) + _cell("—", COL_DIM) + _cell("—", COL_DIM)
	var mean: float = tally.mean_spell_s(team_id, state)
	return _cell("%.1f%%" % (tally.share(team_id, state) * 100.0), col) \
			+ _cell("%d" % tally.entries(team_id, state), col) \
			+ _cell("%.2f" % mean,
					COL_FLAG if mean < CHURN_MEAN_SPELL_S else col)


func _cell(text: String, col: String) -> String:
	return "[cell][color=#%s]%s[/color][/cell]" % [col, text]


func _head_cell(text: String) -> String:
	return "[cell][color=#%s]%s[/color][/cell]" % [COL_HEAD, text]
