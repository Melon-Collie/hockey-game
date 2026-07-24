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

# Mitts' Steamworks App ID. (Dev builds historically used 480 = Valve's
# SpaceWar example before the real App ID was registered.)
const APP_ID: int = 4892600

# How long to wait for an async Steam lobby create/join callback before giving
# up and surfacing a failure (so the menu spinner can't hang forever if
# run_callbacks never delivers the result).
const LOBBY_OP_TIMEOUT: float = 12.0

# ── Availability ────────────────────────────────────────────────────────────
var is_available: bool = false   # true iff Steam initialised successfully
var steam_id: int = 0            # local user's SteamID64 (0 when unavailable)
var persona_name: String = ""    # local user's Steam display name ("" when unavailable)
var current_lobby_id: int = 0    # 0 when not in a lobby
# Visibility of the lobby we own (create_lobby / set_lobby_visibility). Lets
# the lobby screen's selector re-show the right state after a scene swap
# (return-to-lobby) — Steam doesn't echo the type back. Meaningless for
# lobbies we merely joined.
var is_lobby_public: bool = false
var _pending_public: bool = false  # requested type of an in-flight create
# Lobby id from an accepted invite that no UI was alive to handle: cold launch
# via `+connect_lobby` fires during autoload init (Boot title card — no
# SideMenu exists yet), and overlay accepts can land in the Lobby scene. The
# SideMenu consumes this when it builds; emitting alone loses the invite.
var pending_invite_lobby_id: int = 0

# ── Outbound signals (NetworkManager / menu listen) ─────────────────────────
signal steam_unavailable
signal lobby_created(lobby_id: int)
signal lobby_create_failed(reason: String)
signal lobby_joined(lobby_id: int, owner_steam_id: int)
signal lobby_join_failed(reason: String)
signal lobby_list_received(lobbies: Array)        # Array[Dictionary]
signal lobby_invite_accepted(lobby_id: int)       # overlay "Join Game" / launch invite
# Steam's Dynamic Cloud Sync pulled newer cloud files into the local cache
# mid-session (Steam Deck suspend→resume). PlayerPrefs listens and re-reads.
signal cloud_files_changed

# 0 = idle, 1 = creating, 2 = joining. Drives the op-timeout in _process.
var _pending_op: int = 0
var _op_timer: float = 0.0


func _ready() -> void:
	_try_init()


# Leave the lobby on process quit. Autoloads free in REVERSE registration
# order, so by the time NetworkManager (registered earlier) tears down, this
# singleton is already gone and its guarded leave_lobby call no-ops — the
# quit-path leave has to happen here, while the Steam GDExtension is still
# loaded. An explicit leave tells the other members immediately instead of
# making them wait out Steam's disconnect timeout. Idempotent with the
# session-teardown paths that already funnel through NetworkManager._close().
func _exit_tree() -> void:
	leave_lobby()


func _try_init() -> void:
	# A build exported without the GDExtension (e.g. headless CI) has no Steam
	# singleton at all — bail before referencing it.
	if not Engine.has_singleton("Steam"):
		is_available = false
		steam_unavailable.emit.call_deferred()
		return

	# Dev-only: when running from the editor or a debug export (NOT launched
	# through the Steam client) the SDK has no launch context, so tell it which
	# app we are. In a shipped RELEASE build Steam launches the process and knows
	# the App ID from its own launch context (main app, the Playtest child app, a
	# future demo) — we must NOT set it here, or we'd force 4892600 and break the
	# Playtest for testers who own the child app but not the main app. (Same
	# reason steam_appid.txt is excluded from shipped depots.)
	if OS.is_debug_build():
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
	persona_name = Steam.getPersonaName()
	# Prime the local achievement/stat cache from Steam's servers so the first
	# setAchievement of the session persists. (GodotSteam 4.x dropped the old
	# requestCurrentStats(); requesting our own SteamID is the current-user form.)
	# The result lands asynchronously via run_callbacks; we don't block on it —
	# unlocks only happen at game-over, long after this returns.
	Steam.requestUserStats(steam_id)
	# Ground-truth diagnostic: the App ID Steam actually initialised this process
	# under (independent of the name Steam shows in the UI). For the Playtest
	# build launched via Steam this must be 4893650, not the main app 4892600.
	print("[SteamManager] Steam initialised under AppID %d" % Steam.getAppID())
	_connect_steam_signals()
	_check_launch_invite()


