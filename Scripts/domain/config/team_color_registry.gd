class_name TeamColorRegistry

# Loads team color presets on first use.
# Load order: user://team_colors.json (player's editable copy) →
#             res://data/team_colors.json (bundled defaults) →
#             hardcoded fallback (if both are missing or malformed).
#
# Players who want to customize colors place a team_colors.json in their
# game data directory (user://) — no other setup is required.
#
# Color identity is an integer slot: the preset's index in the loaded array.
# JSON keeps a "name" field for self-documentation, but nothing in the UI
# displays it — modders are reassigning slot N, not "the blueberry team".
# Out-of-range slots return a fallback and log a warning; they never crash.

const DEFAULT_HOME_SLOT: int = 0
const DEFAULT_AWAY_SLOT: int = 1

const _USER_JSON_PATH: String = "user://team_colors.json"
const _RES_JSON_PATH:  String = "res://data/team_colors.json"

static var _presets: Array[Dictionary] = []
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	# Try the player's editable copy first, then the bundled defaults.
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
	return _hardcoded_penguins()


# Returns the color set appropriate for the given team slot.
# team_id == 0 → home (dark jersey), team_id == 1 → away (white jersey).
# Merges top-level primary/secondary with the slot-specific fields.
static func get_colors(slot: int, team_id: int) -> Dictionary:
	var preset: Dictionary = get_preset(slot)
	var jersey_slot: Dictionary = preset.home if team_id == 0 else preset.away
	return {
		"primary":        preset.primary,
		"secondary":      preset.secondary,
		"helmet":         jersey_slot.helmet,
		"jersey":         jersey_slot.jersey,
		"jersey_stripe":  jersey_slot.jersey_stripe,
		"gloves":         jersey_slot.gloves,
		"pants":          jersey_slot.pants,
		"pants_stripe":   jersey_slot.pants_stripe,
		"socks":          jersey_slot.socks,
		"socks_stripe":   jersey_slot.socks_stripe,
		"goalie_pads":    jersey_slot.goalie_pads,
		"text":           jersey_slot.text,
		"text_outline":   jersey_slot.text_outline,
	}


static func get_all_slots() -> Array[int]:
	ensure_loaded()
	var result: Array[int] = []
	for i: int in _presets.size():
		result.append(i)
	return result


# Display label. Kept around for debug/inspector use; the UI no longer
# renders names anywhere.
static func get_preset_name(slot: int) -> String:
	return get_preset(slot).get("name", "Slot %d" % slot)


