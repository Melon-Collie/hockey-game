class_name DangleGauntletHUD
extends DrillHUD

# Dangle Gauntlet HUD. Reuses DrillHUD's scaffolding — the top-right tracker
# panel, the centre flash card, and the end-of-run results card — but the drill
# is a single TIMED run rather than N discrete attempts, so it drives a live
# clock and a gate counter instead of the shot-by-shot API. It repurposes the
# base tracker's two labels (they're generic Labels, not shot-specific) and adds
# a hero clock row; the results card is filled with the finishing time and medal
# via show_time_results instead of the base makes/total show_results.
#
# In-play strings stay plain English, matching the sibling drill HUDs
# (ShotAccuracyHUD) — only the drill's menu name is localized (DrillRegistry).

const _AMBER: Color = Color(1.0, 0.82, 0.18, 0.95)
const _GOLD: Color = Color(1.0, 0.84, 0.30, 1.0)
const _SILVER: Color = Color(0.80, 0.84, 0.90, 1.0)
const _BRONZE: Color = Color(0.85, 0.60, 0.38, 1.0)

var _clock_label: Label = null


# ── DrillHUD string hooks ─────────────────────────────────────────────────────

func _title() -> String:
	return "DANGLE GAUNTLET"


func _hint() -> String:
	return "Carry the puck through every gate, in order. Beat the clock."


# ── Extra tracker row: the hero clock ─────────────────────────────────────────

func _add_tracker_rows(vbox: VBoxContainer) -> void:
	_clock_label = Label.new()
	_clock_label.add_theme_font_size_override("font_size", 34)
	_clock_label.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	vbox.add_child(_clock_label)


# ── Public API (driven by DangleGauntletManager) ──────────────────────────────

# The gate counter, shown on the base tracker's primary label. `next_gate` is
# the 1-based gate the player is heading for (== total once the run finishes).
func set_gate(next_gate: int, total: int) -> void:
	if _shot_label != null:
		_shot_label.text = "Gate %d / %d" % [next_gate, total]


# Reference par on the base tracker's secondary label — a fixed target to chase.
func set_par(par_seconds: float) -> void:
	if _score_label != null:
		_score_label.text = "Par %s" % _fmt_time(par_seconds)


# The live clock. Before the run starts it sits dim at 0; running it's teal.
func set_clock(elapsed: float, running: bool) -> void:
	if _clock_label == null:
		return
	_clock_label.text = _fmt_time(elapsed)
	_clock_label.add_theme_color_override("font_color",
			MenuStyle.TEAL_HOVER if running else MenuStyle.TEXT_DIM)


# Centre "GO!" flash when the run starts (reuses the base flash card).
func flash_go() -> void:
	if _flash_label == null:
		return
	_flash_label.text = "GO!"
	_flash_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.45, 0.95))
	_flash_card.visible = true


func hide_flash() -> void:
	if _flash_card != null:
		_flash_card.visible = false


# End-of-run card: the finishing time (or DNF if a gate was bailed) headlines,
# with the medal and a verdict below. Replaces the base makes/total show_results.
func show_time_results(elapsed: float, cleared: int, total: int,
		medal: DangleDrillRules.Medal) -> void:
	hide_flash()
	var clean: bool = cleared >= total
	if clean:
		_results_heading.text = _fmt_time(elapsed)
		_results_heading.add_theme_color_override("font_color", _medal_color(medal))
	else:
		_results_heading.text = "DNF"
		_results_heading.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_results_sub.text = _verdict_line(elapsed, cleared, total, medal)
	_results_panel.visible = true
	if _skip_btn != null:
		_skip_btn.visible = false


# ── Presentation helpers ──────────────────────────────────────────────────────

func _verdict_line(elapsed: float, cleared: int, total: int,
		medal: DangleDrillRules.Medal) -> String:
	if cleared < total:
		return "%d of %d gates. Thread every gate in order for a time." % [cleared, total]
	match medal:
		DangleDrillRules.Medal.GOLD:
			return "GOLD — %s. Filthy hands. That's a near-perfect line." % _fmt_time(elapsed)
		DangleDrillRules.Medal.SILVER:
			return "SILVER — %s. Clean weave. Tighten the cuts for gold." % _fmt_time(elapsed)
		DangleDrillRules.Medal.BRONZE:
			return "BRONZE — %s. All gates threaded. Now carry more speed." % _fmt_time(elapsed)
		_:
			return "Cleared all %d gates in %s. Run it back and push the pace." \
					% [total, _fmt_time(elapsed)]


func _medal_color(medal: DangleDrillRules.Medal) -> Color:
	match medal:
		DangleDrillRules.Medal.GOLD:
			return _GOLD
		DangleDrillRules.Medal.SILVER:
			return _SILVER
		DangleDrillRules.Medal.BRONZE:
			return _BRONZE
		_:
			return MenuStyle.TEAL_HOVER


# "M:SS.d" — minutes, zero-padded seconds, tenths.
static func _fmt_time(t: float) -> String:
	var total_tenths: int = int(round(maxf(0.0, t) * 10.0))
	var tenths: int = total_tenths % 10
	var secs: int = int(total_tenths / 10.0) % 60
	var mins: int = int(total_tenths / 600.0)
	return "%d:%02d.%d" % [mins, secs, tenths]