func _connect_steam_signals() -> void:
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.join_requested.connect(_on_join_requested)
	# Dynamic Cloud Sync: fires when Steam syncs newer cloud files into the local
	# cache mid-session (Deck suspend/resume). The callback carries no payload —
	# consumers re-read via the cloud_* API.
	Steam.local_file_changed.connect(_on_local_file_changed)


# Cold-launch via a friend invite passes `+connect_lobby <id>` on the command
# line; honour it once Steam is up. Stash only (no emit) — this runs during
# autoload init, before any listener exists.
func _check_launch_invite() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	var idx: int = args.find("+connect_lobby")
	if idx != -1 and idx + 1 < args.size():
		var lobby_id: int = int(args[idx + 1])
		if lobby_id != 0:
			pending_invite_lobby_id = lobby_id


# One-shot read of a stashed invite; clearing on read keeps a consumed invite
# from re-firing every time the consumer (SideMenu) is rebuilt on scene load.
func consume_pending_invite() -> int:
	var lobby_id: int = pending_invite_lobby_id
	pending_invite_lobby_id = 0
	return lobby_id


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
	_pending_public = public
	var lobby_type: int = Steam.LOBBY_TYPE_PUBLIC if public else Steam.LOBBY_TYPE_FRIENDS_ONLY
	Steam.createLobby(lobby_type, max_members)


# Flip the live lobby between public (listed in the browser) and friends-only.
# A pure metadata change on Steam's side — nobody disconnects, the lobby just
# appears in / vanishes from the public list. Drives the lobby screen's
# visibility selector; going fully offline is NetworkManager.detach_online.
func set_lobby_visibility(public: bool) -> void:
	if not is_available or current_lobby_id == 0:
		return
	var lobby_type: int = Steam.LOBBY_TYPE_PUBLIC if public else Steam.LOBBY_TYPE_FRIENDS_ONLY
	Steam.setLobbyType(current_lobby_id, lobby_type as Steam.LobbyType)
	is_lobby_public = public


# Publish Rich Presence so this member shows as *joinable* in friends' Steam
# lists — the green "Join Game" entry and the launch/overlay join path both key
# off the "connect" string, NOT off lobby visibility. A friends-only lobby is
# never listed in the public browser (that's the point), so without this a
# friend has no way in even though the lobby type permits them: nothing to
# click in the friends list, and cold launch has no `+connect_lobby` to pass.
# Steam hands the "connect" value back verbatim — as command-line args when it
# has to launch the game (parsed by _check_launch_invite), or via the
# join_requested callback when the game is already running (_on_join_requested).
# Set for members we join too, so a joiner's own friends can chain in.
func _advertise_joinable(lobby_id: int) -> void:
	Steam.setRichPresence("connect", "+connect_lobby %d" % lobby_id)


# The Steam BuildID of the running install — a per-build identity that changes
# on every upload, so it gates simulation parity (physics/tuning) the way
# PROTOCOL_VERSION gates wire format. Returns 0 for dev / non-Steam builds, in
# which case callers skip the build gate (dev manages its own compatibility).
func get_app_build_id() -> int:
	if not is_available:
		return 0
	return Steam.getAppBuildId()


func _on_lobby_created(connect_result: int, lobby_id: int) -> void:
	if _pending_op != 1:
		return
	_clear_op()
	if connect_result != 1:  # 1 == k_EResultOK
		lobby_create_failed.emit("Steam refused to create the lobby (code %d)." % connect_result)
		return
	current_lobby_id = lobby_id
	is_lobby_public = _pending_public
	_advertise_joinable(lobby_id)
	# Advertise the host name so the public browser has something to show.
	Steam.setLobbyData(lobby_id, "name", "%s's game" % Steam.getPersonaName())
	Steam.setLobbyData(lobby_id, "game", "mitts")
	# Stamped so the browser only lists compatible games; the request_join
	# handshake stays the authoritative gate. "protocol" guards the wire format;
	# "build" guards simulation parity (same Steam build = same physics/tuning),
	# so a tuning-only change that keeps the wire format still segregates.
	Steam.setLobbyData(lobby_id, "protocol", str(BuildInfo.PROTOCOL_VERSION))
	Steam.setLobbyData(lobby_id, "build", str(get_app_build_id()))
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
		# Late callback after a cancelled join (the host's own create echo also
		# lands here, but _on_lobby_created already recorded that lobby id). If
		# Steam actually entered a lobby nobody wants anymore, leave it —
		# otherwise we linger as a ghost member occupying a slot.
		if response == 1 and lobby_id != current_lobby_id:
			Steam.leaveLobby(lobby_id)
		return
	_clear_op()
	if response != 1:  # 1 == k_EChatRoomEnterResponseSuccess
		lobby_join_failed.emit("Could not join the lobby (response %d)." % response)
		return
	current_lobby_id = lobby_id
	_advertise_joinable(lobby_id)
	var lobby_owner: int = Steam.getLobbyOwner(lobby_id)
	lobby_joined.emit(lobby_id, lobby_owner)