static func _try_load_from(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text: String = file.get_as_text()
	file.close()
	var data = JSON.parse_string(text)
	if not data is Dictionary or not data.has("presets"):
		push_error("TeamColorRegistry: malformed JSON in %s" % path)
		return false
	_presets.clear()
	for entry: Dictionary in data["presets"]:
		var home: Dictionary = entry.get("home", {})
		var away: Dictionary = entry.get("away", {})
		_presets.append({
			"name":      entry.get("name", "Slot %d" % _presets.size()),
			"primary":   _parse_color(entry.get("primary",   "#FFFFFF")),
			"secondary": _parse_color(entry.get("secondary", "#FFFFFF")),
			"home": {
				"helmet":        _parse_color(home.get("helmet",        "#FFFFFF")),
				"jersey":        _parse_color(home.get("jersey",        "#FFFFFF")),
				"jersey_stripe": _parse_color(home.get("jersey_stripe", "#000000")),
				"gloves":        _parse_color(home.get("gloves",        "#000000")),
				"pants":         _parse_color(home.get("pants",         "#FFFFFF")),
				"pants_stripe":  _parse_color(home.get("pants_stripe",  "#000000")),
				"socks":         _parse_color(home.get("socks",         "#FFFFFF")),
				"socks_stripe":  _parse_color(home.get("socks_stripe",  "#000000")),
				"goalie_pads":   _parse_color(home.get("goalie_pads",   "#FFFFFF")),
				"text":          _parse_color(home.get("text",          "#000000")),
				"text_outline":  _parse_color(home.get("text_outline",  "#FFFFFF")),
			},
			"away": {
				"helmet":        _parse_color(away.get("helmet",        "#FFFFFF")),
				"jersey":        _parse_color(away.get("jersey",        "#FFFFFF")),
				"jersey_stripe": _parse_color(away.get("jersey_stripe", "#000000")),
				"gloves":        _parse_color(away.get("gloves",        "#000000")),
				"pants":         _parse_color(away.get("pants",         "#FFFFFF")),
				"pants_stripe":  _parse_color(away.get("pants_stripe",  "#000000")),
				"socks":         _parse_color(away.get("socks",         "#FFFFFF")),
				"socks_stripe":  _parse_color(away.get("socks_stripe",  "#000000")),
				"goalie_pads":   _parse_color(away.get("goalie_pads",   "#FFFFFF")),
				"text":          _parse_color(away.get("text",          "#000000")),
				"text_outline":  _parse_color(away.get("text_outline",  "#FFFFFF")),
			},
		})
	if _presets.is_empty():
		push_warning("TeamColorRegistry: %s contained no valid presets" % path)
		return false
	return true


static func _parse_color(hex: String) -> Color:
	return Color.from_string(hex, Color.WHITE)


static func _load_hardcoded_fallback() -> void:
	_presets.clear()
	_presets.append(_hardcoded_penguins())
	_presets.append(_hardcoded_leafs())


static func _hardcoded_penguins() -> Dictionary:
	return {
		"name":      "Pittsburgh Penguins",
		"primary":   Color(0.988, 0.710, 0.078),
		"secondary": Color(0.06,  0.06,  0.06),
		"home": {
			"helmet":        Color(0.06,  0.06,  0.06),
			"jersey":        Color(0.988, 0.710, 0.078),
			"jersey_stripe": Color(0.06,  0.06,  0.06),
			"gloves":        Color(0.06,  0.06,  0.06),
			"pants":         Color(0.06,  0.06,  0.06),
			"pants_stripe":  Color(0.988, 0.710, 0.078),
			"socks":         Color(0.988, 0.710, 0.078),
			"socks_stripe":  Color(0.06,  0.06,  0.06),
			"goalie_pads":   Color(1.0,   1.0,   1.0),
			"text":          Color(0.06,  0.06,  0.06),
			"text_outline":  Color(0.988, 0.710, 0.078),
		},
		"away": {
			"helmet":        Color(0.06,  0.06,  0.06),
			"jersey":        Color(1.0,   1.0,   1.0),
			"jersey_stripe": Color(0.988, 0.710, 0.078),
			"gloves":        Color(0.06,  0.06,  0.06),
			"pants":         Color(1.0,   1.0,   1.0),
			"pants_stripe":  Color(0.988, 0.710, 0.078),
			"socks":         Color(1.0,   1.0,   1.0),
			"socks_stripe":  Color(0.988, 0.710, 0.078),
			"goalie_pads":   Color(0.988, 0.710, 0.078),
			"text":          Color(0.06,  0.06,  0.06),
			"text_outline":  Color(0.988, 0.710, 0.078),
		},
	}


static func _hardcoded_leafs() -> Dictionary:
	return {
		"name":      "Toronto Maple Leafs",
		"primary":   Color(0.000, 0.125, 0.357),
		"secondary": Color(1.0,   1.0,   1.0),
		"home": {
			"helmet":        Color(0.000, 0.125, 0.357),
			"jersey":        Color(0.000, 0.125, 0.357),
			"jersey_stripe": Color(1.0,   1.0,   1.0),
			"gloves":        Color(0.000, 0.125, 0.357),
			"pants":         Color(0.000, 0.125, 0.357),
			"pants_stripe":  Color(1.0,   1.0,   1.0),
			"socks":         Color(0.000, 0.125, 0.357),
			"socks_stripe":  Color(1.0,   1.0,   1.0),
			"goalie_pads":   Color(1.0,   1.0,   1.0),
			"text":          Color(1.0,   1.0,   1.0),
			"text_outline":  Color(0.000, 0.125, 0.357),
		},
		"away": {
			"helmet":        Color(0.000, 0.125, 0.357),
			"jersey":        Color(1.0,   1.0,   1.0),
			"jersey_stripe": Color(0.000, 0.125, 0.357),
			"gloves":        Color(0.000, 0.125, 0.357),
			"pants":         Color(1.0,   1.0,   1.0),
			"pants_stripe":  Color(0.000, 0.125, 0.357),
			"socks":         Color(1.0,   1.0,   1.0),
			"socks_stripe":  Color(0.000, 0.125, 0.357),
			"goalie_pads":   Color(1.0,   1.0,   1.0),
			"text":          Color(0.000, 0.125, 0.357),
			"text_outline":  Color(0.000, 0.125, 0.357),
		},
	}
