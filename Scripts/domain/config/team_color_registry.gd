class_name TeamColorRegistry

# Loads team color presets on first use.
# Load order: user://team_colors.json (player's editable copy) →
#             res://data/team_colors.json (bundled defaults) →
#             hardcoded fallback (if both are missing or malformed).
#
# Schema: mitts.jersey.v2. Each team has home + away kits with structured
# regions (jersey/arms/pants/socks/shoulders) carrying a base color plus
# an array of {pos, width, color} stripes painted over the region's UV
# range. See data/team_colors.json for the description.
#
# get_colors(slot, team_id) returns a Dictionary that's a hybrid:
#   - Flat legacy keys (primary, secondary, light, helmet, gloves,
#     goalie_pads, text, text_outline, jersey, jersey_stripe, pants,
#     pants_stripe, socks, socks_stripe) for simple consumers (replay
#     records, goalie/spawn paint) — *_stripe are derived from the first
#     stripe color of the matching region (or the region base if no stripes).
#   - UI palette keys (ui_base, ui_stripe, ui_text) — the canonical 3-color
#     scheme for HUD/lobby surfaces (scorebug header, lobby slot cards). See
#     get_ui_colors() for the home/away rule. UI code should read these, NOT
#     the jersey/* keys (those mirror the 3D uniform mesh and look muddy in
#     flat UI panels).
#   - A nested "uniform" sub-dict carrying the full v2 detail
#     (shoulders, jersey-with-yoke-and-stripes, arms.upper/lower,
#     pants-with-stripes, socks-with-stripes). The skater painter
#     consumes this; UI accent code doesn't need to touch it.
#
# Color identity is an integer slot: the team's index in the loaded array.
# Out-of-range slots return a fallback and log a warning; they never crash.

const DEFAULT_HOME_SLOT: int = 0
const DEFAULT_AWAY_SLOT: int = 1

const _USER_JSON_PATH: String = "user://team_colors.json"
const _RES_JSON_PATH:  String = "res://data/team_colors.json"
const _SCHEMA_ID: String = "mitts.jersey.v2"

# Fallback "light" (away body) for presets that predate the field or come
# from a malformed file. A faint cool white so the away card still reads as a
# card against the dark lobby/HUD panels.
const _UI_WHITE: Color = Color(0.949, 0.957, 0.969)  # #F2F4F7

static var _presets: Array[Dictionary] = []
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	for path: String in [_USER_JSON_PATH, _RES_JSON_PATH]:
		if _try_load_from(path):
			return
	push_error("TeamColorRegistry: no valid JSON found in user:// or res://")
	_load_hardcoded_fallback()


static func get_preset(slot: int) -> Dictionary:
	ensure_loaded()
	if slot >= 0 and slot < _presets.size():
		return _presets[slot]
	push_warning("TeamColorRegistry: unknown slot '%d', using default" % slot)
	if _presets.size() > DEFAULT_HOME_SLOT:
		return _presets[DEFAULT_HOME_SLOT]
	return _hardcoded_papaya()


# Returns the merged color set for a given team slot + side.
# team_id == 0 → home, team_id == 1 → away.
static func get_colors(slot: int, team_id: int) -> Dictionary:
	var preset: Dictionary = get_preset(slot)
	var kit: Dictionary = preset.home if team_id == 0 else preset.away
	var jersey_block: Dictionary = kit.jersey
	var pants_block: Dictionary  = kit.pants
	var socks_block: Dictionary  = kit.socks
	var shoulders: Dictionary    = kit.shoulders
	var ui: Dictionary           = get_ui_colors(slot, team_id)
	return {
		"primary":        preset.primary,
		"secondary":      preset.secondary,
		"light":          preset.get("light", _UI_WHITE),
		"ui_base":        ui.base,
		"ui_stripe":      ui.stripe,
		"ui_text":        ui.text,
		"helmet":         kit.helmet,
		"jersey":         jersey_block.base,
		"jersey_stripe":  _accent_color(jersey_block, shoulders.color),
		"gloves":         kit.gloves,
		"pants":          pants_block.base,
		"pants_stripe":   _accent_color(pants_block, shoulders.color),
		"socks":          socks_block.base,
		"socks_stripe":   _accent_color(socks_block, shoulders.color),
		"goalie_pads":    kit.goalie_pads,
		"text":           kit.text.color,
		"text_outline":   kit.text.outline,
		"uniform":        kit,
	}


