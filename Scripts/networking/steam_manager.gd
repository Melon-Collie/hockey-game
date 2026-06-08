extends Node
## Steam integration: init + lobby lifecycle. Owns every GodotSteam (`Steam`
## singleton) call so the rest of the codebase stays transport-agnostic.
##
## This is the ONLY file that touches the GodotSteam API directly. If your
## installed GodotSteam build exposes slightly different signatures (init form,
## signal arg order), this is the one place to reconcile.
##
## Autoload order: registered after NetworkSimManager, before GameManager.
## NetworkManager drives host/client setup by calling create_lobby/join_lobby
## and waiting on the signals re-emitted here; the menu talks only to
## NetworkManager, never to SteamManager directly (preserves layer discipline).
##
## Graceful degradation: if the Steam client isn't running, the GDExtension is
## absent (headless CI), or init fails, `is_available` stays false, _process
## pumps nothing, and every lobby call is a no-op. Offline / free-play /
## tutorial never reference this autoload, so they are wholly unaffected.

# Dev App ID 480 = Valve's SpaceWar example. Swap to the real Steamworks App ID
# here (one line) once the Steam backend exists.
const APP_ID: int = 480

# How long to wait for an async Steam lobby create/join callback before giving
# up and surfacing a failure (so the menu spinner can't hang forever if
# run_callbacks never delivers the result).
const LOBBY_OP_TIMEOUT: float = 12.0

const LOBBY_DISTANCE_WORLDWIDE: int = 3  # ELobbyDistanceFilter: widest search

# ── Availability ────────────────────────────────────────────────────────────
var is_available: bool = false   # true iff Steam initialised successfully
var steam_id: int = 0            # local user's SteamID64 (0 when unavailable)
var current_lobby_id: int = 0    # 0 when not in a lobby

# ── Outbound signals (NetworkManager / menu listen) ─────────────────────────
signal steam_unavailable
signal lobby_created(lobby_id: int)
signal lobby_create_failed(reason: String)
signal lobby_joined(lobby_id: int, owner_steam_id: int)
signal lobby_join_failed(reason: String)
signal lobby_list_received(lobbies: Array)        # Array[Dictionary]
signal lobby_invite_accepted(lobby_id: int)       # overlay "Join Game" / launch invite

# 0 = idle, 1 = creating, 2 = joining. Drives the op-timeout in _process.
var _pending_op: int = 0
var _op_timer: float = 0.0


func _ready() -> void:
	_try_init()


func _try_init() -> void:
	# A build exported without the GDExtension (e.g. headless CI) has no Steam
	# singleton at all — bail before referencing it.
	if not Engine.has_singleton("Steam"):
		is_available = false
		steam_unavailable.emit.call_deferred()
		return

	# Set the App ID via environment before init. This form is stable across
	# GodotSteam versions (avoids steamInitEx's varying parameter order) and
	# also covers the case where steam_appid.txt isn't found next to the binary.
	OS.set_environment("SteamAppId", str(APP_ID))
	OS.set_environment("SteamGameId", str(APP_ID))

	var result: Dictionary = Steam.steamInitEx()
	# status 0 == STEAM_API_INIT_RESULT_OK across builds.
	if int(result.get("status", -1)) != 0:
		push_warning("Steam init failed: %s" % str(result.get("verbal", "unknown")))
		is_available = false
		steam_unavailable.emit.call_deferred()
		return

	is_available = true
	steam_id = Steam.getSteamID()
	_connect_steam_signals()
	_check_launch_invite()


func _connect_steam_signals() -> void:
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.join_requested.connect(_on_join_requested)


# Cold-launch via a friend invite passes `+connect_lobby <id>` on the command
# line; honour it once Steam is up.
func _check_launch_invite() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	var idx: int = args.find("+connect_lobby")
	if idx != -1 and idx + 1 < args.size():
		var lobby_id: int = int(args[idx + 1])
		if lobby_id != 0:
			lobby_invite_accepted.emit.call_deferred(lobby_id)


