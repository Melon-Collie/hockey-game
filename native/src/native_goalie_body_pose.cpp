#include "native_goalie_body_pose.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cmath>

using namespace godot;

namespace mitts {

// ── Constants aliased from GoalieStickRules (domain/rules/goalie_stick_rules.gd)
// — keep in sync with that file (which itself mirrors Goalie.tscn geometry).
static constexpr double STICK_TILT_STANDING = 22.0; // GoalieStickRules.TILT_STANDING_DEG
static constexpr double STICK_TILT_READY = 22.0; // GoalieStickRules.TILT_READY_DEG
static constexpr double STICK_TILT_BUTTERFLY = 72.0; // GoalieStickRules.TILT_BUTTERFLY_DEG
static constexpr double STICK_TILT_RVH = 65.0; // GoalieStickRules.TILT_RVH_DEG
static constexpr double BLADE_ASSEMBLY_X = -0.15; // GoalieStickRules.ASSEMBLY_LATERAL_M
static constexpr double BLADE_ASSEMBLY_DROP = 0.92; // GoalieStickRules.ASSEMBLY_DROP_M

// Behind-net stride shape constants (GoalieBodyConfigBuilder._STRIDE_*).
static constexpr double STRIDE_SKEW = 0.45;
static constexpr double STRIDE_SWING_M = 0.15;
static constexpr double STRIDE_PITCH_DEG = 16.0;
static constexpr double STRIDE_LIFT_M = 0.05;
static constexpr double STRIDE_BOB_M = 0.025;
static constexpr double STRIDE_LEAN_DEG = 9.0;

// GDScript signf semantics: -1, 0, or +1.
static inline double sgn(double v) {
	return v > 0.0 ? 1.0 : (v < 0.0 ? -1.0 : 0.0);
}

// GDScript angle_difference (godot-cpp 4.5 has no Math::angle_difference) —
// matches Godot core's implementation exactly.
static inline double gd_angle_difference(double p_from, double p_to) {
	const double difference = std::fmod(p_to - p_from, Math_TAU);
	return std::fmod(2.0 * difference, Math_TAU) - difference;
}

// GoalieStickRules.blade_offset_from_wrist — Vector2 (real_t) like the
// GDScript, so the narrowing happens at the same spot.
static inline Vector2 blade_offset_from_wrist(double tilt_deg) {
	return Vector2((real_t)BLADE_ASSEMBLY_X,
			(real_t)(-BLADE_ASSEMBLY_DROP * Math::sin(Math::deg_to_rad(tilt_deg))));
}

// GoalieStickRules.yaw_to_target (see the GDScript for the solve's reasoning).
static double stick_yaw_to_target(double wrist_x, double wrist_z,
		double target_x, double target_z, double tilt_deg, double max_yaw_deg) {
	const double tx = target_x - wrist_x;
	const double tz = target_z - wrist_z;
	if (tx * tx + tz * tz < 0.0004) {
		return 0.0;
	}
	const Vector2 b = blade_offset_from_wrist(tilt_deg);
	if ((double)b.length_squared() < 0.0004) {
		return 0.0;
	}
	const double desired = Math::atan2(-tx, -tz);
	const double base = Math::atan2(-(double)b.x, -(double)b.y);
	return CLAMP(Math::rad_to_deg(gd_angle_difference(base, desired)),
			-max_yaw_deg, max_yaw_deg);
}

// ── NativeGoalieBodyPose ─────────────────────────────────────────────────────

String NativeGoalieBodyPose::configure(Object *controller) {
	ERR_FAIL_NULL_V(controller, String("null controller"));
	String missing;
	// Every macro tunable is a float @export, so a NIL Variant can only mean
	// the property doesn't exist on the controller (renamed/removed export).
#define X(name)                                                          \
	{                                                                    \
		const Variant v = controller->get(StringName(#name));            \
		if (v.get_type() == Variant::NIL) {                              \
			missing += #name " ";                                        \
		} else {                                                         \
			cfg.name = (double)v;                                        \
		}                                                                \
	}
	MITTS_GOALIE_POSE_TUNABLES(X)
#undef X
	// The one bool the builder consumes (GoalieController @export).
	{
		const Variant v = controller->get(StringName("catches_left"));
		if (v.get_type() == Variant::NIL) {
			missing += "catches_left ";
		} else {
			catches_left = (bool)v;
		}
	}
	return missing;
}

void NativeGoalieBodyPose::set_state_ids(
		int64_t standing, int64_t butterfly, int64_t recovering,
		int64_t rvh_left, int64_t rvh_right, int64_t ready,
		int64_t sliding, int64_t coiling, int64_t vh_left,
		int64_t vh_right, int64_t covering, int64_t playing_puck,
		int64_t catching, int64_t catching_down) {
	st_standing = standing;
	st_butterfly = butterfly;
	st_recovering = recovering;
	st_rvh_left = rvh_left;
	st_rvh_right = rvh_right;
	st_ready = ready;
	st_sliding = sliding;
	st_coiling = coiling;
	st_vh_left = vh_left;
	st_vh_right = vh_right;
	st_covering = covering;
	st_playing_puck = playing_puck;
	st_catching = catching;
	st_catching_down = catching_down;
}

// GoalieBodyConfigBuilder._resolved_toe_out
double NativeGoalieBodyPose::resolved_toe_out(double pad_toe) const {
	return pad_toe >= 0.0 ? pad_toe : cfg.pad_toe_out_butterfly_deg;
}

// GoalieBodyConfigBuilder._set_standing_pose
void NativeGoalieBodyPose::set_standing_pose(const In &in) {
	out_left_pad_pos = Vector3((real_t)(-0.22 - in.five_hole_openness), 0.44f, -0.20f);
	out_left_pad_rot = Vector3(0.0f, (real_t)cfg.pad_toe_out_standing_deg, -12.0f);
	out_right_pad_pos = Vector3((real_t)(0.22 + in.five_hole_openness), 0.44f, -0.20f);
	out_right_pad_rot = Vector3(0.0f, (real_t)-cfg.pad_toe_out_standing_deg, 12.0f);
	out_body_pos = Vector3(0.0f, 1.22f, 0.0f);
	out_body_rot = Vector3(-4.0f, 0.0f, 0.0f);
	out_head_pos = Vector3(0.0f, 1.79f, -0.04f);
	out_head_rot = Vector3();
	out_blocker_pos = Vector3(0.38f, 0.85f, -0.18f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_STANDING, 0.0f, -20.0f);
	out_glove_pos = Vector3(-0.35f, 1.19f, -0.18f);
	out_glove_rot = Vector3();
	if (in.reading_pinned_windup) {
		out_glove_pos.y = (real_t)((double)out_glove_pos.y + 0.06);
		out_blocker_pos.y = (real_t)((double)out_blocker_pos.y + 0.06);
	}
}

// GoalieBodyConfigBuilder._set_ready_pose
void NativeGoalieBodyPose::set_ready_pose(const In &in) {
	out_left_pad_pos = Vector3((real_t)(-0.26 - in.five_hole_openness), 0.44f, -0.16f);
	out_left_pad_rot = Vector3(0.0f, (real_t)cfg.pad_toe_out_standing_deg, -10.0f);
	out_right_pad_pos = Vector3((real_t)(0.26 + in.five_hole_openness), 0.44f, -0.16f);
	out_right_pad_rot = Vector3(0.0f, (real_t)-cfg.pad_toe_out_standing_deg, 10.0f);
	out_body_pos = Vector3(0.0f, 1.06f, -0.05f);
	out_body_rot = Vector3(-14.0f, 0.0f, 0.0f);
	out_head_pos = Vector3(0.0f, 1.62f, -0.22f);
	out_head_rot = Vector3();
	out_blocker_pos = Vector3(0.44f, 0.86f, -0.32f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_READY, 0.0f, -20.0f);
	out_glove_pos = Vector3(-0.42f, 0.90f, -0.32f);
	out_glove_rot = Vector3();
	if (in.reading_pinned_windup) {
		out_glove_pos.y = (real_t)((double)out_glove_pos.y + 0.06);
		out_blocker_pos.y = (real_t)((double)out_blocker_pos.y + 0.06);
	}
}

// GoalieBodyConfigBuilder._set_butterfly_pose
void NativeGoalieBodyPose::set_butterfly_pose(const In &in) {
	const double left_toe = resolved_toe_out(in.left_pad_toe_out);
	const double right_toe = resolved_toe_out(in.right_pad_toe_out);
	out_left_pad_pos = Vector3((real_t)(-0.42 - in.five_hole_openness), 0.14f, -0.20f);
	out_left_pad_rot = Vector3(0.0f, (real_t)left_toe, -90.0f);
	out_right_pad_pos = Vector3((real_t)(0.42 + in.five_hole_openness), 0.14f, -0.20f);
	out_right_pad_rot = Vector3(0.0f, (real_t)-right_toe, 90.0f);
	out_body_pos = Vector3(0.0f, 0.40f, 0.0f);
	out_body_rot = Vector3(-10.0f, 0.0f, 0.0f);
	out_head_pos = Vector3(0.0f, 0.97f, -0.06f);
	out_head_rot = Vector3();
	out_blocker_pos = Vector3(0.46f, 0.49f, -0.18f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_BUTTERFLY, 0.0f, 0.0f);
	out_glove_pos = Vector3(-0.42f, 0.44f, -0.18f);
	out_glove_rot = Vector3();
}

// GoalieBodyConfigBuilder._set_sliding_pose
void NativeGoalieBodyPose::set_sliding_pose(const In &in) {
	const double speed_ratio = CLAMP(
			Math::abs(in.slide_velocity_x) / MAX(cfg.slide_initial_speed, 0.01), 0.0, 1.0);
	const double push_lift = cfg.slide_pushoff_lift * speed_ratio;
	const double push_rot = cfg.slide_pushoff_rot_deg * speed_ratio;
	out_body_pos = Vector3(0.0f, 0.40f, 0.0f);
	out_body_rot = Vector3(-10.0f, 0.0f,
			(real_t)(in.slide_dir * -in.direction_sign * cfg.slide_body_lean_deg * speed_ratio));
	out_head_pos = Vector3(0.0f, 0.97f, -0.06f);
	out_head_rot = Vector3();
	out_blocker_pos = Vector3(0.46f, 0.49f, -0.18f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_BUTTERFLY, 0.0f, 0.0f);
	out_glove_pos = Vector3(-0.42f, 0.44f, -0.18f);
	out_glove_rot = Vector3();
	const double left_toe = resolved_toe_out(in.left_pad_toe_out);
	const double right_toe = resolved_toe_out(in.right_pad_toe_out);
	if (in.slide_dir * -in.direction_sign > 0.0) {
		// Sliding right: right pad seals the post, left pad pushes off.
		out_right_pad_pos = Vector3((real_t)(0.42 + in.five_hole_openness), 0.14f, -0.20f);
		out_right_pad_rot = Vector3(0.0f, (real_t)-right_toe, 90.0f);
		out_left_pad_pos = Vector3(-0.42f, (real_t)(0.14 + push_lift), -0.20f);
		out_left_pad_rot = Vector3(0.0f, (real_t)left_toe, (real_t)-(90.0 - push_rot));
	} else {
		// Sliding left: left pad seals the post, right pad pushes off.
		out_left_pad_pos = Vector3((real_t)(-0.42 - in.five_hole_openness), 0.14f, -0.20f);
		out_left_pad_rot = Vector3(0.0f, (real_t)left_toe, -90.0f);
		out_right_pad_pos = Vector3(0.42f, (real_t)(0.14 + push_lift), -0.20f);
		out_right_pad_rot = Vector3(0.0f, (real_t)-right_toe, (real_t)(90.0 - push_rot));
	}
}

// GoalieBodyConfigBuilder._set_covering_pose
void NativeGoalieBodyPose::set_covering_pose(const In &in) {
	const double left_toe = resolved_toe_out(in.left_pad_toe_out);
	const double right_toe = resolved_toe_out(in.right_pad_toe_out);
	out_left_pad_pos = Vector3(-0.42f, 0.14f, -0.20f);
	out_left_pad_rot = Vector3(0.0f, (real_t)left_toe, -90.0f);
	out_right_pad_pos = Vector3(0.42f, 0.14f, -0.20f);
	out_right_pad_rot = Vector3(0.0f, (real_t)-right_toe, 90.0f);
	out_body_pos = Vector3(0.0f, 0.48f, -0.10f);
	out_body_rot = Vector3(-32.0f, 0.0f, 0.0f);
	out_head_pos = Vector3(0.0f, 0.92f, -0.28f);
	out_head_rot = Vector3();
	const double puck_local_x = CLAMP(
			((double)in.puck_position.x - in.current_x) * -in.direction_sign,
			cfg.glove_max_x_outward, Math::abs(cfg.glove_max_x_outward));
	const double puck_local_z = CLAMP(
			((double)in.puck_position.z - in.goalie_z) * -in.direction_sign,
			-0.95, -0.10);
	out_glove_pos = Vector3((real_t)puck_local_x, 0.09f, (real_t)puck_local_z);
	out_glove_rot = Vector3(-70.0f, 0.0f, 0.0f);
	out_blocker_pos = Vector3(0.46f, 0.49f, -0.18f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_BUTTERFLY, 0.0f, 0.0f);
}

// GoalieBodyConfigBuilder._set_puck_play_pose
void NativeGoalieBodyPose::set_puck_play_pose(const In &in) {
	set_ready_pose(in);
	if (!in.puck_play_stopping) {
		apply_puck_play_stride(in);
		return;
	}
	out_blocker_pos = Vector3(0.34f, 0.32f, -0.42f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_BUTTERFLY, 0.0f, -10.0f);
	out_glove_pos = Vector3(-0.38f, 0.55f, -0.30f);
	out_body_rot = Vector3(-18.0f, 0.0f, 0.0f);
}

// GoalieBodyConfigBuilder._set_catching_pose
void NativeGoalieBodyPose::set_catching_pose(const In &in, bool down) {
	if (down) {
		set_butterfly_pose(in);
		out_glove_pos = Vector3(-0.24f, 0.72f, -0.26f);
		out_head_pos = Vector3(-0.06f, 0.95f, -0.12f);
	} else {
		set_ready_pose(in);
		out_glove_pos = Vector3(-0.22f, 0.98f, -0.24f);
		out_head_pos = Vector3(-0.06f, 1.58f, -0.24f);
	}
	out_glove_rot = Vector3(-40.0f, 20.0f, 0.0f);
	out_body_rot = Vector3((real_t)((double)out_body_rot.x - 6.0), 0.0f, 4.0f);
}

// GoalieBodyConfigBuilder._apply_puck_play_stride
void NativeGoalieBodyPose::apply_puck_play_stride(const In &in) {
	const double k = CLAMP(in.puck_play_stride_intensity, 0.0, 1.0);
	if (k <= 0.001) {
		return;
	}
	const double phase = in.puck_play_stride_phase;
	const double s = Math::sin(phase - STRIDE_SKEW * Math::sin(phase));
	const double phase_opp = phase + Math_PI;
	const double s_opp = Math::sin(phase_opp - STRIDE_SKEW * Math::sin(phase_opp));
	// Fore/aft: local -Z is forward. Positive s swings the left pad forward.
	out_left_pad_pos.z = (real_t)((double)out_left_pad_pos.z + -s * STRIDE_SWING_M * k);
	out_right_pad_pos.z = (real_t)((double)out_right_pad_pos.z + -s_opp * STRIDE_SWING_M * k);
	// Recovery lift: only the forward-swinging pad comes off the ice.
	out_left_pad_pos.y = (real_t)((double)out_left_pad_pos.y + MAX(s, 0.0) * STRIDE_LIFT_M * k);
	out_right_pad_pos.y = (real_t)((double)out_right_pad_pos.y + MAX(s_opp, 0.0) * STRIDE_LIFT_M * k);
	// Hip pitch swing rides the same stroke (negative X pitches the pad forward).
	out_left_pad_rot.x = (real_t)((double)out_left_pad_rot.x + -s * STRIDE_PITCH_DEG * k);
	out_right_pad_rot.x = (real_t)((double)out_right_pad_rot.x + -s_opp * STRIDE_PITCH_DEG * k);
	// Body bob (deepest mid-transfer, s = 0) + shoulders driving forward.
	out_body_pos.y = (real_t)((double)out_body_pos.y - STRIDE_BOB_M * (1.0 - s * s) * k);
	out_body_rot.x = (real_t)((double)out_body_rot.x - STRIDE_LEAN_DEG * k);
}

// GoalieBodyConfigBuilder._set_rvh_left_pose
void NativeGoalieBodyPose::set_rvh_left_pose() {
	out_left_pad_pos = Vector3(0.04f, 0.14f, 0.0f);
	out_left_pad_rot = Vector3(0.0f, (real_t)cfg.rvh_post_pad_angle, -90.0f);
	out_right_pad_pos = Vector3(0.45f, 0.33f, 0.0f);
	out_right_pad_rot = Vector3(0.0f, 0.0f, 60.0f);
	out_body_pos = Vector3(-0.02f, 0.60f, 0.05f);
	out_body_rot = Vector3(0.0f, 0.0f, (real_t)rvh_body_lean_deg);
	out_head_pos = Vector3(-0.02f, 1.17f, 0.08f);
	out_head_rot = Vector3();
	out_glove_pos = Vector3(-0.12f, 0.69f, -0.18f);
	out_glove_rot = Vector3();
	out_blocker_pos = Vector3(0.40f, 0.64f, -0.18f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_RVH, 0.0f, -25.0f);
}

// GoalieBodyConfigBuilder._set_vh_left_pose
void NativeGoalieBodyPose::set_vh_left_pose() {
	out_left_pad_pos = Vector3(-0.28f, 0.44f, -0.02f);
	out_left_pad_rot = Vector3(0.0f, 0.0f, -4.0f);
	out_right_pad_pos = Vector3(0.28f, 0.14f, -0.06f);
	out_right_pad_rot = Vector3(0.0f, -12.0f, 90.0f);
	out_body_pos = Vector3(-0.05f, 0.85f, 0.02f);
	out_body_rot = Vector3(-4.0f, 0.0f, (real_t)rvh_body_lean_deg);
	out_head_pos = Vector3(-0.05f, 1.45f, 0.06f);
	out_head_rot = Vector3();
	out_glove_pos = Vector3(-0.30f, 0.90f, -0.14f);
	out_glove_rot = Vector3();
	out_blocker_pos = Vector3(0.36f, 0.68f, -0.16f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_RVH, 0.0f, -25.0f);
}

// GoalieBodyConfigBuilder._set_vh_right_pose
void NativeGoalieBodyPose::set_vh_right_pose() {
	out_right_pad_pos = Vector3(0.28f, 0.44f, -0.02f);
	out_right_pad_rot = Vector3(0.0f, 0.0f, 4.0f);
	out_left_pad_pos = Vector3(-0.28f, 0.14f, -0.06f);
	out_left_pad_rot = Vector3(0.0f, 12.0f, -90.0f);
	out_body_pos = Vector3(0.05f, 0.85f, 0.02f);
	out_body_rot = Vector3(-4.0f, 0.0f, (real_t)-rvh_body_lean_deg);
	out_head_pos = Vector3(0.05f, 1.45f, 0.06f);
	out_head_rot = Vector3();
	out_blocker_pos = Vector3(0.30f, 0.72f, -0.12f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_RVH, 0.0f, 25.0f);
	out_glove_pos = Vector3(-0.36f, 0.68f, -0.16f);
	out_glove_rot = Vector3();
}

// GoalieBodyConfigBuilder._set_rvh_right_pose
void NativeGoalieBodyPose::set_rvh_right_pose() {
	out_right_pad_pos = Vector3(-0.04f, 0.14f, 0.0f);
	out_right_pad_rot = Vector3(0.0f, (real_t)-cfg.rvh_post_pad_angle, 90.0f);
	out_left_pad_pos = Vector3(-0.45f, 0.33f, 0.0f);
	out_left_pad_rot = Vector3(0.0f, 0.0f, -60.0f);
	out_body_pos = Vector3(0.02f, 0.60f, 0.05f);
	out_body_rot = Vector3(0.0f, 0.0f, (real_t)-rvh_body_lean_deg);
	out_head_pos = Vector3(0.02f, 1.17f, 0.08f);
	out_head_rot = Vector3();
	out_blocker_pos = Vector3(0.12f, 0.69f, -0.18f);
	out_blocker_rot = Vector3((real_t)STICK_TILT_RVH, 0.0f, 25.0f);
	out_glove_pos = Vector3(-0.40f, 0.64f, -0.18f);
	out_glove_rot = Vector3();
}

// GoalieBodyConfigBuilder._mirror_hands
void NativeGoalieBodyPose::mirror_hands() {
	const Vector3 tmp_pos = out_glove_pos;
	const Vector3 tmp_rot = out_glove_rot;
	out_glove_pos = Vector3(-out_blocker_pos.x, out_blocker_pos.y, out_blocker_pos.z);
	out_glove_rot = out_blocker_rot;
	out_blocker_pos = Vector3(-tmp_pos.x, tmp_pos.y, tmp_pos.z);
	out_blocker_rot = tmp_rot;
}

// GoalieBodyConfigBuilder._blade_yaw_to_puck
double NativeGoalieBodyPose::blade_yaw_to_puck(const In &in, double max_yaw_deg) const {
	const double px = ((double)in.puck_position.x - in.current_x) * -in.direction_sign;
	const double pz = ((double)in.puck_position.z - in.goalie_z) * -in.direction_sign;
	return stick_yaw_to_target((double)out_blocker_pos.x, (double)out_blocker_pos.z,
			px, pz, (double)out_blocker_rot.x, max_yaw_deg);
}

// GoalieBodyConfigBuilder._apply_active_blade_intent
void NativeGoalieBodyPose::apply_active_blade_intent(const In &in) {
	if (!in.blade_intent_active) {
		return;
	}
	if (in.reacting_to_shot) {
		return;
	}
	out_blocker_rot = Vector3(
			out_blocker_rot.x,
			(real_t)blade_yaw_to_puck(in, cfg.active_blade_max_yaw_deg),
			out_blocker_rot.z);
}

// GoalieBodyConfigBuilder._apply_blade_intent_for_down_state
void NativeGoalieBodyPose::apply_blade_intent_for_down_state(const In &in) {
	if (in.paddle_sweep_active) {
		apply_paddle_sweep(in);
	} else {
		apply_active_blade_intent(in);
	}
}

// GoalieBodyConfigBuilder._apply_blade_intent_for_upright_state
void NativeGoalieBodyPose::apply_blade_intent_for_upright_state(const In &in) {
	if (in.standing_sweep_active) {
		apply_standing_sweep(in);
	} else {
		apply_active_blade_intent(in);
	}
}

// GoalieBodyConfigBuilder._apply_standing_sweep
void NativeGoalieBodyPose::apply_standing_sweep(const In &in) {
	if (in.reacting_to_shot) {
		return;
	}
	const double puck_local_x =
			((double)in.puck_position.x - in.current_x) * -in.direction_sign;
	const double side = sgn(puck_local_x);
	// Extend the wrist toward the puck side FIRST, then solve the blade yaw
	// from the extended wrist — order matters, the solve reads blocker_pos.
	out_blocker_pos = Vector3(
			(real_t)((double)out_blocker_pos.x + side * cfg.standing_sweep_x_extension),
			(real_t)((double)out_blocker_pos.y - cfg.standing_sweep_y_drop),
			out_blocker_pos.z);
	out_blocker_rot = Vector3(
			out_blocker_rot.x,
			(real_t)blade_yaw_to_puck(in, cfg.standing_sweep_max_yaw_deg),
			out_blocker_rot.z);
}

// GoalieBodyConfigBuilder._apply_paddle_sweep
void NativeGoalieBodyPose::apply_paddle_sweep(const In &in) {
	if (in.reacting_to_shot) {
		return;
	}
	const double puck_local_x =
			((double)in.puck_position.x - in.current_x) * -in.direction_sign;
	const double side = sgn(puck_local_x);
	out_blocker_pos = Vector3(
			(real_t)((double)out_blocker_pos.x + side * cfg.paddle_sweep_x_extension),
			(real_t)((double)out_blocker_pos.y - cfg.paddle_sweep_y_drop),
			out_blocker_pos.z);
	out_blocker_rot = Vector3(
			out_blocker_rot.x,
			(real_t)blade_yaw_to_puck(in, cfg.paddle_sweep_max_yaw_deg),
			out_blocker_rot.z);
}

// GoalieBodyConfigBuilder._apply_lunge
void NativeGoalieBodyPose::apply_lunge(const In &in) {
	if (in.lunge_progress <= 0.0) {
		return;
	}
	if (in.reacting_to_shot) {
		return;
	}
	out_blocker_pos = Vector3(
			out_blocker_pos.x,
			out_blocker_pos.y,
			(real_t)((double)out_blocker_pos.z - cfg.lunge_extension * in.lunge_progress));
}

// GoalieBodyConfigBuilder._apply_sweep_anim
void NativeGoalieBodyPose::apply_sweep_anim(const In &in) {
	if (in.reacting_to_shot) {
		return;
	}
	if (in.sweep_windup_progress > 0.0) {
		const double wp = in.sweep_windup_progress;
		const double wdir = in.sweep_anim_dir;
		out_blocker_pos = Vector3(
				(real_t)((double)out_blocker_pos.x - wdir * cfg.sweep_windup_x_extension * wp),
				out_blocker_pos.y,
				(real_t)((double)out_blocker_pos.z + cfg.sweep_windup_z_pull * wp));
		const double wyaw = (double)out_blocker_rot.y + wdir * cfg.sweep_windup_max_yaw_deg * wp;
		out_blocker_rot = Vector3(out_blocker_rot.x,
				(real_t)CLAMP(wyaw, -90.0, 90.0), out_blocker_rot.z);
		return;
	}
	if (in.sweep_anim_progress <= 0.0) {
		return;
	}
	const double p = in.sweep_anim_progress;
	const double dir = in.sweep_anim_dir;
	out_blocker_pos = Vector3(
			(real_t)((double)out_blocker_pos.x + dir * cfg.sweep_anim_x_extension * p),
			out_blocker_pos.y,
			(real_t)((double)out_blocker_pos.z - cfg.sweep_anim_z_extension * p));
	const double yaw = (double)out_blocker_rot.y - dir * cfg.sweep_anim_max_yaw_deg * p;
	out_blocker_rot = Vector3(out_blocker_rot.x,
			(real_t)CLAMP(yaw, -90.0, 90.0), out_blocker_rot.z);
}

// GoalieBodyConfigBuilder._apply_prelean
void NativeGoalieBodyPose::apply_prelean(const In &in) {
	if (!in.prelean_active || in.reacting_to_shot) {
		return;
	}
	const double s = CLAMP(in.prelean_strength, 0.0, 1.0);
	if (s <= 0.0) {
		return;
	}
	if (!in.prelean_directional) {
		// No predicted aim (remote shooter) — just get the hands up, ready.
		out_glove_pos.y = (real_t)((double)out_glove_pos.y + in.prelean_ready_lift * s);
		out_blocker_pos.y = (real_t)((double)out_blocker_pos.y + in.prelean_ready_lift * s);
		return;
	}
	const double impact_local_x =
			(in.prelean_impact_x - in.current_x) * -in.direction_sign;
	const double target_y = reachable_hand_y(in.prelean_impact_y);
	const double lean_factor = CLAMP(
			Math::abs(impact_local_x) / MAX(cfg.body_lean_reach_norm, 0.001), 0.0, 1.0);
	const double lean_sign = sgn(-impact_local_x);
	out_body_rot = Vector3(out_body_rot.x, out_body_rot.y,
			(real_t)((double)out_body_rot.z + lean_sign * lean_factor * cfg.body_lean_max_deg * s));
	if (impact_local_x <= 0.0) {
		const double full_x = CLAMP(impact_local_x, cfg.glove_max_x_outward, cfg.glove_max_x_inward);
		out_glove_pos = out_glove_pos.lerp(
				Vector3((real_t)full_x, (real_t)target_y, out_glove_pos.z), (real_t)s);
	} else {
		const double full_x = CLAMP(impact_local_x, cfg.blocker_max_x_inward, cfg.blocker_max_x_outward);
		out_blocker_pos = out_blocker_pos.lerp(
				Vector3((real_t)full_x, (real_t)target_y, out_blocker_pos.z), (real_t)s);
	}
}

// GoalieBodyConfigBuilder._apply_elevated_shot_reaction (see the GDScript for
// the belief-vs-truth reasoning on the lateral channel).
void NativeGoalieBodyPose::apply_elevated_shot_reaction(const In &in) {
	if (!in.reacting_to_shot || !in.shot_is_elevated) {
		return;
	}
	if (in.arm_reaction_pending) {
		return;
	}
	const double intercept_x = in.shot_impact_x;
	double intercept_y = in.shot_impact_y;
	if (Math::abs((double)in.puck_velocity_est.z) > 0.001) {
		const double dt_to_plane =
				(in.goalie_z - (double)in.puck_position.z) / (double)in.puck_velocity_est.z;
		if (dt_to_plane > 0.0) {
			intercept_y = MAX((double)in.puck_position.y +
							(double)in.puck_velocity_est.y * dt_to_plane -
							0.5 * 9.8 * dt_to_plane * dt_to_plane,
					0.0);
		}
	}
	const double impact_local_x = (intercept_x - in.current_x) * -in.direction_sign;
	const double target_y = reachable_hand_y(intercept_y);
	const double lean_factor = CLAMP(
			Math::abs(impact_local_x) / MAX(cfg.body_lean_reach_norm, 0.001), 0.0, 1.0);
	const double lean_sign = sgn(-impact_local_x);
	const double lean_deg = lean_sign * lean_factor * cfg.body_lean_max_deg;
	double pitch_deg = 0.0;
	if (intercept_y < cfg.shoulder_pitch_y_neutral) {
		const double p = CLAMP((cfg.shoulder_pitch_y_neutral - intercept_y) /
						MAX(cfg.shoulder_pitch_y_neutral, 0.001),
				0.0, 1.0);
		pitch_deg = -cfg.shoulder_pitch_forward_max_deg * p;
	} else {
		const double p = CLAMP((intercept_y - cfg.shoulder_pitch_y_neutral) /
						MAX(cfg.shoulder_pitch_y_range, 0.001),
				0.0, 1.0);
		pitch_deg = cfg.shoulder_pitch_back_max_deg * p;
	}
	out_body_rot = Vector3((real_t)((double)out_body_rot.x + pitch_deg),
			out_body_rot.y, (real_t)lean_deg);
	if (impact_local_x <= 0.0) {
		reach_glove(impact_local_x, target_y);
	} else {
		reach_blocker(impact_local_x, target_y);
	}
}

// GoalieBodyConfigBuilder._reachable_hand_y — reads the chest anchor of the
// pose currently in the out fields.
double NativeGoalieBodyPose::reachable_hand_y(double intercept_y) const {
	const double ceiling = MIN(cfg.react_hand_y_max,
			(double)out_body_pos.y + cfg.arm_reach_above_chest);
	return CLAMP(intercept_y, cfg.react_hand_y_min, MAX(ceiling, cfg.react_hand_y_min));
}

// GoalieBodyConfigBuilder._reach_glove
void NativeGoalieBodyPose::reach_glove(double impact_local_x, double target_y) {
	const double rest_x = (double)out_glove_pos.x;
	const double rest_z = (double)out_glove_pos.z;
	const double glove_x = CLAMP(impact_local_x, cfg.glove_max_x_outward, cfg.glove_max_x_inward);
	const double reach = Math::abs(glove_x - rest_x) /
			MAX(Math::abs(cfg.glove_max_x_outward - rest_x), 0.001);
	const double glove_z = cfg.react_hand_z - cfg.glove_max_z_reach * CLAMP(reach, 0.0, 1.0);
	out_glove_pos = Vector3((real_t)glove_x, (real_t)target_y, (real_t)glove_z);
	const double move_dx = glove_x - rest_x;
	const double move_dz = glove_z - rest_z;
	double yaw_deg = 0.0;
	if (Math::abs(move_dx) > 0.001 || Math::abs(move_dz) > 0.001) {
		yaw_deg = CLAMP(Math::rad_to_deg(Math::atan2(-move_dx, -move_dz)),
				-cfg.glove_max_yaw_deg, cfg.glove_max_yaw_deg);
	}
	out_glove_rot = Vector3(-25.0f, (real_t)yaw_deg, 0.0f);
}

// GoalieBodyConfigBuilder._reach_blocker
void NativeGoalieBodyPose::reach_blocker(double impact_local_x, double target_y) {
	const double rest_x = (double)out_blocker_pos.x;
	const double rest_z = (double)out_blocker_pos.z;
	const double blocker_x = CLAMP(impact_local_x, cfg.blocker_max_x_inward, cfg.blocker_max_x_outward);
	const double reach = Math::abs(blocker_x - rest_x) /
			MAX(Math::abs(cfg.blocker_max_x_outward - rest_x), 0.001);
	const double blocker_z = cfg.react_hand_z - cfg.blocker_max_z_reach * CLAMP(reach, 0.0, 1.0);
	out_blocker_pos = Vector3((real_t)blocker_x, (real_t)target_y, (real_t)blocker_z);
	const double move_dx = blocker_x - rest_x;
	const double move_dz = blocker_z - rest_z;
	double blocker_yaw = 0.0;
	if (Math::abs(move_dx) > 0.001 || Math::abs(move_dz) > 0.001) {
		blocker_yaw = CLAMP(Math::rad_to_deg(Math::atan2(-move_dx, -move_dz)),
				-cfg.blocker_max_yaw_deg, cfg.blocker_max_yaw_deg);
	}
	out_blocker_rot = Vector3(out_blocker_rot.x, (real_t)blocker_yaw, out_blocker_rot.z);
}

// GoalieBodyConfigBuilder.build
void NativeGoalieBodyPose::build(
		int64_t state,
		int64_t flags,
		double five_hole_openness,
		double shot_impact_x,
		double shot_impact_y,
		double current_x,
		double goalie_z,
		int64_t direction_sign,
		double slide_velocity_x,
		double slide_dir,
		const Vector3 &puck_position,
		const Vector3 &puck_velocity_est,
		double lunge_progress,
		double sweep_anim_progress,
		double sweep_anim_dir,
		double sweep_windup_progress,
		double prelean_impact_x,
		double prelean_impact_y,
		double prelean_strength,
		double prelean_ready_lift,
		double left_pad_toe_out,
		double right_pad_toe_out,
		double head_yaw_deg,
		double puck_play_stride_phase,
		double puck_play_stride_intensity) {
	In in;
	in.five_hole_openness = five_hole_openness;
	in.reading_pinned_windup = flags & FLAG_READING_PINNED_WINDUP;
	in.reacting_to_shot = flags & FLAG_REACTING_TO_SHOT;
	in.shot_is_elevated = flags & FLAG_SHOT_IS_ELEVATED;
	in.arm_reaction_pending = flags & FLAG_ARM_REACTION_PENDING;
	in.blade_intent_active = flags & FLAG_BLADE_INTENT_ACTIVE;
	in.paddle_sweep_active = flags & FLAG_PADDLE_SWEEP_ACTIVE;
	in.standing_sweep_active = flags & FLAG_STANDING_SWEEP_ACTIVE;
	in.prelean_active = flags & FLAG_PRELEAN_ACTIVE;
	in.prelean_directional = flags & FLAG_PRELEAN_DIRECTIONAL;
	in.puck_play_stopping = flags & FLAG_PUCK_PLAY_STOPPING;
	in.shot_impact_x = shot_impact_x;
	in.shot_impact_y = shot_impact_y;
	in.current_x = current_x;
	in.goalie_z = goalie_z;
	in.direction_sign = (double)direction_sign;
	in.slide_velocity_x = slide_velocity_x;
	in.slide_dir = slide_dir;
	in.puck_position = puck_position;
	in.puck_velocity_est = puck_velocity_est;
	in.lunge_progress = lunge_progress;
	in.sweep_anim_progress = sweep_anim_progress;
	in.sweep_anim_dir = sweep_anim_dir;
	in.sweep_windup_progress = sweep_windup_progress;
	in.prelean_impact_x = prelean_impact_x;
	in.prelean_impact_y = prelean_impact_y;
	in.prelean_strength = prelean_strength;
	in.prelean_ready_lift = prelean_ready_lift;
	in.left_pad_toe_out = left_pad_toe_out;
	in.right_pad_toe_out = right_pad_toe_out;
	in.head_yaw_deg = head_yaw_deg;
	in.puck_play_stride_phase = puck_play_stride_phase;
	in.puck_play_stride_intensity = puck_play_stride_intensity;

	// Per-state baseline pose, then active blade intent, then elevated-shot
	// reach — same dispatch and helper order as GoalieBodyConfigBuilder.build.
	if (state == st_standing) {
		set_standing_pose(in);
		apply_blade_intent_for_upright_state(in);
		apply_lunge(in);
		apply_sweep_anim(in);
		apply_prelean(in);
		apply_elevated_shot_reaction(in);
	} else if (state == st_ready || state == st_recovering) {
		set_ready_pose(in);
		apply_blade_intent_for_upright_state(in);
		apply_lunge(in);
		apply_sweep_anim(in);
		apply_prelean(in);
		apply_elevated_shot_reaction(in);
	} else if (state == st_butterfly || state == st_coiling) {
		set_butterfly_pose(in);
		apply_blade_intent_for_down_state(in);
		apply_lunge(in);
		apply_sweep_anim(in);
		apply_elevated_shot_reaction(in);
	} else if (state == st_sliding) {
		set_sliding_pose(in);
		apply_blade_intent_for_down_state(in);
		apply_lunge(in);
		apply_sweep_anim(in);
		apply_elevated_shot_reaction(in);
	} else if (state == st_rvh_left) {
		set_rvh_left_pose();
	} else if (state == st_rvh_right) {
		set_rvh_right_pose();
	} else if (state == st_vh_left) {
		set_vh_left_pose();
	} else if (state == st_vh_right) {
		set_vh_right_pose();
	} else if (state == st_covering) {
		set_covering_pose(in);
		apply_sweep_anim(in);
	} else if (state == st_playing_puck) {
		set_puck_play_pose(in);
	} else if (state == st_catching) {
		set_catching_pose(in, false);
	} else if (state == st_catching_down) {
		set_catching_pose(in, true);
	}
	// Head tracking applies in every state — yaw only.
	out_head_rot = Vector3(out_head_rot.x, (real_t)in.head_yaw_deg, out_head_rot.z);
	if (!catches_left) {
		mirror_hands();
	}
}

void NativeGoalieBodyPose::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "controller"),
			&NativeGoalieBodyPose::configure);
	ClassDB::bind_method(D_METHOD("set_state_ids",
			"standing", "butterfly", "recovering", "rvh_left", "rvh_right",
			"ready", "sliding", "coiling", "vh_left", "vh_right", "covering",
			"playing_puck", "catching", "catching_down"),
			&NativeGoalieBodyPose::set_state_ids);
	ClassDB::bind_method(D_METHOD("set_catches_left", "v"),
			&NativeGoalieBodyPose::set_catches_left);
	ClassDB::bind_method(D_METHOD("get_catches_left"),
			&NativeGoalieBodyPose::get_catches_left);
	ClassDB::bind_method(D_METHOD("set_rvh_body_lean_deg", "v"),
			&NativeGoalieBodyPose::set_rvh_body_lean_deg);
	ClassDB::bind_method(D_METHOD("get_rvh_body_lean_deg"),
			&NativeGoalieBodyPose::get_rvh_body_lean_deg);
	ClassDB::bind_method(D_METHOD("build",
			"state", "flags", "five_hole_openness", "shot_impact_x",
			"shot_impact_y", "current_x", "goalie_z", "direction_sign",
			"slide_velocity_x", "slide_dir", "puck_position",
			"puck_velocity_est", "lunge_progress", "sweep_anim_progress",
			"sweep_anim_dir", "sweep_windup_progress", "prelean_impact_x",
			"prelean_impact_y", "prelean_strength", "prelean_ready_lift",
			"left_pad_toe_out", "right_pad_toe_out", "head_yaw_deg",
			"puck_play_stride_phase", "puck_play_stride_intensity"),
			&NativeGoalieBodyPose::build);

