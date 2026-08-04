#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/basis.hpp>

namespace mitts {

// C++ port of Scripts/controllers/skater_skating_coordinator.gd
// (SkaterSkatingCoordinator.apply and its state), including the pure helpers
// it calls from Scripts/domain/rules/ (GaitIntentRules, CarveRules,
// HockeyStopRules). The GDScript files are the reference for the math and its
// reasoning; tests/unit/rules/test_native_gait_parity.gd fuzzes the two
// implementations against each other over long stateful sequences. Change
// them together or not at all.
//
// Boundary design: apply() takes the full per-frame input set as arguments
// (bools packed into a flags bitmask to keep the call coarse) and stores the
// 14 pose outputs for retrieval via getters — the caller decides what to do
// with them, and nothing calls back into script mid-solve. The ~126
// controller tunables load once via configure(controller) (cold path, reads
// the same @export names the GDScript coordinator uses).
//
// Precision mirrors the reference: double for scalar intermediates
// (GDScript's float is 64-bit), godot Vector2/Vector3/Basis (real_t) for the
// vector ops.

// Every controller @export the gait reads, by its exact property name.
#define MITTS_GAIT_TUNABLES(X) \
	X(backpedal_ccut_roll_deg) X(backpedal_ccut_sweep_deg) X(backpedal_chest_deg) \
	X(backpedal_pitch_fade) X(backpedal_start) X(backpedal_tuck_fade) \
	X(block_extend_knee_deg) X(block_kneel_hip_deg) X(block_kneel_shin_deg) \
	X(block_pose_blend_speed) X(cadence_cruise_falloff) X(cadence_glide_stance_gain) \
	X(carve_bank_gain) X(carve_bank_knee_accel) X(carve_bank_max_deg) \
	X(carve_base_lean_deg) \
	X(carve_clearance_knee_deg) X(carve_engage_speed) X(carve_forward_ramp) \
	X(carve_min_speed) X(carve_over_pitch_deg) X(carve_over_roll_deg) \
	X(carve_ref_turn_rate) X(carve_rock_fade) X(carve_stance) \
	X(carve_stride_fade) X(carve_under_roll_deg) X(celebration_leg_stance) \
	X(check_drive_lean_deg) X(check_drive_stance) X(check_drive_time) \
	X(crossover_lean_deg) X(crossover_phase_per_turn) X(crossover_scissor_deg) \
	X(dig_in_cadence_rate) X(dig_in_chop) X(dig_in_fade_speed) \
	X(dig_in_intensity) X(dig_in_lean_deg) X(dig_in_stance) \
	X(faceoff_split_deg) X(faceoff_stance) X(follow_through_arc_skew) \
	X(glide_carve_lean_deg) X(glide_hold_skew) X(glide_inside_tuck_deg) \
	X(glide_stance) X(glide_sway_deg) X(glide_sway_hz) \
	X(hip_align_max_deg) X(hip_align_speed) X(hit_commit_crouch_m) \
	X(hit_commit_lean_deg) X(hit_commit_pose_speed) X(hit_commit_shoulder_deg) \
	X(hockey_stop_blend_speed) X(hockey_stop_edge_deg) X(hockey_stop_effort) \
	X(hockey_stop_max_yaw_deg) X(hockey_stop_min_speed) X(hockey_stop_split_deg) \
	X(hockey_stop_stance) X(hockey_stop_trunk_roll_deg) X(intent_signal_speed) \
	X(knockdown_getup_seconds) X(knockdown_pose_drop_m) X(max_speed) \
	X(pivot_band_hi_deg) X(pivot_band_lo_deg) X(pivot_blend_speed) \
	X(pivot_commit_time) X(pivot_depth_ramp_deg) X(pivot_min_speed) \
	X(pivot_rate_min) X(pivot_stance) X(pivot_step_begin) \
	X(pivot_stride_fade) X(pivot_yaw_speed) \
	X(reversal_lean_deg) X(reversal_min_speed) X(reversal_plant_deg) \
	X(reversal_stance) X(reversal_start_opposition) X(reversal_stride_fade) \
	X(shot_stride_fade) X(shuffle_cadence_rate) X(shuffle_fade_speed) \
	X(shuffle_intensity) X(shuffle_start_lateral) X(slapper_kick_back_deg) \
	X(slapper_kick_hip_yaw_deg) X(slapper_kick_knee_extend_deg) \
	X(slapper_kick_lean_deg) X(slapper_kick_min_power) X(slapper_kick_stance) \
	X(slapper_kick_time) X(slapper_load_hip_coil_deg) X(slapper_load_lean_deg) \
	X(slapper_load_split_deg) X(slapper_load_stance) X(sprint_lean_deg) \
	X(sprint_stance_gain) X(sprint_stride_gain) X(stagger_max_seconds) \
	X(stagger_wobble_deg) X(stagger_wobble_hz) X(stance_full_speed_fraction) \
	X(stance_hip_deg) X(stance_knee_release) X(stance_push_gain) \
	X(stick_lift_blend_speed) X(stick_lift_stance) X(stick_lift_trunk_deg) \
	X(stride_abduction_deg) X(stride_back_pitch_deg) X(stride_bob_m) \
	X(stride_cadence) X(stride_cadence_max_rate) X(stride_dig_lean_deg) \
	X(stride_effort_ref_accel) X(stride_effort_speed) X(stride_glide_floor) \
	X(stride_intensity_speed) X(stride_knee_deg) X(stride_pitch_deg) \
	X(stride_push_ceiling) X(stride_push_gain) X(stride_rear_bias) \
	X(stride_roll_deg) X(stride_skew) X(stride_sway_deg) \
	X(weight_shift_deg) X(weight_spring_damping) X(weight_spring_stiffness) \
	X(wrister_kick_back_deg) X(wrister_kick_hip_yaw_deg) \
	X(wrister_kick_knee_extend_deg) X(wrister_kick_lean_deg) \
	X(wrister_kick_min_power) X(wrister_kick_stance) X(wrister_kick_time) \
	X(wrister_load_blend_speed) X(wrister_load_hip_coil_deg) \
	X(wrister_load_lean_deg) X(wrister_load_split_deg) X(wrister_load_stance)

class NativeSkaterGait : public godot::RefCounted {
	GDCLASS(NativeSkaterGait, godot::RefCounted)

public:
	// apply() flags bitmask.
	enum Flags {
		FLAG_BRAKE = 1,
		FLAG_HIT_COMMITTED = 2,
		FLAG_BLADE_UP = 4,
		FLAG_LEFT_HANDED = 8,
		FLAG_SPRINT = 16,
		FLAG_FACEOFF_READY = 32,
	};

