class_name ArenaBowlSpec
extends RefCounted

# An immutable snapshot of every number that describes one bowl.
#
# `ArenaStands` fills one of these from its exports at the top of a rebuild and
# hands it to each collaborator's constructor. That is what keeps the seam clean:
# a collaborator reads the shape of the arena it is building without holding a
# reference to the node that owns the exports, so nothing below `ArenaStands`
# can reach back up into it, and nothing has to be re-plumbed when an export
# moves. The defaults here are never used in anger — `ArenaStands` overwrites
# every field — but they keep a bare `ArenaBowlSpec.new()` buildable in a test.

# ── Rink footprint ───────────────────────────────────────────────────────────
var rink_length: float = 60.0
var rink_width: float = 26.0
var corner_radius: float = 8.53
var corner_segments: int = 14
# Outward offset of the first tread, measured from rink_width/2 (the wall/glass
# center).
var base_outward_offset: float = 0.20

# ── Lower bowl ───────────────────────────────────────────────────────────────
var stands_base_y: float = 0.8
var num_terraces: int = 15
var tread_depth: float = 0.6
var riser_height: float = 0.4

# ── Upper deck ───────────────────────────────────────────────────────────────
var walkway_depth: float = 2.2
var upper_terraces: int = 10
var upper_riser_height: float = 0.55
var upper_deck_rise: float = 4.0

# ── Shell ────────────────────────────────────────────────────────────────────
var shell_height: float = 8.0
var shell_color: Color = Color(0.14, 0.15, 0.2)
var concrete_color: Color = Color(0.42, 0.42, 0.45)

# ── Vomitories ───────────────────────────────────────────────────────────────
var vomitories_enabled: bool = true
var vomitory_width: float = 2.2
var vomitory_height: float = 2.9
var vomitory_depth: float = 2.6

# ── Seating sections ─────────────────────────────────────────────────────────
var num_aisles: int = 12
var aisle_width: float = 1.1
var attendance: float = 0.93

# ── Crowd placement ──────────────────────────────────────────────────────────
var spectator_spacing: float = 0.55
var spectator_inset_from_riser: float = 0.18
var spectator_yaw_jitter_deg: float = 18.0
var spectator_y_jitter: float = 0.03

# ── Fan mix ──────────────────────────────────────────────────────────────────
var home_fan_ratio: float = 0.65
var away_fan_ratio: float = 0.08
var secondary_color_ratio: float = 0.30
var team_cap_ratio: float = 0.22

# ── Team colors ──────────────────────────────────────────────────────────────
var home_color: Color = Color(0.85, 0.20, 0.22)
var home_color_secondary: Color = Color(0.97, 0.78, 0.20)
var away_color: Color = Color(0.18, 0.40, 0.85)
var away_color_secondary: Color = Color(0.92, 0.92, 0.95)

# ── Seats ────────────────────────────────────────────────────────────────────
var seat_color: Color = Color(0.13, 0.16, 0.26)
var seat_shade_variation: float = 0.16

# ── Signage ──────────────────────────────────────────────────────────────────
var banner_height: float = 4.2


# Every param that moves geometry, transforms, or the AABB — the key the layout
# cache is stored under. The team colors and fan ratios are deliberately absent:
# they only repaint, and so is `seat_color`, which lives on the seat material.
# `seat_shade_variation` IS here, because it is rolled into per-instance colors
# baked into the cached MultiMeshes rather than applied at instancing time.
func geometry_key() -> String:
	return str([rink_length, rink_width, corner_radius, stands_base_y,
			num_terraces, tread_depth, riser_height, base_outward_offset,
			corner_segments, spectator_spacing, spectator_inset_from_riser,
			spectator_yaw_jitter_deg, spectator_y_jitter,
			walkway_depth, upper_terraces, upper_riser_height, upper_deck_rise,
			shell_height, num_aisles, aisle_width, attendance,
			seat_shade_variation,
			# The shell mesh is cached, and these cut holes in it.
			vomitories_enabled, vomitory_width, vomitory_height])


# Everything the crowd's paint pass reads: the four team colors + the mix ratios.
func paint_key() -> String:
	return str([home_color, home_color_secondary, away_color,
			away_color_secondary, home_fan_ratio, away_fan_ratio,
			secondary_color_ratio, team_cap_ratio])
