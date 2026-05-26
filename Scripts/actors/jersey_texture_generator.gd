class_name JerseyTextureGenerator

# Static utility for generating procedural jersey textures that wrap the
# torso CylinderMesh. Numbers, names, and the hem stripe are painted into
# a single texture applied as the cylinder's material albedo — so they
# follow the surface curvature instead of floating above it.

# 5×7 pixel bitmap font. Each entry is 7 row-bitmasks (MSB = leftmost of 5 columns).
const _JERSEY_FONT: Dictionary = {
	"0": [14,17,17,17,17,17,14], "1": [4,12,4,4,4,4,14],
	"2": [14,17,1,2,4,8,31],    "3": [14,17,1,6,1,17,14],
	"4": [2,6,10,18,31,2,2],    "5": [31,16,16,30,1,1,30],
	"6": [6,8,16,30,17,17,14],  "7": [31,1,2,4,8,8,8],
	"8": [14,17,17,14,17,17,14],"9": [14,17,17,15,1,2,12],
	"A": [14,17,17,31,17,17,17],"B": [30,17,17,30,17,17,30],
	"C": [14,17,16,16,16,17,14],"D": [30,17,17,17,17,17,30],
	"E": [31,16,16,30,16,16,31],"F": [31,16,16,30,16,16,16],
	"G": [14,17,16,23,17,17,14],"H": [17,17,17,31,17,17,17],
	"I": [14,4,4,4,4,4,14],     "J": [7,1,1,1,1,17,14],
	"K": [17,18,20,24,20,18,17],"L": [16,16,16,16,16,16,31],
	"M": [17,27,21,17,17,17,17],"N": [17,25,21,19,17,17,17],
	"O": [14,17,17,17,17,17,14],"P": [30,17,17,30,16,16,16],
	"Q": [14,17,17,17,21,18,13],"R": [30,17,17,30,20,18,17],
	"S": [14,17,16,14,1,17,14], "T": [31,4,4,4,4,4,4],
	"U": [17,17,17,17,17,17,14],"V": [17,17,17,17,10,10,4],
	"W": [17,17,17,21,21,27,17],"X": [17,10,10,4,10,10,17],
	"Y": [17,17,10,4,4,4,4],    "Z": [31,1,2,4,8,16,31],
	" ": [0,0,0,0,0,0,0],
}

const _GLYPH_W: int = 5


static func _draw_glyph(img: Image, ch: String, x: int, y: int, glyph_scale: int, color: Color) -> void:
	var rows: Array = _JERSEY_FONT.get(ch.to_upper(), _JERSEY_FONT[" "])
	for row: int in rows.size():
		var bits: int = rows[row]
		for col: int in _GLYPH_W:
			if bits & (1 << (_GLYPH_W - 1 - col)):
				for sy: int in glyph_scale:
					for sx: int in glyph_scale:
						var px: int = x + col * glyph_scale + sx
						var py: int = y + row * glyph_scale + sy
						if px >= 0 and px < img.get_width() and py >= 0 and py < img.get_height():
							img.set_pixel(px, py, color)


# Generates a 512×256 jersey texture sized to wrap the torso CylinderMesh.
# Godot's CylinderMesh starts U=0 at +Z and increases counterclockwise
# (looking down +Y). The caller pairs this texture with
# material.uv1_offset.x = 0.25 to rotate the mapping so the texture's
# back-center (texel x=128) lands at the skater's +Z (the back). Without
# that offset, content drawn at x=128 would land at +X (right side).
#
# V maps from 0 at the TOP of the cylinder to 1 at the BOTTOM (Godot
# generates the side with y = top − height·V), so image y=0 (the top of
# the image) ends up at the top of the torso and image y=IMG_H−1 lands
# at the bottom — same as a flat picture pinned to the torso.
#
# Layout:
#   - Base fill: jersey_color across the entire texture
#   - Hem band: jersey_stripe_color in the bottom 28 rows (≈ 11% of the
#     0.55m torso → ~6cm visible hem)
#   - Player name: centered at x=128, in the upper portion of the torso
#   - Player number: centered at x=128, in the mid-upper portion
# Name / number scales shrink adaptively (min 2) so long names don't
# overflow the back quadrant.
static func make_jersey_cylinder_texture(
		jersey_color: Color,
		stripe_color: Color,
		player_name: String,
		number: int,
		text_color: Color) -> ImageTexture:
	const IMG_W: int = 512
	const IMG_H: int = 256
	const BACK_CENTER_X: int = 128         # paired with uv1_offset.x = 0.25 → +Z back
	const HEM_HEIGHT: int = 28             # ≈ 6cm of a 0.55m-tall torso
	const MAX_BACK_WIDTH: int = 280        # max horizontal text span on the back
	const NAME_BASE_SCALE: int = 3
	const NUM_BASE_SCALE: int = 6
	const NAME_Y_TOP: int = 60
	const NUM_Y_TOP: int = 100

	var img := Image.create(IMG_W, IMG_H, false, Image.FORMAT_RGBA8)
	img.fill(jersey_color)
	img.fill_rect(Rect2i(0, IMG_H - HEM_HEIGHT, IMG_W, HEM_HEIGHT), stripe_color)

	var name_upper: String = player_name.to_upper()
	if name_upper.length() > 0:
		_draw_centered_string(img, name_upper, BACK_CENTER_X, NAME_Y_TOP,
				NAME_BASE_SCALE, MAX_BACK_WIDTH, text_color)

	var num_str: String = str(number)
	if num_str.length() > 0:
		_draw_centered_string(img, num_str, BACK_CENTER_X, NUM_Y_TOP,
				NUM_BASE_SCALE, MAX_BACK_WIDTH, text_color)

	return ImageTexture.create_from_image(img)


# Draws a string horizontally centered at center_x. Shrinks the scale if
# the rendered width would exceed max_width (minimum scale 2 so glyphs
# stay legible).
static func _draw_centered_string(
		img: Image, s: String, center_x: int, y_top: int,
		base_scale: int, max_width: int, color: Color) -> void:
	var n: int = s.length()
	var unit_width: int = n * _GLYPH_W + (n - 1)  # glyph + 1-unit gap
	var scale: int = base_scale
	if unit_width > 0 and scale * unit_width > max_width:
		scale = maxi(2, int(float(max_width) / float(unit_width)))
	var char_w: int = _GLYPH_W * scale
	var gap: int = scale
	var total_w: int = n * char_w + (n - 1) * gap
	var x_start: int = center_x - int(total_w / 2.0)
	for i: int in n:
		_draw_glyph(img, s[i], x_start + i * (char_w + gap), y_top, scale, color)
