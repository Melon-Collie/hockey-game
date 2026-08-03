#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

namespace mitts {

// C++ port of Scripts/domain/rules/top_hand_ik.gd (TopHandIK). The GDScript
// file is the reference for the math and its reasoning; this port must stay
// behaviorally identical — tests/unit/rules/test_native_ik_parity.gd fuzzes
// the two against each other. Change them together or not at all.
//
// Config fields live as properties on the instance (mirroring the cached-
// config pattern GDScript callers use); solve() stores hand/blade for
// retrieval via get_hand()/get_blade() so no per-call heap allocation crosses
// the boundary.
//
// Scalar intermediates are double on purpose: GDScript's float is 64-bit, so
// double-precision scalars keep this port numerically closest to the
// reference. Vector2/Vector3 component math stays real_t, same as GDScript's.
class NativeTopHandIK : public godot::RefCounted {
	GDCLASS(NativeTopHandIK, godot::RefCounted)

	double stick_length = 0.0;
	double blade_y = 0.0;
	double hand_rest_y = 0.0;
	double hand_y_max = 0.0;
	double rom_forehand_angle_max = 0.0;
	double rom_backhand_angle_max = 0.0;
	double rom_forehand_reach_max = 0.0;
	double rom_backhand_reach_max = 0.0;

	godot::Vector3 hand;
	godot::Vector3 blade;

	godot::Vector2 clamp_aim_to_rom(const godot::Vector2 &aim_dir, double blade_side_sign) const;
	static double stick_horiz_for(double stick_length, double hand_y, double blade_y);

protected:
	static void _bind_methods();

public:
	godot::Vector3 project_blade(
			const godot::Vector3 &shoulder,
			const godot::Vector2 &desired_blade_xz,
			double blade_side_sign) const;
	void solve(
			const godot::Vector3 &shoulder,
			const godot::Vector2 &desired_blade_xz,
			double blade_side_sign);

	godot::Vector3 get_hand() const { return hand; }
	godot::Vector3 get_blade() const { return blade; }

	void set_stick_length(double v) { stick_length = v; }
	double get_stick_length() const { return stick_length; }
	void set_blade_y(double v) { blade_y = v; }
	double get_blade_y() const { return blade_y; }
	void set_hand_rest_y(double v) { hand_rest_y = v; }
	double get_hand_rest_y() const { return hand_rest_y; }
	void set_hand_y_max(double v) { hand_y_max = v; }
	double get_hand_y_max() const { return hand_y_max; }
	void set_rom_forehand_angle_max(double v) { rom_forehand_angle_max = v; }
	double get_rom_forehand_angle_max() const { return rom_forehand_angle_max; }
	void set_rom_backhand_angle_max(double v) { rom_backhand_angle_max = v; }
	double get_rom_backhand_angle_max() const { return rom_backhand_angle_max; }
	void set_rom_forehand_reach_max(double v) { rom_forehand_reach_max = v; }
	double get_rom_forehand_reach_max() const { return rom_forehand_reach_max; }
	void set_rom_backhand_reach_max(double v) { rom_backhand_reach_max = v; }
	double get_rom_backhand_reach_max() const { return rom_backhand_reach_max; }
};

} // namespace mitts
