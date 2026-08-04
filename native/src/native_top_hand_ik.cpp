#include "native_top_hand_ik.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

using namespace godot;

namespace mitts {

Vector3 NativeTopHandIK::project_blade(
		const Vector3 &shoulder,
		const Vector2 &desired_blade_xz,
		double blade_side_sign) const {
	const double stick_horiz_at_rest = stick_horiz_for(stick_length, hand_rest_y, blade_y);

	const Vector2 shoulder_xz(shoulder.x, shoulder.z);
	const Vector2 delta = desired_blade_xz - shoulder_xz;
	double r = delta.length();
	Vector2 aim_dir = r > 0.0001 ? delta / (real_t)r : Vector2(0.0, -1.0);
	// Obstacle cap (the boards) on the desired DISTANCE, before the regime split
	// — see top_hand_ik.gd for why it lands here and not on the solved pose.
	r = MIN(r, MAX(max_blade_reach, 0.0));

	// CLOSE regime: see top_hand_ik.gd for why the aim is clamped to the same
	// angular ROM the FAR regime enforces, and why hand_y_max is the inner
	// boundary of a long stick's reachable region.
	if (r < stick_horiz_at_rest) {
		aim_dir = clamp_aim_to_rom(aim_dir, blade_side_sign);
		const double ideal_drop_sq = stick_length * stick_length - r * r;
		const double ideal_hand_y = blade_y + Math::sqrt(MAX(ideal_drop_sq, 0.0));
		const double hand_y = MIN(ideal_hand_y, hand_y_max);
		const double stick_horiz = stick_horiz_for(stick_length, hand_y, blade_y);
		const Vector2 close_blade_xz = shoulder_xz + aim_dir * (real_t)stick_horiz;
		return Vector3(close_blade_xz.x, blade_y, close_blade_xz.y);
	}

	// FAR regime: hand displaces toward the target in XZ, clamped to the
	// asymmetric ROM; the blade sits stick_horiz_at_rest farther along the
	// clamped direction.
	const Vector2 disp = aim_dir * (real_t)(r - stick_horiz_at_rest);

	// Forehand-signed polar (see top_hand_ik.gd for the handedness reasoning).
	const double angle_raw = Math::atan2((double)disp.x, (double)-disp.y);
	double angle_to_forehand = angle_raw * blade_side_sign;
	double radius = disp.length();

	angle_to_forehand = CLAMP(
			angle_to_forehand, -rom_backhand_angle_max, rom_forehand_angle_max);

	// Asymmetric max reach with a small linear blend across zero.
	const double blend_band = Math::deg_to_rad(5.0);
	double max_reach;
	if (angle_to_forehand >= blend_band) {
		max_reach = rom_forehand_reach_max;
	} else if (angle_to_forehand <= -blend_band) {
		max_reach = rom_backhand_reach_max;
	} else {
		const double t = (angle_to_forehand + blend_band) / (2.0 * blend_band);
		max_reach = Math::lerp(rom_backhand_reach_max, rom_forehand_reach_max, t);
	}
	radius = CLAMP(radius, 0.0, max_reach);

	// Clamped world angle, not hand_to_target — holds the blade at the ROM
	// limit instead of wrapping when the cursor moves further past it.
	const double world_angle = angle_to_forehand * blade_side_sign;
	const Vector2 blade_dir(Math::sin(world_angle), -Math::cos(world_angle));
	const Vector2 blade_xz = shoulder_xz + blade_dir * (real_t)(radius + stick_horiz_at_rest);
	return Vector3(blade_xz.x, blade_y, blade_xz.y);
}

void NativeTopHandIK::solve(
		const Vector3 &shoulder,
		const Vector2 &desired_blade_xz,
		double blade_side_sign) {
	blade = project_blade(shoulder, desired_blade_xz, blade_side_sign);

	// Hand reconstructed from the blade — colinear from the shoulder with a
	// rigid stick, so blade distance fully determines the hand (inverts exactly
	// even when the close-regime hand_y was clamped).
	const Vector2 shoulder_xz(shoulder.x, shoulder.z);
	const Vector2 from_shoulder = Vector2(blade.x, blade.z) - shoulder_xz;
	const double d = from_shoulder.length();
	const double stick_horiz_at_rest = stick_horiz_for(stick_length, hand_rest_y, blade_y);
	if (d >= stick_horiz_at_rest) {
		const Vector2 dir = d > 0.0001 ? from_shoulder / (real_t)d : Vector2(0.0, -1.0);
		const Vector2 hand_xz = shoulder_xz + dir * (real_t)(d - stick_horiz_at_rest);
		hand = Vector3(hand_xz.x, hand_rest_y, hand_xz.y);
	} else {
		const double drop_sq = stick_length * stick_length - d * d;
		const double hand_y = blade_y + Math::sqrt(MAX(drop_sq, 0.0));
		hand = Vector3(shoulder_xz.x, hand_y, shoulder_xz.y);
	}
}

Vector2 NativeTopHandIK::clamp_aim_to_rom(const Vector2 &aim_dir, double blade_side_sign) const {
	const double angle_to_forehand =
			Math::atan2((double)aim_dir.x, (double)-aim_dir.y) * blade_side_sign;
	const double clamped = CLAMP(
			angle_to_forehand, -rom_backhand_angle_max, rom_forehand_angle_max);
	if (clamped == angle_to_forehand) {
		return aim_dir;
	}
	const double world_angle = clamped * blade_side_sign;
	return Vector2(Math::sin(world_angle), -Math::cos(world_angle));
}

double NativeTopHandIK::stick_horiz_for(double stick_length, double hand_y, double blade_y) {
	const double drop = hand_y - blade_y;
	const double sq = stick_length * stick_length - drop * drop;
	return Math::sqrt(MAX(sq, 0.0001));
}

void NativeTopHandIK::_bind_methods() {
	ClassDB::bind_method(D_METHOD("project_blade", "shoulder", "desired_blade_xz", "blade_side_sign"),
			&NativeTopHandIK::project_blade);
	ClassDB::bind_method(D_METHOD("solve", "shoulder", "desired_blade_xz", "blade_side_sign"),
			&NativeTopHandIK::solve);
	ClassDB::bind_method(D_METHOD("get_hand"), &NativeTopHandIK::get_hand);
	ClassDB::bind_method(D_METHOD("get_blade"), &NativeTopHandIK::get_blade);

	ClassDB::bind_method(D_METHOD("set_stick_length", "v"), &NativeTopHandIK::set_stick_length);
	ClassDB::bind_method(D_METHOD("get_stick_length"), &NativeTopHandIK::get_stick_length);
	ClassDB::bind_method(D_METHOD("set_blade_y", "v"), &NativeTopHandIK::set_blade_y);
	ClassDB::bind_method(D_METHOD("get_blade_y"), &NativeTopHandIK::get_blade_y);
	ClassDB::bind_method(D_METHOD("set_hand_rest_y", "v"), &NativeTopHandIK::set_hand_rest_y);
	ClassDB::bind_method(D_METHOD("get_hand_rest_y"), &NativeTopHandIK::get_hand_rest_y);
	ClassDB::bind_method(D_METHOD("set_hand_y_max", "v"), &NativeTopHandIK::set_hand_y_max);
	ClassDB::bind_method(D_METHOD("get_hand_y_max"), &NativeTopHandIK::get_hand_y_max);
	ClassDB::bind_method(D_METHOD("set_rom_forehand_angle_max", "v"),
			&NativeTopHandIK::set_rom_forehand_angle_max);
	ClassDB::bind_method(D_METHOD("get_rom_forehand_angle_max"),
			&NativeTopHandIK::get_rom_forehand_angle_max);
	ClassDB::bind_method(D_METHOD("set_rom_backhand_angle_max", "v"),
			&NativeTopHandIK::set_rom_backhand_angle_max);
	ClassDB::bind_method(D_METHOD("get_rom_backhand_angle_max"),
			&NativeTopHandIK::get_rom_backhand_angle_max);
	ClassDB::bind_method(D_METHOD("set_rom_forehand_reach_max", "v"),
			&NativeTopHandIK::set_rom_forehand_reach_max);
	ClassDB::bind_method(D_METHOD("get_rom_forehand_reach_max"),
			&NativeTopHandIK::get_rom_forehand_reach_max);
	ClassDB::bind_method(D_METHOD("set_rom_backhand_reach_max", "v"),
			&NativeTopHandIK::set_rom_backhand_reach_max);
	ClassDB::bind_method(D_METHOD("get_rom_backhand_reach_max"),
			&NativeTopHandIK::get_rom_backhand_reach_max);
	ClassDB::bind_method(D_METHOD("set_max_blade_reach", "v"),
			&NativeTopHandIK::set_max_blade_reach);
	ClassDB::bind_method(D_METHOD("get_max_blade_reach"),
			&NativeTopHandIK::get_max_blade_reach);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stick_length"), "set_stick_length", "get_stick_length");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "blade_y"), "set_blade_y", "get_blade_y");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hand_rest_y"), "set_hand_rest_y", "get_hand_rest_y");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hand_y_max"), "set_hand_y_max", "get_hand_y_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rom_forehand_angle_max"),
			"set_rom_forehand_angle_max", "get_rom_forehand_angle_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rom_backhand_angle_max"),
			"set_rom_backhand_angle_max", "get_rom_backhand_angle_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rom_forehand_reach_max"),
			"set_rom_forehand_reach_max", "get_rom_forehand_reach_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rom_backhand_reach_max"),
			"set_rom_backhand_reach_max", "get_rom_backhand_reach_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_blade_reach"),
			"set_max_blade_reach", "get_max_blade_reach");
}

} // namespace mitts
