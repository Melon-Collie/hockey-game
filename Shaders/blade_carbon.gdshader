shader_type spatial;

// Carbon-weave blade: the checkerboard read of exposed twill (see any modern
// composite blade). The procedural blade mesh carries no UVs and its shape
// changes per pattern, so cells key off object-space position (heel-origin
// frame: z runs heel→toe, y up) — the weave stays put through pattern
// rebuilds and covers the hosel for free. Alternating cells split both
// albedo and roughness, which is what makes a weave read as material rather
// than paint under a moving light.
//
// The Fresnel emission term mirrors BodyRim for ShaderMaterials (same
// formula as goalie_jersey.gdshader) so the blade keeps the shared
// player-silhouette rim.

uniform vec4 albedo_a : source_color = vec4(0.045, 0.045, 0.05, 1.0);
uniform vec4 albedo_b : source_color = vec4(0.085, 0.085, 0.095, 1.0);
uniform float cell_m = 0.013;
uniform float roughness_a : hint_range(0.0, 1.0) = 0.52;
uniform float roughness_b : hint_range(0.0, 1.0) = 0.36;

varying vec3 obj_pos;

void vertex() {
	obj_pos = VERTEX;
}

void fragment() {
	float check = mod(floor(obj_pos.z / cell_m) + floor(obj_pos.y / cell_m), 2.0);
	ALBEDO = mix(albedo_a.rgb, albedo_b.rgb, check);
	ROUGHNESS = mix(roughness_a, roughness_b, check);
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	EMISSION = vec3(rim * 0.2 * 0.4);
}