	ClassDB::bind_method(D_METHOD("get_left_pad_pos"), &NativeGoalieBodyPose::get_left_pad_pos);
	ClassDB::bind_method(D_METHOD("get_left_pad_rot"), &NativeGoalieBodyPose::get_left_pad_rot);
	ClassDB::bind_method(D_METHOD("get_right_pad_pos"), &NativeGoalieBodyPose::get_right_pad_pos);
	ClassDB::bind_method(D_METHOD("get_right_pad_rot"), &NativeGoalieBodyPose::get_right_pad_rot);
	ClassDB::bind_method(D_METHOD("get_body_pos"), &NativeGoalieBodyPose::get_body_pos);
	ClassDB::bind_method(D_METHOD("get_body_rot"), &NativeGoalieBodyPose::get_body_rot);
	ClassDB::bind_method(D_METHOD("get_head_pos"), &NativeGoalieBodyPose::get_head_pos);
	ClassDB::bind_method(D_METHOD("get_head_rot"), &NativeGoalieBodyPose::get_head_rot);
	ClassDB::bind_method(D_METHOD("get_glove_pos"), &NativeGoalieBodyPose::get_glove_pos);
	ClassDB::bind_method(D_METHOD("get_glove_rot"), &NativeGoalieBodyPose::get_glove_rot);
	ClassDB::bind_method(D_METHOD("get_blocker_pos"), &NativeGoalieBodyPose::get_blocker_pos);
	ClassDB::bind_method(D_METHOD("get_blocker_rot"), &NativeGoalieBodyPose::get_blocker_rot);
	ClassDB::bind_method(D_METHOD("get_outputs_packed"),
			&NativeGoalieBodyPose::get_outputs_packed);

