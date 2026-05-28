class_name SkaterAimingBehavior
extends RefCounted

# ── Wrister charge state ──────────────────────────────────────────────────────
var charge_distance: float = 0.0
var wrister_start_blade_local_x: float = 0.0
# Blade world position with skater translation subtracted — the frame the
# charge tracker measures in. Translation removed so locomotion doesn't pump
# charge; rotation kept in world XZ so the accumulated direction matches the
# aim vector at release. Public (no underscore): LocalController saves and
# restores it across reconcile() replay alongside charge_distance.
var prev_blade_pos_rel_skater: Vector3 = Vector3.ZERO
var prev_blade_dir: Vector3 = Vector3.ZERO

# ── Slapper charge state ──────────────────────────────────────────────────────
var slapper_charge_timer: float = 0.0
var one_timer_window_timer: float = 0.0

# ── Wrister ───────────────────────────────────────────────────────────────────

func reset_wrister(initial_blade_pos_rel_skater: Vector3) -> void:
	charge_distance = 0.0
	prev_blade_dir = Vector3.ZERO
	prev_blade_pos_rel_skater = initial_blade_pos_rel_skater


func tick_wrister_charge(
		blade_pos_rel_skater: Vector3,
		max_charge_direction_variance: float,
		max_wrister_charge_distance: float) -> void:
	var result: Dictionary = ChargeTracking.accumulate(
			prev_blade_pos_rel_skater, blade_pos_rel_skater, prev_blade_dir,
			charge_distance, max_charge_direction_variance)
	charge_distance = minf(result.charge, max_wrister_charge_distance)
	prev_blade_dir = result.direction
	prev_blade_pos_rel_skater = blade_pos_rel_skater

# ── Slapper ───────────────────────────────────────────────────────────────────

func reset_slapper() -> void:
	slapper_charge_timer = 0.0
	one_timer_window_timer = 0.0


func tick_slapper(delta: float) -> void:
	slapper_charge_timer += delta


func tick_one_timer_window(delta: float) -> void:
	if one_timer_window_timer > 0.0:
		one_timer_window_timer -= delta
