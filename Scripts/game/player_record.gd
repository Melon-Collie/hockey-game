class_name PlayerRecord

var peer_id: int = 0
var team_slot: int = 0  # within-team index: 0, 1, or 2
var player_name: String = ""
var jersey_number: int = 10
var skater: Skater = null
var controller: SkaterController = null
var is_local: bool = false
# True for AI-controlled actors (bot peer_ids in [BOT_ID_BASE, BOT_ID_BASE+5]).
# Use this to gate per-peer RPC dispatch — peer_id sign is NOT a reliable
# bot indicator and shouldn't be checked directly.
var is_bot: bool = false
# True only on the synthesized records GameManager.get_stars_of_game builds
# for a starred AI goalie — goalies aren't roster records (no real peer id,
# controller, skater, or stats). The HUD branches on this to caption the star
# row with a saves line instead of a skater stat line. Never true in the
# PlayerRegistry.
var is_goalie: bool = false
var team: Team = null
# faceoff_position used to live here but it's pure-derived from team_id +
# team_slot. Compute it via PlayerRules.faceoff_position(record.team.team_id,
# record.team_slot) at the call site; the registry stays the only place that
# knows the team/slot mapping.
var jersey_color: Color        = Color.WHITE
var helmet_color: Color        = Color.BLACK
var pants_color: Color         = Color.BLACK
var jersey_stripe_color: Color = Color.WHITE
var gloves_color: Color        = Color.BLACK
var pants_stripe_color: Color  = Color.WHITE
var socks_color: Color         = Color.WHITE
var socks_stripe_color: Color  = Color.BLACK
var secondary_color: Color     = Color.WHITE
var text_color: Color          = Color.WHITE
var text_outline_color: Color  = Color.BLACK
var is_left_handed: bool = true
# Packed StickTapeConfig code (cosmetic tape job) — carried on the record so
# the host's roster payload for late joiners can replay it.
var tape_code: int = StickTapeConfig.DEFAULT_CODE
# Per-player gameplay attribute levels (Speed/Agility/Size/Shot). Default to
# all-medium so a record built without attribute data behaves like the
# pre-attributes baseline.
var attributes: PlayerAttributes = PlayerAttributes.all_average()
var stats: PlayerStats = PlayerStats.new()

func _init(p_peer_id: int, p_team_slot: int, p_is_local: bool, p_team: Team) -> void:
	peer_id = p_peer_id
	team_slot = p_team_slot
	is_local = p_is_local
	team = p_team

func display_name() -> String:
	return player_name if not player_name.is_empty() else "P%d" % (team_slot + 1)
