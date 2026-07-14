class_name PingRules

# Smart-ping resolution — the pure decision table that turns "the player
# pressed the ping key with the cursor HERE, in THIS game situation" into a
# context-sensitive team message. One key, no menu: the target under the
# cursor (self / teammate / opponent / loose puck / bare ice) crossed with
# the possession state picks the message, mirroring what a real player would
# shout. The resolution runs client-side on the pinger's rendered world (the
# world the player is reacting to), then rides a tiny RPC; bots obey the
# resulting directive host-side (see AIPingDirectives / TeamBrain).
#
# Everything here is stateless and engine-free so the full decision table is
# GUT-testable: tests/unit/rules/test_ping_rules.gd.

enum Type {
	PASS_TO_ME,        # self-ping while a teammate carries: "Pass to me!"
	IM_OPEN,           # self-ping with no teammate carrier: "I'm open!"
	SHOOT,             # ping the carrying teammate: "Shoot!"
	GET_PUCK,          # ping the loose puck (or a teammate while it's loose)
	GET_OPEN,          # ping an off-puck teammate while we possess
	DEFEND,            # ping an off-puck teammate while opponents possess
	PRESSURE_CARRIER,  # ping the opposing carrier: "Get him!"
	COVER_HIM,         # ping an off-puck opponent: "Cover him!"
	GO_THERE,          # ping bare ice: "Over there!" (location marker)
}

# Translation keys for the chat-bubble text, indexed by Type. The domain stays
# engine-free (no tr() here — that's an engine call): it hands back a stable
# key and the display seam localizes it (tr() in GameManager's ping handler),
# which also keeps the wire carrying only the enum int. English/Spanish copy
# lives in locale/translations.csv.
const _MESSAGE_KEYS: Array[String] = [
	"PING_PASS_TO_ME",
	"PING_IM_OPEN",
	"PING_SHOOT",
	"PING_GET_PUCK",
	"PING_GET_OPEN",
	"PING_PICK_HIM_UP",
	"PING_GET_HIM",
	"PING_COVER_HIM",
	"PING_OVER_THERE",
]

# How long each ping's bot directive stays live (seconds). Tactical feel
# tunables, not evaluation curves: long enough for the order to play out,
# short enough that a stale order can't drag a bot out of the play. Indexed
# by Type.
const _DIRECTIVE_DURATION_S: Array[float] = [
	4.0,  # PASS_TO_ME
	4.0,  # IM_OPEN
	3.0,  # SHOOT
	4.0,  # GET_PUCK
	4.0,  # GET_OPEN
	5.0,  # DEFEND
	5.0,  # PRESSURE_CARRIER
	6.0,  # COVER_HIM
	5.0,  # GO_THERE
]

# Cursor pick radius (m, XZ) around a skater / the loose puck. Wider than a
# body so the ping reads intent, not pixel precision, but narrow enough that
# open ice a stride away from anyone still resolves to a location ping.
const PICK_RADIUS_M: float = 2.0

# Minimum wall-clock between pings from one player (anti-spam; enforced
# client-side before sending and host-side at the RPC boundary).
const COOLDOWN_S: float = 1.5


# Resolved ping: what to broadcast. `target_peer` is -1 for untargeted types
# (IM_OPEN, undirected GET_PUCK, GO_THERE); `world_pos` is meaningful for
# GET_PUCK (the puck) and GO_THERE (the pinged spot).
class Resolution:
	extends RefCounted
	var type: int = Type.GO_THERE
	var target_peer: int = -1
	var world_pos: Vector3 = Vector3.ZERO


