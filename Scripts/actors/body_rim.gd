class_name BodyRim
extends Object

# Shared Fresnel rim-light tuning for player-body materials. Both the skater and
# the goalie are "players," so their rim must read identically — this is the
# single source of truth for that, applied via SkaterUniformCoordinator and
# GoalieUniformCoordinator so the two can't drift.
#
# A subtle rim highlights the silhouette so the rounded primitive forms read as
# lit volumes from the top-down camera rather than flat blobs. rim_tint leans the
# edge mostly white with a hint of the part's own color. Cheap — built into the
# standard shader. (The goalie's one custom-shader part, the jersey box body,
# carries a matching Fresnel emission term in goalie_jersey.gdshader, since a
# ShaderMaterial can't use the StandardMaterial3D rim.)

const STRENGTH: float = 0.4
const TINT: float = 0.35


static func apply(mat: StandardMaterial3D) -> void:
	mat.rim_enabled = true
	mat.rim = STRENGTH
	mat.rim_tint = TINT
