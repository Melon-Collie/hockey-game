// Goal net panels: tinted diamond-mesh twine, double-sided, that bulges where
// it is struck.
//
// Up to MAX_IMPACTS live impacts are held in a ring buffer written by
// HockeyGoal. Each is a point on the twine, a peak displacement, a push
// direction and an age; the mesh displaces by a damped spring in time and a
// gaussian in space, so a puck buried in the corner bulges the corner and the
// far side of the cage stays still.
//
// The push direction is a function of WORLD POSITION, never of which panel a
// vertex belongs to, and that is load-bearing rather than incidental. Panels
// meet at right angles: displacing each one along its own face normal moves the
// two sides of a shared seam apart, tearing an open gap in the twine — up to
// ~1.4x the bulge depth — exactly where a puck gets jammed into a corner. One
// direction across the seam cannot do that. NetGeometry.nearest_surface_normal
// picks it for a strike; the goal celebration uses the radial mode below, which
// is continuous for the same reason.
//
// Ages advance from `net_time`, a clock HockeyGoal ticks only while impacts are
// live — shader TIME cannot serve, because an impact has to know when it
// started and nothing can hand a start stamp back into TIME's frame.
//
// Net panel vertices are authored in world space (the HockeyGoal node sits at
// scene origin), so VERTEX, the impact origins and cavity_center share a
// coordinate space.
shader_type spatial;
render_mode cull_disabled;

const int MAX_IMPACTS = 4;

// Twine settles in about half a second: the amplitude envelope exp(-t/DECAY_TAU)
// is down to 6% after four of them, and SWING_OMEGA fits a little over one full
// swing inside that. The result is a net that takes the puck, bulges once and
// stops, rather than ringing like a drum skin.
const float DECAY_TAU = 0.17;
const float SWING_OMEGA = 26.0;

uniform vec4 tint : source_color = vec4(0.8, 0.8, 0.8, 1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_texture = false;

// xyz = impact origin in world space, w = peak displacement in metres.
uniform vec4 impact_origin_amp[MAX_IMPACTS];
// x = net_time the impact landed, y = gaussian falloff radius in metres.
uniform vec4 impact_start_radius[MAX_IMPACTS];
// xyz = unit push direction; w >= 0.5 selects the radial mode instead, which
// billows the whole cage away from cavity_center (the goal celebration).
uniform vec4 impact_dir[MAX_IMPACTS];
// Inside of the cage, for the radial mode.
uniform vec3 cavity_center = vec3(0.0);
uniform float net_time = 0.0;

void vertex() {
	vec3 push = vec3(0.0);
	for (int i = 0; i < MAX_IMPACTS; i++) {
		float amp = impact_origin_amp[i].w;
		if (amp < 0.0001) {
			continue;
		}
		float t = net_time - impact_start_radius[i].x;
		if (t < 0.0) {
			continue;
		}
		float d = distance(VERTEX, impact_origin_amp[i].xyz);
		float r = impact_start_radius[i].y;
		float falloff = exp(-(d * d) / (r * r));
		vec3 dir = impact_dir[i].w >= 0.5
				? normalize(VERTEX - cavity_center)
				: impact_dir[i].xyz;
		push += dir * amp * exp(-t / DECAY_TAU) * cos(SWING_OMEGA * t) * falloff;
	}
	VERTEX += push;
}

void fragment() {
	vec4 base = tint;
	if (use_texture) {
		base *= texture(albedo_tex, UV);
	}
	ALBEDO = base.rgb;
	ALPHA = base.a;
}
