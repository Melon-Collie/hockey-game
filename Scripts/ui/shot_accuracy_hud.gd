class_name ShotAccuracyHUD
extends DrillHUD

# Shot-accuracy drill strings for the shared DrillHUD scaffolding — HIT! /
# MISS calls — plus one extra tracker row: the called target spot, shown in
# the bullseye's amber so the HUD text and the lit target on the net read as
# the same thing. ShotAccuracyManager drives it.

# Matches TutorialTargets' outer-band amber.
const _AMBER: Color = Color(1.0, 0.82, 0.18, 0.95)

var _target_label: Label = null


func _title() -> String:
	return "SHOT ACCURACY"


func _hint() -> String:
	return "Hit the lit target. Every release counts as a shot."


func _score_noun() -> String:
	return "Hits"


func _success_flash() -> String:
	return "HIT!"


func _fail_flash() -> String:
	return "MISS"


# A little flavour line scaled to how many targets went down.
func _verdict(hits: int, total: int) -> String:
	if hits == total:
		return "Sniper. Every call, buried."
	if hits == 0:
		return "Blanked. Slow down, read the spot, and pick your loft first."
	if hits * 2 >= total:
		return "Sharp shooting — most of your calls found the mark."
	return "A few connected. Run it back and tighten up."


func _add_tracker_rows(vbox: VBoxContainer) -> void:
	_target_label = Label.new()
	_target_label.add_theme_font_size_override("font_size", 22)
	_target_label.add_theme_color_override("font_color", _AMBER)
	vbox.add_child(_target_label)


# The called spot for the current attempt (e.g. "FIVE-HOLE").
func set_target(target_name: String) -> void:
	_target_label.text = "▸ %s" % target_name
