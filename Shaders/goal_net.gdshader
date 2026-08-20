// Goal net panels. Same look as the old StandardMaterial3D path (tinted
// diamond-mesh texture, alpha, double-sided) plus a ripple: when
// ripple_amount > 0 the mesh bulges along its normals in a decaying wave
// radiating from ripple_origin (the goal mouth), so the net visibly shakes
// when a goal is scored. GoalVFX tweens ripple_amount back to zero.
//
// Net panel vertices are authored in world space (the HockeyGoal node sits
// at scene origin), so VERTEX and ripple_origin share a coordinate space.
shader_type spatial;
render_mode cull_disabled;

uniform vec4 tint : source_color = vec4(0.8, 0.8, 0.8, 1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_texture = false;
uniform vec3 ripple_origin = vec3(0.0);
uniform float ripple_amount = 0.0; // peak displacement in metres

void vertex() {
	if (ripple_amount > 0.0001) {
		float d = distance(VERTEX, ripple_origin);
		// Travelling wave outward from the mouth, damped with distance so the
		// far corners of the net move less than the panel the puck hit.
		float wave = sin(d * 10.0 - TIME * 28.0);
		VERTEX += NORMAL * wave * ripple_amount * exp(-d * 0.9);
	}
}

void fragment() {
	vec4 base = tint;
	if (use_texture) {
		base *= texture(albedo_tex, UV);
	}
	ALBEDO = base.rgb;
	ALPHA = base.a;
}
