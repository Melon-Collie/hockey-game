#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

namespace mitts {

// C++ port of Scripts/domain/rules/bottom_hand_ik.gd (BottomHandIK). The
// GDScript file is the reference; the parity fuzz test keeps them identical.
//
// backhand_angle is a per-tick input, so it is a solve() argument rather than
// a property — one boundary crossing per tick instead of two.
class NativeBottomHandIK : public godot::RefCounted {
	GDCLASS(NativeBottomHandIK, godot::RefCounted)

	double hand_y = 0.0;
	double release_angle_max = 0.0;
	double release_angle_band = 0.0;

protected:
	static void _bind_methods();

public:
	godot::Vector3 solve(
			const godot::Vector3 &shoulder,
			const godot::Vector2 &grip_target_xz,
			double backhand_angle) const;

	void set_hand_y(double v) { hand_y = v; }
	double get_hand_y() const { return hand_y; }
	void set_release_angle_max(double v) { release_angle_max = v; }
	double get_release_angle_max() const { return release_angle_max; }
	void set_release_angle_band(double v) { release_angle_band = v; }
	double get_release_angle_band() const { return release_angle_band; }
};

} // namespace mitts