# ── Public lobby browser ────────────────────────────────────────────────────
func request_lobby_list() -> void:
	if not is_available:
		lobby_list_received.emit([])
		return
	Steam.addRequestLobbyListDistanceFilter(
			Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE as Steam.LobbyDistanceFilter)
	Steam.addRequestLobbyListStringFilter("game", "mitts", Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter("protocol", str(BuildInfo.PROTOCOL_VERSION),
			Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter("build", str(get_app_build_id()),
			Steam.LOBBY_COMPARISON_EQUAL)
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
	# Stash as well as emit: if no SideMenu is alive to hear the signal (Lobby
	# scene, mid-transition), the next one to build consumes the stash. The
	# live handler consumes it too, so it never double-fires.
	pending_invite_lobby_id = lobby_id
	lobby_invite_accepted.emit(lobby_id)


func open_invite_overlay() -> void:
	if is_available and current_lobby_id != 0:
		Steam.activateGameOverlayInviteDialog(current_lobby_id)


# SteamID64s of every member currently in our lobby (including the local user).
# Empty when Steam is unavailable or we're not in a lobby — so offline / free
# play / headless CI simply report no roster. Used by the roster achievements
# ("play a game with X"), which every machine can evaluate locally since the
# lobby membership is visible to all members.
func lobby_member_steam_ids() -> Array[int]:
	var ids: Array[int] = []
	if not is_available or current_lobby_id == 0:
		return ids
	var count: int = Steam.getNumLobbyMembers(current_lobby_id)
	for i: int in count:
		ids.append(Steam.getLobbyMemberByIndex(current_lobby_id, i))
	return ids


# ── Steam Cloud (Remote Storage) ─────────────────────────────────────────────
# Mitts mirrors one file to Steam Cloud — the player's preferences — so settings
# follow the player across machines. All ISteamRemoteStorage access funnels
# through here to keep the GodotSteam dependency confined to this file.
#
# Cloud is the cross-machine backup that retired the old per-install uuid sidecar
# in PlayerPrefs. PlayerPrefs owns the reconcile policy (read at boot, push on
# save); these are the thin transport wrappers.

# Cloud writes silently no-op unless Cloud is enabled BOTH for the app (Steamworks
# backend config) and the user's account (Steam → Settings → Cloud), so gate on
# both. Without this guard a fileWrite would appear to succeed yet never sync.
func is_cloud_available() -> bool:
	return is_available and Steam.isCloudEnabledForApp() and Steam.isCloudEnabledForAccount()


func cloud_file_exists(filename: String) -> bool:
	return is_cloud_available() and Steam.fileExists(filename)


# Unix-seconds timestamp of the cloud file (0 when Cloud is off / absent). Used
# by PlayerPrefs to break a local-vs-cloud conflict in favour of the newer write.
func cloud_file_timestamp(filename: String) -> int:
	if not cloud_file_exists(filename):
		return 0
	return Steam.getFileTimestamp(filename)


# Returns the cloud file's bytes, or an empty array when Cloud is off / the file
# is absent / the read fails. Callers treat empty as "no cloud copy."
func cloud_read(filename: String) -> PackedByteArray:
	if not cloud_file_exists(filename):
		return PackedByteArray()
	var size: int = Steam.getFileSize(filename)
	if size <= 0:
		return PackedByteArray()
	var result: Dictionary = Steam.fileRead(filename, size)
	if not bool(result.get("ret", false)):
		return PackedByteArray()
	var buf: Variant = result.get("buf", PackedByteArray())
	return buf if buf is PackedByteArray else PackedByteArray()


# Writes bytes to Cloud under `filename`. Returns false (no-op) when Cloud is
# unavailable. Steam syncs the bytes to the backend opportunistically; there is
# nothing to flush here. The write is bracketed in a file-write batch so Steam's
# Dynamic Cloud Sync can never upload a half-written file if the system suspends
# mid-write (Steam Deck) — required by the "Cloud sync on suspend/resume" feature.
func cloud_write(filename: String, data: PackedByteArray) -> bool:
	if not is_cloud_available():
		return false
	Steam.beginFileWriteBatch()
	var ok: bool = Steam.fileWrite(filename, data, data.size())
	Steam.endFileWriteBatch()
	return ok


# Re-emit Steam's local-file-changed callback as a typed signal so PlayerPrefs
# can adopt the freshly synced-down cloud copy mid-session.
func _on_local_file_changed() -> void:
	cloud_files_changed.emit()


# ── Achievements / Stats (User Stats) ────────────────────────────────────────
# The thin Steam-side surface for achievements. Conditions live in the domain
# (Achievements / AchievementRules); AchievementService decides what to unlock
# and calls in here. Every call is a no-op when Steam is unavailable, so the
# whole feature is inert in headless CI and non-Steam builds.
#
# Each achievement's `api_name` MUST exist + be published in the Steamworks
# partner site, or setAchievement silently does nothing. setAchievement is
# idempotent: re-unlocking an already-earned achievement won't re-toast, so
# callers can report freely without tracking prior state.

# Unlock an achievement by its Steamworks API Name and flush to Steam. storeStats
# is what actually triggers the overlay toast and the server write.
func unlock_achievement(api_name: String) -> void:
	if not is_available or api_name.is_empty():
		return
	if not Steam.setAchievement(api_name):
		push_warning("SteamManager: setAchievement('%s') failed (not defined in Steamworks?)" % api_name)
		return
	Steam.storeStats()


# True if the local user has already earned `api_name`. False when Steam is
# unavailable or the achievement isn't defined. Lets callers skip redundant work.
func is_achievement_unlocked(api_name: String) -> bool:
	if not is_available or api_name.is_empty():
		return false
	var result: Dictionary = Steam.getAchievement(api_name)
	return bool(result.get("achieved", false))


# Dev-only: clears every registered achievement and resets stats so a tester can
# re-earn them. Guarded to debug builds — never reachable in a shipped release.
func reset_all_achievements() -> void:
	if not is_available or not OS.is_debug_build():
		return
	for entry in Achievements.ALL:
		Steam.clearAchievement(String(entry["id"]))
	for entry in SteamStats.ALL:
		Steam.setStatInt(String(entry["id"]), 0)
	Steam.storeStats()


# Steam User Stats (integer). These are per-user career counters stored on
# Steam's servers, synced across the player's machines — the mirror that backs
# the career-threshold achievements without a reachable backend. SteamStatRecorder
# owns the read-modify-write; this is the thin transport. Each `stat_name` must
# be a published INT stat in Steamworks, or get/set silently no-op.
func get_stat_int(stat_name: String) -> int:
	if not is_available or stat_name.is_empty():
		return 0
	return Steam.getStatInt(stat_name)


# Buffers a stat value locally; nothing persists until store_stats() flushes the
# whole batch to Steam's servers.
func set_stat_int(stat_name: String, value: int) -> void:
	if not is_available or stat_name.is_empty():
		return
	Steam.setStatInt(stat_name, value)


# Flushes buffered stat/achievement writes to Steam. One call covers a batch of
# set_stat_int / unlock — call it once after a group of changes.
func store_stats() -> void:
	if not is_available:
		return
	Steam.storeStats()


# ── Teardown ────────────────────────────────────────────────────────────────
# Idempotent: a no-op when not in a lobby, so offline/free-play teardown paths
# (which funnel through NetworkManager._close) can call it unconditionally.
func leave_lobby() -> void:
	_clear_op()
	if is_available and current_lobby_id != 0:
		Steam.leaveLobby(current_lobby_id)
		# Stop advertising as joinable — a stale "connect" string would leave
		# friends a dead "Join Game" entry pointing at a lobby we've left.
		Steam.clearRichPresence()
	current_lobby_id = 0
	is_lobby_public = false
