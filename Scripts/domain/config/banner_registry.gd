class_name BannerRegistry
extends RefCounted

# What hangs from the rafters: championship banners and retired numbers.
#
# The arena has always had a hole here. ArenaStands' shell comment notes that
# "whatever sliver of void remains visible above it reads as dark rafters", and
# the Jumbotron's column "runs up into the dark above the shell wall so it reads
# as hung from unseen rafters" — two places where the geometry stops and the
# fiction takes over. Banners are what a real building puts in that volume.
#
# Invented history, like the sponsors are invented businesses. `kind` picks the
# layout the painter draws: a TITLE banner stacks a name over a year, a NUMBER
# banner puts a jersey number over a surname.

enum Kind { TITLE, NUMBER }

# `field` is the banner cloth, `ink` the lettering, `trim` the border and the
# rule between the two lines. Fields stay dark: these hang unlit in the roof
# space, so a pale banner would read as a hole punched in the ceiling.
const BANNERS: Array[Dictionary] = [
	{"kind": Kind.TITLE, "top": "MITTS CUP", "bottom": "2029",
		"field": Color(0.09, 0.13, 0.30), "ink": Color(0.97, 0.97, 1.0), "trim": Color(0.85, 0.70, 0.28)},
	{"kind": Kind.TITLE, "top": "MITTS CUP", "bottom": "2031",
		"field": Color(0.09, 0.13, 0.30), "ink": Color(0.97, 0.97, 1.0), "trim": Color(0.85, 0.70, 0.28)},
	{"kind": Kind.TITLE, "top": "MITTS CUP", "bottom": "2032",
		"field": Color(0.09, 0.13, 0.30), "ink": Color(0.97, 0.97, 1.0), "trim": Color(0.85, 0.70, 0.28)},
	{"kind": Kind.TITLE, "top": "DIVISION", "bottom": "2028",
		"field": Color(0.24, 0.07, 0.11), "ink": Color(0.97, 0.95, 0.92), "trim": Color(0.72, 0.62, 0.35)},
	{"kind": Kind.TITLE, "top": "DIVISION", "bottom": "2030",
		"field": Color(0.24, 0.07, 0.11), "ink": Color(0.97, 0.95, 0.92), "trim": Color(0.72, 0.62, 0.35)},
	{"kind": Kind.TITLE, "top": "CONFERENCE", "bottom": "2031",
		"field": Color(0.24, 0.07, 0.11), "ink": Color(0.97, 0.95, 0.92), "trim": Color(0.72, 0.62, 0.35)},
	{"kind": Kind.NUMBER, "top": "4", "bottom": "TREMBLAY",
		"field": Color(0.07, 0.09, 0.14), "ink": Color(0.96, 0.97, 1.0), "trim": Color(0.55, 0.62, 0.78)},
	{"kind": Kind.NUMBER, "top": "9", "bottom": "OKONKWO",
		"field": Color(0.07, 0.09, 0.14), "ink": Color(0.96, 0.97, 1.0), "trim": Color(0.55, 0.62, 0.78)},
	{"kind": Kind.NUMBER, "top": "12", "bottom": "HALVORSEN",
		"field": Color(0.07, 0.09, 0.14), "ink": Color(0.96, 0.97, 1.0), "trim": Color(0.55, 0.62, 0.78)},
	{"kind": Kind.NUMBER, "top": "16", "bottom": "DUFRESNE",
		"field": Color(0.07, 0.09, 0.14), "ink": Color(0.96, 0.97, 1.0), "trim": Color(0.55, 0.62, 0.78)},
	{"kind": Kind.NUMBER, "top": "21", "bottom": "NAKASHIMA",
		"field": Color(0.07, 0.09, 0.14), "ink": Color(0.96, 0.97, 1.0), "trim": Color(0.55, 0.62, 0.78)},
	{"kind": Kind.NUMBER, "top": "30", "bottom": "SOKOLOV",
		"field": Color(0.07, 0.09, 0.14), "ink": Color(0.96, 0.97, 1.0), "trim": Color(0.55, 0.62, 0.78)},
]