	// apply() return codes.
	enum ApplyResult {
		APPLY_ACTIVE = 0,       // outputs valid, write them
		APPLY_SETTLED_HOLD = 1, // settled early-out, skip writes
		APPLY_JUST_SETTLED = 2, // settle edge: write the rest pose once
	};

private:
	struct Config {
#define X(name) double name = 0.0;
		MITTS_GAIT_TUNABLES(X)
#undef X
	};
	Config cfg;

	// Shot-state ids from SkaterStateMachine.State, injected via
	// set_state_ids so an enum reorder can't silently desync the port.
	int64_t st_skating_with_puck = -1;
	int64_t st_skating_without_puck = -1;
	int64_t st_shot_blocking = -1;
	int64_t st_follow_through = -1;
	int64_t st_wrister_aim = -1;
	int64_t st_slapper_charge_with_puck = -1;
	int64_t st_slapper_charge_without_puck = -1;
	int64_t st_one_timer_retention = -1;

	double leg_scale = 1.0;

	// Runtime state — mirrors the GDScript coordinator's fields one-for-one.
	double settle_timer = 0.0;
	bool settled = false;
	double stride_phase = 0.0;
	double trunk_pitch_add = 0.0;
	double trunk_roll_add = 0.0;
	double hit_commit_blend = 0.0;
	double intensity = 0.0;
	double effort = 0.0;
	godot::Vector3 prev_velocity;
	bool have_prev_velocity = false;
	double fd_time = 0.0;
	double fd_effort_target = 0.0;
	double fd_turn = 0.0;
	double fd_carve = 0.0;
	double faceoff_blend = 0.0;
	double stop_yaw_offset = 0.0;
	bool stop_engaged = false;
	double stop_side = 1.0;
	double stop_blend = 0.0;
	double travel_align_yaw = 0.0;
	double hip_align_yaw = 0.0;
	double prev_psi = 0.0;
	bool have_prev_psi = false;
	double psi_smooth = 0.0;
	double psi_rate = 0.0;
	bool pivot_engaged = false;
	double pivot_sense = 1.0;
	double pivot_blend = 0.0;
	double pivot_dwell = 0.0;
	double carve = 0.0;
	double carve_curve = 0.0;
	double turn_rate = 0.0;
	double dig = 0.0;
	double reversal = 0.0;
	double shuffle = 0.0;
	double backpedal = 0.0;
	double glide = 0.0;
	double glide_phase = 0.0;
	double sprint = 0.0;
	double weight_shift = 0.0;
	double weight_shift_vel = 0.0;
	double shot_hip_yaw = 0.0;
	int64_t shot_prev_state = 0;
	double wrister_load = 0.0;
	double slap_load = 0.0;
	double shot_kick_t = -1.0;
	double shot_kick_power = 0.0;
	bool shot_kick_is_slap = false;
	double block_blend = 0.0;
	godot::Vector3 drive_dir;
	double drive_t = -1.0;
	double drive_intensity = 0.0;
	double lift_blend = 0.0;

