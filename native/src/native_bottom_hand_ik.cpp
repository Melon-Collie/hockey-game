#include "native_bottom_hand_ik.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

using namespace godot;

namespace mitts {

Vector3 NativeBottomHandIK::solve(
		const Vector3 &shoulder,
		const Vector2 &grip_target_xz,
		double backhand_angle) const {
	const Vector3 target(grip_target_xz.x, hand_y, grip_target_xz.y);
	const Vector3 rest(shoulder.x, hand_y, shoulder.z);

	const double t = Math::smoothstep(
			release_angle_max, release_angle_max + release_angle_band, backhand_angle);
	return target.lerp(rest, (real_t)t);
}

void NativeBottomHandIK::_bind_methods() {
	ClassDB::bind_method(D_METHOD("solve", "shoulder", "grip_target_xz", "backhand_angle"),
			&NativeBottomHandIK::solve);

	ClassDB::bind_method(D_METHOD("set_hand_y", "v"), &NativeBottomHandIK::set_hand_y);
	ClassDB::bind_method(D_METHOD("get_hand_y"), &NativeBottomHandIK::get_hand_y);
	ClassDB::bind_method(D_METHOD("set_release_angle_max", "v"),
			&NativeBottomHandIK::set_release_angle_max);
	ClassDB::bind_method(D_METHOD("get_release_angle_max"),
			&NativeBottomHandIK::get_release_angle_max);
	ClassDB::bind_method(D_METHOD("set_release_angle_band", "v"),
			&NativeBottomHandIK::set_release_angle_band);
	ClassDB::bind_method(D_METHOD("get_release_angle_band"),
			&NativeBottomHandIK::get_release_angle_band);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hand_y"), "set_hand_y", "get_hand_y");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "release_angle_max"),
			"set_release_angle_max", "get_release_angle_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "release_angle_band"),
			"set_release_angle_band", "get_release_angle_band");
}

} // namespace mitts
