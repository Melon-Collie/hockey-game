#include "native_skater_gait.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include <cmath>

using namespace godot;

namespace mitts {

// Mesh-native leg segment spans — must match the GDScript coordinator's
// constants (which must match Scenes/Skater.tscn).
static constexpr double THIGH_LEN = 0.31;
static constexpr double SHIN_LEN = 0.45;
static constexpr double FOOT_FWD = 0.10;
static constexpr double SETTLE_SECONDS = 1.0;
// Cap on the effort/carve finite-difference sampling interval — mirrors the
// GDScript coordinator's _FD_WINDOW_MAX.
static constexpr double FD_WINDOW_MAX = 0.1;
// Pivot detector constants — mirror _PSI_RATE_EASE, _PSI_SMOOTH_EASE and
// PivotRules.RELEASE_MARGIN.
static constexpr double PSI_RATE_EASE = 10.0;
static constexpr double PSI_SMOOTH_EASE = 15.0;
static constexpr double PIVOT_RELEASE_MARGIN = 8.0 * Math_PI / 180.0;

// GDScript signf semantics: -1, 0, or +1.
static inline double sgn(double v) {
	return v > 0.0 ? 1.0 : (v < 0.0 ? -1.0 : 0.0);
}

// GDScript angle_difference (core math_funcs.h) — shortest signed angle.
static inline double angle_diff(double p_from, double p_to) {
	const double difference = fmod(p_to - p_from, Math_TAU);
	return fmod(2.0 * difference, Math_TAU) - difference;
}

// PivotRules.should_engage
static bool pivot_should_engage(double abs_psi, double abs_psi_rate, double ground_speed,
		double band_lo, double band_hi, double rate_min, double min_speed) {
	return ground_speed >= min_speed && abs_psi_rate >= rate_min &&
			abs_psi > band_lo && abs_psi < band_hi;
}

// PivotRules.should_release
static bool pivot_should_release(double abs_psi, double ground_speed,
		double band_lo, double band_hi, double min_speed) {
	return ground_speed < min_speed ||
			abs_psi <= band_lo - PIVOT_RELEASE_MARGIN ||
			abs_psi >= band_hi + PIVOT_RELEASE_MARGIN;
}

// PivotRules.latch_sense
static double pivot_latch_sense(double abs_psi, double band_lo, double band_hi) {
	return abs_psi < 0.5 * (band_lo + band_hi) ? 1.0 : -1.0;
}

// PivotRules.hold_depth
static double pivot_hold_depth(double abs_psi, double band_lo, double ramp) {
	return CLAMP((abs_psi - band_lo) / MAX(ramp, 0.001), 0.0, 1.0);
}

// PivotRules.phase
static double pivot_phase(double abs_psi, double sense, double band_lo, double band_hi) {
	const double p = CLAMP((abs_psi - band_lo) / MAX(band_hi - band_lo, 0.001), 0.0, 1.0);
	return sense > 0.0 ? p : 1.0 - p;
}

// PivotRules.pivot_yaw
static double pivot_yaw_law(double psi, double sense, double p, double step_begin) {
	const double along = -psi;
	const double anti = -psi + Math_PI * sgn(psi);
	double t = 0.0;
	if (p > step_begin) {
		t = (p - step_begin) / MAX(1.0 - step_begin, 0.001);
		t = t * t * (3.0 - 2.0 * t);
	}
	if (sense > 0.0) {
		return Math::lerp(along, anti, t);
	}
	return Math::lerp(anti, along, t);
}

// ── Ports of the pure domain helpers (see the GDScript files for reasoning) ──

// GaitIntentRules.dig_in
static double rules_dig_in(bool has_intent, double ground_speed, double fade_speed) {
	if (!has_intent || fade_speed <= 0.001) {
		return 0.0;
	}
	return CLAMP(1.0 - ground_speed / fade_speed, 0.0, 1.0);
}

// GaitIntentRules.reversal
static double rules_reversal(const Vector2 &travel_xz, const Vector2 &intent_xz,
		double ground_speed, double min_speed, double start_opposition) {
	if (ground_speed < min_speed) {
		return 0.0;
	}
	if (travel_xz.length_squared() < 0.01 || intent_xz.length_squared() < 0.0025) {
		return 0.0;
	}
	const double opposition = -(double)travel_xz.normalized().dot(intent_xz.normalized());
	return CLAMP((opposition - start_opposition) / MAX(1.0 - start_opposition, 0.001),
			0.0, 1.0);
}

// GaitIntentRules.shuffle
static double rules_shuffle(const Vector2 &local_intent_xz, double ground_speed,
		double fade_speed, double start_lateral) {
	if (fade_speed <= 0.001 || local_intent_xz.length_squared() < 0.0025) {
		return 0.0;
	}
	const double speed_fade = CLAMP(1.0 - ground_speed / fade_speed, 0.0, 1.0);
	if (speed_fade <= 0.0) {
		return 0.0;
	}
	const double lat = local_intent_xz.normalized().x;
	const double mag = CLAMP((Math::abs(lat) - start_lateral) / MAX(1.0 - start_lateral, 0.001),
			0.0, 1.0);
	return mag * sgn(lat) * speed_fade;
}

// GaitIntentRules.backpedal
static double rules_backpedal(const Vector2 &local_intent_xz, double start_backward) {
	if (local_intent_xz.length_squared() < 0.0025) {
		return 0.0;
	}
	const double back = local_intent_xz.normalized().y;
	return CLAMP((back - start_backward) / MAX(1.0 - start_backward, 0.001), 0.0, 1.0);
}

// CarveRules.turn_rate
static double rules_turn_rate(const Vector2 &prev_vel_xz, const Vector2 &vel_xz,
		double delta, double min_speed) {
	if (delta <= 0.0) {
		return 0.0;
	}
	if (prev_vel_xz.length() < min_speed || vel_xz.length() < min_speed) {
		return 0.0;
	}
	return (double)prev_vel_xz.angle_to(vel_xz) / delta;
}

// CarveRules.carve_target
static double rules_carve_target(double p_turn_rate, double ground_speed,
		double ref_turn_rate, double min_speed) {
	if (ground_speed < min_speed) {
		return 0.0;
	}
	return CLAMP(p_turn_rate / MAX(ref_turn_rate, 0.001), -1.0, 1.0);
}

// CarveRules.intent_carve
static double rules_intent_carve(const Vector2 &travel_xz, const Vector2 &intent_xz,
		double ground_speed, double min_speed) {
	if (ground_speed < min_speed) {
		return 0.0;
	}
	if (travel_xz.length_squared() < 0.01 || intent_xz.length_squared() < 0.0025) {
		return 0.0;
	}
	const Vector2 t_dir = travel_xz.normalized();
	const Vector2 i_dir = intent_xz.normalized();
	const double cross = (double)t_dir.x * (double)i_dir.y - (double)t_dir.y * (double)i_dir.x;
	return cross * Math::abs(cross);
}

// HockeyStopRules.should_engage
static bool rules_stop_should_engage(double effort, double ground_speed,
		double effort_threshold, double min_speed, bool brake_held) {
	return brake_held && effort <= -effort_threshold && ground_speed >= min_speed;
}

// HockeyStopRules.should_release
static bool rules_stop_should_release(double effort, double ground_speed,
		double effort_threshold, double min_speed, bool brake_held) {
	return !brake_held || effort > -effort_threshold * 0.4 ||
			ground_speed < min_speed * 0.4;
}

// HockeyStopRules.latch_side
static double rules_stop_latch_side(const Vector3 &local_velocity) {
	return local_velocity.x >= 0.0f ? 1.0 : -1.0;
}

// HockeyStopRules.stop_yaw
static double rules_stop_yaw(const Vector3 &local_velocity, double side, double max_yaw) {
	const double fwd = -(double)local_velocity.z;
	const double lat = (double)local_velocity.x;
	if (Vector2(lat, fwd).length() < 0.01) {
		return 0.0;
	}
	const double travel_angle = Math::atan2(lat, fwd);
	const double legs_angle = Math::wrapf(travel_angle + side * Math_PI * 0.5, -Math_PI, Math_PI);
	return CLAMP(-legs_angle, -max_yaw, max_yaw);
}

// ── NativeSkaterGait ─────────────────────────────────────────────────────────

void NativeSkaterGait::reset_state() {
	stride_phase = 0.0;
	intensity = 0.0;
	effort = 0.0;
	faceoff_blend = 0.0;
	trunk_pitch_add = 0.0;
	trunk_roll_add = 0.0;
	trunk_pitch_s = 0.0;
	trunk_roll_s = 0.0;
	prev_velocity = Vector3();
	have_prev_velocity = false;
	fd_time = 0.0;
	fd_effort_target = 0.0;
	fd_turn = 0.0;
	fd_carve = 0.0;
	stop_yaw_offset = 0.0;
	stop_engaged = false;
	stop_blend = 0.0;
	travel_align_yaw = 0.0;
	hip_align_yaw = 0.0;
	prev_psi = 0.0;
	have_prev_psi = false;
	psi_smooth = 0.0;
	psi_rate = 0.0;
	pivot_engaged = false;
	pivot_sense = 1.0;
	pivot_blend = 0.0;
	pivot_dwell = 0.0;
	carve = 0.0;
	carve_curve = 0.0;
	turn_rate = 0.0;
	dig = 0.0;
	reversal = 0.0;
	shuffle = 0.0;
	backpedal = 0.0;
	glide = 0.0;
	glide_phase = 0.0;
	sprint = 0.0;
	weight_shift = 0.0;
	weight_shift_vel = 0.0;
	shot_hip_yaw = 0.0;
	shot_prev_state = 0;
	wrister_load = 0.0;
	slap_load = 0.0;
	shot_kick_t = -1.0;
	shot_kick_power = 0.0;
	shot_kick_is_slap = false;
	block_blend = 0.0;
	drive_dir = Vector3();
	drive_t = -1.0;
	drive_intensity = 0.0;
	lift_blend = 0.0;
	out_l_pitch = 0.0;
	out_l_roll = 0.0;
	out_l_knee = 0.0;
	out_r_pitch = 0.0;
	out_r_roll = 0.0;
	out_r_knee = 0.0;
	out_l_yaw = 0.0;
	out_r_yaw = 0.0;
	out_foot_evert_l = 0.0;
	out_foot_evert_r = 0.0;
	out_edge_load_l = 0.0;
	out_edge_load_r = 0.0;
	out_drop = 0.0;
}

void NativeSkaterGait::reset_to_rest() {
	reset_state();
}

String NativeSkaterGait::configure(Object *controller) {
	ERR_FAIL_NULL_V(controller, String("null controller"));
	String missing;
	// Every tunable is a float @export, so a NIL Variant can only mean the
	// property doesn't exist on the controller (renamed/removed export).
#define X(name)                                                          \
	{                                                                    \
		const Variant v = controller->get(StringName(#name));            \
		if (v.get_type() == Variant::NIL) {                              \
			missing += #name " ";                                        \
		} else {                                                         \
			cfg.name = (double)v;                                        \
		}                                                                \
	}
	MITTS_GAIT_TUNABLES(X)
#undef X
	return missing;
}

void NativeSkaterGait::set_state_ids(
		int64_t skating_with_puck, int64_t skating_without_puck,
		int64_t shot_blocking, int64_t follow_through, int64_t wrister_aim,
		int64_t slapper_charge_with_puck, int64_t slapper_charge_without_puck,
		int64_t one_timer_retention) {
	st_skating_with_puck = skating_with_puck;
	st_skating_without_puck = skating_without_puck;
	st_shot_blocking = shot_blocking;
	st_follow_through = follow_through;
	st_wrister_aim = wrister_aim;
	st_slapper_charge_with_puck = slapper_charge_with_puck;
	st_slapper_charge_without_puck = slapper_charge_without_puck;
	st_one_timer_retention = one_timer_retention;
}

void NativeSkaterGait::start_check_drive(const Vector3 &hit_dir, double p_intensity) {
	const Vector3 flat(hit_dir.x, 0.0f, hit_dir.z);
	if ((double)flat.length_squared() < 0.0001 || p_intensity <= 0.0) {
		return;
	}
	if (drive_t >= 0.0) {
		drive_intensity = MAX(drive_intensity, p_intensity);
		return;
	}
	drive_dir = flat.normalized();
	drive_intensity = p_intensity;
	drive_t = 0.0;
}

int64_t NativeSkaterGait::apply(
		double delta,
		const Vector3 &vel,
		const Basis &basis,
		const Vector2 &mi,
		int64_t shot_state_in,
		double shot_charge,
		double stagger_timer,
		double knockdown_timer,
		double knockdown_elapsed,
		double celebr_p,
		int64_t flags) {
	if (delta <= 0.0) {
		return APPLY_SETTLED_HOLD;
	}
	const bool brake_intent = flags & FLAG_BRAKE;
	const bool hit_committed = flags & FLAG_HIT_COMMITTED;
	const bool blade_up = flags & FLAG_BLADE_UP;
	const bool is_left_handed = flags & FLAG_LEFT_HANDED;
	const bool sprint_active = flags & FLAG_SPRINT;
	const bool faceoff_ready = flags & FLAG_FACEOFF_READY;

	// ── Settled early-out ──
	const bool quiet =
			(double)vel.x * (double)vel.x + (double)vel.z * (double)vel.z < 0.0025 &&
			(double)mi.length_squared() <= 0.0025 &&
			!brake_intent && !sprint_active && !hit_committed && !blade_up &&
			(shot_state_in == st_skating_with_puck ||
					shot_state_in == st_skating_without_puck) &&
			shot_state_in == shot_prev_state &&
			stagger_timer <= 0.0 && knockdown_timer <= 0.0 &&
			drive_t < 0.0 && shot_kick_t < 0.0 &&
			!faceoff_ready && celebr_p <= 0.0;
	if (quiet) {
		settle_timer = MIN(settle_timer + delta, SETTLE_SECONDS);
		if (settle_timer >= SETTLE_SECONDS) {
			if (!settled) {
				settled = true;
				reset_state();
				shot_prev_state = shot_state_in;
				return APPLY_JUST_SETTLED;
			}
			return APPLY_SETTLED_HOLD;
		}
	} else {
		settle_timer = 0.0;
		settled = false;
	}

	const double ground_speed = (double)Vector2(vel.x, vel.z).length();
	const double speed_t = CLAMP(ground_speed / MAX(cfg.max_speed, 0.001), 0.0, 1.0);

	const bool planted = shot_state_in == st_shot_blocking;
	const bool has_move_intent = (double)mi.length_squared() > 0.0025;

	// ── Intent signals ──
	const Basis basis_inv = basis.inverse();
	const Vector3 local_intent3 = basis_inv.xform(Vector3(mi.x, 0.0f, mi.y));
	const Vector2 local_intent(local_intent3.x, local_intent3.z);
	double dig_t = 0.0;
	double rev_t = 0.0;
	double shuf_t = 0.0;
	double back_t = 0.0;
	if (!planted) {
		dig_t = rules_dig_in(has_move_intent, ground_speed, cfg.dig_in_fade_speed);
		rev_t = rules_reversal(Vector2(vel.x, vel.z), mi, ground_speed,
				cfg.reversal_min_speed, cfg.reversal_start_opposition);
		shuf_t = rules_shuffle(local_intent, ground_speed,
				cfg.shuffle_fade_speed, cfg.shuffle_start_lateral);
		back_t = rules_backpedal(local_intent, cfg.backpedal_start);
	}
	const double intent_ease = cfg.intent_signal_speed * delta;
	dig = Math::lerp(dig, dig_t, intent_ease);
	reversal = Math::lerp(reversal, rev_t, intent_ease);
	shuffle = Math::lerp(shuffle, shuf_t, intent_ease);
	backpedal = Math::lerp(backpedal, back_t, intent_ease);
	glide = Math::lerp(glide,
			(has_move_intent || planted || brake_intent) ? 0.0 : 1.0, intent_ease);
	sprint = Math::lerp(sprint,
			(sprint_active && !planted) ? 1.0 : 0.0, intent_ease);

	// ── Shots: load + release kick signals ──
	const int64_t shot_state = shot_state_in;
	const bool in_slap_charge = shot_state == st_slapper_charge_with_puck ||
			shot_state == st_slapper_charge_without_puck ||
			shot_state == st_one_timer_retention;
	if (shot_state != shot_prev_state) {
		if (shot_state == st_follow_through) {
			shot_kick_t = 0.0;
			shot_kick_is_slap = shot_prev_state == st_slapper_charge_with_puck ||
					shot_prev_state == st_slapper_charge_without_puck ||
					shot_prev_state == st_one_timer_retention;
			if (shot_kick_is_slap) {
				shot_kick_power = MAX(slap_load, cfg.slapper_kick_min_power);
			} else {
				shot_kick_power = MAX(
						MAX(wrister_load, shot_charge),
						cfg.wrister_kick_min_power);
			}
		}
		shot_prev_state = shot_state;
	}
	const double wrister_target = shot_state == st_wrister_aim ? shot_charge : 0.0;
	wrister_load = Math::lerp(wrister_load, wrister_target,
			MIN(cfg.wrister_load_blend_speed * delta, 1.0));
	double slap_target = 0.0;
	if (in_slap_charge) {
		slap_target = Math::sqrt(CLAMP(shot_charge, 0.0, 1.0));
	}
	slap_load = Math::lerp(slap_load, slap_target,
			MIN(cfg.wrister_load_blend_speed * delta, 1.0));
	double kick_env = 0.0;
	if (shot_kick_t >= 0.0) {
		shot_kick_t += delta;
		const double kick_total = shot_kick_is_slap ? cfg.slapper_kick_time
													: cfg.wrister_kick_time;
		const double kt = shot_kick_t / MAX(kick_total, 0.001);
		if (kt >= 1.0) {
			shot_kick_t = -1.0;
		} else {
			kick_env = Math::sin(Math_PI * Math::pow(kt, cfg.follow_through_arc_skew)) *
					shot_kick_power;
		}
	}
	block_blend = Math::lerp(block_blend, planted ? 1.0 : 0.0,
			MIN(cfg.block_pose_blend_speed * delta, 1.0));
	double drive_env = 0.0;
	if (drive_t >= 0.0) {
		drive_t += delta;
		const double du = drive_t / MAX(cfg.check_drive_time, 0.001);
		if (du >= 1.0) {
			drive_t = -1.0;
		} else {
			drive_env = Math::sin(Math_PI * Math::pow(du, 0.35)) * drive_intensity;
		}
	}
	lift_blend = Math::lerp(lift_blend, blade_up ? 1.0 : 0.0,
			MIN(cfg.stick_lift_blend_speed * delta, 1.0));
	const double shot_body = MAX(MAX(wrister_load, slap_load), MAX(kick_env, drive_env));
	const double stick_side = is_left_handed ? -1.0 : 1.0;
	const double kick_hip_yaw_deg = shot_kick_is_slap ? cfg.slapper_kick_hip_yaw_deg
													  : cfg.wrister_kick_hip_yaw_deg;
	shot_hip_yaw = -stick_side * (Math::deg_to_rad(cfg.wrister_load_hip_coil_deg) * wrister_load +
						   Math::deg_to_rad(cfg.slapper_load_hip_coil_deg) * slap_load) +
			stick_side * Math::deg_to_rad(kick_hip_yaw_deg) * kick_env;

	double target_intensity = (has_move_intent && !planted) ? speed_t : 0.0;
	if (!planted) {
		target_intensity = MAX(target_intensity, MAX(
				dig * cfg.dig_in_intensity,
				Math::abs(shuffle) * cfg.shuffle_intensity));
	}
	intensity = Math::lerp(intensity, target_intensity, cfg.stride_intensity_speed * delta);

	// Stride phase advance (tanh-saturated cadence; see the GDScript for the
	// biomechanics reasoning behind every term here).
	const double cadence_ceiling = MAX(cfg.stride_cadence_max_rate, 0.001);
	const double linear_rate = ground_speed * cfg.stride_cadence;
	double phase_rate = cadence_ceiling * std::tanh(linear_rate / cadence_ceiling);
	const double cruise_gear = speed_t * (1.0 - CLAMP(effort, 0.0, 1.0));
	phase_rate *= 1.0 - cfg.cadence_cruise_falloff * cruise_gear;
	const Vector3 local_vel_early = basis_inv.xform(vel);
	const double carve_fwd_gate = CLAMP(-(double)local_vel_early.z /
					MAX(cfg.carve_forward_ramp, 0.001), 0.0, 1.0);
	const double carve_cadence = Math::abs(carve_curve) * carve_fwd_gate;
	if (carve_cadence > 0.001) {
		phase_rate = Math::lerp(phase_rate,
				Math::abs(turn_rate) * cfg.crossover_phase_per_turn, carve_cadence);
	}
	phase_rate = MAX(phase_rate, MAX(dig * cfg.dig_in_cadence_rate,
			Math::abs(shuffle) * cfg.shuffle_cadence_rate));
	stride_phase = Math::wrapf(stride_phase + phase_rate *
			(1.0 - MAX(MAX(stop_blend, reversal * cfg.reversal_stride_fade),
					pivot_blend * cfg.pivot_stride_fade)) * delta,
			0.0, Math_TAU);

	// ── Effort: glide vs. push ──
	// Sampled over the interval since the velocity LAST CHANGED (with a forced
	// re-sample at FD_WINDOW_MAX), not per render frame — see the aliasing note
	// in the GDScript reference.
	fd_time += delta;
	if (!have_prev_velocity) {
		prev_velocity = vel;
		have_prev_velocity = true;
		fd_time = 0.0;
	} else if (vel != prev_velocity || fd_time >= FD_WINDOW_MAX) {
		const Vector3 accel = (vel - prev_velocity) / (real_t)fd_time;
		const Vector2 travel(vel.x, vel.z);
		fd_effort_target = 0.0;
		if ((double)travel.length() > 0.1) {
			const double tangential = (double)Vector2(accel.x, accel.z).dot(travel.normalized());
			fd_effort_target = CLAMP(
					tangential / MAX(cfg.stride_effort_ref_accel, 0.001), -1.0, 1.0);
		}
		fd_turn = rules_turn_rate(
				Vector2(prev_velocity.x, prev_velocity.z),
				Vector2(vel.x, vel.z), fd_time, cfg.carve_min_speed);
		fd_carve = rules_carve_target(fd_turn,
				ground_speed, cfg.carve_ref_turn_rate, cfg.carve_min_speed);
		prev_velocity = vel;
		fd_time = 0.0;
	}
	const double effort_target = fd_effort_target;
	double carve_target = fd_carve;
	const double raw_turn = fd_turn;
	const double curve_only = carve_target;
	const double intent_carve = rules_intent_carve(
			Vector2(vel.x, vel.z), mi, ground_speed, cfg.carve_min_speed);
	if (Math::abs(intent_carve) > Math::abs(carve_target)) {
		carve_target = intent_carve;
	}
	effort = Math::lerp(effort, effort_target, cfg.stride_effort_speed * delta);
	carve = Math::lerp(carve, carve_target, cfg.carve_engage_speed * delta);
	carve_curve = Math::lerp(carve_curve, curve_only, cfg.carve_engage_speed * delta);
	turn_rate = Math::lerp(turn_rate, raw_turn, cfg.carve_engage_speed * delta);
	double push_scale = CLAMP(1.0 + effort * cfg.stride_push_gain,
			cfg.stride_glide_floor, cfg.stride_push_ceiling);
	push_scale *= 1.0 + sprint * cfg.sprint_stride_gain;

	// Decompose travel into the body frame.
	const Vector3 local_vel = local_vel_early;
	double fwd = -(double)local_vel.z;
	double lat = (double)local_vel.x;
	double fb_w = 1.0;
	double lr_w = 0.0;
	double denom = Math::abs(fwd) + Math::abs(lat);
	if (denom > 0.001) {
		fb_w = Math::abs(fwd) / denom;
		lr_w = Math::abs(lat) / denom;
	}

	// ── Hockey stop ──
	if (stop_engaged) {
		if (rules_stop_should_release(effort, ground_speed,
				cfg.hockey_stop_effort, cfg.hockey_stop_min_speed, brake_intent)) {
			stop_engaged = false;
		}
	} else if (rules_stop_should_engage(effort, ground_speed,
			cfg.hockey_stop_effort, cfg.hockey_stop_min_speed, brake_intent)) {
		stop_engaged = true;
		stop_side = rules_stop_latch_side(local_vel);
	}
	stop_blend = Math::lerp(stop_blend, stop_engaged ? 1.0 : 0.0,
			cfg.hockey_stop_blend_speed * delta);
	if (stop_blend > 0.001) {
		stop_yaw_offset = rules_stop_yaw(local_vel, stop_side,
				Math::deg_to_rad(cfg.hockey_stop_max_yaw_deg)) * stop_blend;
	} else {
		stop_yaw_offset = 0.0;
	}
	double gait_scale = 1.0 - MAX(MAX(stop_blend, reversal * cfg.reversal_stride_fade),
			pivot_blend * cfg.pivot_stride_fade);
	gait_scale *= 1.0 - shot_body * cfg.shot_stride_fade;
	const double rev_amt = reversal * (1.0 - stop_blend);

	// ── Hip-to-travel alignment ──
	double align_target = 0.0;
	double psi = prev_psi;
	if (ground_speed > 0.1) {
		psi = Math::atan2(lat, fwd);
		const double align_engage = CLAMP(
				intensity / MAX(cfg.stance_full_speed_fraction, 0.01), 0.0, 1.0);
		align_target = CLAMP(-psi,
				-Math::deg_to_rad(cfg.hip_align_max_deg),
				Math::deg_to_rad(cfg.hip_align_max_deg)) * align_engage;
	}
	if (!have_prev_psi) {
		psi_smooth = psi;
	} else {
		psi_smooth = Math::wrapf(psi_smooth +
				angle_diff(psi_smooth, psi) * MIN(PSI_SMOOTH_EASE * delta, 1.0),
				-Math_PI, Math_PI);
	}
	const double abs_psi = Math::abs(psi_smooth);
	const double band_lo = Math::deg_to_rad(cfg.pivot_band_lo_deg);
	const double band_hi = Math::deg_to_rad(cfg.pivot_band_hi_deg);
	align_target *= 1.0 - MAX(backpedal, Math::abs(shuffle));
	// Backward-hemisphere fade of the toward-travel pull — see the GDScript
	// reference.
	align_target *= 1.0 - CLAMP(
			(abs_psi - Math_PI * 0.5) / MAX(band_hi - Math_PI * 0.5, 0.001), 0.0, 1.0);
	// ── Pivot: the facing↔travel swap (see the GDScript reference) ──
	double psi_rate_raw = 0.0;
	if (have_prev_psi) {
		psi_rate_raw = angle_diff(prev_psi, psi) / delta;
	}
	prev_psi = psi;
	have_prev_psi = true;
	psi_rate = Math::lerp(psi_rate, psi_rate_raw, MIN(PSI_RATE_EASE * delta, 1.0));
	if (pivot_engaged) {
		if (pivot_should_release(abs_psi, ground_speed, band_lo, band_hi,
				cfg.pivot_min_speed)) {
			pivot_engaged = false;
		}
	} else if (pivot_should_engage(abs_psi, Math::abs(psi_rate), ground_speed,
			band_lo, band_hi, cfg.pivot_rate_min, cfg.pivot_min_speed)) {
		pivot_engaged = true;
		pivot_sense = pivot_latch_sense(abs_psi, band_lo, band_hi);
	}
	double pivot_target_blend = 0.0;
	if (pivot_engaged) {
		pivot_dwell += delta;
		pivot_target_blend = pivot_hold_depth(abs_psi, band_lo,
				Math::deg_to_rad(cfg.pivot_depth_ramp_deg)) *
				CLAMP(pivot_dwell / MAX(cfg.pivot_commit_time, 0.001), 0.0, 1.0) *
				(1.0 - CLAMP(Math::abs(carve_curve), 0.0, 1.0));
	} else {
		pivot_dwell = 0.0;
	}
	pivot_blend = Math::lerp(pivot_blend, pivot_target_blend,
			cfg.pivot_blend_speed * delta);
	double align_speed = cfg.hip_align_speed;
	double pivot_yaw_l = 0.0;
	double pivot_yaw_r = 0.0;
	if (pivot_blend > 0.001) {
		const double pivot_p = pivot_phase(abs_psi, pivot_sense, band_lo, band_hi);
		const double pivot_target = pivot_yaw_law(psi_smooth, pivot_sense, pivot_p,
				cfg.pivot_step_begin);
		// Mohawk V — see the GDScript reference.
		const double v_open = Math::deg_to_rad(cfg.pivot_mohawk_deg) * pivot_blend *
				Math::sin(Math_PI * pivot_p);
		const double step_sign = sgn(psi_smooth) * pivot_sense;
		if (step_sign > 0.0) {
			pivot_yaw_l = v_open;
		} else if (step_sign < 0.0) {
			pivot_yaw_r = -v_open;
		}
		align_target = Math::lerp(align_target, pivot_target, pivot_blend);
		align_speed = Math::lerp(align_speed, cfg.pivot_yaw_speed, pivot_blend);
	}
	hip_align_yaw = Math::lerp(hip_align_yaw, align_target, align_speed * delta);
	travel_align_yaw = hip_align_yaw * (1.0 - stop_blend);
	const double hip_cos = Math::cos(travel_align_yaw);
	const double hip_sin = Math::sin(travel_align_yaw);
	const double hip_x = (double)local_vel.x * hip_cos - (double)local_vel.z * hip_sin;
	const double hip_z = (double)local_vel.x * hip_sin + (double)local_vel.z * hip_cos;
	fwd = -hip_z;
	lat = hip_x;
	denom = Math::abs(fwd) + Math::abs(lat);
	fb_w = 1.0;
	lr_w = 0.0;
	if (denom > 0.001) {
		fb_w = Math::abs(fwd) / denom;
		lr_w = Math::abs(lat) / denom;
	}
	if (Math::abs(shuffle) > 0.001) {
		lr_w = MAX(lr_w, Math::abs(shuffle));
		fb_w = 1.0 - lr_w;
	}

	// ── Stance: the speed-engaged crouch ──
	double stance = CLAMP(
			intensity / MAX(cfg.stance_full_speed_fraction, 0.01), 0.0, 1.0);
	stance *= CLAMP(1.0 + effort * cfg.stance_push_gain, 0.0, 1.35);
	stance *= 1.0 + sprint * cfg.sprint_stance_gain;
	stance *= 1.0 + cfg.cadence_glide_stance_gain * cruise_gear;
	faceoff_blend = Math::lerp(faceoff_blend,
			faceoff_ready ? 1.0 : 0.0,
			cfg.stride_intensity_speed * delta);
	if (faceoff_blend > 0.001) {
		stance = MAX(stance, cfg.faceoff_stance * faceoff_blend);
	}
	if (stop_blend > 0.001) {
		stance = MAX(stance, cfg.hockey_stop_stance * stop_blend);
	}
	if (!has_move_intent) {
		stance = MAX(stance, cfg.glide_stance * speed_t);
	}
	stance = MAX(stance, cfg.dig_in_stance * dig);
	stance = MAX(stance, cfg.reversal_stance * rev_amt);
	stance = MAX(stance, cfg.carve_stance * Math::abs(carve));
	stance = MAX(stance, cfg.pivot_stance * pivot_blend);
	stance = MAX(stance, cfg.wrister_load_stance * wrister_load);
	stance = MAX(stance, cfg.slapper_load_stance * slap_load);
	const double kick_stance = shot_kick_is_slap ? cfg.slapper_kick_stance
												 : cfg.wrister_kick_stance;
	stance = MAX(stance, kick_stance * kick_env);
	stance = MAX(stance, cfg.check_drive_stance * drive_env);
	stance = MAX(stance, cfg.stick_lift_stance * lift_blend);
	if (celebr_p > 0.0 && (shot_state == st_skating_with_puck ||
								  shot_state == st_skating_without_puck)) {
		double cel_ramp = CLAMP(celebr_p / 0.2, 0.0, 1.0);
		cel_ramp = cel_ramp * cel_ramp * (3.0 - 2.0 * cel_ramp);
		const double pump = 0.5 - 0.5 * Math::cos(celebr_p * Math_TAU * 3.0);
		stance = MAX(stance, cfg.celebration_leg_stance * cel_ramp * pump);
	}
	const double stance_hip = Math::deg_to_rad(cfg.stance_hip_deg) * stance;
	const double stance_knee = stance_hip + Math::asin(
			CLAMP(THIGH_LEN / SHIN_LEN * Math::sin(stance_hip), -1.0, 1.0));
	double drop = leg_scale * (THIGH_LEN * (1.0 - Math::cos(stance_hip)) +
			SHIN_LEN * (1.0 - Math::cos(stance_knee - stance_hip)));

	// Asymmetric stroke sampling (slow-load / fast-release warp).
	const double skew = CLAMP(
			cfg.stride_skew + cfg.glide_hold_skew * cruise_gear, 0.0, 0.95);
	const double s = Math::sin(stride_phase - skew * Math::sin(stride_phase));
	const double phase_opp = stride_phase + Math_PI;
	const double s_opp = Math::sin(phase_opp - skew * Math::sin(phase_opp));
	const double c = Math::cos(stride_phase - skew * Math::sin(stride_phase)) *
			(1.0 - skew * Math::cos(stride_phase)) / (1.0 + skew);
	const double c_opp = Math::cos(phase_opp - skew * Math::sin(phase_opp)) *
			(1.0 - skew * Math::cos(phase_opp)) / (1.0 + skew);
	double roll_amp = Math::deg_to_rad(cfg.stride_roll_deg) * intensity * push_scale * gait_scale;

	double l_pitch = stance_hip;
	double l_roll = 0.0;
	double r_pitch = stance_hip;
	double r_roll = 0.0;

	// Faceoff foot stagger.
	if (faceoff_blend > 0.001) {
		const double split = Math::deg_to_rad(cfg.faceoff_split_deg) * faceoff_blend *
				(is_left_handed ? -1.0 : 1.0);
		l_pitch += split;
		r_pitch -= split;
	}

	// Hockey-stop leg pose.
	if (stop_blend > 0.001) {
		const double stop_split = Math::deg_to_rad(cfg.hockey_stop_split_deg) *
				stop_blend * stop_side;
		l_pitch += stop_split;
		r_pitch -= stop_split;
		const double stop_edge = Math::deg_to_rad(cfg.hockey_stop_edge_deg) *
				stop_blend * stop_side;
		l_roll += stop_edge;
		r_roll += stop_edge;
	}

	// Reversal plant.
	if (rev_amt > 0.001) {
		const double plant = Math::deg_to_rad(cfg.reversal_plant_deg) * rev_amt;
		l_roll -= plant;
		r_roll += plant;
	}

	// Shot stance: load stagger/lean, release kick lean/back-reach.
	const double shot_load_split_deg = cfg.wrister_load_split_deg * wrister_load +
			cfg.slapper_load_split_deg * slap_load;
	const double shot_load_lean_deg = cfg.wrister_load_lean_deg * wrister_load +
			cfg.slapper_load_lean_deg * slap_load;
	if (shot_load_split_deg > 0.001 || shot_load_lean_deg > 0.001) {
		const double load_split = Math::deg_to_rad(shot_load_split_deg) * stick_side;
		l_pitch += load_split;
		r_pitch -= load_split;
		const double load_lean = Math::deg_to_rad(shot_load_lean_deg) * stick_side;
		l_roll += load_lean;
		r_roll += load_lean;
	}
	if (kick_env > 0.001) {
		const double kick_lean_deg = shot_kick_is_slap ? cfg.slapper_kick_lean_deg
													   : cfg.wrister_kick_lean_deg;
		const double kick_lean = Math::deg_to_rad(kick_lean_deg) * kick_env * stick_side;
		l_roll -= kick_lean;
		r_roll -= kick_lean;
		const double kick_back_deg = shot_kick_is_slap ? cfg.slapper_kick_back_deg
													   : cfg.wrister_kick_back_deg;
		const double kick_back = Math::deg_to_rad(kick_back_deg) * kick_env;
		if (stick_side > 0.0) {
			r_pitch -= kick_back;
		} else {
			l_pitch -= kick_back;
		}
	}

	// Forward / backward gait.
	const double push_deg = fwd >= 0.0 ? cfg.stride_pitch_deg : cfg.stride_back_pitch_deg;
	const double push_dir = fwd >= 0.0 ? 1.0 : -1.0;
	const double ccut = backpedal * CLAMP(-fwd, 0.0, 1.0);
	roll_amp += Math::deg_to_rad(cfg.backpedal_ccut_roll_deg) * ccut * intensity * gait_scale;
	const double push_amp = Math::deg_to_rad(push_deg) * intensity * push_dir * push_scale *
			gait_scale *
			(1.0 - Math::abs(carve) * cfg.carve_stride_fade) *
			(1.0 - dig * cfg.dig_in_chop) *
			(1.0 - ccut * cfg.backpedal_pitch_fade);
	const double bias = cfg.stride_rear_bias;
	l_pitch += fb_w * (s - bias) * push_amp;
	r_pitch += fb_w * (s_opp - bias) * push_amp;
	const double rock_fade = 1.0 - Math::abs(carve) * carve_fwd_gate * cfg.carve_rock_fade;
	l_roll += fb_w * s * roll_amp * rock_fade;
	r_roll += fb_w * s * roll_amp * rock_fade;

	// Abduction (V-flare on the push half).
	double l_ext = MAX(-s, 0.0);
	double r_ext = MAX(-s_opp, 0.0);
	const double abduct_amp = Math::deg_to_rad(cfg.stride_abduction_deg +
			cfg.backpedal_ccut_sweep_deg * ccut) * intensity *
			push_scale * gait_scale;
	l_roll -= fb_w * abduct_amp * l_ext * rock_fade;
	r_roll += fb_w * abduct_amp * r_ext * rock_fade;

	// Strafe scissor.
	const double strafe_sign = Math::abs(shuffle) > 0.3 ? sgn(shuffle) : sgn(lat);
	const double lean = strafe_sign * Math::deg_to_rad(cfg.crossover_lean_deg) *
			intensity * gait_scale;
	const double scissor = Math::deg_to_rad(cfg.crossover_scissor_deg) * intensity *
			push_scale * gait_scale;
	l_roll += lr_w * (lean + s * scissor) * rock_fade;
	r_roll += lr_w * (lean + s_opp * scissor) * rock_fade;

	// ── Carve crossovers ──
	double l_tuck_extra = 0.0;
	double r_tuck_extra = 0.0;
	const double carve_amt = Math::abs(carve) * intensity * gait_scale * carve_fwd_gate;
	if (carve_amt > 0.001) {
		const double over_stroke = MAX(s, 0.0);
		const double under_stroke = MAX(-s, 0.0);
		const double base_lean = Math::deg_to_rad(cfg.carve_base_lean_deg) *
				sgn(carve) * carve_amt;
		l_roll += base_lean;
		r_roll += base_lean;
		const double over_roll = Math::deg_to_rad(cfg.carve_over_roll_deg) * carve_amt * over_stroke;
		const double under_roll = Math::deg_to_rad(cfg.carve_under_roll_deg) * carve_amt * under_stroke;
		const double over_pitch = Math::deg_to_rad(cfg.carve_over_pitch_deg) * carve_amt * over_stroke;
		const double clearance = Math::deg_to_rad(cfg.carve_clearance_knee_deg) *
				carve_amt * MAX(c, 0.0);
		if (carve > 0.0) {
			l_roll += over_roll;
			l_pitch += over_pitch;
			l_tuck_extra = clearance;
			r_roll -= under_roll;
			r_ext = MAX(r_ext, under_stroke);
		} else {
			r_roll -= over_roll;
			r_pitch += over_pitch;
			r_tuck_extra = clearance;
			l_roll += under_roll;
			l_ext = MAX(l_ext, under_stroke);
		}
	}

	// ── Glide reads ──
	const double glide_amt = glide * speed_t * gait_scale;
	if (glide_amt > 0.001 && Math::abs(carve) > 0.001) {
		const double glide_lean = Math::deg_to_rad(cfg.glide_carve_lean_deg) * carve * glide_amt;
		l_roll += glide_lean;
		r_roll += glide_lean;
		const double inside_tuck = Math::deg_to_rad(cfg.glide_inside_tuck_deg) *
				Math::abs(carve) * glide_amt;
		if (carve > 0.0) {
			r_tuck_extra += inside_tuck;
		} else {
			l_tuck_extra += inside_tuck;
		}
	}

	// Knee flex — stance base, push extension, recovery tuck.
	const double tuck_amp = Math::deg_to_rad(cfg.stride_knee_deg) * intensity *
			push_scale * gait_scale * (1.0 - cfg.backpedal_tuck_fade * ccut);
	const double release = cfg.stance_knee_release * intensity * gait_scale;
	double l_knee = -(stance_knee * (1.0 - release * l_ext) + tuck_amp * MAX(c, 0.0) + l_tuck_extra);
	double r_knee = -(stance_knee * (1.0 - release * r_ext) + tuck_amp * MAX(c_opp, 0.0) + r_tuck_extra);

	// Shot release: back knee straightens through the kick.
	if (kick_env > 0.001) {
		const double kick_extend_deg = shot_kick_is_slap ? cfg.slapper_kick_knee_extend_deg
														 : cfg.wrister_kick_knee_extend_deg;
		const double kick_extend = Math::deg_to_rad(kick_extend_deg) * kick_env;
		if (stick_side > 0.0) {
			r_knee = MIN(r_knee + kick_extend, 0.0);
		} else {
			l_knee = MIN(l_knee + kick_extend, 0.0);
		}
	}

	// ── Knee fore-aft compensation ──
	const double shin_frac = SHIN_LEN / (THIGH_LEN + SHIN_LEN);
	l_pitch += -(l_knee + stance_knee) * shin_frac;
	r_pitch += -(r_knee + stance_knee) * shin_frac;

	// Body bob.
	drop += cfg.stride_bob_m * intensity * (1.0 - s * s) * gait_scale;

	// Trunk texture. Roll channels ride the stride FUNDAMENTAL, not the skewed
	// stroke `s` — see the GDScript reference.
	const double s_fund = Math::sin(stride_phase);
	trunk_pitch_add = -Math::deg_to_rad(cfg.stride_dig_lean_deg) * effort;
	trunk_roll_add = Math::deg_to_rad(cfg.stride_sway_deg) * intensity * fb_w * s_fund * gait_scale;
	const double shift_target = fb_w * s_fund * intensity * gait_scale;
	const double shift_accel = cfg.weight_spring_stiffness * (shift_target - weight_shift) -
			cfg.weight_spring_damping * weight_shift_vel;
	weight_shift_vel += shift_accel * delta;
	weight_shift += weight_shift_vel * delta;
	trunk_roll_add += Math::deg_to_rad(cfg.weight_shift_deg) * weight_shift;
	trunk_pitch_add += -Math::deg_to_rad(cfg.dig_in_lean_deg) * dig +
			Math::deg_to_rad(cfg.reversal_lean_deg) * rev_amt +
			Math::deg_to_rad(cfg.backpedal_chest_deg) * ccut;
	trunk_pitch_add += -Math::deg_to_rad(cfg.sprint_lean_deg) * sprint * gait_scale;
	if (drive_env > 0.0) {
		const Vector3 drive_local = basis_inv.xform(drive_dir);
		const double drive_mag = Math::deg_to_rad(cfg.check_drive_lean_deg) * drive_env;
		trunk_pitch_add += drive_mag * (double)drive_local.z;
		trunk_roll_add += -drive_mag * (double)drive_local.x;
	}
	trunk_pitch_add += Math::deg_to_rad(cfg.stick_lift_trunk_deg) * lift_blend;
	if (glide > 0.01) {
		glide_phase = Math::wrapf(glide_phase +
				Math_TAU * cfg.glide_sway_hz * glide * delta, 0.0, Math_TAU);
	}
	if (glide_amt > 0.001) {
		const double sway = Math::sin(glide_phase) * Math::deg_to_rad(cfg.glide_sway_deg) * glide_amt;
		trunk_roll_add += sway;
		l_roll += sway * 0.5;
		r_roll += sway * 0.5;
	}
	if (stop_blend > 0.001) {
		trunk_roll_add += Math::deg_to_rad(cfg.hockey_stop_trunk_roll_deg) *
				stop_blend * stop_side;
	}
	// Centripetal bank — see the GDScript reference.
	if (ground_speed > 0.1) {
		const double a_lat = ground_speed * Math::abs(turn_rate);
		const double knee = MAX(cfg.carve_bank_knee_accel, 0.001);
		const double bank_engage = a_lat * a_lat / (a_lat * a_lat + knee * knee);
		const double bank_mag = MIN(
				Math::atan2(a_lat, 9.8) * cfg.carve_bank_gain,
				Math::deg_to_rad(cfg.carve_bank_max_deg)) * bank_engage * (1.0 - stop_blend);
		const double centri_x = sgn(turn_rate) * -(double)local_vel.z / ground_speed;
		const double centri_z = sgn(turn_rate) * (double)local_vel.x / ground_speed;
		trunk_pitch_add += bank_mag * centri_z;
		trunk_roll_add += -bank_mag * centri_x;
	}

	// Stagger stumble / knockdown factor. The entry end ramps over the buckle
	// window (mirrors KnockdownFallRules.entry_ramp — kd_t alone is 1 on the
	// first down frame).
	double kd_t = CLAMP(
			knockdown_timer / MAX(cfg.knockdown_getup_seconds, 0.001), 0.0, 1.0);
	if (kd_t > 0.0) {
		const double buckle_t = CLAMP(
				knockdown_elapsed / MAX(cfg.knockdown_fall_buckle_seconds, 0.001),
				0.0, 1.0);
		kd_t *= buckle_t * buckle_t * (3.0 - 2.0 * buckle_t);
	}
	const double stagger_t = CLAMP(
			stagger_timer / MAX(cfg.stagger_max_seconds, 0.001), 0.0, 1.0);
	double stagger_pitch = 0.0;
	double stagger_roll = 0.0;
	if (stagger_t > 0.0) {
		const double wobble_amp = Math::deg_to_rad(cfg.stagger_wobble_deg) * stagger_t * (1.0 - kd_t);
		const double wobble_phase = stagger_timer * Math_TAU * cfg.stagger_wobble_hz;
		stagger_pitch = wobble_amp * Math::sin(wobble_phase);
		stagger_roll = wobble_amp * 0.7 * Math::sin(wobble_phase * 1.31);
	}

	double foot_evert_l = 0.0;
	double foot_evert_r = 0.0;

	// ── Shot block: the one-knee drop ──
	if (block_blend > 0.001) {
		const double kneel_hip = Math::deg_to_rad(cfg.block_kneel_hip_deg);
		const double kneel_shin = Math::deg_to_rad(cfg.block_kneel_shin_deg);
		const double hip_h = leg_scale * (THIGH_LEN * Math::cos(kneel_hip) +
				SHIN_LEN * Math::cos(kneel_shin) + FOOT_FWD * Math::sin(kneel_shin));
		const double ext_knee = Math::deg_to_rad(cfg.block_extend_knee_deg);
		const double ext_len = leg_scale * (THIGH_LEN +
				SHIN_LEN * Math::cos(ext_knee) + FOOT_FWD * Math::sin(ext_knee));
		const double ext_roll = Math::acos(CLAMP(hip_h / MAX(ext_len, 0.001), -1.0, 1.0));
		const double down_knee = -(kneel_hip + kneel_shin);
		if (stick_side > 0.0) {
			foot_evert_l = ext_roll * block_blend;
		} else {
			foot_evert_r = -ext_roll * block_blend;
		}
		if (stick_side > 0.0) {
			r_pitch = Math::lerp(r_pitch, kneel_hip, block_blend);
			r_roll = Math::lerp(r_roll, 0.0, block_blend);
			r_knee = Math::lerp(r_knee, down_knee, block_blend);
			l_pitch = Math::lerp(l_pitch, 0.0, block_blend);
			l_roll = Math::lerp(l_roll, -ext_roll, block_blend);
			l_knee = Math::lerp(l_knee, -ext_knee, block_blend);
		} else {
			l_pitch = Math::lerp(l_pitch, kneel_hip, block_blend);
			l_roll = Math::lerp(l_roll, 0.0, block_blend);
			l_knee = Math::lerp(l_knee, down_knee, block_blend);
			r_pitch = Math::lerp(r_pitch, 0.0, block_blend);
			r_roll = Math::lerp(r_roll, ext_roll, block_blend);
			r_knee = Math::lerp(r_knee, -ext_knee, block_blend);
		}
		drop = Math::lerp(drop, leg_scale * (THIGH_LEN + SHIN_LEN) - hip_h, block_blend);
	}

	// Knockdown crumple.
	if (kd_t > 0.0) {
		drop = Math::lerp(drop, cfg.knockdown_pose_drop_m, kd_t);
		l_pitch = Math::lerp(l_pitch, 0.0, kd_t);
		r_pitch = Math::lerp(r_pitch, 0.0, kd_t);
		l_roll = Math::lerp(l_roll, 0.0, kd_t);
		r_roll = Math::lerp(r_roll, 0.0, kd_t);
		l_knee = Math::lerp(l_knee, 0.0, kd_t);
		r_knee = Math::lerp(r_knee, 0.0, kd_t);
	}

	// Commit stance — lean and crouch only. The per-side shoulder load-up is
	// CheckStanceRules, off the skater's own physics-rate ease, and never a
	// trunk channel: see the GDScript reference.
	hit_commit_blend = Math::move_toward(hit_commit_blend,
			hit_committed ? 1.0 : 0.0, cfg.hit_commit_pose_speed * delta);
	const double commit_t = hit_commit_blend * (1.0 - kd_t);
	if (commit_t > 0.001) {
		trunk_pitch_add += -Math::deg_to_rad(cfg.hit_commit_lean_deg) * commit_t;
		drop += cfg.hit_commit_crouch_m * commit_t;
	}

	// Trunk inertia filter + post-filter stumble wobble — see the GDScript
	// reference's publish tail.
	double tex_ease = 1.0;
	if (cfg.trunk_texture_smooth_rate > 0.0) {
		tex_ease = MIN(cfg.trunk_texture_smooth_rate * delta, 1.0);
	}
	trunk_pitch_s = Math::lerp(trunk_pitch_s, trunk_pitch_add, tex_ease);
	trunk_roll_s = Math::lerp(trunk_roll_s, trunk_roll_add, tex_ease);
	trunk_pitch_add = trunk_pitch_s + stagger_pitch;
	trunk_roll_add = trunk_roll_s + stagger_roll;

	out_l_pitch = l_pitch;
	out_l_roll = l_roll;
	out_l_knee = l_knee;
	out_r_pitch = r_pitch;
	out_r_roll = r_roll;
	out_r_knee = r_knee;
	out_l_yaw = pivot_yaw_l * (1.0 - kd_t);
	out_r_yaw = pivot_yaw_r * (1.0 - kd_t);
	out_foot_evert_l = foot_evert_l;
	out_foot_evert_r = foot_evert_r;
	out_edge_load_l = CLAMP(MAX(l_ext * intensity, stop_blend), 0.0, 1.0) * (1.0 - kd_t);
	out_edge_load_r = CLAMP(MAX(r_ext * intensity, stop_blend), 0.0, 1.0) * (1.0 - kd_t);
	out_drop = drop;
	return APPLY_ACTIVE;
}

void NativeSkaterGait::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "controller"), &NativeSkaterGait::configure);
	ClassDB::bind_method(D_METHOD("set_state_ids",
			"skating_with_puck", "skating_without_puck", "shot_blocking",
			"follow_through", "wrister_aim", "slapper_charge_with_puck",
			"slapper_charge_without_puck", "one_timer_retention"),
			&NativeSkaterGait::set_state_ids);
	ClassDB::bind_method(D_METHOD("set_leg_scale", "v"), &NativeSkaterGait::set_leg_scale);
	ClassDB::bind_method(D_METHOD("get_leg_scale"), &NativeSkaterGait::get_leg_scale);
	ClassDB::bind_method(D_METHOD("reset_to_rest"), &NativeSkaterGait::reset_to_rest);
	ClassDB::bind_method(D_METHOD("start_check_drive", "hit_dir", "intensity"),
			&NativeSkaterGait::start_check_drive);
	ClassDB::bind_method(D_METHOD("apply",
			"delta", "velocity", "basis", "move_intent", "shot_state",
			"shot_charge", "stagger_timer", "knockdown_timer",
			"knockdown_elapsed", "celebration_progress", "flags"),
			&NativeSkaterGait::apply);

