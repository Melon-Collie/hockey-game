#include "native_puck_step.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

using namespace godot;

namespace mitts {

// AITrajectory airborne epsilons.
static constexpr double AIRBORNE_POS_EPS_M = 0.001;
static constexpr double AIRBORNE_VY_EPS_M_S = 0.05;

// GDScript signf/sign semantics: -1, 0, or +1.
static inline double sgn(double v) {
	return v > 0.0 ? 1.0 : (v < 0.0 ? -1.0 : 0.0);
}

// ── Setters ──────────────────────────────────────────────────────────────────

void NativePuckStep::set_rink_geometry(double p_inner_half_width, double p_inner_half_length,
		double p_inner_corner_radius, double p_corner_center_x, double p_corner_center_z) {
	inner_half_width = p_inner_half_width;
	inner_half_length = p_inner_half_length;
	inner_corner_radius = p_inner_corner_radius;
	corner_center_x = p_corner_center_x;
	corner_center_z = p_corner_center_z;
}

void NativePuckStep::set_puck_params(double p_board_bounce, double p_board_friction,
		double p_ice_decel, double p_gravity, double p_rest_height) {
	board_bounce = p_board_bounce;
	board_friction = p_board_friction;
	ice_decel = p_ice_decel;
	gravity = p_gravity;
	rest_height = p_rest_height;
}

void NativePuckStep::set_net_geometry(double p_goal_line_z, double p_net_half_width,
		double p_net_post_radius, double p_net_depth, double p_net_back_half_width,
		double p_net_height, double p_net_crown_half_width, double p_net_top_depth,
		double p_puck_half_height, double p_post_restitution, double p_net_restitution) {
	goal_line_z = p_goal_line_z;
	net_half_width = p_net_half_width;
	net_post_radius = p_net_post_radius;
	net_depth = p_net_depth;
	net_back_half_width = p_net_back_half_width;
	net_height = p_net_height;
	net_crown_half_width = p_net_crown_half_width;
	net_top_depth = p_net_top_depth;
	puck_half_height = p_puck_half_height;
	post_restitution = p_post_restitution;
	net_restitution = p_net_restitution;
}

void NativePuckStep::set_substep_params(double p_range_z, double p_substep_m, int64_t p_max_substeps) {
	substep_range_z = p_range_z;
	substep_m = p_substep_m;
	max_substeps = p_max_substeps;
}

// ── GameRules.clamp_to_rink_inner (margin 0) ─────────────────────────────────

Vector2 NativePuckStep::clamp_to_rink_inner(const Vector2 &world_xz) const {
	const double half_w = inner_half_width;
	const double half_l = inner_half_length;
	const double corner_r = inner_corner_radius;
	const double ax = Math::abs((double)world_xz.x);
	const double az = Math::abs((double)world_xz.y);
	if (ax > corner_center_x && az > corner_center_z) {
		const double dx = ax - corner_center_x;
		const double dz = az - corner_center_z;
		const double dist = Math::sqrt(dx * dx + dz * dz);
		if (dist > corner_r) {
			const double scale = corner_r / dist;
			return Vector2(
					sgn(world_xz.x) * (corner_center_x + dx * scale),
					sgn(world_xz.y) * (corner_center_z + dz * scale));
		}
	} else {
		if (ax > half_w) {
			return Vector2(sgn(world_xz.x) * half_w, world_xz.y);
		}
		if (az > half_l) {
			return Vector2(world_xz.x, sgn(world_xz.y) * half_l);
		}
	}
	return world_xz;
}

// ── PuckCollisionRules.deflect_velocity (defaults: no falloff, full tangent) ─

Vector3 NativePuckStep::deflect_velocity_h(const Vector3 &incoming, const Vector3 &normal,
		double restitution) const {
	const Vector3 horiz(incoming.x, 0.0f, incoming.z);
	const double speed = horiz.length();
	if (speed < 0.0001) {
		return Vector3();
	}
	Vector3 n(normal.x, 0.0f, normal.z);
	if ((double)n.length() < 0.0001) {
		return horiz;
	}
	n = n.normalized();
	const Vector3 v_normal = n * horiz.dot(n);
	const Vector3 v_tangent = horiz - v_normal;
	return v_tangent - v_normal * (real_t)restitution;
}

// ── PuckGeometryCollision.reflect_3d ─────────────────────────────────────────

Vector3 NativePuckStep::reflect_3d(const Vector3 &vel, const Vector3 &normal, double restitution) {
	const Vector3 n = normal.normalized();
	const double vn = vel.dot(n);
	if (vn >= 0.0) {
		return vel;
	}
	return vel - n * (real_t)((1.0 + restitution) * vn);
}

// ── AITrajectory._step ───────────────────────────────────────────────────────

void NativePuckStep::step_core(Vector3 &p, Vector3 &v, double dt,
		double decel, double bounce, const Vector3 &accel,
		double max_speed_cap, double b_friction) const {
	if (accel != Vector3()) {
		v += accel * (real_t)dt;
	}
	if (max_speed_cap > 0.0) {
		const double v_cap_mag = Math::sqrt((double)v.x * (double)v.x + (double)v.z * (double)v.z);
		if (v_cap_mag > max_speed_cap) {
			const double cap_scale = max_speed_cap / v_cap_mag;
			v.x *= (real_t)cap_scale;
			v.z *= (real_t)cap_scale;
		}
	}
	p += v * (real_t)dt;

	const Vector2 clamped_xz = clamp_to_rink_inner(Vector2(p.x, p.z));
	if (bounce > 0.0) {
		const Vector2 outward(p.x - clamped_xz.x, p.z - clamped_xz.y);
		if ((double)outward.length_squared() > 1e-9) {
			const Vector2 n = outward.normalized();
			Vector2 v_xz(v.x, v.z);
			const double vn = (double)v_xz.dot(n);
			if (vn > 0.0) {
				v_xz -= n * (real_t)((1.0 + bounce) * vn);
				if (b_friction > 0.0) {
					const Vector2 v_tan = v_xz - n * v_xz.dot(n);
					const double t_speed = v_tan.length();
					if (t_speed > 1e-6) {
						const double drop = b_friction * (1.0 + bounce) * vn;
						const double new_t = MAX(t_speed - drop, 0.0);
						v_xz += v_tan * (real_t)(new_t / t_speed - 1.0);
					}
				}
				v.x = v_xz.x;
				v.z = v_xz.y;
			}
		}
	}
	p = Vector3(clamped_xz.x, p.y, clamped_xz.y);

	if (decel > 0.0) {
		const double v_xz_mag = Math::sqrt((double)v.x * (double)v.x + (double)v.z * (double)v.z);
		if (v_xz_mag > 0.001) {
			const double decel_amount = decel * dt;
			if (v_xz_mag <= decel_amount) {
				v.x = 0.0f;
				v.z = 0.0f;
			} else {
				const double scale = (v_xz_mag - decel_amount) / v_xz_mag;
				v.x *= (real_t)scale;
				v.z *= (real_t)scale;
			}
		}
	}
}

// ── AITrajectory.step_puck_3d (grounded branch == step_puck) ─────────────────

void NativePuckStep::step_puck_3d(Vector3 &p, Vector3 &v, double dt, double ice_height) const {
	const bool airborne = (double)p.y > ice_height + AIRBORNE_POS_EPS_M ||
			Math::abs((double)v.y) > AIRBORNE_VY_EPS_M_S;
	if (!airborne) {
		step_core(p, v, dt, ice_decel, board_bounce, Vector3(), 0.0, board_friction);
		return;
	}
	step_core(p, v, dt, 0.0, board_bounce,
			Vector3(0.0f, (real_t)-gravity, 0.0f), 0.0, board_friction);
	if ((double)p.y <= ice_height) {
		p.y = (real_t)ice_height;
		v.y = 0.0f;
	}
}

// ── PuckAuthorityRules.advance_loose_puck ────────────────────────────────────

void NativePuckStep::advance_loose_puck(Vector3 &p, Vector3 &v, double dt,
		double max_speed, double ice_height, double max_height) const {
	step_puck_3d(p, v, dt, ice_height);
	if ((double)v.length() > max_speed) {
		v = v.normalized() * (real_t)max_speed;
	}
	if ((double)p.y > ice_height + max_height) {
		p.y = (real_t)(ice_height + max_height);
		if (v.y > 0.0f) {
			v.y = 0.0f;
		}
	}
}

// ── PuckGeometryCollision resolvers ──────────────────────────────────────────

bool NativePuckStep::resolve_one_post(Vector3 &p, Vector3 &v, double puck_radius,
		double post_x, double end_z) const {
	const double combined_r = puck_radius + net_post_radius;
	const Vector2 post_xz(post_x, end_z);
	const Vector2 offset = Vector2(p.x, p.z) - post_xz;
	const double d = offset.length();
	if (d >= combined_r || d < 1e-6) {
		return false;
	}
	const Vector2 n = offset / (real_t)d;
	const Vector3 n3(n.x, 0.0f, n.y);
	const Vector2 ejected = post_xz + n * (real_t)combined_r;
	const Vector3 reflected_h = deflect_velocity_h(v, n3, post_restitution);
	p = Vector3(ejected.x, p.y, ejected.y);
	v = Vector3(reflected_h.x, v.y, reflected_h.z);
	return true;
}

bool NativePuckStep::resolve_posts(Vector3 &p, Vector3 &v, double puck_radius) const {
	const double end_z = (double)p.z >= 0.0 ? goal_line_z : -goal_line_z;
	if (Math::abs((double)p.z - end_z) > 1.0 + puck_radius + net_post_radius) {
		return false;
	}
	if ((double)p.y > net_height + puck_radius) {
		return false;
	}
	const double first_x = (double)p.x >= 0.0 ? net_half_width : -net_half_width;
	if (resolve_one_post(p, v, puck_radius, first_x, end_z)) {
		return true;
	}
	return resolve_one_post(p, v, puck_radius, -first_x, end_z);
}

bool NativePuckStep::resolve_crossbar(Vector3 &p, Vector3 &v, double puck_radius) const {
	if (Math::abs((double)p.x) > net_crown_half_width) {
		return false;
	}
	const double end_z = (double)p.z >= 0.0 ? goal_line_z : -goal_line_z;
	const double combined_r = puck_radius + net_post_radius;
	const Vector2 dyz((double)p.y - net_height, (double)p.z - end_z);
	const double d = dyz.length();
	if (d >= combined_r || d < 1e-6) {
		return false;
	}
	const Vector2 n = dyz / (real_t)d;
	const Vector2 ejected = Vector2((real_t)net_height, (real_t)end_z) + n * (real_t)combined_r;
	p = Vector3(p.x, ejected.x, ejected.y);
	v = reflect_3d(v, Vector3(0.0f, n.x, n.y), post_restitution);
	return true;
}

bool NativePuckStep::resolve_top_net(const Vector3 &prev, Vector3 &p, Vector3 &v) const {
	if (Math::abs((double)p.x) > net_crown_half_width) {
		return false;
	}
	const double az = Math::abs((double)p.z);
	if (az < goal_line_z || az > goal_line_z + net_top_depth) {
		return false;
	}
	const double hh = puck_half_height;
	if ((double)prev.y <= net_height) {
		if ((double)p.y < net_height - hh) {
			return false;
		}
		p = Vector3(p.x, (real_t)(net_height - hh), p.z);
		v = reflect_3d(v, Vector3(0.0f, -1.0f, 0.0f), net_restitution);
		return true;
	}
	if ((double)p.y > net_height + hh) {
		return false;
	}
	p = Vector3(p.x, (real_t)(net_height + hh), p.z);
	v = reflect_3d(v, Vector3(0.0f, 1.0f, 0.0f), net_restitution);
	return true;
}

double NativePuckStep::back_slope() const {
	return (net_top_depth - net_depth) / net_height;
}

double NativePuckStep::back_plane_norm() const {
	const double s = back_slope();
	return Math::sqrt(1.0 + s * s);
}

double NativePuckStep::back_plane_distance(const Vector3 &p) const {
	const double depth = Math::abs((double)p.z) - goal_line_z;
	return (depth - net_depth - back_slope() * (double)p.y) / back_plane_norm();
}

Vector3 NativePuckStep::back_plane_normal(double end_sign) const {
	const double inv = 1.0 / back_plane_norm();
	return Vector3(0.0f, (real_t)(-back_slope() * inv), (real_t)(end_sign * inv));
}

double NativePuckStep::back_depth_at_height(double y) const {
	const double t = CLAMP(y / net_height, 0.0, 1.0);
	return Math::lerp(net_depth, net_top_depth, t);
}

bool NativePuckStep::interior_or_mouth(const Vector3 &p) const {
	if ((double)p.y > net_height) {
		return false;
	}
	const double az = Math::abs((double)p.z);
	if (az <= goal_line_z) {
		return Math::abs((double)p.x) <= net_half_width;
	}
	if (back_plane_distance(p) >= 0.0) {
		return false;
	}
	return Math::abs((double)p.x) < net_half_width;
}

bool NativePuckStep::resolve_net_panels(const Vector3 &prev, Vector3 &p, Vector3 &v,
		double puck_radius) const {
	const double az = Math::abs((double)p.z);
	if (az <= goal_line_z || az > goal_line_z + net_depth + puck_radius) {
		return false;
	}
	if (Math::abs((double)p.x) > net_back_half_width + puck_radius || (double)p.y > net_height) {
		return false;
	}
	bool hit = false;
	const double end_sign = sgn(p.z);
	if (interior_or_mouth(prev)) {
		const double back_limit = goal_line_z + back_depth_at_height(p.y) - puck_radius;
		if (Math::abs((double)p.z) > back_limit) {
			p.z = (real_t)(end_sign * back_limit);
			v = reflect_3d(v, Vector3(0.0f, 0.0f, (real_t)-end_sign), net_restitution);
			hit = true;
		}
		const double side_limit = net_half_width - puck_radius;
		if (Math::abs((double)p.x) > side_limit) {
			const double x_sign = sgn(p.x);
			p.x = (real_t)(x_sign * side_limit);
			v = reflect_3d(v, Vector3((real_t)-x_sign, 0.0f, 0.0f), net_restitution);
			hit = true;
		}
	} else {
		const double back_dist = back_plane_distance(p);
		if (back_plane_distance(prev) >= 0.0 && back_dist < puck_radius) {
			p += back_plane_normal(end_sign) * (real_t)(puck_radius - back_dist);
			v = reflect_3d(v, Vector3(0.0f, 0.0f, (real_t)end_sign), net_restitution);
			hit = true;
		} else {
			const double side_surface = net_half_width;
			if (Math::abs((double)prev.x) >= side_surface &&
					Math::abs((double)p.x) < side_surface + puck_radius) {
				const double x_sign = (double)prev.x >= 0.0 ? 1.0 : -1.0;
				p.x = (real_t)(x_sign * (side_surface + puck_radius));
				v = reflect_3d(v, Vector3((real_t)x_sign, 0.0f, 0.0f), net_restitution);
				hit = true;
			}
		}
	}
	return hit;
}

// ── PuckAuthorityRules.frame_substeps / step_frame_substep / batched tick ────

int64_t NativePuckStep::frame_substeps(double pos_z, double speed, double dt) const {
	if (Math::abs(pos_z) <= goal_line_z - substep_range_z) {
		return 1;
	}
	const int64_t n = (int64_t)Math::ceil(speed * dt / substep_m);
	return CLAMP(n, (int64_t)1, max_substeps);
}

void NativePuckStep::step_frame_substep(const Vector3 &pos, const Vector3 &vel,
		double sub_dt, double puck_radius, double max_speed,
		double ice_height, double max_height) {
	const Vector3 sub_prev = pos;
	Vector3 p = pos;
	Vector3 v = vel;
	advance_loose_puck(p, v, sub_dt, max_speed, ice_height, max_height);
	if (resolve_posts(p, v, puck_radius) || resolve_crossbar(p, v, puck_radius)) {
		out_touched_post = true;
	}
	if (resolve_top_net(sub_prev, p, v) || resolve_net_panels(sub_prev, p, v, puck_radius)) {
		out_touched_net = true;
	}
	out_position = p;
	out_velocity = v;
}

void NativePuckStep::step_tick(const Vector3 &pos, const Vector3 &vel,
		double dt, double puck_radius, double max_speed,
		double ice_height, double max_height) {
	const double speed = vel.length();
	const int64_t n = frame_substeps(pos.z, speed, dt);
	const double sub_dt = dt / (double)n;
	Vector3 p = pos;
	Vector3 v = vel;
	for (int64_t i = 0; i < n; i++) {
		step_frame_substep(p, v, sub_dt, puck_radius, max_speed, ice_height, max_height);
		p = out_position;
		v = out_velocity;
	}
}

void NativePuckStep::clear_touched() {
	out_touched_post = false;
	out_touched_net = false;
}

// ── SweptDiscOBB.contact ─────────────────────────────────────────────────────

// The slab test itself, shared by obb_contact and the packed nearest loop.
static bool obb_contact_test(const Vector3 &prev, const Vector3 &curr,
		double radius, const Transform3D &box_transform, const Vector3 &half_extents,
		double &r_toi, Vector3 &r_point, Vector3 &r_normal, double &r_depth) {
	const Transform3D inv = box_transform.affine_inverse();
	const Vector3 p0 = inv.xform(prev);
	const Vector3 p1 = inv.xform(curr);
	const Vector3 d = p1 - p0;
	const Vector3 e = half_extents + Vector3((real_t)radius, (real_t)radius, (real_t)radius);
	double t_near = -INFINITY;
	double t_far = INFINITY;
	int hit_axis = -1;
	double hit_sign = 0.0;
	for (int axis = 0; axis < 3; axis++) {
		const double o = p0[axis];
		const double dir = d[axis];
		if (Math::abs(dir) < 1e-9) {
			if (o < -(double)e[axis] || o > (double)e[axis]) {
				return false;
			}
		} else {
			const double inv_d = 1.0 / dir;
			double t1 = (-(double)e[axis] - o) * inv_d;
			double t2 = ((double)e[axis] - o) * inv_d;
			double sign_v = -1.0;
			if (t1 > t2) {
				const double tmp = t1;
				t1 = t2;
				t2 = tmp;
				sign_v = 1.0;
			}
			if (t1 > t_near) {
				t_near = t1;
				hit_axis = axis;
				hit_sign = sign_v;
			}
			t_far = MIN(t_far, t2);
			if (t_near > t_far) {
				return false;
			}
		}
	}
	if (hit_axis >= 0 && (t_far < 0.0 || t_near > 1.0)) {
		return false;
	}
	double toi = hit_axis >= 0 ? CLAMP(t_near, 0.0, 1.0) : 0.0;
	double depth = 0.0;
	if (hit_axis < 0 || t_near < 0.0) {
		toi = 0.0;
		int best_axis = 0;
		double best_pen = INFINITY;
		for (int axis = 0; axis < 3; axis++) {
			const double pen = (double)e[axis] - Math::abs((double)p0[axis]);
			if (pen < best_pen) {
				best_pen = pen;
				best_axis = axis;
			}
		}
		hit_axis = best_axis;
		hit_sign = (double)p0[best_axis] >= 0.0 ? 1.0 : -1.0;
		depth = MAX(best_pen, 0.0);
	}
	Vector3 local_n;
	local_n[hit_axis] = (real_t)hit_sign;
	r_toi = toi;
	r_point = prev + (curr - prev) * (real_t)toi;
	r_normal = (box_transform.basis.xform(local_n)).normalized();
	r_depth = depth;
	return true;
}

bool NativePuckStep::obb_contact(const Vector3 &prev, const Vector3 &curr,
		double radius, const Transform3D &box_transform, const Vector3 &half_extents) {
	return obb_contact_test(prev, curr, radius, box_transform, half_extents,
			obb_toi, obb_point, obb_normal, obb_depth);
}

int64_t NativePuckStep::obb_nearest(const Vector3 &prev, const Vector3 &curr,
		double radius, const PackedFloat32Array &boxes, int64_t count) {
	const int64_t available = boxes.size() / 15;
	const int64_t n = MIN(count, available);
	const float *b = boxes.ptr();
	int64_t best = -1;
	// Mirror GoalieContactDetector.nearest: strictly-smaller toi wins, so ties
	// keep the first box encountered.
	double best_toi = INFINITY;
	Vector3 best_point;
	Vector3 best_normal;
	double best_depth = 0.0;
	for (int64_t i = 0; i < n; i++) {
		const float *e = b + i * 15;
		Basis basis;
		basis.set_column(0, Vector3(e[0], e[1], e[2]));
		basis.set_column(1, Vector3(e[3], e[4], e[5]));
		basis.set_column(2, Vector3(e[6], e[7], e[8]));
		const Transform3D xform(basis, Vector3(e[9], e[10], e[11]));
		const Vector3 half(e[12], e[13], e[14]);
		double toi;
		Vector3 point;
		Vector3 normal;
		double depth;
		if (obb_contact_test(prev, curr, radius, xform, half, toi, point, normal, depth)) {
			if (toi < best_toi) {
				best = i;
				best_toi = toi;
				best_point = point;
				best_normal = normal;
				best_depth = depth;
			}
		}
	}
	if (best >= 0) {
		obb_toi = best_toi;
		obb_point = best_point;
		obb_normal = best_normal;
		obb_depth = best_depth;
	}
	return best;
}

void NativePuckStep::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_rink_geometry",
			"inner_half_width", "inner_half_length", "inner_corner_radius",
			"corner_center_x", "corner_center_z"),
			&NativePuckStep::set_rink_geometry);
	ClassDB::bind_method(D_METHOD("set_puck_params",
			"board_bounce", "board_friction", "ice_decel", "gravity", "rest_height"),
			&NativePuckStep::set_puck_params);
	ClassDB::bind_method(D_METHOD("set_net_geometry",
			"goal_line_z", "net_half_width", "net_post_radius", "net_depth",
			"net_back_half_width", "net_height", "net_crown_half_width",
			"net_top_depth", "puck_half_height", "post_restitution", "net_restitution"),
			&NativePuckStep::set_net_geometry);
	ClassDB::bind_method(D_METHOD("set_substep_params", "range_z", "substep_m", "max_substeps"),
			&NativePuckStep::set_substep_params);
	ClassDB::bind_method(D_METHOD("frame_substeps", "pos_z", "speed", "dt"),
			&NativePuckStep::frame_substeps);
	ClassDB::bind_method(D_METHOD("step_frame_substep",
			"pos", "vel", "sub_dt", "puck_radius", "max_speed", "ice_height", "max_height"),
			&NativePuckStep::step_frame_substep);
	ClassDB::bind_method(D_METHOD("step_tick",
			"pos", "vel", "dt", "puck_radius", "max_speed", "ice_height", "max_height"),
			&NativePuckStep::step_tick);
	ClassDB::bind_method(D_METHOD("clear_touched"), &NativePuckStep::clear_touched);
	ClassDB::bind_method(D_METHOD("get_position"), &NativePuckStep::get_position);
	ClassDB::bind_method(D_METHOD("get_velocity"), &NativePuckStep::get_velocity);
	ClassDB::bind_method(D_METHOD("get_touched_post"), &NativePuckStep::get_touched_post);
	ClassDB::bind_method(D_METHOD("get_touched_net"), &NativePuckStep::get_touched_net);
	ClassDB::bind_method(D_METHOD("obb_contact",
			"prev", "curr", "radius", "box_transform", "half_extents"),
			&NativePuckStep::obb_contact);
	ClassDB::bind_method(D_METHOD("obb_nearest",
			"prev", "curr", "radius", "boxes", "count"),
			&NativePuckStep::obb_nearest);
	ClassDB::bind_method(D_METHOD("get_obb_toi"), &NativePuckStep::get_obb_toi);
	ClassDB::bind_method(D_METHOD("get_obb_point"), &NativePuckStep::get_obb_point);
	ClassDB::bind_method(D_METHOD("get_obb_normal"), &NativePuckStep::get_obb_normal);
	ClassDB::bind_method(D_METHOD("get_obb_depth"), &NativePuckStep::get_obb_depth);
}

} // namespace mitts
