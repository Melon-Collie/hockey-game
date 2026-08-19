class_name HudChrome

# Widget factories, team colors and clock/period text shared by the HUD panels.
# Palette comes from MenuStyle's BROADCAST_* family; only the clock-warning
# amber has no home there.

const WARN_AMBER := Color(0.95, 0.65, 0.20, 1.0)

# Stand-in until team_colors_ready lands and the real palette is resolved.
const _UNRESOLVED := Color(0.5, 0.5, 0.5)

const _SEP_COLOR := MenuStyle.BROADCAST_SEP

static func lbl(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

static func cell(h_margin: int, v_margin: int) -> MarginContainer:
	var c := MarginContainer.new()
	c.add_theme_constant_override("margin_left", h_margin)
	c.add_theme_constant_override("margin_right", h_margin)
	c.add_theme_constant_override("margin_top", v_margin)
	c.add_theme_constant_override("margin_bottom", v_margin)
	return c

static func vsep() -> VSeparator:
	var sep := VSeparator.new()
	var style := StyleBoxFlat.new()
	style.bg_color = _SEP_COLOR
	style.set_content_margin_all(0)
	sep.add_theme_stylebox_override("separator", style)
	sep.custom_minimum_size = Vector2(1, 0)
	return sep

# Scorebug stripe color for a team: always its own primary, so a team's color
# is consistent regardless of who it's playing.
static func team_stripe(team_id: int) -> Color:
	if GameManager.teams.size() > 1:
		var pair: Dictionary = TeamColorRegistry.get_score_stripe_pair(
				GameManager.teams[0].color_slot, GameManager.teams[1].color_slot)
		return pair.home if team_id == 0 else pair.away
	return _UNRESOLVED

static func team_primary(team_id: int) -> Color:
	if GameManager.teams.size() > team_id:
		return TeamColorRegistry.get_colors(GameManager.teams[team_id].color_slot, team_id).primary
	return _UNRESOLVED

static func period_ordinal(p: int) -> String:
	var n: int = GameManager.get_num_periods()
	if p > n:
		return "OT%d" % (p - n)
	match p:
		1: return "1ST"
		2: return "2ND"
		3: return "3RD"
		_: return "P%d" % p

# Hero text for the period-start intro card: "2ND PERIOD" for regulation,
# "OVERTIME" for the first OT, numbered beyond (repeated ties keep cycling OT).
static func period_intro_title(p: int) -> String:
	var n: int = GameManager.get_num_periods()
	if p <= n:
		return "%s PERIOD" % period_ordinal(p)
	var ot: int = p - n
	if ot <= 1:
		return "OVERTIME"
	return "OVERTIME %d" % ot

# Band title for the break after period `p`: "END OF 1ST PERIOD", or
# "END OF OVERTIME" when repeated OT ties keep the game going.
static func intermission_title(p: int) -> String:
	var n: int = GameManager.get_num_periods()
	if p <= n:
		return "END OF %s PERIOD" % period_ordinal(p)
	var ot: int = p - n
	if ot <= 1:
		return "END OF OVERTIME"
	return "END OF OVERTIME %d" % ot

static func format_clock(t: float) -> String:
	var secs: int = int(ceil(t))
	return "%d:%02d" % [secs / 60, secs % 60]
