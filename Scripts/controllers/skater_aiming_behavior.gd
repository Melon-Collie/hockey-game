class_name SkaterAimingBehavior
extends RefCounted

# ── Wrister charge state ──────────────────────────────────────────────────────
var charge_distance: float = 0.0
var wrister_start_blade_local_x: float = 0.0
# prev_mouse_screen_pos is intentionally public (no underscore): LocalController
# seeds it from _input_history at the start and end of reconcile() replay.
var prev_mouse_screen_pos: Vector2 = Vector2.ZERO
var prev_blade_dir: Vector3 = Vector3.ZERO

# ── Slapper charge state ──────────────────────────────────────────────────────
var slapper_charge_timer: float = 0.0
var one_timer_window_timer: float = 0.0

# ── Wrister ───────────────────────────────────────────────────────────────────

func reset_wrister(initial_mouse_pos: Vector2) -> void:
	charge_distance = 0.0
	prev_blade_dir = Vector3.ZERO
	prev_mouse_screen_pos = initial_mouse_pos


func tick_wrister_charge(
		screen_pos: Vector2,
		max_charge_direction_variance: float,
		max_wrister_charge_distance: float) -> void:
	var scale: float = 0.01 * PlayerPrefs.mouse_sensitivity
	var cur := Vector3(screen_pos.x * scale, 0.0, screen_pos.y * scale)
	var prev := Vector3(prev_mouse_screen_pos.x * scale, 0.0, prev_mouse_screen_pos.y * scale)
	var result: Dictionary = ChargeTracking.accumulate(
			prev, cur, prev_blade_dir, charge_distance, max_charge_direction_variance)
	charge_distance = minf(result.charge, max_wrister_charge_distance)
	prev_blade_dir = result.direction
	prev_mouse_screen_pos = screen_pos

# ── Slapper ───────────────────────────────────────────────────────────────────

func reset_slapper() -> void:
	slapper_charge_timer = 0.0
	one_timer_window_timer = 0.0


func tick_slapper(delta: float) -> void:
	slapper_charge_timer += delta


func tick_one_timer_window(delta: float) -> void:
	if one_timer_window_timer > 0.0:
		one_timer_window_timer -= delta