# The decision table. Returns null when the ping is a no-op (pinging
# yourself while YOU carry the puck — there is nothing to say).
#   cursor_pos        — the pinger's cursor projected to the ice plane
#   pinger_peer/team  — who pinged
#   skater_positions  — peer_id -> Vector3 (every live skater)
#   team_id_by_peer   — peer_id -> team_id
#   carrier_peer_id   — current puck carrier, -1 when loose
#   puck_pos          — puck world position
static func resolve(cursor_pos: Vector3, pinger_peer: int, pinger_team: int,
		skater_positions: Dictionary, team_id_by_peer: Dictionary,
		carrier_peer_id: int, puck_pos: Vector3) -> Resolution:
	# Nearest skater to the cursor within the pick radius.
	var picked_peer: int = -1
	var picked_d2: float = PICK_RADIUS_M * PICK_RADIUS_M
	for pid: int in skater_positions:
		var p: Vector3 = skater_positions[pid]
		var dx: float = p.x - cursor_pos.x
		var dz: float = p.z - cursor_pos.z
		var d2: float = dx * dx + dz * dz
		if d2 < picked_d2:
			picked_d2 = d2
			picked_peer = pid

	# A LOOSE puck is its own pick target; a carried puck resolves through its
	# carrier's body instead.
	if carrier_peer_id == -1:
		var pdx: float = puck_pos.x - cursor_pos.x
		var pdz: float = puck_pos.z - cursor_pos.z
		if pdx * pdx + pdz * pdz < picked_d2:
			return _make(Type.GET_PUCK, -1, puck_pos)

	if picked_peer == -1:
		# Bare ice: location ping, clamped inside the boards so the marker
		# (and the obeying bot's destination) is always reachable.
		var xz: Vector2 = GameRules.clamp_to_rink_inner(
				Vector2(cursor_pos.x, cursor_pos.z))
		return _make(Type.GO_THERE, -1, Vector3(xz.x, 0.0, xz.y))

	var teammate_carries: bool = carrier_peer_id != -1 \
			and carrier_peer_id != pinger_peer \
			and team_id_by_peer.get(carrier_peer_id, -1) == pinger_team

	if picked_peer == pinger_peer:
		if carrier_peer_id == pinger_peer:
			return null  # pinging yourself while holding the puck says nothing
		if teammate_carries:
			return _make(Type.PASS_TO_ME, pinger_peer, cursor_pos)
		return _make(Type.IM_OPEN, pinger_peer, cursor_pos)

	var picked_pos: Vector3 = skater_positions[picked_peer]
	if team_id_by_peer.get(picked_peer, -1) == pinger_team:
		if picked_peer == carrier_peer_id:
			return _make(Type.SHOOT, picked_peer, picked_pos)
		if carrier_peer_id == -1:
			# Directed retrieval: THIS teammate goes and gets the loose puck.
			return _make(Type.GET_PUCK, picked_peer, puck_pos)
		if carrier_peer_id == pinger_peer or teammate_carries:
			return _make(Type.GET_OPEN, picked_peer, picked_pos)
		return _make(Type.DEFEND, picked_peer, picked_pos)

	# Opponent under the cursor.
	if picked_peer == carrier_peer_id:
		return _make(Type.PRESSURE_CARRIER, picked_peer, picked_pos)
	return _make(Type.COVER_HIM, picked_peer, picked_pos)


# Which bot should obey the ping, or -1 when the ping needs no obeyer pick:
# PASS_TO_ME / IM_OPEN apply to whichever bot carries (resolved at consume
# time), and a directed ping at a human is bubble-only. `bot_peers` is the
# pinger's team's bots; the current carrier is never conscripted for a
# positional order (it is playing the puck).
static func choose_obeyer(type: int, target_peer: int, world_pos: Vector3,
		pinger_peer: int, carrier_peer_id: int, puck_pos: Vector3,
		bot_peers: Array, skater_positions: Dictionary) -> int:
	match type:
		Type.PASS_TO_ME, Type.IM_OPEN:
			return -1
		Type.SHOOT, Type.GET_OPEN, Type.DEFEND:
			return target_peer if bot_peers.has(target_peer) else -1
		Type.GET_PUCK:
			if bot_peers.has(target_peer):
				return target_peer
			return _nearest_bot(puck_pos, bot_peers, skater_positions,
					pinger_peer, carrier_peer_id)
		Type.PRESSURE_CARRIER, Type.COVER_HIM:
			var anchor: Vector3 = skater_positions.get(target_peer, world_pos)
			return _nearest_bot(anchor, bot_peers, skater_positions,
					pinger_peer, carrier_peer_id)
		Type.GO_THERE:
			return _nearest_bot(world_pos, bot_peers, skater_positions,
					pinger_peer, carrier_peer_id)
	return -1


# The translation key for a ping type's bubble text; "" for an out-of-range
# type. Callers tr() the result at the display seam.
static func message_key_for(type: int) -> String:
	if type < 0 or type >= _MESSAGE_KEYS.size():
		return ""
	return _MESSAGE_KEYS[type]


static func directive_duration_s(type: int) -> float:
	if type < 0 or type >= _DIRECTIVE_DURATION_S.size():
		return 0.0
	return _DIRECTIVE_DURATION_S[type]


static func is_valid_type(type: int) -> bool:
	return type >= 0 and type < _MESSAGE_KEYS.size()


static func _make(type: int, target_peer: int, world_pos: Vector3) -> Resolution:
	var r := Resolution.new()
	r.type = type
	r.target_peer = target_peer
	r.world_pos = world_pos
	return r


static func _nearest_bot(to_pos: Vector3, bot_peers: Array,
		skater_positions: Dictionary, pinger_peer: int,
		carrier_peer_id: int) -> int:
	var best_pid: int = -1
	var best_d2: float = INF
	for pid: int in bot_peers:
		if pid == pinger_peer or pid == carrier_peer_id:
			continue
		if not skater_positions.has(pid):
			continue
		var p: Vector3 = skater_positions[pid]
		var dx: float = p.x - to_pos.x
		var dz: float = p.z - to_pos.z
		var d2: float = dx * dx + dz * dz
		if d2 < best_d2 or (d2 == best_d2 and (best_pid == -1 or pid < best_pid)):
			best_d2 = d2
			best_pid = pid
	return best_pid
