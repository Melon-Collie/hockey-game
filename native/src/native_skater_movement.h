#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

namespace mitts {

// C++ port of Scripts/domain/rules/skater_movement_rules.gd
// (SkaterMovementRules.apply_movement / integrate_forward) plus the one
// BodyCheckRules formula integrate_forward consumes (thrust_mult). The
// GDScript files are the reference; tests/unit/rules/test_native_movement_parity.gd
// fuzzes the implementations against each other. Change them together or not
// at all.
//
// This kernel sits on all three multiplied paths: the live tick (x10
// skaters), reconcile replay (once per unconfirmed input), and stage-3
// remote forward prediction / host lag-comp rewind (integrate_forward's N
// ticks cross the boundary in ONE call here — the loop runs natively).
//
// MovementConfig fields load by property name from the GDScript config
// object via configure(cfg); the stagger scaling needs only two
// BodyCheckRules.Config fields, set via set_stagger_params.

#define MITTS_MOVEMENT_TUNABLES(X) \
	X(thrust) X(friction) X(max_speed) X(move_deadzone) X(brake_multiplier) \
	X(puck_carry_speed_multiplier) X(backward_thrust_multiplier) \
	X(crossover_thrust_multiplier) X(friction_drag) X(sprint_thrust_multiplier) \
	X(sprint_max_speed_multiplier) X(sprint_carry_penalty_bypass) X(lateral_grip)

class NativeSkaterMovement : public godot::RefCounted {
	GDCLASS(NativeSkaterMovement, godot::RefCounted)

	struct Config {
#define X(name) double name = 0.0;
		MITTS_MOVEMENT_TUNABLES(X)
#undef X
	};
	Config cfg;

	double stagger_max_seconds = 0.0;
	double stagger_max_thrust_penalty = 0.0;

	godot::Vector3 fwd_position;
	godot::Vector3 fwd_velocity;

	godot::Vector3 apply_movement_internal(
			const godot::Vector3 &current_velocity,
			const godot::Vector2 &move_input,
			double facing_rotation_y,
			bool has_puck, bool brake, double delta, bool sprint_active,
			double thrust_override) const;

protected:
	static void _bind_methods();

public:
	// Returns a space-separated list of missing property names — empty means
	// every tunable loaded.
	godot::String configure(godot::Object *movement_config);
	void set_stagger_params(double max_stagger_seconds, double max_thrust_penalty);

	godot::Vector3 apply_movement(
			const godot::Vector3 &current_velocity,
			const godot::Vector2 &move_input,
			double facing_rotation_y,
			bool has_puck, bool brake, double delta, bool sprint_active) const;

	void integrate_forward(
			const godot::Vector3 &position,
			const godot::Vector3 &velocity,
			const godot::Vector2 &move_input,
			double facing_rotation_y,
			bool has_puck, bool brake, bool sprint_active,
			double dt, int64_t ticks, int64_t intent_decay_ticks,
			double stagger_timer, bool use_stagger);

	godot::Vector3 get_forward_position() const { return fwd_position; }
	godot::Vector3 get_forward_velocity() const { return fwd_velocity; }
};

} // namespace mitts
