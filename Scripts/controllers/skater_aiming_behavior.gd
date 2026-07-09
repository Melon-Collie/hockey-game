class_name SkaterAimingBehavior
extends RefCounted

# ── Wrister charge state ──────────────────────────────────────────────────────
# VESTIGIAL: the old blade-speed × distance power model read charge_distance /
# sweep_time (the average on-axis sweep speed). Power is now the pure cursor
# speed (cursor_speed_ema), so these accumulate but no longer feed power —
# slated for removal with the rest of the distance machinery.
var charge_distance: float = 0.0
var sweep_time: float = 0.0
# Net signed angular sweep of the blade around the player (radians), over the
# current stroke. Its SIGN is the forehand/backhand chirality
# (ShotMechanics.is_backhand_from_swing). Accumulated by ChargeTracking, reset
# with the rest of the stroke on a variance break, and saved/restored across
# reconcile like charge_distance / sweep_time.
var swing_rotation: float = 0.0
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
# EMA of the raw SCREEN-space cursor speed (px/s) — THE wrister power signal.
# Unfiltered hand motion (unlike the old ROM-clamped, speed-capped blade
# speed): flick fast = hard, sweep slow = soft. Saved/restored across reconcile
# like the rest of the charge state.
var cursor_speed_ema: float = 0.0

# ── Slapper charge state ──────────────────────────────────────────────────────
var slapper_charge_timer: float = 0.0
var one_timer_window_timer: float = 0.0

# ── Wrister ───────────────────────────────────────────────────────────────────

func reset_wrister(initial_intent_pos: Vector3, initial_blade_pos_rel_skater: Vector3) -> void:
	charge_distance = 0.0
	sweep_time = 0.0
	swing_rotation = 0.0
	cursor_speed_ema = 0.0
	prev_blade_dir = Vector3.ZERO
	prev_intent_pos = initial_intent_pos
	prev_blade_pos_rel_skater = initial_blade_pos_rel_skater


func tick_wrister_charge(
		intent_pos: Vector3,
		blade_pos_rel_skater: Vector3,
		max_charge_direction_variance: float,
		delta: float,
		max_counted_sweep_speed: float,
		cursor_speed_smoothing: float) -> void:
	# Raw screen-space cursor speed (px/s), EMA-smoothed — computed against the
	# OLD prev_intent_pos before ChargeTracking's result overwrites it below.
	if delta > 0.0:
		var screen_delta := intent_pos - prev_intent_pos
		screen_delta.y = 0.0
		var inst_speed: float = screen_delta.length() / delta
		var a: float = clampf(cursor_speed_smoothing * delta, 0.0, 1.0)
		cursor_speed_ema = lerpf(cursor_speed_ema, inst_speed, a)
	var result: Dictionary = ChargeTracking.accumulate(
			prev_intent_pos, intent_pos,
			prev_blade_pos_rel_skater, blade_pos_rel_skater,
			prev_blade_dir, charge_distance, max_charge_direction_variance,
			sweep_time, delta, max_counted_sweep_speed, swing_rotation)
	charge_distance = result.charge
	sweep_time = result.sweep_time
	swing_rotation = result.rotation
	prev_blade_dir = result.direction
	prev_intent_pos = intent_pos
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
