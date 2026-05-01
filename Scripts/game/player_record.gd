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
var team: Team = null
var faceoff_position: Vector3 = Vector3.ZERO
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
var stats: PlayerStats = PlayerStats.new()

func _init(p_peer_id: int, p_team_slot: int, p_is_local: bool, p_team: Team) -> void:
	peer_id = p_peer_id
	team_slot = p_team_slot
	is_local = p_is_local
	team = p_team

func display_name() -> String:
	return player_name if not player_name.is_empty() else "P%d" % (team_slot + 1)
