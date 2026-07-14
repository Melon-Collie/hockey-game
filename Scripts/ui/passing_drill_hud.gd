class_name PassingDrillHUD
extends DrillHUD

# Passing-drill strings for the shared DrillHUD scaffolding — COMPLETE! / MISSED
# calls — plus one extra tracker row: the current scenario name, in the drill
# accent so the HUD text and the play on the ice read as the same thing.
# PassingDrillManager drives it.

# Matches the tracker's teal accent used elsewhere in the drill HUDs.
const _ACCENT: Color = Color(0.35, 0.85, 0.95, 0.95)

var _scenario_label: Label = null


func _title() -> String:
	return "PASSING"


func _hint() -> String:
	return "Lead the skater — put it on their tape. A board in the lane means saucer it over."


func _score_noun() -> String:
	return "Completed"


func _success_flash() -> String:
	return "TAPE TO TAPE!"


func _fail_flash() -> String:
	return "MISSED"


# A little flavour line scaled to how many connected.
func _verdict(makes: int, total: int) -> String:
	if makes == total:
		return "Every pass on the tape. A real playmaker."
	if makes == 0:
		return "Nobody home. Read the skater and lead them into the lane."
	if makes * 2 >= total:
		return "Crisp feeds — most found a blade."
	return "A few connected. Run it back and sharpen the lead."


func _add_tracker_rows(vbox: VBoxContainer) -> void:
	_scenario_label = Label.new()
	_scenario_label.add_theme_font_size_override("font_size", 22)
	_scenario_label.add_theme_color_override("font_color", _ACCENT)
	vbox.add_child(_scenario_label)


# The scenario being staged for the current attempt (e.g. "STRETCH — LEAD IT").
func set_scenario(scenario_name: String) -> void:
	_scenario_label.text = "▸ %s" % scenario_name
