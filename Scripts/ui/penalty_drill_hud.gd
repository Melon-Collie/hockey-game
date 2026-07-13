class_name PenaltyDrillHUD
extends DrillHUD

# Penalty-shot drill strings for the shared DrillHUD scaffolding: GOAL! /
# NO GOAL calls and the beat-the-goalie hint. PenaltyDrillManager drives it.


func _title() -> String:
	return "PENALTY SHOTS"


func _hint() -> String:
	return "Skate in and beat the goalie."


func _success_flash() -> String:
	return "GOAL!"


func _fail_flash() -> String:
	return "NO GOAL"


# A little flavour line scaled to how many went in.
func _verdict(makes: int, total: int) -> String:
	if makes == total:
		return "Perfect — you buried every one. Lights out."
	if makes == 0:
		return "Robbed every time. The goalie wins this round."
	if makes * 2 >= total:
		return "Solid shooting. The goalie got a few of them."
	return "A few found the net. Run it back and sharpen up."
