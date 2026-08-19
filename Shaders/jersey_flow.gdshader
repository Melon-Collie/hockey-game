// Skater torso — the jersey — with a hem that swings.
//
// A ShaderMaterial rather than the StandardMaterial3D every other body part
// uses, because the skirt has to move. It reproduces what that material did:
// the JerseyDecal SubViewport as albedo, the 0.25 U offset that rotates the
// wrap so the texture's back-centre lands on the skater's +Z, cloth roughness,
// and a Fresnel rim.
//
// The rim is the same hand-rolled approximation goalie_jersey.gdshader carries
// (a ShaderMaterial cannot use StandardMaterial3D's rim term) so the two custom-
// shader kit parts in the game agree with each other. It is an approximation of
// BodyRim, not that term reproduced, so the torso's edge light is not pixel-
// identical to the arms and helmet beside it.
//
// The swing is a LAG, not a physics sim: `flow` is how far the body has moved
// out from under the cloth this instant, computed and filtered on the CPU by
// SkaterUniformCoordinator, and the hem displaces against it. Accelerate and the
// skirt trails; stop hard and it swings forward past the body and settles. That
// overshoot is the filter's, so nothing here integrates anything.
//
// `flow` arrives in the skater's BODY-LOCAL frame. The torso bone's pose is
// identity plus the gait's lean, so this is that frame to within the lean angle
// — invisible on a cosmetic hem, and keeping the model body-local is what stops
// this needing a world-space read at render rate (see the render-clock rule in
// CLAUDE.md).
shader_type spatial;

uniform sampler2D jersey_tex : source_color, filter_linear_mipmap, repeat_enable;
// xyz = body-local displacement to apply at the hem, in metres. w unused.
uniform vec4 flow = vec4(0.0);
// Where the swing ramps in and reaches full, in the lathe's V — which runs 0 at
// the collar to 0.5 at the hem, so 0.30 is a little below the waist. Starting it
// there rather than at the waist keeps most of the swing in the skirt and leaves
// the number on the back nearly still.
uniform float hem_start_v = 0.30;
uniform float hem_full_v = 0.5;
// Matches BodyRim.STRENGTH's intent; see the note above about it being an
// approximation rather than that term.
uniform float rim_strength = 0.2;

void vertex() {
	VERTEX += flow.xyz * smoothstep(hem_start_v, hem_full_v, UV.y);
}

void fragment() {
	// The 0.25 U shift is StandardMaterial3D's uv1_offset.x, folded in here:
	// JerseyDecal paints the back at texel x=128 of 512 and the lathe's U starts
	// at +Z, so the wrap needs a quarter turn to put the nameplate on the back.
	ALBEDO = texture(jersey_tex, vec2(UV.x + 0.25, UV.y)).rgb;
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	EMISSION = vec3(rim * rim_strength);
}