	BIND_CONSTANT(FLAG_READING_PINNED_WINDUP);
	BIND_CONSTANT(FLAG_REACTING_TO_SHOT);
	BIND_CONSTANT(FLAG_SHOT_IS_ELEVATED);
	BIND_CONSTANT(FLAG_ARM_REACTION_PENDING);
	BIND_CONSTANT(FLAG_BLADE_INTENT_ACTIVE);
	BIND_CONSTANT(FLAG_PADDLE_SWEEP_ACTIVE);
	BIND_CONSTANT(FLAG_STANDING_SWEEP_ACTIVE);
	BIND_CONSTANT(FLAG_PRELEAN_ACTIVE);
	BIND_CONSTANT(FLAG_PRELEAN_DIRECTIONAL);
	BIND_CONSTANT(FLAG_PUCK_PLAY_STOPPING);
}

} // namespace mitts

namespace mitts {

godot::PackedVector3Array NativeGoalieBodyPose::get_outputs_packed() const {
	godot::PackedVector3Array out;
	out.resize(12);
	godot::Vector3 *w = out.ptrw();
	w[0] = out_left_pad_pos;
	w[1] = out_left_pad_rot;
	w[2] = out_right_pad_pos;
	w[3] = out_right_pad_rot;
	w[4] = out_body_pos;
	w[5] = out_body_rot;
	w[6] = out_head_pos;
	w[7] = out_head_rot;
	w[8] = out_glove_pos;
	w[9] = out_glove_rot;
	w[10] = out_blocker_pos;
	w[11] = out_blocker_rot;
	return out;
}

} // namespace mitts
