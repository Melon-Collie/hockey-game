shader_type spatial;

// Stick shaft flex — bows the shaft between its pinned endpoints.
//
// The shaft is a unit-length BoxMesh that update_stick_mesh() stretches
// between the top hand and the blade heel (node scale.z = live length), so
// VERTEX.z runs [-0.5, +0.5] in object space with the BLADE end at -0.5
// (look_at points -Z at the blade). Object-space X is perpendicular to the
// shaft and unaffected by the Z stretch, so a bow displaced here survives
// the per-frame resize untouched. sin(PI * t^kick) is zero at both ends —
// the hand and blade anchors (gameplay) never move; only the material
// between them curves. kick_point < 1 shifts the bulge toward the blade
// end (a low-kick stick); the mesh needs subdivide_depth > 0 to have
// vertices along the length to bend (set in Skater._ready).
//
// flex_m is driven per rendered frame by Skater._update_stick_flex from
// replicated state (shot charge / shot state), so every machine renders
// the identical bend.

uniform vec4 albedo : source_color = vec4(0.06, 0.06, 0.07, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float flex_m = 0.0;                              // signed mid-shaft bow, metres
uniform float kick_point : hint_range(0.3, 2.0) = 0.75;  // <1 = bulge toward the blade

void vertex() {
	float t = clamp(VERTEX.z + 0.5, 0.0, 1.0);
	VERTEX.x += flex_m * sin(PI * pow(t, kick_point));
}

void fragment() {
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness;
}
