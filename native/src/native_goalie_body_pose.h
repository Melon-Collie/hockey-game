#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace mitts {

// C++ port of Scripts/controllers/goalie_body_config_builder.gd
// (GoalieBodyConfigBuilder.build and every helper it calls), including the
// stick-aim solve it aliases from Scripts/domain/rules/goalie_stick_rules.gd
// (GoalieStickRules.yaw_to_target / blade_offset_from_wrist). The GDScript
// files are the reference for the math and its reasoning;
// tests/unit/rules/test_native_goalie_pose_parity.gd fuzzes the two
// implementations against each other. Change them together or not at all.
//
// Boundary design: build() takes the full Inputs bundle as arguments (the ten
// booleans packed into a flags bitmask to keep the call coarse) and stores the
// twelve GoalieBodyConfig Vector3s for retrieval via getters — nothing calls
// back into script mid-solve. The 39 float tunables load once via
// configure(controller) (cold path, reads the same @export names
// GoalieController._configure_collaborators pushes into the GDScript builder),
// plus `catches_left` (the one bool export the builder consumes).
// `rvh_body_lean_deg` is builder-local (never pushed from the controller), so
// it keeps the GDScript default and has its own setter instead of a configure
// row. State ids from GoalieStateMachine.State are injected via set_state_ids
// so an enum reorder can't silently desync the port.
//
// Precision mirrors the reference: double for scalar intermediates (GDScript's
// float is 64-bit), godot Vector2/Vector3 (real_t) for the vector values the
// GDScript stores into the shared GoalieBodyConfig scratch.

// Every controller @export the pose builder reads, by its exact property name
// (see GoalieController._configure_collaborators' `_pose.*` block — two rows
// rename on the way in: pad_toe_out_standing_deg/_butterfly_deg land in the
// builder without the _deg suffix).
#define MITTS_GOALIE_POSE_TUNABLES(X) \
	X(active_blade_max_yaw_deg) X(arm_reach_above_chest) X(blocker_max_x_inward) \
	X(blocker_max_x_outward) X(blocker_max_yaw_deg) X(blocker_max_z_reach) \
	X(body_lean_max_deg) X(body_lean_reach_norm) X(glove_max_x_inward) \
	X(glove_max_x_outward) X(glove_max_yaw_deg) X(glove_max_z_reach) \
	X(lunge_extension) X(pad_toe_out_butterfly_deg) X(pad_toe_out_standing_deg) \
	X(paddle_sweep_max_yaw_deg) X(paddle_sweep_x_extension) X(paddle_sweep_y_drop) \
	X(react_hand_y_max) X(react_hand_y_min) X(react_hand_z) \
	X(rvh_post_pad_angle) X(shoulder_pitch_back_max_deg) \
	X(shoulder_pitch_forward_max_deg) X(shoulder_pitch_y_neutral) \
	X(shoulder_pitch_y_range) X(slide_body_lean_deg) X(slide_initial_speed) \
	X(slide_pushoff_lift) X(slide_pushoff_rot_deg) X(standing_sweep_max_yaw_deg) \
	X(standing_sweep_x_extension) X(standing_sweep_y_drop) \
	X(sweep_anim_max_yaw_deg) X(sweep_anim_x_extension) X(sweep_anim_z_extension) \
	X(sweep_windup_max_yaw_deg) X(sweep_windup_x_extension) X(sweep_windup_z_pull)

class NativeGoalieBodyPose : public godot::RefCounted {
	GDCLASS(NativeGoalieBodyPose, godot::RefCounted)

public:
	// build() flags bitmask — one bit per Inputs boolean.
	enum Flags {
		FLAG_READING_PINNED_WINDUP = 1,
		FLAG_REACTING_TO_SHOT = 2,
		FLAG_SHOT_IS_ELEVATED = 4,
		FLAG_ARM_REACTION_PENDING = 8,
		FLAG_BLADE_INTENT_ACTIVE = 16,
		FLAG_PADDLE_SWEEP_ACTIVE = 32,
		FLAG_STANDING_SWEEP_ACTIVE = 64,
		FLAG_PRELEAN_ACTIVE = 128,
		FLAG_PRELEAN_DIRECTIONAL = 256,
		FLAG_PUCK_PLAY_STOPPING = 512,
	};

private:
	struct Config {
#define X(name) double name = 0.0;
		MITTS_GOALIE_POSE_TUNABLES(X)
#undef X
	};
	Config cfg;

	bool catches_left = true;
	// Builder-local tunable — GoalieController never pushes it, so the
	// GDScript default is the live value.
	double rvh_body_lean_deg = 8.0;

	// State ids from GoalieStateMachine.State, injected via set_state_ids.
	int64_t st_standing = -1;
	int64_t st_butterfly = -1;
	int64_t st_recovering = -1;
	int64_t st_rvh_left = -1;
	int64_t st_rvh_right = -1;
	int64_t st_ready = -1;
	int64_t st_sliding = -1;
	int64_t st_coiling = -1;
	int64_t st_vh_left = -1;
	int64_t st_vh_right = -1;
	int64_t st_covering = -1;
	int64_t st_playing_puck = -1;
	int64_t st_catching = -1;
	int64_t st_catching_down = -1;

