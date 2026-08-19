class_name PostPhysicsNetHook
extends Node

# End-of-tick capture + broadcast hook. GameManager parents one of these and
# points `callback` at its capture/broadcast body. Physics priority 2 runs
# AFTER every actor's physics work this tick (SkaterController at −1,
# autoloads + bodies at 0, PuckController/Puck at +1), so the captured state
# is THIS tick's post-move, post-puck-step result and the packet ships the
# same tick it was simulated. Never capture from GameManager's own
# _physics_process instead: as an autoload it runs BEFORE the scene's actors, so
# it takes the PREVIOUS tick's result at the start of the next one — every
# snapshot pays a tick (~8.3 ms) of departure latency, skater velocity (updated
# at −1) is captured one phase ahead of position, and the label overstates the
# content's age by a tick, which the client input-lead servo measures as
# "overdue" and silently pads lead over. See Scripts/networking/CLAUDE.md
# (host capture / broadcast timing).

var callback: Callable = Callable()


func _ready() -> void:
	process_physics_priority = 2


func _physics_process(_delta: float) -> void:
	if callback.is_valid():
		callback.call()
