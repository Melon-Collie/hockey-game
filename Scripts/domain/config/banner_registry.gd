class_name BannerRegistry
extends RefCounted

# What hangs from the rafters: a banner for each playtester.
#
# The arena had always had a hole here. ArenaStands' shell comment notes that
# "whatever sliver of void remains visible above it reads as dark rafters", and
# the Jumbotron's column "runs up into the dark above the shell wall so it reads
# as hung from unseen rafters" — two places where the geometry stops and the
# fiction takes over. A real building fills that volume with the people it owes
# something to, and so does this one.
#
# Four banners for four names, repeated around the ring (see ArenaStands'
# _BANNER_RING_REPEATS) so every camera angle sees some without the roof turning
# into a wall of the same four. Lettering is uppercase because banner lettering
# is; the names are otherwise exactly as given.
#
# `field` is the banner cloth, `ink` the number and name, `trim` the border and
# the rule between them. Fields stay dark — these hang unlit in the roof space,
# and a pale banner reads as a hole punched in the ceiling rather than as cloth.
# Each gets its own so a name is identifiable at a glance from the ice.
const BANNERS: Array[Dictionary] = [
	{"number": "7", "name": "NETHERS",
		"field": Color(0.09, 0.13, 0.30), "ink": Color(0.97, 0.97, 1.00), "trim": Color(0.85, 0.70, 0.28)},
	{"number": "3", "name": "SCRUB",
		"field": Color(0.26, 0.07, 0.11), "ink": Color(0.99, 0.96, 0.94), "trim": Color(0.86, 0.74, 0.42)},
	{"number": "27", "name": "BUUKIE",
		"field": Color(0.07, 0.22, 0.17), "ink": Color(0.96, 1.00, 0.98), "trim": Color(0.80, 0.82, 0.45)},
	{"number": "16", "name": "CANOOOK",
		"field": Color(0.20, 0.10, 0.28), "ink": Color(0.98, 0.96, 1.00), "trim": Color(0.72, 0.66, 0.88)},
]