	// Pose outputs of the last APPLY_ACTIVE pass.
	double out_l_pitch = 0.0, out_l_roll = 0.0, out_l_knee = 0.0;
	double out_r_pitch = 0.0, out_r_roll = 0.0, out_r_knee = 0.0;
	double out_foot_evert_l = 0.0, out_foot_evert_r = 0.0;
	double out_drop = 0.0;

	void reset_state();

protected:
	static void _bind_methods();

public:
	// Returns a space-separated list of missing property names — empty means
	// every tunable loaded.
	godot::String configure(godot::Object *controller);
	void set_state_ids(
			int64_t skating_with_puck, int64_t skating_without_puck,
			int64_t shot_blocking, int64_t follow_through, int64_t wrister_aim,
			int64_t slapper_charge_with_puck, int64_t slapper_charge_without_puck,
			int64_t one_timer_retention);

	void set_leg_scale(double v) { leg_scale = v; }
	double get_leg_scale() const { return leg_scale; }

	void reset_to_rest();
	void start_check_drive(const godot::Vector3 &hit_dir, double p_intensity);

	int64_t apply(
			double delta,
			const godot::Vector3 &velocity,
			const godot::Basis &basis,
			const godot::Vector2 &move_intent,
			int64_t shot_state,
			double shot_charge,
			double stagger_timer,
			double knockdown_timer,
			double celebration_progress,
			int64_t flags);

	double get_l_pitch() const { return out_l_pitch; }
	double get_l_roll() const { return out_l_roll; }
	double get_l_knee() const { return out_l_knee; }
	double get_r_pitch() const { return out_r_pitch; }
	double get_r_roll() const { return out_r_roll; }
	double get_r_knee() const { return out_r_knee; }
	double get_foot_evert_l() const { return out_foot_evert_l; }
	double get_foot_evert_r() const { return out_foot_evert_r; }
	double get_crouch_drop() const { return out_drop; }
	double get_trunk_pitch_add() const { return trunk_pitch_add; }
	double get_trunk_roll_add() const { return trunk_roll_add; }
	double get_stop_yaw_offset() const { return stop_yaw_offset; }
	double get_travel_align_yaw() const { return travel_align_yaw; }
	double get_shot_hip_yaw() const { return shot_hip_yaw; }
	double get_pivot_blend() const { return pivot_blend; }
	double get_stride_phase() const { return stride_phase; }
	bool is_settled() const { return settled; }
};

} // namespace mitts
