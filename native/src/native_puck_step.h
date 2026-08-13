#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace mitts {

// C++ port of the loose-puck analytic step — the shared kernel behind the
// host drive (Puck._drive_analytic), the client's per-frame re-prediction
// (PuckController._run_prediction), and reconcile. GDScript references:
//   Scripts/domain/ai/trajectory.gd            (_step, step_puck, step_puck_3d)
//   Scripts/domain/rules/puck_authority_rules.gd (advance_loose_puck,
//                                                 frame_substeps, step_frame_substep)
//   Scripts/domain/rules/puck_geometry_collision.gd (posts/crossbar/net panels)
//   Scripts/domain/rules/puck_collision_rules.gd  (deflect_velocity)
//   Scripts/domain/rules/swept_disc_obb.gd        (contact)
//   Scripts/domain/config/game_rules.gd           (clamp_to_rink_inner, with margin)
// Those files are the behavioral reference — parity is pinned by
// tests/unit/rules/test_native_puck_step_parity.gd; change both or neither.
// Determinism note: host drive and client prediction must agree by
// construction, so a production wiring must swap BOTH callers to this port at
// once, never one side.
//
// Geometry and material constants are injected from GDScript symbols
// (GameRules.*, PuckGeometryCollision.*, PuckAuthorityRules.*) via the
// set_* methods so a constant edit can't silently desync the port — the
// parity test compares against the live GDScript values.
class NativePuckStep : public godot::RefCounted {
	GDCLASS(NativePuckStep, godot::RefCounted)

	// Rink (GameRules.clamp_to_rink_inner inputs).
	double inner_half_width = 0.0;
	double inner_half_length = 0.0;
	double inner_corner_radius = 0.0;
	double corner_center_x = 0.0;
	double corner_center_z = 0.0;

	// Puck material / integration (GameRules.*).
	double board_bounce = 0.0;
	double board_friction = 0.0;
	double ice_decel = 0.0;
	double gravity = 0.0;
	double rest_height = 0.0;

	// Net / goal frame (GameRules.* + PuckGeometryCollision.*).
	double goal_line_z = 0.0;
	double net_half_width = 0.0;
	double net_post_radius = 0.0;
	double net_depth = 0.0;
	double net_back_half_width = 0.0;
	double net_height = 0.0;
	double net_crown_half_width = 0.0;
	double net_mouth_corner_radius = 0.0;
	double net_top_depth = 0.0;
	double puck_half_height = 0.0;
	double post_restitution = 0.0;
	double net_restitution = 0.0;

	// Sub-step law (PuckAuthorityRules.*).
	double substep_range_z = 0.0;
	double substep_m = 0.0;
	int64_t max_substeps = 1;

	// step / step_tick outputs.
	godot::Vector3 out_position;
	godot::Vector3 out_velocity;
	bool out_touched_post = false;
	bool out_touched_net = false;

	// obb_contact outputs.
	double obb_toi = 0.0;
	godot::Vector3 obb_point;
	godot::Vector3 obb_normal;
	double obb_depth = 0.0;

