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

// Handle wrap (StickTapeConfig.KnobStyle) is painted here rather than meshed:
// the shaft is one stretched box, so separate wrap geometry would need
// per-frame placement AND its own copy of the flex bow. Fragment paint gets
// both for free. grip_mode 0 = bare, 1 = candy-cane spiral, 2 = full grip;
// the wrap hangs down grip_len_m of REAL shaft from the BUTT end (object z =
// +0.5 — the shaft extends past the top hand and the knob caps it), which
// needs shaft_len_m because node scale never reaches object space —
// update_stick_mesh feeds the live rendered length.

uniform vec4 albedo : source_color = vec4(0.06, 0.06, 0.07, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float flex_m = 0.0;                              // signed mid-shaft bow, metres
uniform float kick_point : hint_range(0.3, 2.0) = 0.75;  // <1 = bulge toward the blade
uniform int grip_mode = 0;                               // StickTapeConfig.KnobStyle
uniform vec4 grip_color : source_color = vec4(1.0);
uniform float grip_len_m = 0.5;                          // wrap reach down from the butt
uniform float shaft_len_m = 1.3;                         // live rendered shaft length

// Brand wordmark on the two wide (±X) faces, sampled by object-space position
// like the grip — the box has no authored UVs and stretches per pose, so
// texture placement is in real metres down the shaft. brand_len_m should be
// height × texture aspect so the mark isn't stretched (StickStyle sets it).
// Tape (grip paint) always wins where the two would overlap.
uniform sampler2D brand_tex : source_color, filter_linear_mipmap;
uniform vec4 brand_color : source_color = vec4(1.0);
uniform float brand_from_butt_m = 0.55;
uniform float brand_len_m = 0.194;

// Colorway bands (StickModelRegistry): up to two painted spans along the
// shaft, each in real metres from its anchor end (0 = butt, 1 = blade) —
// the same metric placement as the brand, so a blade-anchored kick zone
// stays pinned at the blade whatever the live length. from == to disables a
// slot. Painted under the wordmark and the grip wrap, so both always win.
uniform vec4 band1_color : source_color = vec4(0.0);
uniform float band1_from_m = 0.0;
uniform float band1_to_m = 0.0;
uniform int band1_anchor = 0;
uniform vec4 band2_color : source_color = vec4(0.0);
uniform float band2_from_m = 0.0;
uniform float band2_to_m = 0.0;
uniform int band2_anchor = 0;

// Candy-cane pitch: one full turn per this much shaft, half tape half bare.
const float CANDY_PERIOD_M = 0.075;
// Shaft cross-section half-extents (the 0.04 × 0.05 BoxMesh) — the side-face
// test and the brand's vertical mapping read them.
const float HALF_W = 0.02;
const float HALF_H = 0.025;

varying vec3 obj_pos;                                    // pre-flex object-space position

void vertex() {
	obj_pos = VERTEX;
	float t = clamp(VERTEX.z + 0.5, 0.0, 1.0);
	VERTEX.x += flex_m * sin(PI * pow(t, kick_point));
}

void fragment() {
	vec3 col = albedo.rgb;
	float rough = roughness;
	float from_butt = (0.5 - obj_pos.z) * shaft_len_m;
	bool taped = false;
	if (grip_mode != 0 && from_butt < grip_len_m) {
		taped = true;
		if (grip_mode == 1) {
			// Barber-pole spiral: tape band advances one turn per period.
			float ang = atan(obj_pos.y, obj_pos.x) / (2.0 * PI);
			taped = fract(from_butt / CANDY_PERIOD_M + ang) < 0.5;
		}
		if (taped) {
			col = grip_color.rgb;
			rough = 0.9;  // cloth over composite
		}
	}
	if (!taped) {
		float d1 = band1_anchor == 1 ? shaft_len_m - from_butt : from_butt;
		if (d1 >= band1_from_m && d1 < band1_to_m) {
			col = band1_color.rgb;
		}
		float d2 = band2_anchor == 1 ? shaft_len_m - from_butt : from_butt;
		if (d2 >= band2_from_m && d2 < band2_to_m) {
			col = band2_color.rgb;
		}
	}
	if (!taped && abs(obj_pos.x) > HALF_W * 0.98) {
		float u = (from_butt - brand_from_butt_m) / brand_len_m;
		if (u >= 0.0 && u <= 1.0) {
			// Mirror on the −X face so the mark reads left-to-right from
			// both sides of the stick.
			if (obj_pos.x < 0.0) {
				u = 1.0 - u;
			}
			float v = clamp(0.5 - obj_pos.y / (2.0 * HALF_H), 0.0, 1.0);
			vec4 b = texture(brand_tex, vec2(u, v));
			col = mix(col, brand_color.rgb, b.a);
		}
	}
	ALBEDO = col;
	ROUGHNESS = rough;
}