	ClassDB::bind_method(D_METHOD("get_l_pitch"), &NativeSkaterGait::get_l_pitch);
	ClassDB::bind_method(D_METHOD("get_l_roll"), &NativeSkaterGait::get_l_roll);
	ClassDB::bind_method(D_METHOD("get_l_knee"), &NativeSkaterGait::get_l_knee);
	ClassDB::bind_method(D_METHOD("get_r_pitch"), &NativeSkaterGait::get_r_pitch);
	ClassDB::bind_method(D_METHOD("get_r_roll"), &NativeSkaterGait::get_r_roll);
	ClassDB::bind_method(D_METHOD("get_r_knee"), &NativeSkaterGait::get_r_knee);
	ClassDB::bind_method(D_METHOD("get_foot_evert_l"), &NativeSkaterGait::get_foot_evert_l);
	ClassDB::bind_method(D_METHOD("get_foot_evert_r"), &NativeSkaterGait::get_foot_evert_r);
	ClassDB::bind_method(D_METHOD("get_crouch_drop"), &NativeSkaterGait::get_crouch_drop);
	ClassDB::bind_method(D_METHOD("get_trunk_pitch_add"), &NativeSkaterGait::get_trunk_pitch_add);
	ClassDB::bind_method(D_METHOD("get_trunk_roll_add"), &NativeSkaterGait::get_trunk_roll_add);
	ClassDB::bind_method(D_METHOD("get_pivot_blend"), &NativeSkaterGait::get_pivot_blend);
	ClassDB::bind_method(D_METHOD("get_l_yaw"), &NativeSkaterGait::get_l_yaw);
	ClassDB::bind_method(D_METHOD("get_r_yaw"), &NativeSkaterGait::get_r_yaw);
	ClassDB::bind_method(D_METHOD("get_edge_load_l"), &NativeSkaterGait::get_edge_load_l);
	ClassDB::bind_method(D_METHOD("get_edge_load_r"), &NativeSkaterGait::get_edge_load_r);
	ClassDB::bind_method(D_METHOD("get_stop_yaw_offset"), &NativeSkaterGait::get_stop_yaw_offset);
	ClassDB::bind_method(D_METHOD("get_travel_align_yaw"), &NativeSkaterGait::get_travel_align_yaw);
	ClassDB::bind_method(D_METHOD("get_shot_hip_yaw"), &NativeSkaterGait::get_shot_hip_yaw);
	ClassDB::bind_method(D_METHOD("get_stride_phase"), &NativeSkaterGait::get_stride_phase);
	ClassDB::bind_method(D_METHOD("is_settled"), &NativeSkaterGait::is_settled);

	BIND_CONSTANT(FLAG_BRAKE);
	BIND_CONSTANT(FLAG_HIT_COMMITTED);
	BIND_CONSTANT(FLAG_BLADE_UP);
	BIND_CONSTANT(FLAG_LEFT_HANDED);
	BIND_CONSTANT(FLAG_SPRINT);
	BIND_CONSTANT(FLAG_FACEOFF_READY);
	BIND_CONSTANT(APPLY_ACTIVE);
	BIND_CONSTANT(APPLY_SETTLED_HOLD);
	BIND_CONSTANT(APPLY_JUST_SETTLED);
}

} // namespace mitts
