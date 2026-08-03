#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

namespace mitts {

// C++ port of the blade-dangle smoothing core of
// Scripts/controllers/skater_ik_coordinator.gd (SkaterIKCoordinator
// .apply_blade_from_mouse step 2, plus reset_blade_smoothing /
// seed_blade_smoothing). The GDScript file is the reference for the math and
// its reasoning; tests/unit/controllers/test_native_blade_dangle_parity.gd
// drives the two against each other over long stateful sequences. Change
// them together or not at all.
//
// The cross-tick state (smoothed blade, previous skater position, dangle
// velocity, init flag) lives here in native mode — advance() runs the whole
// per-tick body: init branch, skater-translation carry, y-zeroing, the
// wrister on/off-axis split, the second-order arrive law, the first-order
// fallback, and the delta == 0 no-op semantics (reconcile re-apply must NOT
// snap; the translation carry and prev-skater update still happen).
//
// Scalar intermediates are double on purpose: GDScript's float is 64-bit, so
// double-precision scalars keep this port numerically closest to the
// reference. Vector3 component math stays real_t, same as GDScript's.
class NativeBladeDangle : public godot::RefCounted {
	GDCLASS(NativeBladeDangle, godot::RefCounted)

	// Controller @export tunables, synced via set_config from
	// SkaterIKCoordinator._sync_dangle_config.
	double max_blade_speed = 0.0;
	double wrister_on_axis_blade_speed = 0.0;
	double max_blade_accel = 0.0;

	// Runtime state — mirrors the GDScript coordinator's fields one-for-one.
	godot::Vector3 smoothed_blade_world;
	godot::Vector3 blade_dangle_vel;
	godot::Vector3 prev_skater_pos;
	bool smoothed_blade_initialized = false;

protected:
	static void _bind_methods();

public:
	void set_config(
			double p_max_blade_speed,
			double p_wrister_on_axis_blade_speed,
			double p_max_blade_accel);

	void reset_smoothing();
	void seed(const godot::Vector3 &world_pos, const godot::Vector3 &skater_pos);

	godot::Vector3 advance(
			const godot::Vector3 &target_blade_world,
			const godot::Vector3 &skater_pos,
			double delta,
			bool wrister_aim);
};

} // namespace mitts
