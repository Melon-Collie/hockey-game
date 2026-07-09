class_name SkaterAimingBehavior
extends RefCounted

# ── Wrister charge state ──────────────────────────────────────────────────────
# Cumulative counted sweep distance, UNCLAMPED — consumers normalize against
# max_wrister_charge_distance at use (release/pred clamp dist_t to 0..1).
# Keeping the raw total is what keeps avg_sweep_speed() honest when a long
# hard sweep runs past the charge cap: distance and time keep counting
# together, so the average doesn't decay just because the bar is full.
var charge_distance: float = 0.0
# Seconds the sweep actively spent moving (ChargeTracking adds delta only on
# counted ticks). charge_distance / sweep_time is the average sweep speed —
# the wrister power model's primary signal. Saved/restored across reconcile
# replay alongside charge_distance (LocalController), same shape of problem.
var sweep_time: float = 0.0
# Cursor (intent) position in SCREEN-space, packed into a Vector3 as
# (screen.x, 0, screen.y). The charge tracker reads its DIRECTION from
# the delta of this position frame-over-frame. Screen space is the
# camera-immune frame — pixel motion captures pure mouse drag intent
# regardless of camera lag, body rotation, or skater locomotion.
# Public (no underscore): LocalController saves and restores it across
# reconcile() replay alongside the rest of the charge state.
var prev_intent_pos: Vector3 = Vector3.ZERO
# Blade world position with skater translation subtracted — the frame
# the charge tracker measures MAGNITUDE in. Translation removed so
# locomotion doesn't pump charge. Magnitude is projected onto the
# screen-space intent direction (see ChargeTracking), so blade motion
# orthogonal to player intent (body rotation, IK convergence noise)
# contributes nothing.
var prev_blade_pos_rel_skater: Vector3 = Vector3.ZERO
var prev_blade_dir: Vector3 = Vector3.ZERO

# ── Slapper charge state ──────────────────────────────────────────────────────
var slapper_charge_timer: float = 0.0
var one_timer_window_timer: float = 0.0

# ── Wrister ───────────────────────────────────────────────────────────────────

func reset_wrister(initial_intent_pos: Vector3, initial_blade_pos_rel_skater: Vector3) -> void:
	charge_distance = 0.0
	sweep_time = 0.0
	prev_blade_dir = Vector3.ZERO
	prev_intent_pos = initial_intent_pos
	prev_blade_pos_rel_skater = initial_blade_pos_rel_skater


func tick_wrister_charge(
		intent_pos: Vector3,
		blade_pos_rel_skater: Vector3,
		max_charge_direction_variance: float,
		delta: float,
		max_counted_sweep_speed: float) -> void:
	var result: Dictionary = ChargeTracking.accumulate(
			prev_intent_pos, intent_pos,
			prev_blade_pos_rel_skater, blade_pos_rel_skater,
			prev_blade_dir, charge_distance, max_charge_direction_variance,
			sweep_time, delta, max_counted_sweep_speed)
	charge_distance = result.charge
	sweep_time = result.sweep_time
	prev_blade_dir = result.direction
	prev_intent_pos = intent_pos
	prev_blade_pos_rel_skater = blade_pos_rel_skater


# Average on-axis sweep speed (m/s) of the accumulated drag — the wrister
# power model's speed signal (ShotMechanics.wrister_power_t). Zero until a
# sweep has actually counted motion.
func avg_sweep_speed() -> float:
	if charge_distance <= 0.0 or sweep_time <= 0.0:
		return 0.0
	return charge_distance / sweep_time

# ── Slapper ───────────────────────────────────────────────────────────────────

func reset_slapper() -> void:
	slapper_charge_timer = 0.0
	one_timer_window_timer = 0.0


func tick_slapper(delta: float) -> void:
	slapper_charge_timer += delta


func tick_one_timer_window(delta: float) -> void:
	if one_timer_window_timer > 0.0:
		one_timer_window_timer -= delta
