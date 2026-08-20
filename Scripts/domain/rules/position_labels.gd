class_name PositionLabels

# Translation keys for a skater's position badge and the lobby grid's column
# headers. Engine-free like the rest of the domain: this hands back a stable
# key and the display seam localizes it (see Scripts/ui/CLAUDE.md).
#
# Two rules shape the tables:
#
#   Away mirrors the wings. The away team attacks the opposite direction, so
#   its slot 1 sits in the same on-screen column as home's slot 2. Labelling
#   both "L" would put two left wings in one column; away's slots 1/2 read as
#   its own R/L instead.
#
#   3v3 is position-free. Slots 1/2 are rovers, so they keep the classic
#   single letters. 5v5 has a real forward/defense split, and there the
#   wingers spell out LW/RW so they read consistently beside LD/RD.

const _BADGE_HOME: Array[StringName] = [
	&"POS_BADGE_C", &"POS_BADGE_L", &"POS_BADGE_R", &"POS_BADGE_LD", &"POS_BADGE_RD",
]
const _BADGE_AWAY: Array[StringName] = [
	&"POS_BADGE_C", &"POS_BADGE_R", &"POS_BADGE_L", &"POS_BADGE_RD", &"POS_BADGE_LD",
]
const _BADGE_HOME_5V5: Array[StringName] = [
	&"POS_BADGE_C", &"POS_BADGE_LW", &"POS_BADGE_RW", &"POS_BADGE_LD", &"POS_BADGE_RD",
]
const _BADGE_AWAY_5V5: Array[StringName] = [
	&"POS_BADGE_C", &"POS_BADGE_RW", &"POS_BADGE_LW", &"POS_BADGE_RD", &"POS_BADGE_LD",
]

# Forward-row column headers, indexed by on-screen column rather than by slot
# (the grid orders its cards LW / C / RW, not 0 / 1 / 2). Same mirror.
const _HEADER_HOME: Array[StringName] = [
	&"POSITION_LW", &"POSITION_C", &"POSITION_RW",
]
const _HEADER_AWAY: Array[StringName] = [
	&"POSITION_RW", &"POSITION_C", &"POSITION_LW",
]

# Badge for one roster slot. `slot` is a team_slot; out-of-range slots fall
# back to the centre badge rather than crashing a HUD rebuild.
static func badge_key(team_id: int, slot: int, is_5v5: bool) -> StringName:
	var table: Array[StringName] = _BADGE_HOME
	if team_id == 1:
		table = _BADGE_AWAY_5V5 if is_5v5 else _BADGE_AWAY
	elif is_5v5:
		table = _BADGE_HOME_5V5
	if slot < 0 or slot >= table.size():
		return _BADGE_HOME[0]
	return table[slot]

# Header over one forward column of the lobby's slot grid.
static func column_header_key(team_id: int, col: int) -> StringName:
	var table: Array[StringName] = _HEADER_AWAY if team_id == 1 else _HEADER_HOME
	if col < 0 or col >= table.size():
		return _HEADER_HOME[1]
	return table[col]
