#include "native_blade_dangle.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

using namespace godot;

namespace mitts {

void NativeBladeDangle::set_config(
		double p_max_blade_speed,
		double p_wrister_on_axis_blade_speed,
		double p_max_blade_accel) {
	max_blade_speed = p_max_blade_speed;
	wrister_on_axis_blade_speed = p_wrister_on_axis_blade_speed;
	max_blade_accel = p_max_blade_accel;
}

void NativeBladeDangle::reset_smoothing() {
	smoothed_blade_initialized = false;
	blade_dangle_vel = Vector3();
}

void NativeBladeDangle::seed(const Vector3 &world_pos, const Vector3 &skater_pos) {
	smoothed_blade_world = Vector3(world_pos.x, 0.0, world_pos.z);
	prev_skater_pos = Vector3(skater_pos.x, 0.0, skater_pos.z);
	smoothed_blade_initialized = true;
	blade_dangle_vel = Vector3();
}

Vector3 NativeBladeDangle::advance(
		const Vector3 &target_blade_world,
		const Vector3 &skater_pos,
		double delta,
		bool wrister_aim) {
	if (!smoothed_blade_initialized) {
		smoothed_blade_world = target_blade_world;
		prev_skater_pos = skater_pos;
		smoothed_blade_initialized = true;
		blade_dangle_vel = Vector3();
	}
	smoothed_blade_world += skater_pos - prev_skater_pos;
	smoothed_blade_world.y = 0.0;
	prev_skater_pos = skater_pos;
	Vector3 step = target_blade_world - smoothed_blade_world;
	step.y = 0.0;
	const double max_step = max_blade_speed * delta;
	if (max_step > 0.0) {
		// Wrister on/off-axis split — see skater_ik_coordinator.gd for why the
		// axis reads the LAGGED smoothed blade and why only the on-axis budget
		// is uncapped.
		Vector3 axis_vec = smoothed_blade_world - skater_pos;
		axis_vec.y = 0.0;
		if (wrister_aim && axis_vec.length_squared() > 0.0001) {
			const Vector3 axis = axis_vec.normalized();
			Vector3 on_axis = axis * step.dot(axis);
			Vector3 off_axis = step - on_axis;
			const double on_max = wrister_on_axis_blade_speed * delta;
			const double on_len = on_axis.length();
			if (on_len > on_max) {
				on_axis *= (real_t)(on_max / on_len);
			}
			const double off_len = off_axis.length();
			if (off_len > max_step) {
				off_axis *= (real_t)(max_step / off_len);
			}
			smoothed_blade_world += on_axis + off_axis;
			blade_dangle_vel = (on_axis + off_axis) / (real_t)delta;
		} else if (max_blade_accel > 0.0) {
			// Second-order arrive law (stick inertia) — reasoning in the
			// GDScript reference.
			const double accel = max_blade_accel;
			const double dist = step.length();
			Vector3 desired;
			if (dist > 0.00001) {
				const double arrive_speed = MIN(
						max_blade_speed, Math::sqrt(2.0 * accel * dist));
				desired = step * (real_t)(arrive_speed / dist);
			}
			blade_dangle_vel = blade_dangle_vel.move_toward(desired, (real_t)(accel * delta));
			const Vector3 move = blade_dangle_vel * (real_t)delta;
			if (move.length() >= dist && blade_dangle_vel.dot(step) >= 0.0) {
				smoothed_blade_world = target_blade_world;
			} else {
				smoothed_blade_world += move;
			}
		} else {
			// First-order servo (inertia disabled).
			const double step_len = step.length();
			if (step_len > max_step) {
				smoothed_blade_world += step * (real_t)(max_step / step_len);
				blade_dangle_vel = step * (real_t)(max_step / step_len) / (real_t)delta;
			} else {
				smoothed_blade_world = target_blade_world;
				blade_dangle_vel = delta > 0.0 ? step / (real_t)delta : Vector3();
			}
		}
	}
	// else (delta == 0): reconcile re-apply — keep the replayed smoothed blade
	// (no snap); the translation carry and prev-skater update above still ran.
	return smoothed_blade_world;
}

void NativeBladeDangle::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("set_config", "max_blade_speed", "wrister_on_axis_blade_speed",
					"max_blade_accel"),
			&NativeBladeDangle::set_config);
	ClassDB::bind_method(D_METHOD("reset_smoothing"), &NativeBladeDangle::reset_smoothing);
	ClassDB::bind_method(D_METHOD("seed", "world_pos", "skater_pos"),
			&NativeBladeDangle::seed);
	ClassDB::bind_method(
			D_METHOD("advance", "target_blade_world", "skater_pos", "delta", "wrister_aim"),
			&NativeBladeDangle::advance);
}

} // namespace mitts
