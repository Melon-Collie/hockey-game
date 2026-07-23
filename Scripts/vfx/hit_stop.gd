class_name HitStop
extends Node

# Local, cosmetic "hit-stop" — a brief global time-dilation freeze on a hard
# impact or a goal. The fighting-game / action-game "juice" trick: stalling the
# whole picture for a few tens of milliseconds at the moment of contact makes a
# collision read as a real hit rather than a soft merge, and gives a goal a
# tactile clunk before the celebration. Purely presentation — it scales
# Engine.time_scale and restores it on a WALL-CLOCK timer (Time.get_ticks_msec,
# which is unaffected by time_scale, unlike a SceneTreeTimer or delta).
#
# NETCODE: time_scale dilates the ENTIRE simulation on this machine only, so it
# is gated to OFFLINE play (NetworkManager.is_offline_mode). Online the sim is
# host-authoritative and every peer must advance in lockstep — a per-machine
# freeze would skew prediction / reconcile / the phase clock — so hit-stop is a
# no-op there and the existing camera shake + screen flash carry the moment.
# Offline there is no reconcile and the fixed-delta ticks stay deterministic
# (time_scale changes how OFTEN _physics_process runs, not the per-tick delta),
# so a freeze is safe. Also gated by the PlayerPrefs.hit_stop comfort toggle.
#
# Owned by HUD (the local A/V feedback hub, alongside FlashOverlay); HUD calls
# freeze() on the goal and hard-impact signals.

# Freeze depth at the two ends of the strength range. A soft qualifying hit
# only dips time to 0.6×; a full-intensity check / goal nearly stops it. Never
# a full 0 — a hard 0 can stall tweens/particles that key off a nonzero delta.
const _SCALE_SOFT: float = 0.6
const _SCALE_HARD: float = 0.05

var _restore_at_ms: int = -1


func _ready() -> void:
	set_process(false)


# strength: 0..1 hit hardness → freeze depth (deeper the harder).
# duration: real (wall-clock) seconds to hold the freeze.
func freeze(strength: float, duration: float) -> void:
	if not PlayerPrefs.hit_stop:
		return
	# Only ever touch time_scale when this machine owns the whole sim.
	if not NetworkManager.is_offline_mode:
		return
	strength = clampf(strength, 0.0, 1.0)
	if strength <= 0.01 or duration <= 0.0:
		return
	var scale: float = lerpf(_SCALE_SOFT, _SCALE_HARD, strength)
	# Overlapping hits take the deeper freeze and the later release, never a
	# shallower/earlier one that would cut an in-progress freeze short.
	if _restore_at_ms >= 0:
		Engine.time_scale = minf(Engine.time_scale, scale)
	else:
		Engine.time_scale = scale
	var end_ms: int = Time.get_ticks_msec() + int(duration * 1000.0)
	_restore_at_ms = maxi(_restore_at_ms, end_ms)
	set_process(true)


func _process(_delta: float) -> void:
	if _restore_at_ms < 0:
		return
	if Time.get_ticks_msec() >= _restore_at_ms:
		Engine.time_scale = 1.0
		_restore_at_ms = -1
		set_process(false)


# Safety: if this node leaves the tree mid-freeze (scene teardown, return to
# menu), never strand the engine in slow motion.
func _exit_tree() -> void:
	if _restore_at_ms >= 0:
		Engine.time_scale = 1.0
		_restore_at_ms = -1
