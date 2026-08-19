class_name UniformPaint
extends Object

# Shared paint for player-body materials — the sibling of BodyRim. The skater and
# the goalie coordinators both build their solid materials, their textured ones,
# and the horizontal stripe texture every cylindrical part wears through here, so
# a change to any of the three reaches both bodies.

# Surface roughness by material, so a jersey and a helmet catch the arena lights
# the way cloth and hard plastic do.
const ROUGH_CLOTH: float = 0.9
const ROUGH_HELMET: float = 0.28   # glossy hard plastic
const ROUGH_SKATE: float = 0.42    # synthetic boot leather

# Stripe-texture layout. Godot's cylinder UV puts the curved side in the lower
# half of V and the two end caps in the upper half, so a stripe pattern is
# painted into that lower fraction and the caps are filled separately. Four
# pixels wide is enough for a horizontally-uniform band.
const CYLINDER_SIDE_V_FRACTION: float = 0.5
const STRIPE_TEX_HEIGHT_PX: int = 128
const STRIPE_TEX_WIDTH_PX: int = 4


static func solid(color: Color, roughness: float = ROUGH_CLOTH) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	BodyRim.apply(mat)
	return mat


static func textured(tex: Texture2D, roughness: float = ROUGH_CLOTH) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = roughness
	BodyRim.apply(mat)
	return mat


# Horizontal bands across a cylinder's curved side. Each stripe is `pos` (centre,
# as a fraction of the side region) and `width` (also a fraction), so a uniform
# authored once lands at the same proportion of every part regardless of its
# real length. `top_cap`, when a Color, fills the cylinder's end-cap half of the
# atlas — used where a capped part would otherwise show the base colour on its
# flat end.
static func h_stripes(base: Color, stripes: Array,
		top_cap: Variant = null) -> ImageTexture:
	var img := Image.create(STRIPE_TEX_WIDTH_PX, STRIPE_TEX_HEIGHT_PX, false, Image.FORMAT_RGBA8)
	img.fill(base)
	var side_px: int = int(round(CYLINDER_SIDE_V_FRACTION * float(STRIPE_TEX_HEIGHT_PX)))
	for s: Dictionary in stripes:
		var center_px: float = float(s.pos) * float(side_px)
		var half_px: float = float(s.width) * float(side_px) * 0.5
		var y0: int = clampi(int(round(center_px - half_px)), 0, side_px)
		var y1: int = clampi(int(round(center_px + half_px)), 0, side_px)
		if y1 > y0:
			img.fill_rect(Rect2i(0, y0, STRIPE_TEX_WIDTH_PX, y1 - y0), s.color)
	if top_cap is Color:
		img.fill_rect(Rect2i(0, side_px, STRIPE_TEX_WIDTH_PX / 2,
				STRIPE_TEX_HEIGHT_PX - side_px), top_cap)
	return ImageTexture.create_from_image(img)