	godot::Vector2 clamp_to_rink_inner(const godot::Vector2 &world_xz, double margin) const;
	godot::Vector3 deflect_velocity_h(const godot::Vector3 &incoming, const godot::Vector3 &normal,
			double restitution) const;
	static godot::Vector3 reflect_3d(const godot::Vector3 &vel, const godot::Vector3 &normal,
			double restitution);
	void step_core(godot::Vector3 &p, godot::Vector3 &v, double dt,
			double decel, double bounce, const godot::Vector3 &accel,
			double max_speed_cap, double b_friction, double board_margin) const;
	void step_puck_3d(godot::Vector3 &p, godot::Vector3 &v, double dt, double ice_height,
			double puck_radius) const;
	void advance_loose_puck(godot::Vector3 &p, godot::Vector3 &v, double dt,
			double puck_radius, double max_speed, double ice_height, double max_height) const;
	bool resolve_one_post(godot::Vector3 &p, godot::Vector3 &v, double puck_radius,
			double post_x, double end_z) const;
	bool resolve_posts(godot::Vector3 &p, godot::Vector3 &v, double puck_radius) const;
	bool resolve_crossbar(godot::Vector3 &p, godot::Vector3 &v, double puck_radius) const;
	bool resolve_crossbar_bends(godot::Vector3 &p, godot::Vector3 &v, double puck_radius) const;
	double post_top_y() const;
	godot::Vector3 closest_point_on_bend(const godot::Vector3 &p, double end_z) const;
	bool resolve_top_net(const godot::Vector3 &prev, godot::Vector3 &p, godot::Vector3 &v) const;
	double back_plane_distance(const godot::Vector3 &p) const;
	bool within_back_panel(double x, double slack) const;
	double back_plane_norm() const;
	godot::Vector3 back_plane_normal(double end_sign) const;
	double back_slope() const;
	double back_depth_at_height(double y) const;
	bool interior_or_mouth(const godot::Vector3 &p) const;
	bool resolve_net_panels(const godot::Vector3 &prev, godot::Vector3 &p, godot::Vector3 &v,
			double puck_radius) const;

protected:
	static void _bind_methods();

public:
	void set_rink_geometry(double p_inner_half_width, double p_inner_half_length,
			double p_inner_corner_radius, double p_corner_center_x, double p_corner_center_z);
	void set_puck_params(double p_board_bounce, double p_board_friction,
			double p_ice_decel, double p_gravity, double p_rest_height);
	void set_net_geometry(double p_goal_line_z, double p_net_half_width,
			double p_net_post_radius, double p_net_depth, double p_net_back_half_width,
			double p_net_height, double p_net_crown_half_width,
			double p_net_mouth_corner_radius, double p_net_top_depth,
			double p_puck_half_height, double p_post_restitution, double p_net_restitution);
	void set_substep_params(double p_range_z, double p_substep_m, int64_t p_max_substeps);

	int64_t frame_substeps(double pos_z, double speed, double dt) const;

	// One sub-step (mirrors PuckAuthorityRules.step_frame_substep). Touched
	// flags OR-accumulate across calls — clear_touched() per tick, like the
	// GDScript caller clearing its TickResult.
	void step_frame_substep(const godot::Vector3 &pos, const godot::Vector3 &vel,
			double sub_dt, double puck_radius, double max_speed,
			double ice_height, double max_height);

	// One full tick: frame_substeps(...) sub-steps run natively in one call.
	// Composition of the two calls above — valid only when no goalie
	// interleaving is needed this tick (the caller owns that gate).
	void step_tick(const godot::Vector3 &pos, const godot::Vector3 &vel,
			double dt, double puck_radius, double max_speed,
			double ice_height, double max_height);

	void clear_touched();
	godot::Vector3 get_position() const { return out_position; }
	godot::Vector3 get_velocity() const { return out_velocity; }
	bool get_touched_post() const { return out_touched_post; }
	bool get_touched_net() const { return out_touched_net; }

	// SweptDiscOBB.contact. Returns hit; details via the obb_* getters.
	bool obb_contact(const godot::Vector3 &prev, const godot::Vector3 &curr,
			double radius, const godot::Transform3D &box_transform,
			const godot::Vector3 &half_extents);

	// Nearest contact (smallest toi, first wins ties) over `count` boxes packed
	// 15 floats each: basis columns x,y,z (9), origin (3), half extents (3) —
	// gathered ONCE per tick by the caller so the per-sub-step test crosses the
	// boundary once with zero engine property reads. Returns the winning box
	// index or -1; details via the obb_* getters.
	int64_t obb_nearest(const godot::Vector3 &prev, const godot::Vector3 &curr,
			double radius, const godot::PackedFloat32Array &boxes, int64_t count);
	double get_obb_toi() const { return obb_toi; }
	godot::Vector3 get_obb_point() const { return obb_point; }
	godot::Vector3 get_obb_normal() const { return obb_normal; }
	double get_obb_depth() const { return obb_depth; }
};

} // namespace mitts