# Canonical UI palette for a team's side. The single source of truth for how
# HUD/lobby surfaces color a home/away team — keep all UI panels routed through
# here (directly, or via get_colors' ui_base/ui_stripe/ui_text keys) so the
# scheme stays consistent.
#
#   Home (team_id 0): primary body, secondary stripe, light lettering.
#   Away (team_id 1): light body, primary stripe, primary lettering.
#
# Returns { base, stripe, text } as Colors.
static func get_ui_colors(slot: int, team_id: int) -> Dictionary:
	var preset: Dictionary = get_preset(slot)
	var light: Color = preset.get("light", _UI_WHITE)
	if team_id == 0:
		return {"base": preset.primary, "stripe": preset.secondary, "text": light}
	return {"base": light, "stripe": preset.primary, "text": preset.primary}


# Stripe colors for score surfaces (scorebug + box-score period summary): each
# team always wears its own primary, so a team's color stays fixed no matter
# who it's playing. Returns { home, away } as Colors.
static func get_score_stripe_pair(home_slot: int, away_slot: int) -> Dictionary:
	return {
		"home": get_preset(home_slot).primary,
		"away": get_preset(away_slot).primary,
	}


static func get_all_slots() -> Array[int]:
	ensure_loaded()
	var result: Array[int] = []
	for i: int in _presets.size():
		result.append(i)
	return result


static func get_preset_name(slot: int) -> String:
	return get_preset(slot).get("name", "Slot %d" % slot)


# Pick the "accent" color for legacy *_stripe consumers: first stripe of
# the region, or the shoulder color if the region has no stripes.
static func _accent_color(region: Dictionary, fallback: Color) -> Color:
	var stripes: Array = region.get("stripes", [])
	if stripes.size() > 0:
		return stripes[0].color
	return fallback


