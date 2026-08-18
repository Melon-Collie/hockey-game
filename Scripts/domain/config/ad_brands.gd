class_name AdBrands
extends RefCounted

# The arena's sponsors — the dasher-board panels and the in-ice wordmarks both
# draw from this one table.
#
# Every name here is invented. Real marks on the boards would be a licensing
# problem, and the house brand (Mitts) already carries its own art elsewhere in
# the project, so the sponsors that fill a rink are made up in the same spirit as
# the crowd: set dressing that has to look plausible from ten metres away.
#
# A sponsor is a row, not an art file. The painters compose each panel from a
# field, a wordmark, and a rule, so adding one costs an entry here rather than a
# texture plus its .import — and the wordmark stays crisp at whatever resolution
# the atlas is built at.
#
# `bg` is the panel field, `fg` the wordmark, `accent` the tagline and the rule
# under it. Fields are chosen dark enough that a white wordmark carries at a
# distance, since the boards behind them are white.

const BRANDS: Array[Dictionary] = [
	{"name": "TOP SHELF", "tag": "LAGER",
		"bg": Color(0.35, 0.15, 0.05), "fg": Color(0.98, 0.94, 0.86), "accent": Color(0.95, 0.72, 0.20)},
	{"name": "SLAPSHOT", "tag": "AUTO GROUP",
		"bg": Color(0.13, 0.13, 0.15), "fg": Color(0.97, 0.97, 0.97), "accent": Color(0.88, 0.18, 0.18)},
	{"name": "GLACIER", "tag": "TRUST BANK",
		"bg": Color(0.06, 0.20, 0.42), "fg": Color(0.96, 0.98, 1.0), "accent": Color(0.55, 0.85, 0.95)},
	{"name": "IRON MITTS", "tag": "STICK TAPE",
		"bg": Color(0.09, 0.09, 0.10), "fg": Color(0.97, 0.97, 0.97), "accent": Color(0.95, 0.50, 0.10)},
	{"name": "NORTHWIND", "tag": "AIRLINES",
		"bg": Color(0.05, 0.30, 0.32), "fg": Color(0.96, 0.99, 0.98), "accent": Color(0.95, 0.80, 0.25)},
	{"name": "BLUE LINE", "tag": "INSURANCE",
		"bg": Color(0.08, 0.14, 0.38), "fg": Color(0.95, 0.96, 1.0), "accent": Color(0.45, 0.70, 0.98)},
	{"name": "COLD SNAP", "tag": "HEATING & AIR",
		"bg": Color(0.24, 0.27, 0.31), "fg": Color(0.97, 0.98, 1.0), "accent": Color(0.62, 0.88, 0.98)},
	{"name": "TWINE & TAPE", "tag": "PRO SHOP",
		"bg": Color(0.32, 0.07, 0.12), "fg": Color(0.98, 0.95, 0.88), "accent": Color(0.90, 0.75, 0.35)},
	{"name": "PUCKHOUND", "tag": "PIZZA CO",
		"bg": Color(0.62, 0.14, 0.10), "fg": Color(0.99, 0.96, 0.88), "accent": Color(0.35, 0.65, 0.30)},
	{"name": "FIVE HOLE", "tag": "DONUTS",
		"bg": Color(0.55, 0.13, 0.38), "fg": Color(0.99, 0.95, 0.97), "accent": Color(0.99, 0.85, 0.60)},
	{"name": "GRINDER", "tag": "COFFEE ROASTERS",
		"bg": Color(0.22, 0.13, 0.09), "fg": Color(0.97, 0.92, 0.84), "accent": Color(0.80, 0.62, 0.38)},
	{"name": "ZAMBOWL", "tag": "LANES",
		"bg": Color(0.28, 0.12, 0.45), "fg": Color(0.97, 0.95, 1.0), "accent": Color(0.70, 0.92, 0.30)},
	{"name": "CROSSBAR", "tag": "HARDWARE",
		"bg": Color(0.08, 0.26, 0.14), "fg": Color(0.95, 0.99, 0.95), "accent": Color(0.95, 0.82, 0.22)},
	{"name": "OVERTIME", "tag": "ENERGY",
		"bg": Color(0.07, 0.08, 0.07), "fg": Color(0.72, 0.95, 0.25), "accent": Color(0.72, 0.95, 0.25)},
]

# In-ice sponsor slots, in rink metres: `center` is (x, z), `size` is the
# panel's (x extent, z extent), `brand` indexes BRANDS.
#
# Hand-picked the way a rink crew picks them — the stretches of sheet that carry
# no painted marking. One fills each neutral-zone quadrant, boxed in by the
# centre red line, a blue line, the centre circle, and a neutral-zone dot; one
# sits in each high slot, between the blue line and the tops of the end-zone
# faceoff circles. A slot is long in Z and narrow in X because the wordmark runs
# along the length of the rink, reading from the broadcast side.
#
# The clearances are not eyeballed: test_board_ad_layout.gd re-derives every line,
# circle, dot, and crease from GameRules and fails if a slot creeps onto paint,
# so moving one of these is checked rather than trusted.
const ICE_SLOTS: Array[Dictionary] = [
	{"center": Vector2( 10.1,  3.65), "size": Vector2(2.8, 6.3), "brand": 0},
	{"center": Vector2( 10.1, -3.65), "size": Vector2(2.8, 6.3), "brand": 6},
	{"center": Vector2(-10.1,  3.65), "size": Vector2(2.8, 6.3), "brand": 4},
	{"center": Vector2(-10.1, -3.65), "size": Vector2(2.8, 6.3), "brand": 11},
	{"center": Vector2(  0.0,  12.2), "size": Vector2(2.6, 5.6), "brand": 2},
	{"center": Vector2(  0.0, -12.2), "size": Vector2(2.6, 5.6), "brand": 9},
]


# Board panels are dealt round-robin around the perimeter, so a full lap shows
# every sponsor before it shows one twice.
static func brand_at(index: int) -> Dictionary:
	return BRANDS[index % BRANDS.size()]
