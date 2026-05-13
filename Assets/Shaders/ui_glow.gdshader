// Soft drop-shadow glow for UI sprites. Equivalent to CSS
// `filter: drop-shadow(0 0 N color)` — samples the source texture's alpha in
// a Gaussian-weighted radius and outputs that as a tinted silhouette.
//
// Usage: apply as the material on a TextureRect that sits *behind* the
// real (unmodified) sprite. The behind-rect should use the same texture as
// the foreground; this shader only emits the glow halo, the original RGB is
// not drawn. To extend the glow past the sprite's bounding box, give the
// rect some transparent margin in the PNG (or scale the rect larger than
// the texture with stretch_mode = STRETCH_KEEP_ASPECT_CENTERED).
shader_type canvas_item;

uniform vec4 glow_color : source_color = vec4(0.753, 0.847, 0.878, 1.0);
uniform float intensity : hint_range(0.0, 5.0) = 1.4;
uniform float radius_px : hint_range(0.0, 60.0) = 22.0;

void fragment() {
	vec2 texel = TEXTURE_PIXEL_SIZE;
	float total = 0.0;
	float weight_total = 0.0;

	const int N = 8;  // (2N+1)^2 = 289 samples — fine for a static logo
	float sigma = max(radius_px * 0.5, 0.001);
	float two_sigma_sq = 2.0 * sigma * sigma;
	float step_px = radius_px / float(N);

	for (int x = -N; x <= N; x++) {
		for (int y = -N; y <= N; y++) {
			float fx = float(x) * step_px;
			float fy = float(y) * step_px;
			vec2 uv = UV + vec2(fx, fy) * texel;

			// Treat samples outside the texture as fully transparent so the
			// glow falls off naturally at the texture edge.
			if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) continue;

			float w = exp(-(fx * fx + fy * fy) / two_sigma_sq);
			total += texture(TEXTURE, uv).a * w;
			weight_total += w;
		}
	}

	float a = (total / max(weight_total, 0.0001)) * intensity;
	COLOR = vec4(glow_color.rgb, clamp(a * glow_color.a, 0.0, 1.0));
}