static func _try_load_from(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text: String = file.get_as_text()
	file.close()
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		push_error("TeamColorRegistry: malformed JSON in %s" % path)
		return false
	var data_dict: Dictionary = data
	if data_dict.get("schema", "") != _SCHEMA_ID:
		push_error("TeamColorRegistry: %s schema mismatch (need %s)" % [path, _SCHEMA_ID])
		return false
	if not data_dict.has("teams"):
		push_error("TeamColorRegistry: %s missing 'teams' array" % path)
		return false
	_presets.clear()
	for entry: Dictionary in data_dict.teams:
		_presets.append({
			"name":      entry.get("name", "Slot %d" % _presets.size()),
			"primary":   _parse_color(entry.get("primary",   "#FFFFFF")),
			"secondary": _parse_color(entry.get("secondary", "#FFFFFF")),
			"light":     _parse_color(entry.get("light",     "#F2F4F7")),
			"home":      _parse_kit(entry.get("home", {})),
			"away":      _parse_kit(entry.get("away", {})),
		})
	if _presets.is_empty():
		push_warning("TeamColorRegistry: %s contained no valid teams" % path)
		return false
	return true


static func _parse_kit(raw: Dictionary) -> Dictionary:
	var shoulders_raw: Dictionary = raw.get("shoulders", {})
	var jersey_raw:    Dictionary = raw.get("jersey",    {})
	var arms_raw:      Dictionary = raw.get("arms",      {})
	var arms_upper:    Dictionary = arms_raw.get("upper", {})
	var arms_lower:    Dictionary = arms_raw.get("lower", {})
	var pants_raw:     Dictionary = raw.get("pants",     {})
	var socks_raw:     Dictionary = raw.get("socks",     {})
	var text_raw:      Dictionary = raw.get("text",      {})
	return {
		"helmet":      _parse_color(raw.get("helmet", "#FFFFFF")),
		"shoulders": {
			"color":   _parse_color(shoulders_raw.get("color",   "#FFFFFF")),
			"text":    _parse_color(shoulders_raw.get("text",    "#FFFFFF")),
			"outline": _parse_color(shoulders_raw.get("outline", "#000000")),
		},
		"jersey": {
			"base":    _parse_color(jersey_raw.get("base",    "#FFFFFF")),
			"yoke":    _parse_optional_color(jersey_raw.get("yoke", null)),
			"stripes": _parse_stripes(jersey_raw.get("stripes", [])),
		},
		"arms": {
			"upper": {
				"base":    _parse_color(arms_upper.get("base",    "#FFFFFF")),
				"stripes": _parse_stripes(arms_upper.get("stripes", [])),
			},
			"lower": {
				"base":    _parse_color(arms_lower.get("base",    "#FFFFFF")),
				"stripes": _parse_stripes(arms_lower.get("stripes", [])),
			},
		},
		"gloves":      _parse_color(raw.get("gloves", "#FFFFFF")),
		"pants": {
			"base":    _parse_color(pants_raw.get("base",    "#FFFFFF")),
			"stripes": _parse_stripes(pants_raw.get("stripes", [])),
		},
		"socks": {
			"base":    _parse_color(socks_raw.get("base",    "#FFFFFF")),
			"stripes": _parse_stripes(socks_raw.get("stripes", [])),
		},
		"goalie_pads": _parse_color(raw.get("goalie_pads", "#FFFFFF")),
		"text": {
			"color":   _parse_color(text_raw.get("color",   "#FFFFFF")),
			"outline": _parse_color(text_raw.get("outline", "#000000")),
		},
	}


# Parses an array of {pos, width, color} stripes into Dictionaries with
# real Color values. Bad entries are skipped with a warning.
static func _parse_stripes(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not raw is Array:
		return out
	for s: Variant in raw:
		if not s is Dictionary:
			continue
		var sd: Dictionary = s
		out.append({
			"pos":   float(sd.get("pos",   0.5)),
			"width": float(sd.get("width", 0.0)),
			"color": _parse_color(sd.get("color", "#FFFFFF")),
		})
	return out


static func _parse_color(hex: Variant) -> Color:
	if hex is String:
		return Color.from_string(hex, Color.WHITE)
	return Color.WHITE


# yoke is optional — null means "no yoke band".
static func _parse_optional_color(hex: Variant) -> Variant:
	if hex == null:
		return null
	return _parse_color(hex)


static func _load_hardcoded_fallback() -> void:
	_presets.clear()
	_presets.append(_hardcoded_papaya())
	_presets.append(_hardcoded_lime())


static func _hardcoded_papaya() -> Dictionary:
	# Mirrors the Papaya team from data/team_colors.json so a missing file
	# still produces a usable kit.
	return {
		"name":      "Papaya",
		"primary":   _parse_color("#F46B2A"),
		"secondary": _parse_color("#2A9472"),
		"light":     _parse_color("#FFFFFF"),  # mirrors away jersey base
		"home":      _parse_kit({
			"helmet":      "#2A9472",
			"shoulders":   {"color": "#2A9472", "text": "#FFFFFF", "outline": "#C8321A"},
			"jersey":      {"base": "#F46B2A", "stripes": []},
			"arms":        {"upper": {"base": "#F46B2A", "stripes": []},
							"lower": {"base": "#C8321A", "stripes": []}},
			"gloves":      "#2A9472",
			"pants":       {"base": "#2A9472", "stripes": []},
			"socks":       {"base": "#F46B2A", "stripes": []},
			"goalie_pads": "#F46B2A",
			"text":        {"color": "#FFFFFF", "outline": "#C8321A"},
		}),
		"away":      _parse_kit({
			"helmet":      "#FFFFFF",
			"shoulders":   {"color": "#2A9472", "text": "#F46B2A", "outline": "#C8321A"},
			"jersey":      {"base": "#FFFFFF", "stripes": []},
			"arms":        {"upper": {"base": "#F46B2A", "stripes": []},
							"lower": {"base": "#C8321A", "stripes": []}},
			"gloves":      "#2A9472",
			"pants":       {"base": "#2A9472", "stripes": []},
			"socks":       {"base": "#FFFFFF", "stripes": []},
			"goalie_pads": "#FFFFFF",
			"text":        {"color": "#F46B2A", "outline": "#C8321A"},
		}),
	}


static func _hardcoded_lime() -> Dictionary:
	return {
		"name":      "Lime",
		"primary":   _parse_color("#7FB320"),
		"secondary": _parse_color("#4A6B15"),
		"light":     _parse_color("#FFFFFF"),  # mirrors away jersey base
		"home":      _parse_kit({
			"helmet":      "#4A6B15",
			"shoulders":   {"color": "#7FB320", "text": "#FFFFFF", "outline": "#4A6B15"},
			"jersey":      {"base": "#7FB320", "stripes": []},
			"arms":        {"upper": {"base": "#7FB320", "stripes": []},
							"lower": {"base": "#7FB320", "stripes": []}},
			"gloves":      "#4A6B15",
			"pants":       {"base": "#4A6B15", "stripes": []},
			"socks":       {"base": "#7FB320", "stripes": []},
			"goalie_pads": "#7FB320",
			"text":        {"color": "#F5E6D3", "outline": "#4A6B15"},
		}),
		"away":      _parse_kit({
			"helmet":      "#FFFFFF",
			"shoulders":   {"color": "#7FB320", "text": "#FFFFFF", "outline": "#4A6B15"},
			"jersey":      {"base": "#FFFFFF", "stripes": []},
			"arms":        {"upper": {"base": "#FFFFFF", "stripes": []},
							"lower": {"base": "#FFFFFF", "stripes": []}},
			"gloves":      "#4A6B15",
			"pants":       {"base": "#4A6B15", "stripes": []},
			"socks":       {"base": "#FFFFFF", "stripes": []},
			"goalie_pads": "#FFFFFF",
			"text":        {"color": "#7FB320", "outline": "#4A6B15"},
		}),
	}
