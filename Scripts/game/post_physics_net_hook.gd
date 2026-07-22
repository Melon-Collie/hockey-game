class_name PostPhysicsNetHook
extends Node

# End-of-tick capture + broadcast hook. GameManager parents one of these and
# points `callback` at its capture/broadcast body. Physics priority 2 runs
# AFTER every actor's physics work this tick (SkaterController at −1,
# autoloads + bodies at 0, PuckController/Puck at +1), so the captured state
# is THIS tick's post-move, post-puck-step result and the packet ships the
# same tick it was simulated. The old placement — GameManager's own
# _physics_process, which as an autoload runs BEFORE the scene's actors —
# captured the PREVIOUS tick's result at the start of the next tick: every
# snapshot paid one tick (~8.3 ms) of departure latency, skater velocity
# (updated at −1) was captured one phase ahead of position, and the label
# overstated the content's age by a tick — which the client input-lead servo
# measured as "overdue" and silently padded lead over. See ARCHITECTURE.md →
# Networking Invariants (host capture/broadcast timing).

var callback: Callable = Callable()


func _ready() -> void:
	process_physics_priority = 2


func _physics_process(_delta: float) -> void:
	if callback.is_valid():
		callback.call()
