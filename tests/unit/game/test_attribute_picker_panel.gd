extends GutTest

# AttributePickerPanel — the shared body-build picker (sliders + presets) hosted
# by PlayerSettingsPopup (free play) and LobbyBuildPopup (pre-match).
#
# Regression guard for the "weight isn't saved" bug: _refresh() assigns the
# weight slider's min/max from the active preset's height band. Godot's
# Range.set_min/set_max re-clamp the slider value and route through set_value,
# which emits value_changed (set_value_no_signal only silences an explicit value
# write, not a bounds-driven clamp). Left unguarded, that reentrant
# _on_weight_changed overwrites the active preset's stored weight with the
# band-clamped slider value — so switching to a preset whose weight sits outside
# the previous band silently rewrote its weight to the band floor, and commit()
# persisted the wrong number.
#
# The panel reads/writes the PlayerPrefs autoload directly, so we snapshot and
# restore its preset list around the test rather than mutating it permanently.

var _panel: AttributePickerPanel = null
var _saved_entries: Array = []
var _saved_active: int = 0


func before_each() -> void:
	# Preserve the real preset list; the test overwrites it in-memory.
	_saved_entries = _entries_from(PlayerPrefs.get_presets())
	_saved_active = PlayerPrefs.get_active_preset_index()
	_panel = AttributePickerPanel.new()
	add_child(_panel)  # _ready() builds the sliders


func after_each() -> void:
	_panel.free()
	_panel = null
	if not _saved_entries.is_empty():
		PlayerPrefs.set_all_presets(_saved_entries, _saved_active)


# Two builds whose height bands don't overlap (5'8" → [158,191], 6'7" →
# [213,257]) so switching between them forces the weight slider's bounds past
# its current value — the exact condition that fired the reentrant clamp.
func test_switching_presets_preserves_out_of_band_weight() -> void:
	PlayerPrefs.set_all_presets([
		{"name": "Light", "levels": [68, 170, 1, 1, 1, 1]},
		{"name": "Heavy", "levels": [79, 240, 1, 1, 1, 1]},
	], 0)
	_panel.snapshot()          # active = 0 (Light), weight band [158,191]
	_panel._on_chip_pressed(1) # switch to Heavy — refresh drags the band to [213,257]

	var committed: PlayerAttributes = _panel.commit()
	assert_eq(committed.weight, 240,
			"active (Heavy) preset keeps its stored weight after the band shift")
	assert_eq(PlayerPrefs.get_presets()[1]["attrs"].weight, 240,
			"committed Heavy preset persists 240 lbs, not the band floor")
	assert_eq(PlayerPrefs.get_presets()[0]["attrs"].weight, 170,
			"Light preset is untouched by the switch")


# Reopening the panel (snapshot → commit with no edits) must round-trip weight
# unchanged. The first _refresh sets the weight slider's bounds from the default
# 0..100 range, which alone could fire the clamp and rewrite the active preset.
func test_snapshot_commit_roundtrips_weight_unedited() -> void:
	PlayerPrefs.set_all_presets([
		{"name": "Heavy", "levels": [79, 240, 1, 1, 1, 1]},
	], 0)
	_panel.snapshot()
	var committed: PlayerAttributes = _panel.commit()
	assert_eq(committed.weight, 240, "unedited reopen preserves weight")


func _entries_from(presets: Array) -> Array:
	var out: Array = []
	for p: Dictionary in presets:
		var a: PlayerAttributes = p["attrs"]
		out.append({
			"name": String(p["name"]),
			"levels": [a.height, a.weight, a.profile, a.curve, a.flex, a.length],
		})
	return out
