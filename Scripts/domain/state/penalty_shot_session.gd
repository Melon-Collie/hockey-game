class_name PenaltyShotSession
extends RefCounted

# Tracks progress through an offline penalty-shot drill: "how many can you score
# out of N". Pure and engine-free so the scoring/sequencing is unit-testable
# headless; PenaltyDrillManager owns the puck/goalie staging and feeds results
# in. One attempt is recorded per shot, success or miss.

var total_attempts: int = 10
var attempts_taken: int = 0
var makes: int = 0


func _init(total: int = 10) -> void:
	total_attempts = maxi(1, total)


# Record one resolved attempt. Returns the make count for convenience.
func record(made: bool) -> int:
	attempts_taken += 1
	if made:
		makes += 1
	return makes


func misses() -> int:
	return attempts_taken - makes


# 1-based index of the attempt now being taken (1 on the first shot). Clamped to
# total so a late call after the final shot still reads sensibly.
func current_attempt_number() -> int:
	return mini(attempts_taken + 1, total_attempts)


func remaining() -> int:
	return maxi(0, total_attempts - attempts_taken)


func is_complete() -> bool:
	return attempts_taken >= total_attempts


# Resets for a replay of the same-length drill.
func restart() -> void:
	attempts_taken = 0
	makes = 0


func summary() -> String:
	return "%d / %d" % [makes, total_attempts]
