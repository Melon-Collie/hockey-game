shader_type spatial;

// Paints the goalie body (BoxMesh) with jersey base color, horizontal stripe
// bands, and a text decal (name / number) projected onto the front and back
// Z faces. All stripe math uses object-space VERTEX.y so stripes run
// horizontally on every face regardless of BoxMesh UV layout.
//
// Stripe pos/width follow the v2 jersey schema: pos and width are normalised
// over the body height [0 = bottom, 1 = top], matching TeamColorRegistry's
// uniform.jersey.stripes convention. Painted in array order; later entries
// overwrite earlier (same as JerseyDecal band painting).
//
// Text decal: a 256x320 SubViewport (aspect-matched to the 0.48 x 0.6 m face)
// rendering name and number on a transparent background. Sampled on ±Z faces
// by projecting object-space x/y onto [0,1]² UV; front face (-Z) mirrors U so
// the number reads correctly when viewed from the shooter's side.

const int MAX_STRIPES = 5;

// Half-extents of the body BoxMesh — kept as constants here so the shader
// compiles with exact values even if the mesh size is ever adjusted.
const float HALF_H = 0.3;   // body height 0.6 m
const float HALF_W = 0.24;  // body width  0.48 m

uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform int stripe_count = 0;
uniform vec4 stripe_colors[MAX_STRIPES] : source_color;
uniform float stripe_positions[MAX_STRIPES];
uniform float stripe_widths[MAX_STRIPES];
// Transparent-background viewport with name + number drawn centred.
uniform sampler2D text_decal : hint_default_transparent, filter_linear_mipmap;

varying float v_obj_y;
varying float v_obj_x;
varying vec3 v_obj_normal;

void vertex() {
	v_obj_y = VERTEX.y;
	v_obj_x = VERTEX.x;
	v_obj_normal = NORMAL;
}

void fragment() {
	ROUGHNESS = 0.9;
	METALLIC = 0.0;

	// Normalise height to [0, 1] (0 = bottom of body, 1 = top).
	float norm_y = (v_obj_y + HALF_H) / (HALF_H * 2.0);

	// Base colour, then stripes in array order.
	vec3 col = base_color.rgb;
	for (int i = 0; i < MAX_STRIPES; i++) {
		if (i < stripe_count &&
				abs(norm_y - stripe_positions[i]) < stripe_widths[i] * 0.5) {
			col = stripe_colors[i].rgb;
		}
	}

	// Project text decal onto front (-Z) and back (+Z) faces.
	if (abs(v_obj_normal.z) > 0.9) {
		// U: 0 at left edge, 1 at right (mirrored on the front face so text
		// reads correctly when viewed from the shooter's side).
		float face_u = (v_obj_normal.z < 0.0)
			? (v_obj_x + HALF_W) / (HALF_W * 2.0)
			: (HALF_W - v_obj_x) / (HALF_W * 2.0);
		// V: 0 at top of body, 1 at bottom (screen / texture convention).
		float face_v = (HALF_H - v_obj_y) / (HALF_H * 2.0);
		vec4 decal = texture(text_decal, vec2(face_u, face_v));
		col = mix(col, decal.rgb, decal.a);
	}

	ALBEDO = col;
}
