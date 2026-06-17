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
// rendering name and number on a transparent background. Sampled only on the
// back (+Z) face — the goalie faces -Z toward the shooter, so +Z is the back
// of the jersey where the nameplate lives. U: 0=left, 1=right from behind.

const int MAX_STRIPES = 5;

// Half-extents of the body BoxMesh — kept as constants here so the shader
// compiles with exact values even if the mesh size is ever adjusted.
const float HALF_H = 0.3;   // body height 0.6 m
const float HALF_W = 0.24;  // body width  0.48 m

uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 yoke_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool yoke_enabled = false;
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

	// Normalise height to [0, 1] (0 = TOP of body, 1 = BOTTOM) to match the
	// v2 jersey schema convention where stripe pos=0 is the collar and pos=1
	// is the waist — same direction as JerseyDecal's pixel-V coordinate.
	float norm_y = (HALF_H - v_obj_y) / (HALF_H * 2.0);

	// Base colour, then stripes in array order.
	vec3 col = base_color.rgb;
	for (int i = 0; i < MAX_STRIPES; i++) {
		if (i < stripe_count &&
				abs(norm_y - stripe_positions[i]) < stripe_widths[i] * 0.5) {
			col = stripe_colors[i].rgb;
		}
	}

	// Yoke on the top face only — same approach as JerseyDecal's TOP_CAP_RECT
	// which paints the flat top disk of the skater's CylinderMesh. Here the
	// top face is detected by the upward-facing normal.
	if (yoke_enabled && v_obj_normal.y > 0.9) {
		col = yoke_color.rgb;
	}

	// Project text decal onto the back (+Z) face only. The goalie faces -Z
	// toward the shooter, so +Z is the back of the jersey — where the name
	// plate and number live. U: 0 at left, 1 at right from behind. V reuses
	// norm_y (0=collar, 1=waist) which already matches the texture convention.
	if (v_obj_normal.z > 0.9) {
		float face_u = (HALF_W - v_obj_x) / (HALF_W * 2.0);
		vec4 decal = texture(text_decal, vec2(face_u, norm_y));
		col = mix(col, decal.rgb, decal.a);
	}

	ALBEDO = col;
}