func _process(delta: float) -> void:
	if not is_available:
		return
	# REQUIRED: without pumping callbacks, lobby_created/joined/match_list/
	# join_requested never fire and the async flow stalls.
	Steam.run_callbacks()

	if _pending_op != 0:
		_op_timer += delta
		if _op_timer >= LOBBY_OP_TIMEOUT:
			var was_creating: bool = _pending_op == 1
			_clear_op()
			if was_creating:
				lobby_create_failed.emit("Timed out creating Steam lobby.")
			else:
				lobby_join_failed.emit("Timed out joining Steam lobby.")


func _clear_op() -> void:
	_pending_op = 0
	_op_timer = 0.0


# ── Host ────────────────────────────────────────────────────────────────────
func create_lobby(max_members: int, public: bool = true) -> void:
	if not is_available:
		lobby_create_failed.emit("Steam is not available.")
		return
	_pending_op = 1
	_op_timer = 0.0
	var lobby_type: int = Steam.LOBBY_TYPE_PUBLIC if public else Steam.LOBBY_TYPE_FRIENDS_ONLY
	Steam.createLobby(lobby_type, max_members)


func _on_lobby_created(connect_result: int, lobby_id: int) -> void:
	if _pending_op != 1:
		return
	_clear_op()
	if connect_result != 1:  # 1 == k_EResultOK
		lobby_create_failed.emit("Steam refused to create the lobby (code %d)." % connect_result)
		return
	current_lobby_id = lobby_id
	# Advertise the host name so the public browser has something to show.
	Steam.setLobbyData(lobby_id, "name", "%s's game" % Steam.getPersonaName())
	Steam.setLobbyData(lobby_id, "game", "mitts")
	lobby_created.emit(lobby_id)


# ── Client ──────────────────────────────────────────────────────────────────
func join_lobby(lobby_id: int) -> void:
	if not is_available:
		lobby_join_failed.emit("Steam is not available.")
		return
	_pending_op = 2
	_op_timer = 0.0
	Steam.joinLobby(lobby_id)


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if _pending_op != 2:
		return
	_clear_op()
	if response != 1:  # 1 == k_EChatRoomEnterResponseSuccess
		lobby_join_failed.emit("Could not join the lobby (response %d)." % response)
		return
	current_lobby_id = lobby_id
	var owner: int = Steam.getLobbyOwner(lobby_id)
	lobby_joined.emit(lobby_id, owner)


# ── Public lobby browser ────────────────────────────────────────────────────
func request_lobby_list() -> void:
	if not is_available:
		lobby_list_received.emit([])
		return
	Steam.addRequestLobbyListDistanceFilter(LOBBY_DISTANCE_WORLDWIDE)
	Steam.addRequestLobbyListStringFilter("game", "mitts", Steam.LOBBY_COMPARISON_EQUAL)
	Steam.requestLobbyList()


func _on_lobby_match_list(lobbies: Array) -> void:
	var results: Array = []
	for lobby in lobbies:
		var id: int = int(lobby)
		results.append({
			"lobby_id": id,
			"name": Steam.getLobbyData(id, "name"),
			"members": Steam.getNumLobbyMembers(id),
			"max": Steam.getLobbyMemberLimit(id),
		})
	lobby_list_received.emit(results)


# ── Invites / overlay ───────────────────────────────────────────────────────
func _on_join_requested(lobby_id: int, _friend_id: int) -> void:
	lobby_invite_accepted.emit(lobby_id)


func open_invite_overlay() -> void:
	if is_available and current_lobby_id != 0:
		Steam.activateGameOverlayInviteDialog(current_lobby_id)


# ── Teardown ────────────────────────────────────────────────────────────────
# Idempotent: a no-op when not in a lobby, so offline/free-play teardown paths
# (which funnel through NetworkManager._close) can call it unconditionally.
func leave_lobby() -> void:
	_clear_op()
	if is_available and current_lobby_id != 0:
		Steam.leaveLobby(current_lobby_id)
	current_lobby_id = 0
