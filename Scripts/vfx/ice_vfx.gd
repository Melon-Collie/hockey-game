class_name IceVFX

# Primitives every on-ice cosmetic is built from. Each was written out where it
# was used — the low-poly particle blob six times across four files, the snow
# tint five times, the ground plane and the teleport guard three times each,
# with one of the guards carrying the comment "same as SkaterVFX" instead of
# saying so in code.
#
# What does NOT belong here is the emitters. Their amounts, lifetimes, spreads
# and velocities are hand-picked per effect — a shared builder would take a
# dozen parameters and every call site would pass all of them, which is the same
# duplication with extra indirection.

# Just above the ice plane, so ground-level marks and emitters don't z-fight
# with it. PuckShadow deliberately sits a hair lower (0.004) to stay under the
# marks it passes over.
const ICE_Y: float = 0.005

# A per-frame position jump this large is a teleport — a faceoff reset, a goal
# reset, or a reconcile snap — not motion. Cosmetics that integrate movement
# (sprays, scratch marks) must skip that frame or they draw a stripe across the
# rink.
const TELEPORT_THRESHOLD: float = 1.0

# Shaved ice. Every spray, chip and blade mark is this colour at some opacity,
# which is what makes them read as the same material.
const SNOW_RGB: Color = Color(0.95, 0.93, 0.88, 1.0)


static func snow(alpha: float) -> Color:
	return Color(SNOW_RGB.r, SNOW_RGB.g, SNOW_RGB.b, alpha)


# The particle blob: an unshaded, alpha-blended, deliberately coarse sphere.
# Four radial segments and two rings is not a placeholder — particles are small
# and numerous, so the silhouette never reads and the vertex count does.
static func blob(color: Color) -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 4
	sphere.rings = 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	sphere.material = mat
	return sphere


# Same blob, tinted per particle by the emitter's own colour ramp rather than by
# one material colour — what the goal burst uses to fade its particles out.
static func vertex_colored_blob() -> Mesh:
	var sphere: SphereMesh = blob(Color.WHITE) as SphereMesh
	var mat: StandardMaterial3D = sphere.material as StandardMaterial3D
	mat.vertex_color_use_as_albedo = true
	return sphere