	// Per-call input bundle (mirror of GoalieBodyConfigBuilder.Inputs),
	// unpacked from build()'s arguments.
	struct In {
		double five_hole_openness = 0.0;
		bool reading_pinned_windup = false;
		bool reacting_to_shot = false;
		bool shot_is_elevated = false;
		double shot_impact_x = 0.0;
		double shot_impact_y = 0.0;
		double current_x = 0.0;
		double goalie_z = 0.0;
		double direction_sign = 1.0;
		double slide_velocity_x = 0.0;
		double slide_dir = 0.0;
		bool arm_reaction_pending = false;
		godot::Vector3 puck_position;
		godot::Vector3 puck_velocity_est;
		bool blade_intent_active = false;
		bool paddle_sweep_active = false;
		bool standing_sweep_active = false;
		double lunge_progress = 0.0;
		double sweep_anim_progress = 0.0;
		double sweep_anim_dir = 0.0;
		double sweep_windup_progress = 0.0;
		bool prelean_active = false;
		bool prelean_directional = false;
		double prelean_impact_x = 0.0;
		double prelean_impact_y = 0.0;
		double prelean_strength = 0.0;
		double prelean_ready_lift = 0.0;
		double left_pad_toe_out = -1.0;
		double right_pad_toe_out = -1.0;
		double head_yaw_deg = 0.0;
		bool puck_play_stopping = false;
		double puck_play_stride_phase = 0.0;
		double puck_play_stride_intensity = 0.0;
	};

	// The twelve GoalieBodyConfig fields of the last build(). Persist across
	// calls, mirroring the GDScript's shared scratch config (an unknown state
	// id leaves them untouched, exactly like the GDScript match's no-op fall-
	// through).
	godot::Vector3 out_left_pad_pos, out_left_pad_rot;
	godot::Vector3 out_right_pad_pos, out_right_pad_rot;
	godot::Vector3 out_body_pos, out_body_rot;
	godot::Vector3 out_head_pos, out_head_rot;
	godot::Vector3 out_glove_pos, out_glove_rot;
	godot::Vector3 out_blocker_pos, out_blocker_rot;

	double resolved_toe_out(double pad_toe) const;
	void set_standing_pose(const In &in);
	void set_ready_pose(const In &in);
	void set_butterfly_pose(const In &in);
	void set_sliding_pose(const In &in);
	void set_covering_pose(const In &in);
	void set_puck_play_pose(const In &in);
	void apply_puck_play_stride(const In &in);
	void set_catching_pose(const In &in, bool down);
	void set_rvh_left_pose();
	void set_rvh_right_pose();
	void set_vh_left_pose();
	void set_vh_right_pose();
	void mirror_hands();
	double blade_yaw_to_puck(const In &in, double max_yaw_deg) const;
	void apply_active_blade_intent(const In &in);
	void apply_blade_intent_for_down_state(const In &in);
	void apply_blade_intent_for_upright_state(const In &in);
	void apply_standing_sweep(const In &in);
	void apply_paddle_sweep(const In &in);
	void apply_lunge(const In &in);
	void apply_sweep_anim(const In &in);
	void apply_prelean(const In &in);
	void apply_elevated_shot_reaction(const In &in);
	double reachable_hand_y(double intercept_y) const;
	void reach_glove(double impact_local_x, double target_y);
	void reach_blocker(double impact_local_x, double target_y);

protected:
	static void _bind_methods();

public:
	// Returns a space-separated list of missing property names — empty means
	// every tunable loaded.
	godot::String configure(godot::Object *controller);
	void set_state_ids(
			int64_t standing, int64_t butterfly, int64_t recovering,
			int64_t rvh_left, int64_t rvh_right, int64_t ready,
			int64_t sliding, int64_t coiling, int64_t vh_left,
			int64_t vh_right, int64_t covering, int64_t playing_puck,
			int64_t catching, int64_t catching_down);

	void set_catches_left(bool v) { catches_left = v; }
	bool get_catches_left() const { return catches_left; }
	void set_rvh_body_lean_deg(double v) { rvh_body_lean_deg = v; }
	double get_rvh_body_lean_deg() const { return rvh_body_lean_deg; }

	void build(
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
			const godot::Vector3 &puck_position,
			const godot::Vector3 &puck_velocity_est,
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
			double puck_play_stride_intensity);

	godot::Vector3 get_left_pad_pos() const { return out_left_pad_pos; }
	godot::Vector3 get_left_pad_rot() const { return out_left_pad_rot; }
	godot::Vector3 get_right_pad_pos() const { return out_right_pad_pos; }
	godot::Vector3 get_right_pad_rot() const { return out_right_pad_rot; }
	godot::Vector3 get_body_pos() const { return out_body_pos; }
	godot::Vector3 get_body_rot() const { return out_body_rot; }
	godot::Vector3 get_head_pos() const { return out_head_pos; }
	godot::Vector3 get_head_rot() const { return out_head_rot; }
	godot::Vector3 get_glove_pos() const { return out_glove_pos; }
	godot::Vector3 get_glove_rot() const { return out_glove_rot; }
	godot::Vector3 get_blocker_pos() const { return out_blocker_pos; }
	godot::Vector3 get_blocker_rot() const { return out_blocker_rot; }

	// All 12 outputs in one crossing (order: left pad pos/rot, right pad
	// pos/rot, body, head, glove, blocker). One small allocation per call —
	// measured cheaper than 12 getter crossings; per-goalie per-tick rate, so
	// the churn is negligible.
	godot::PackedVector3Array get_outputs_packed() const;
};

} // namespace mitts
