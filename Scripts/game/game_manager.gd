extends Node

# Orchestrator. Owns the GameStateMachine and wires together six focused
# collaborators, each in its own file:
#
#   PlayerRegistry       — players dict, spawn/despawn, resolvers
#   WorldStateCodec      — RPC-wire serialization for world state + stats
#   ShotOnGoalTracker    — pending-shot state machine + assist crediting
#   HitTracker           — cross-team hit validation + stat crediting
#   PhaseCoordinator     — phase-entry side effects, goal pipeline, replay cinematic
#   SlotSwapCoordinator  — mid-game slot swap request/confirm
#
# The public signals below are re-exposed from collaborators so HUD / Camera /
# Scoreboard / Controllers continue to receive the same events.

# ── Signals ───────────────────────────────────────────────────────────────────
signal goal_scored(scoring_team: Team, scorer_name: String, assist1_name: String, assist2_name: String)
signal score_changed(score_0: int, score_1: int)
signal phase_changed(new_phase: GamePhase.Phase)
# Reliable-channel "faceoff prep begins now" beat: on the host it fires from
# PhaseCoordinator._enter_faceoff_prep; on the client it fires after the
# notify_faceoff_positions RPC lands. HUD listens for the countdown banner so
# it can't race the unreliable phase broadcast and start before the skater
# teleport.
signal faceoff_prep_announced
signal period_synced(new_period: int)
signal clock_updated(time_remaining: float)
signal game_over()
signal game_reset()
signal player_joined(player_name: String, team_color: Color)
signal player_left(player_name: String, team_color: Color)
signal stats_updated
signal shots_on_goal_changed(sog_0: int, sog_1: int)
signal team_colors_ready(home_primary: Color, home_secondary: Color, away_primary: Color, away_secondary: Color)
signal local_player_hit(magnitude: float)
# Local player DELIVERED a check (fires immediately off the predicted
# body_checked_player signal on the deliverer's machine — no host round-trip), so
# the camera can punch on the hit you land, not just the ones you take.
signal local_player_landed_hit(magnitude: float)
# Local player was involved in a hard hit (delivered OR taken), carrying the
# horizontal heading to lurch the camera and a 0..1 intensity. Separate from the
# magnitude-only signals above because the two hit scales differ (impact_force vs
# delivered impulse), so intensity is normalized at each emit site; the camera
# just consumes 0..1. Drives the directional impact kick.
signal local_player_impact(direction: Vector3, intensity: float)
# Host-authoritative body-check impact, re-emitted for cosmetic listeners
# (crowd reaction in ArenaStands) after the burst/sound fire in
# _on_body_check_landed. `force` is the same VFX-scale impact force.
signal body_check_broadcast(force: float)
# Fired (before faceoff_prep_announced) on the opening faceoff of a match —
# game start and rematch, never mid-game stoppages. The opening prep window is
# host-extended by `duration`, so listeners (camera sweep, HUD matchup card,
# crowd buzz) have that long before the normal faceoff countdown begins.
signal pregame_intro_started(duration: float)
# Fired (before faceoff_prep_announced) on a period / stoppage faceoff whose
# prep is extended so players skate in from where play stopped. `delay` is the
# seconds the HUD should hold before the "2 → 1 → DROP" countdown so it lands on
# the real (extended) drop. 0-delay faceoffs (opening intro, post-goal) don't
# fire this. Host and client both fire it, deriving `delay` locally.
signal faceoff_skate_in_started(delay: float)
# Fired on every peer when END_OF_PERIOD begins — the between-period break.
# Skaters skate off to their bench doors over the window (PhaseCoordinator.
# on_period_break_entered) while the camera rises to the wide intro framing.
# `duration` is the break length (INTERMISSION_DURATION).
signal period_break_started(duration: float)
# Fired (before faceoff_prep_announced) on a period-start faceoff — the prep
# right after a period break. Same treatment as the pregame intro (bench
# skate-on, camera sweep, host-extended prep) with a "2ND PERIOD" card instead
# of the matchup card. `period` is the period being started (> num_periods → OT).
signal period_intro_started(period: int, duration: float)
signal replay_started
signal replay_stopped
# Between-period intermission presentation. started raises the band (score +
# countdown) on every peer INTERMISSION_SETTLE into the break — with the
# ended period's goals looping behind it when there are any; clip_started
# fires as each goal clip begins so the band can caption it with the goal
# credit; ended fires when a reel is torn down (a reel-less break's band is
# dismissed by the next faceoff prep instead). `reel_seconds` is the
# post-settle window (INTERMISSION_DURATION − INTERMISSION_SETTLE) for the
# band's countdown — derived from shared constants, so clients match the
# host's timer up to clock skew, which is fine for a cosmetic count.
signal intermission_started(period: int, reel_seconds: float)
signal intermission_clip_started(
		scoring_team_id: int, scorer_name: String,
		assist1_name: String, assist2_name: String)
signal intermission_ended
# Live tally of unanimous skip-replay votes (emitted on every accepted vote and
# at replay start with current=0). Shared by the goal cinematic and the
# intermission reel — only one can be active at a time. HUD listens to keep
# the "[SPACE] TO SKIP (X/Y)" prompt current.
signal skip_replay_vote_updated(current: int, total: int)
# Emitted on the local peer when a spectator-slot assignment lands. HUD / camera /
# input subsystems listen so they can flip spectator chrome on/off without
# polling. Only ever fires once per session right now (lobby → game transition);
# mid-game player ↔ spectator swap is deferred.
signal local_spectator_state_changed(is_spectator: bool)
# Emitted on every peer the moment an out-of-play puck is confirmed (after the
# grace window). HUD listens to flash the "PUCK OUT OF PLAY" toast; the
# FACEOFF_PREP phase change drives the countdown banner separately.
signal puck_out_of_play()
# Emitted on every peer when an NHL-rule stoppage fires. Same role as
# puck_out_of_play but lets HUD differentiate the toast text. Hosts emit
# inside _consume_pending_faceoff; clients emit from the RPC handler.
signal icing_called()
signal goalie_freeze_called()
signal offside_called()

# ── Domain state ──────────────────────────────────────────────────────────────
var _state_machine: GameStateMachine = null
var _last_emitted_clock_secs: int = -1
# True once any faceoff prep has been announced this match. The first prep
# after world setup / a reset is the OPENING faceoff — the only one that gets
# the pre-game intro. Tracked here (not in the domain SM) because clients
# never tick the SM but still need to fire their local intro cosmetics.
var _seen_first_prep: bool = false
var _last_ghost_state: Dictionary = {}  # peer_id -> bool, host only
# Reused peer_id -> position scratch for the per-tick ghost-state and icing
# checks (host only). The domain calls read it synchronously and never retain
# it; each call site clears + refills before use.
var _positions_scratch: Dictionary = {}
var _input_blocked: bool = false
var _puck_oob_timer: float = 0.0
var _puck_net_stuck_timer: float = 0.0
# Swept goal detection (host): the puck's center last physics tick, so the goals
# can test the segment prev -> curr for a full goal-line crossing. Invalid until
# the first loose-puck tick of a live period (see _check_goal_crossing).
var _prev_puck_pos: Vector3 = Vector3.ZERO
var _has_prev_puck_pos: bool = false
# Carry state of the puck last goal-crossing tick. A loose<->carried transition
# moves the puck discontinuously (pickup snap to blade / release), so the tracker
# reseeds across it instead of spanning the jump.
var _puck_was_carried: bool = false
# The AI goalies' fixed identities, indexed by team_id — spawned onto the
# jerseys and reused by the Three Stars podium when a goalie stars. Same on
# every machine, so a goalie star candidate needs no wire traffic.
const GOALIE_NAMES: Array[String] = ["WALL", "WARD"]
const GOALIE_NUMBERS: Array[int] = [31, 35]

# Any single-tick puck travel beyond this (metres) is a reset/reposition, not a
# real crossing — the tracker reseeds and skips it. Far above any shot or blade
# speed at 120 Hz (~2 m/tick = 240 m/s); a faceoff/OOB reset jumps much further.
const _GOAL_MAX_TICK_TRAVEL: float = 2.0
# Tighter bound for a puck that was PINNED on both ends of the segment. A
# carried puck teleports to the carry target every tick, and that target can
# jump discontinuously while play is continuous: a forehand/backhand flip
# swings it around the body, and the blade's net clamp hands the contact
# between box faces. Treating such a jump as a swept path let a carrier
# dangling behind the net "score through the mesh" — pin beside the post one
# tick, pin past the net the next, and the straight segment between them
# pierced the goal-line plane inside the mouth (visually, the puck went
# through the back of the net). Real carried motion is bounded by skate +
# blade speed (~13 + 8 m/s -> ~0.18 m/tick); 0.5 gives ~3x headroom while the
# flip artifacts it must reject span the net's width (~1 m and up).
const _GOAL_MAX_CARRIED_TICK_TRAVEL: float = 0.5
# True while the local goal cinematic OR intermission reel is playing. Gates
# the skip_replay action so we don't fire stray vote RPCs outside a skippable
# window.
var _in_replay_locally: bool = false
# Goal credit + period stamped onto the next captured goal clip (see
# _stash_goal_clip_meta / _on_goal_replay_started_capture).
var _pending_clip_meta: Dictionary = {}
# Holds an existing-players sync that arrived before _spawn_world ran. The
# host sends sync_existing_players just before assign_player_slot; if the
# RPCs land after the scene has changed but before on_slot_assigned has
# created _state_machine, the sync would otherwise be dropped and the host
# (only delivered through this path) would never spawn on the client.
var _pending_existing_players: Array = []
# Same defense for spawn_remote_skater RPCs: at game start the host's spawn
# burst (bots + peers assigned after us in the lobby fan-out) can land while
# _state_machine is still null (scene loading). Each entry is the full
# argument list of spawn_remote_skater; flushed in on_slot_assigned. Without
# this the skaters were silently dropped and never appeared on this client —
# there is no later re-sync.
var _pending_remote_spawns: Array[Array] = []
# Wall-clock timestamp of the previous host physics tick. Used to record the
# inter-tick gap into NetworkTelemetry so F3 can surface host stalls.
var _last_phys_tick_us: int = 0

# ── Infrastructure ────────────────────────────────────────────────────────────
var _spawner: ActorSpawner = null
var teams: Array[Team] = []
var puck: Puck = null
# One TeamBrain per team, host-only. Allocated in _spawn_world. Bots read
# their role from here via SkaterAgent. Indexed by team_id (0=home, 1=away).
# AI consumes WorldSnapshots via get_state_at() rather than a separate
# perception buffer — the lag-comp ring already captures the same data.
var team_brains: Array[TeamBrain] = []
# Shared "current frame" world snapshot, refreshed once per host physics
# frame after StateBufferManager.capture. AIControllers and TeamBrains
# read from here instead of each fetching their own — saves redundant
# interpolation work and per-tick allocations.
var current_snapshot: WorldSnapshot = null
# Global per-skater acceleration read for the bots. Each skater's smoothed
# accel is identical for every bot, so it is computed once per host frame here
# and shared onto current_snapshot.accel_by_peer instead of all 6 bots
# recomputing the same velocity diff every tick (see AIAccelerationTracker).
var _accel_tracker: AIAccelerationTracker = AIAccelerationTracker.new()
# Drives all bot dispatch off the AI worker thread (AI threading). See AICoordinator.
var _ai_coordinator := AICoordinator.new()
# Bot difficulty knobs for this match, resolved from PlayerPrefs at match start
# (on_host_started). Drives the carrier reaction delay applied to current_
# snapshot below, and is read by PlayerRegistry.spawn_bot to wire each agent's
# execution knobs. Defaults to Hard so any path that spawns bots before
# resolution behaves close to the old perfect bot.
var bot_skill_profile: BotSkillProfile = BotSkillProfile.hard()
# Goalie difficulty for this match. Host-spawned AI (the host runs both nets),
# so like bot difficulty it's a host-local PlayerPrefs preference re-read each
# match. Defaults to Hard so any pre-resolution spawn matches today's goalie.
var goalie_skill_profile: GoalieSkillProfile = GoalieSkillProfile.hard()
# The TEAM's lagged possession belief, written onto the AI snapshot each frame
# (see _apply_bot_carrier_reaction_delay). Drives team SHAPE only — individual
# puck reactivity runs on the agent's own clock against the REAL carrier
# (SkaterAgentStateMachine._loose_elapsed_s), so a slow possession belief can no
# longer stall bots off a live puck. Rules + rationale on CarrierBelief.
var _carrier_belief := CarrierBelief.new()
# Private puck-state copy for the AI snapshot. The interpolated snapshot's
# puck_state is frequently the live ring-buffer object (see
# _apply_bot_carrier_reaction_delay), so the debounced carrier is written into
# this reused scratch instead — never the buffer. Filled once per tick and
# consumed synchronously by brains + agents within the same tick.
var _ai_puck_scratch: PuckNetworkState = PuckNetworkState.new()
var goals: Array[HockeyGoal] = []
var goalies: Array[Goalie] = []
var goalie_controllers: Array[GoalieController] = []
# Single stationary goalie spawned on demand for the Shooting tutorial's goalie
# drills (see spawn_tutorial_goalie). Kept out of the `goalies` arrays so the
# rest of the rink wiring (team brains, goalie data cache) ignores it.
var _tutorial_goalie: Goalie = null
var _tutorial_goalie_controller: GoalieController = null
# Single REACTIVE goalie for the penalty-shot drill — same single-net setup as
# the tutorial goalie, but ticking AI (is_server, process enabled) so it plays
# the breakaway. Also kept out of the `goalies` arrays.
var _penalty_goalie: Goalie = null
var _penalty_goalie_controller: GoalieController = null
var puck_controller: PuckController = null

# Cached snapshot of goalie pose for skater IK clamping. Refreshed once per
# physics tick from `goalies` / `goalie_controllers`. Without the cache,
# `get_goalie_data()` allocates a fresh `Array[Dictionary]` of two dict
# literals on every call — `SkaterIKCoordinator.clamp_blade_from_goalies`
# calls it on every skater per tick (~12 calls every physics tick).
var _cached_goalie_data: Array[Dictionary] = []

# Tutorial mode gates offsides detection on this flag. Defaults to false so
# every step except STEP_OFFSIDES has it off; TutorialManager flips it true
# only when entering the offsides step. See _apply_ghost_state.
var _tutorial_offsides_active: bool = false

# ── Subsystems ────────────────────────────────────────────────────────────────
var _registry: PlayerRegistry = null
var _codec: WorldStateCodec = null
var _shot_tracker: ShotOnGoalTracker = null
var _hit_tracker: HitTracker = null
var _turnover_tracker: TurnoverTracker = null
var _possession_tracker: PossessionTracker = null
var _advanced_stats_tracker: AdvancedStatsTracker = null
# A CLIENT's copy of the game's shot log, pushed by the host at game-over
# (analytics B1). The host reads its own live buffer off _advanced_stats_tracker
# instead — get_shot_events() picks the right one. Cleared per match.
var _client_shot_events: Array[ShotEvent] = []
var _pickup_claim: PickupClaimResolver = null
var _poke_claim: PokeClaimResolver = null
var _stick_lift_claim: StickLiftClaimResolver = null
var _hit_claim: HitClaimResolver = null
var _phase_coord: PhaseCoordinator = null
var _swap_coord: SlotSwapCoordinator = null
var _telemetry: NetworkTelemetry = null
# Last phase pushed to telemetry.current_phase — dirty-checks the per-frame push so
# the GamePhase.Phase.keys() name lookup only runs on an actual transition.
var _last_telemetry_phase_id: int = -1
var _debug_overlay: NetworkDebugOverlay = null
var _state_buffer_manager: StateBufferManager = null
# Per-team last-elected loose-puck chaser, fed back into
# AILoosePuckChase.elect each frame for incumbent hysteresis.
var _prev_chase_by_team: Dictionary[int, int] = {}
var _recorder: ReplayRecorder = null
var _goal_replay_driver: GoalReplayDriver = null
# Every goal's trimmed clip, kept for the whole match so the post-game screen
# can loop all of them (the recorder ring only holds the last few seconds).
var _goal_replay_store: GoalReplayStore = null
var _post_game_replay_driver: PostGameReplayDriver = null
# One-shot timer that starts the post-game highlight loop after the final-horn
# beat plays on the ice, roughly when the HUD reveals the final-score card.
var _post_game_replay_timer: SceneTreeTimer = null
# Intermission reel: the same playlist engine configured once-through +
# shared replay mode (see PostGameReplayDriver class doc). Host-started
# INTERMISSION_SETTLE after the period horn; clients start theirs off the
# mirrored replay-mode edge.
var _intermission_replay_driver: PostGameReplayDriver = null
var _intermission_timer: SceneTreeTimer = null
# Host-only: ends the fixed intermission window (stops the looping reel,
# which advances the period). Cleared alongside _intermission_timer.
var _intermission_end_timer: SceneTreeTimer = null
var _career_reporter: CareerStatsReporter = null
var _net_session_reporter: NetworkSessionReporter = null
# Double-post guard for the network-quality row: the game-over path reports
# "completed" and the scene-exit path reports abnormal ends ("quit",
# "host_lost", …) — whichever fires first wins. Re-armed at world spawn and on
# rematch reset (each game posts its own row).
var _net_session_reported: bool = false
var _achievements: AchievementService = null
var _stat_recorder: SteamStatRecorder = null
# Streams broadcast frames to user://replays/<game_id>.mreplay on a worker
# thread. Lives on every peer (host + client + spectator) for any session
# with a non-empty _game_id and PlayerPrefs.replay_recording_enabled. Opens
# once the registry has stabilized (post-_push_lobby_assignments_to_clients
# on host, post-sync_existing_players on clients) and closes on scene exit.
var _replay_file_writer: ReplayFileWriter = null
# host_ts of the last world-state frame written to the .mreplay file. Drives the
# REPLAY_FILE_RATE throttle in _record_world_state_to_file. -INF so the first
# frame of each recording always writes; reset on writer open.
var _last_file_frame_ts: float = -INF
# Tracks the phase of the most recent .mreplay frame so movement-locked
# phases (GOAL_SCORED, FACEOFF_PREP, END_OF_PERIOD, GAME_OVER) record their
# first transition frame and skip the duplicate-static frames that follow.
# The transition frame at GOAL_SCORED entry captures puck-in-net, which the
# previous broadcast (still PLAYING) usually missed. -1 = nothing recorded
# yet this game; reset on scene exit + rematch rollover.
var _last_recorded_phase: int = -1

# ── Spectator state ───────────────────────────────────────────────────────────
# Host-side: peer_ids of connected spectators. Used to gate `_registry.spawn`
# and the `send_spawn_remote_skater` broadcast on join.  Locally cleared on
# scene exit. Spectators are NOT in `_registry`, so any path that iterates
# `_registry.all()` already excludes them naturally.
var _spectator_peers: Dictionary[int, bool] = {}
# ── Reconnect / slot reservation (host-side) ──────────────────────────────────
# steam_id -> { team_id, team_slot, stats: PlayerStats, attributes, token: int }.
# Populated when a player drops mid-match (on_player_disconnected); consumed when
# a peer with the same Steam ID rejoins (on_player_connected → restore). The
# domain GameStateMachine.reserved_slots mirrors the (team_id, team_slot) so the
# slot isn't reassigned and the team plays short-handed in the meantime. Each
# reservation carries a monotonic `token`; the expiry SceneTreeTimer captures it
# so a re-drop (which mints a fresh token) isn't expired by a stale timer.
# Cleared wholesale on scene exit. Keyed by Steam ID because a reconnecting peer
# gets a brand-new peer_id from the transport.
var _reserved_slots: Dictionary[int, Dictionary] = {}
var _reservation_token: int = 0
const RECONNECT_RESERVATION_S: float = 60.0
# Client-side: true when the local peer was assigned a spectator slot. Drives
# the SpectatorCamera mount and HUD chrome hiding. Also gates the local-skater
# spawn path in on_slot_assigned.
var _is_local_spectator: bool = false
var _camera_director: CameraDirector = null

# ── Game identity ─────────────────────────────────────────────────────────────
# Minted by the host in LobbyManager._on_start_pressed and broadcast via
# game_start, so EVERY lobby match carries one — including offline Play vs
# Bots, whose games therefore write local replays. Used as the .mreplay
# filename and stored on career_stats rows so a single game can be
# reconstructed across players. **Empty in free play / tutorial / drill
# sessions** (no lobby, nothing minted) — those don't write replays or career
# stats. Downstream consumers must treat empty as "skip recording".
var _game_id: String = ""
# True once this match has (ever) had two or more human players — the bar for
# uploading ranked backend rows (career stats, network-session telemetry).
# With the lobby's visibility toggle, an online-visible session can still be a
# solo-vs-bots game, so is_offline_mode alone no longer implies "unranked".
# Latched, not sampled: a human joining mid-match (spectator taking over a
# bot) makes the game ranked from then on, but players leaving before the
# horn don't un-rank it. Reset at world spawn and recomputed on rematch.
var _ranked_match: bool = false
# Peak human headcount seen this match (see _refresh_ranked_match). Stored on the
# career row so a future filter can pick its own bar instead of inheriting the
# latch's arbitrary 2.
var _peak_humans: int = 0

# Sound wiring is split between persistent (NetworkManager autoload, GameManager
# self-signals — wire once for the lifetime of the process) and per-game (puck /
# puck_controller / _phase_coord — recreated each match in _spawn_world). The
# guard prevents duplicate connections to the persistent set on rematch.
var _persistent_sound_signals_wired: bool = false

# Echo-suppression for the broadcast puck-contact cues (post / goalie / boards /
# net frame). Every client predicts the loose puck through the shared analytic
# solver, and PuckController's predicted_*_contact signals fire the cue LOCALLY
# the instant the predicted flight makes contact (the live cue); the host's
# broadcast of the same contact lands ~RTT later — the same event twice. We
# stamp the local play time here and skip an incoming broadcast that lands
# within the echo window. Keyed on a real local play (not on a mode check), so
# a peer that did NOT predict the contact (fallback interpolation, deep loss,
# spectate edge cases) still hears the broadcast — no silence hole. See
# _cue_is_echo. On the host these stamps are set by the authoritative contact
# handlers but never read (the host receives no cue broadcasts).
var _local_post_cue_at: float = -1000.0
var _local_goalie_cue_at: float = -1000.0
var _local_boards_cue_at: float = -1000.0
var _local_net_cue_at: float = -1000.0


func _ready() -> void:
	randomize()
	# Make Manrope the engine-wide fallback font so every Control that
	# doesn't set its own font picks it up automatically — saves us from
	# touching every popup, dialog, and HUD label by hand. Explicit font
	# overrides (DISPLAY_FONT on the scorebug, player card, etc.) still
	# win since they're per-control theme overrides on top of the fallback.
	ThemeDB.fallback_font = MenuStyle.UI_FONT
	_career_reporter = CareerStatsReporter.new()
	_net_session_reporter = NetworkSessionReporter.new()
	_achievements = AchievementService.new()
	_stat_recorder = SteamStatRecorder.new()
	# End-of-tick capture + broadcast (physics priority 2 — after all actor
	# integration), replacing the old start-of-next-tick capture in
	# _physics_process. Ships each tick's state the tick it was simulated:
	# ~8.3 ms off every client's world view and off the measured input-lead
	# overdue the servo pads. The callback body carries all the session gates,
	# so the hook is safe to run from boot.
	var net_hook := PostPhysicsNetHook.new()
	net_hook.callback = _capture_and_broadcast_post_physics
	add_child(net_hook)
	game_over.connect(_on_game_over)
	_wire_network_signals()


func _wire_network_signals() -> void:
	NetworkManager.set_world_state_provider(get_world_state)
	NetworkManager.host_ready.connect(on_host_started)
	NetworkManager.client_connected.connect(on_connected_to_server)
	NetworkManager.disconnected_from_server.connect(on_scene_exit)
	NetworkManager.peer_joined.connect(on_player_connected)
	NetworkManager.peer_disconnected.connect(on_player_disconnected)
	NetworkManager.world_state_received.connect(_on_world_state_received)
	NetworkManager.slot_assigned.connect(on_slot_assigned)
	NetworkManager.remote_skater_spawn_requested.connect(spawn_remote_skater)
	NetworkManager.existing_players_synced.connect(sync_existing_players)
	NetworkManager.local_puck_pickup_confirmed.connect(on_local_player_picked_up_puck)
	NetworkManager.local_puck_stolen.connect(on_local_player_puck_stolen)
	NetworkManager.remote_carrier_changed.connect(_on_remote_carrier_changed)
	NetworkManager.one_timer_release_received.connect(on_remote_one_timer_release)
	NetworkManager.carrier_puck_dropped.connect(on_carrier_puck_dropped)
	NetworkManager.goal_received.connect(_on_goal_received)
	NetworkManager.puck_out_of_play_received.connect(_on_puck_out_of_play_received)
	NetworkManager.icing_called_received.connect(_on_icing_called_received)
	NetworkManager.goalie_freeze_called_received.connect(_on_goalie_freeze_called_received)
	NetworkManager.offside_called_received.connect(_on_offside_called_received)
	NetworkManager.faceoff_positions_received.connect(_on_faceoff_positions_received)
	NetworkManager.game_reset_received.connect(on_game_reset)
	NetworkManager.stats_received.connect(_on_stats_received)
	NetworkManager.shot_events_received.connect(_on_shot_events_received)
	NetworkManager.slot_swap_requested.connect(_on_slot_swap_requested)
	NetworkManager.slot_swap_confirmed.connect(_on_slot_swap_confirmed)
	NetworkManager.return_to_lobby_received.connect(_on_return_to_lobby)
	NetworkManager.local_identity_changed.connect(_on_local_identity_changed)
	NetworkManager.local_attributes_changed.connect(_on_local_attributes_changed)
	NetworkManager.local_tape_changed.connect(_on_local_tape_changed)
	NetworkManager.local_preferred_color_changed.connect(_on_local_preferred_color_changed)
	NetworkManager.pickup_claim_received.connect(_on_pickup_claim_received)
	NetworkManager.pickup_claim_rejected_received.connect(_on_pickup_claim_rejected)
	NetworkManager.poke_claim_received.connect(_on_poke_claim_received)
	NetworkManager.stick_lift_claim_received.connect(_on_stick_lift_claim_received)
	NetworkManager.ghost_state_received.connect(_on_ghost_state_received)
	NetworkManager.hit_claim_received.connect(_on_hit_claim_received)
	NetworkManager.input_batch_received.connect(_on_input_batch_received)
	NetworkManager.spectator_demoted_received.connect(_on_spectator_demoted_received)
	NetworkManager.skip_replay_request_received.connect(_on_remote_skip_replay_request)
	NetworkManager.skip_replay_vote_updated.connect(_on_remote_skip_replay_vote)
	NetworkManager.replay_event_received.connect(_on_replay_event_received)
	NetworkManager.replay_mode_changed.connect(_on_remote_replay_mode_changed)
	replay_started.connect(_on_local_replay_started)
	replay_stopped.connect(_on_local_replay_stopped)


# ── Process ───────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _telemetry != null:
		_telemetry.tick(delta)
		_observe_telemetry()
	# Cosmetic, both roles: skaters "step off the ice" at their bench door
	# during the period-break skate-off (see _update_period_break_hiding).
	_update_period_break_hiding()
	if not NetworkManager.is_host or _state_machine == null:
		return
	if NetworkManager.is_replay_mode():
		return
	if _state_machine.tick(delta):
		_phase_coord.handle_phase_entered()
	if _state_machine.current_phase == GamePhase.Phase.PLAYING:
		var secs: int = int(_state_machine.time_remaining)
		if secs != _last_emitted_clock_secs:
			_last_emitted_clock_secs = secs
			clock_updated.emit(_state_machine.time_remaining)


func _physics_process(delta: float) -> void:
	# Host-frame health telemetry: wall-clock gap between consecutive physics
	# ticks. The MEAN gap → effective tick rate (F3 "Sim rate"): ≈ target means
	# real-time, well below means the host is overloaded and the sim is dilating.
	# The MAX gap → worst stall (F3 "Worst stall"): CPU steal, heavy Jolt frame,
	# GC pause, OS hitch. The raw gap is quantized to render frames, so we report
	# mean+max, not percentiles. Host only — clients don't run the sim loop.
	if NetworkManager.is_host:
		var now_us: int = Time.get_ticks_usec()
		if _last_phys_tick_us != 0:
			NetworkTelemetry.record_host_physics_tick_us(now_us - _last_phys_tick_us)
		_last_phys_tick_us = now_us
	if _state_machine != null and _registry != null:
		var local: PlayerRecord = _registry.get_local()
		if local != null and _state_machine.current_phase == GamePhase.Phase.PLAYING:
			local.stats.toi_seconds += delta
	# Refresh goalie pose cache once per tick — read by skater IK on every
	# blade-from-mouse call. Runs on host AND clients before the host gate
	# below since IK clamping happens everywhere.
	_refresh_goalie_data_cache()
	if not NetworkManager.is_host or puck == null or _state_machine == null:
		return
	# Goal replay temporarily owns actor positions on the host. Skip the live
	# simulation tick so authoritative state buffer captures, ghost checks, etc.
	# don't fight (or pollute the recorder with) replay positions.
	if NetworkManager.is_replay_mode():
		return
	# Capture + broadcast moved to _capture_and_broadcast_post_physics
	# (PostPhysicsNetHook, physics priority 2) so the packet ships THIS tick's
	# post-integration state instead of paying a tick of departure latency.
	#
	# Build the shared "current frame" snapshot once per tick. AI controllers
	# and team brains both read from current_snapshot rather than each calling
	# get_state_delayed independently — at 6 bots + 2 brains that's 8 redundant
	# interpolation passes per frame, each allocating ~10 RefCounted state
	# objects. Reads the ring captured at the END of the previous tick — the
	# identical content the old start-of-this-tick capture produced, so AI
	# data age is unchanged by the capture move.
	if _state_buffer_manager != null:
		# Fresh ground-truth snapshot — bots track every position/velocity in
		# real time (so a receiver aims at the puck's ACTUAL spot, not a stale
		# one). The ONLY thing softened at lower difficulties is the discrete
		# carrier signal, debounced below after enrichment so the delayed
		# carrier reaches both the team brains and the agents.
		current_snapshot = get_state_delayed(0.0)
		if current_snapshot != null:
			_enrich_snapshot_for_ai(current_snapshot)
			# Shared dead-reckoning: advance the global accel estimate once and
			# hand it to every bot by reference (was recomputed per bot per tick).
			_accel_tracker.update(current_snapshot.skater_states, delta)
			current_snapshot.accel_by_peer = _accel_tracker.accel_by_peer
			current_snapshot.heading_omega_by_peer = _accel_tracker.heading_omega_by_peer
			_apply_bot_carrier_reaction_delay(current_snapshot, delta)
	# Centralized AI dispatch. Brains run first (team strategy) so each bot reads
	# this tick's fresh slot assignments, then every bot dispatches against the
	# SAME enriched snapshot the brains saw — unified perception (bots no longer
	# lag the brains by the old priority-split tick; see docs/ai-threading-plan.md).
	# This whole block is the seam Phase 3 lifts onto the AI worker thread; the
	# per-bot dispatch moved here from AIController._physics_process (was prio -1).
	if current_snapshot != null:
		if not team_brains.is_empty():
			for brain: TeamBrain in team_brains:
				brain.tick(delta, current_snapshot)
		if _registry != null:
			# The coordinator freezes each brain's view (build_view) at the point it
			# hands work to the worker — only while the worker is idle, so the view
			# the worker reads is never rebuilt mid-batch.
			_ai_coordinator.dispatch(
					_registry.ai_controllers(), team_brains, current_snapshot, delta)
	_update_host_puck_tracking()
	_check_goal_crossing()
	_check_puck_out_of_bounds(delta)
	_check_puck_stuck_on_net(delta)
	_apply_ghost_state(delta)
	_shot_tracker.tick(delta)
	_hit_tracker.tick(delta)
	_possession_tracker.tick(delta)
	_pickup_claim.tick(delta)


# End-of-tick host capture + broadcast, invoked by PostPhysicsNetHook at
# physics priority 2 — after SkaterController (−1), the bodies' integration +
# analytic contact (0), and the puck's analytic step (+1) — so the ring slot holds this tick's
# fully-integrated state, phase-coherent (position AND velocity post-move),
# labeled with the wall time it was actually produced. The packet leaves one
# tick earlier than the old start-of-next-tick capture, and the snapshot ack
# reaches clients one tick earlier — the input-lead servo's measured overdue
# drops by the same tick, so the lead relaxes to match. Gates mirror the old
# _physics_process block: host only, live session, not during goal replay
# (the recorder must not see replay positions).
func _capture_and_broadcast_post_physics() -> void:
	if not NetworkManager.is_host or puck == null or _state_machine == null:
		return
	if NetworkManager.is_replay_mode():
		return
	if _state_buffer_manager != null and puck_controller != null:
		_state_buffer_manager.capture(_registry, puck_controller, goalie_controllers)
		NetworkManager.try_broadcast()


func _check_puck_out_of_bounds(delta: float) -> void:
	if _state_machine.current_phase != GamePhase.Phase.PLAYING:
		_puck_oob_timer = 0.0
		return
	# Scripted drills (tutorial, penalty shot) deliberately stash the puck far
	# outside the rink (e.g. at (100, 100) between attempts) and reposition it —
	# letting the OOB check fire a faceoff under a drill would derail the script.
	# The drill manager owns puck placement; nothing else can move it OOB anyway.
	if NetworkManager.is_drill_mode():
		_puck_oob_timer = 0.0
		return
	if puck.carrier != null:
		_puck_oob_timer = 0.0
		return
	var pos := puck.global_position
	var pos2d := Vector2(pos.x, pos.z)
	var clamped := GameRules.clamp_to_rink_inner(pos2d)
	var xz_outside: float = pos2d.distance_to(clamped)
	# The puck's collision face IS the inner boundary (kickplate lip), so a loose
	# puck's own radius keeps its center ≥6 cm inside it. Any center sustained
	# past the boundary — at any height — means the puck escaped into or through
	# the wall; the grace absorbs transient penetration spikes. See the tolerance
	# doc in GameRules for why there's no separate height branch anymore.
	if xz_outside > GameRules.PUCK_OOB_XZ_TOLERANCE:
		_puck_oob_timer += delta
		if _puck_oob_timer >= GameRules.PUCK_OOB_GRACE_DURATION:
			_puck_oob_timer = 0.0
			# Escape diagnostics. The analytic drive clamps the puck's center to
			# the rink's rounded rectangle on every sub-step, so a loose puck
			# cannot walk out — reaching here means something PLACED it outside
			# (and by less than Puck.CONTAINMENT_TELEPORT_SKIP, or the drive
			# would have left it parked). Rare event, so the log string build is
			# fine; playtest logs pinpoint where/how it got out.
			print("[puck-oob] whistle: pos=%.2v vel=%.1v height=%.2f xz_outside=%.3f" % [
					pos, puck.linear_velocity, pos.y - puck.ice_height, xz_outside])
			# Use the boundary projection — how far past the boards the puck
			# travelled shouldn't sway dot selection.
			var dot: Vector2 = GameRules.nearest_faceoff_dot(clamped)
			puck_out_of_play.emit()
			NetworkManager.notify_puck_out_of_play_to_all()
			_whistle_and_faceoff(dot)
	else:
		_puck_oob_timer = 0.0


# Host-only: catch a puck that settled motionless on the net frame. It never
# touches the ice, so the on-ice/airborne logic would leave it stuck forever. If
# it's only on the low back/skirt frame (a few cm up) it's realistically
# playable, so drop it to the ice; if it's perched up on the crossbar/crown it's
# genuinely unplayable, so whistle it dead like an out-of-play puck.
func _check_puck_stuck_on_net(delta: float) -> void:
	if _state_machine.current_phase != GamePhase.Phase.PLAYING:
		_puck_net_stuck_timer = 0.0
		return
	if NetworkManager.is_drill_mode() or puck.carrier != null:
		_puck_net_stuck_timer = 0.0
		return
	var pos: Vector3 = puck.global_position
	var settled: bool = puck.linear_velocity.length() < GameRules.NET_STUCK_MAX_SPEED
	if not (puck.is_airborne() and settled and GameRules.is_over_net_footprint(Vector2(pos.x, pos.z))):
		_puck_net_stuck_timer = 0.0
		return
	_puck_net_stuck_timer += delta
	if _puck_net_stuck_timer < GameRules.NET_STUCK_GRACE_DURATION:
		return
	_puck_net_stuck_timer = 0.0
	if pos.y - puck.ice_height <= GameRules.NET_STUCK_PLAYABLE_HEIGHT:
		# Low on the frame — realistically reachable. Drop it to the ice so play
		# continues instead of stopping for something a stick could poke free.
		puck.settle_to_ice()
		return
	# Perched up on the crossbar/crown — unplayable. Whistle dead and face off.
	var dot: Vector2 = GameRules.nearest_faceoff_dot(Vector2(pos.x, pos.z))
	puck_out_of_play.emit()
	NetworkManager.notify_puck_out_of_play_to_all()
	_whistle_and_faceoff(dot)


# Plays the whistle, transitions the state machine to FACEOFF_PREP at the
# given dot, and runs phase-entry side effects (puck reset, player teleport,
# RPC broadcast). Shared by the OOB path and the NHL stoppage paths; the
# caller is responsible for emitting its own pre-whistle signal + RPC so
# clients can play their own whistle/toast.
func _whistle_and_faceoff(dot: Vector2) -> void:
	SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)
	# Flush the stat trackers BEFORE the phase-entry side effects run — the
	# puck drop they trigger must not arm hit grace off a dead-ball release.
	_on_stoppage_flush_stat_trackers(GamePhase.Phase.FACEOFF_PREP)
	_state_machine.begin_faceoff_prep(dot)
	_phase_coord.handle_phase_entered()


# Host-only: a goalie secured (smothered) a loose puck. NHL rules: whistle
# the play dead and face off in the covering goalie's defensive zone (same
# dot geometry as icing — offender's-zone dot picked by puck X). ARCADE / OFF:
# no stoppage — the goalie's own hold-and-release timer plays the puck out.
# Deferred: the signal fires mid-goalie-physics-tick, and the faceoff phase
# entry teleports actors; the same-frame remainder of that tick shouldn't run
# against a half-reset world.
func _on_goalie_covered_puck(covering_team_id: int) -> void:
	if not NetworkManager.is_host:
		return
	if _state_machine == null or _state_machine.rule_set != GameRules.RuleSet.NHL:
		return
	call_deferred("_whistle_goalie_freeze", covering_team_id)


func _whistle_goalie_freeze(covering_team_id: int) -> void:
	# Re-check phase — a goal / period horn in the same frame wins.
	if _state_machine == null or _state_machine.current_phase != GamePhase.Phase.PLAYING:
		return
	goalie_freeze_called.emit()
	NetworkManager.notify_goalie_freeze_called_to_all()
	_whistle_and_faceoff(GameRules.icing_faceoff_dot(covering_team_id, puck.global_position.x))


# Host: any transition out of live play (whistle prep, goal, period horn,
# game over) is a stoppage for stat attribution — resolve a still-pending
# draw via the last-toucher fallback and clear pending hits + release grace
# (nothing carries across dead play). The goal path resolved the draw to the
# scoring team already (more precise than last-toucher when a defender tips
# one in), so this finds nothing pending there. Idempotent with the explicit
# flush in _whistle_and_faceoff.
func _on_stoppage_flush_stat_trackers(phase: GamePhase.Phase) -> void:
	if not NetworkManager.is_host:
		return
	if phase == GamePhase.Phase.PLAYING or phase == GamePhase.Phase.FACEOFF:
		return
	_flush_pending_faceoff_win()
	if _hit_tracker != null:
		_hit_tracker.on_play_stopped()
	if _possession_tracker != null:
		_possession_tracker.reset()


# Host: play stopped before anyone established possession off a faceoff, so
# the NHL fallback applies — the draw goes to the team of the last toucher
# (the scoring team when the stoppage is a goal, via _on_goal_resolve_faceoff).
func _flush_pending_faceoff_win() -> void:
	if _turnover_tracker == null or not _turnover_tracker.has_pending_faceoff():
		return
	var team_id: int = -1
	if _registry != null and _shot_tracker != null:
		team_id = _registry.resolve_team_id_for_peer(_shot_tracker.get_last_toucher())
	if _turnover_tracker.resolve_pending_faceoff(team_id):
		_sync_stats_to_clients()


# Host-only: any skater-skater contact can end an active NHL delayed offside
# (Rule 83.3 — an offside attacker touching, or about to touch, the defending
# puck carrier ends the delay; contact is the deterministic stand-in for the
# linesman's "about to" judgment, applied to any defender, not just the
# carrier). Resolves the victim's peer_id and hands both off to the domain,
# which no-ops unless one side is the currently-flagged offending team.
func _on_skater_contact_for_offside(attacker_peer_id: int, victim: Skater) -> void:
	if _state_machine == null or _registry == null:
		return
	var victim_peer_id: int = _registry.resolve_peer_id(victim)
	if victim_peer_id == -1:
		return
	_state_machine.notify_offside_contact(attacker_peer_id, victim_peer_id)
	_consume_pending_faceoff()


# Host-only: drain a domain-flagged stoppage (icing race confirmed, offside
# touch). Called after every event that can set pending_faceoff_reason —
# loose-puck tick, pickups, deflections.
func _consume_pending_faceoff() -> void:
	if _state_machine == null:
		return
	var reason: int = _state_machine.consume_pending_faceoff()
	if reason == GameStateMachine.FaceoffReason.NONE:
		return
	var dot: Vector2 = _state_machine.pending_faceoff_dot
	match reason:
		GameStateMachine.FaceoffReason.ICING:
			icing_called.emit()
			NetworkManager.notify_icing_called_to_all()
		GameStateMachine.FaceoffReason.OFFSIDE:
			offside_called.emit()
			NetworkManager.notify_offside_called_to_all()
	_whistle_and_faceoff(dot)


func _update_host_puck_tracking() -> void:
	if puck.carrier != null:
		var carrier_team: Team = _registry.resolve_team(puck.carrier)
		if carrier_team != null:
			_state_machine.notify_puck_carried(carrier_team.team_id,
					puck.carrier.global_position.z, puck.carrier.global_position.x)
	elif _state_machine.current_phase == GamePhase.Phase.PLAYING:
		_registry.fill_positions_by_peer_id(_positions_scratch)
		_state_machine.check_icing_for_loose_puck(
				puck.global_position.z, _positions_scratch)
		_consume_pending_faceoff()


# Host-only swept goal detection. Feeds each goal the puck-center segment from
# last tick to this tick; the goal emits `goal_scored` when the whole puck fully
# crosses its line inside the mouth (GoalDetectionRules). Runs BEFORE the OOB /
# stuck-on-net checks so a scored puck flips the phase out of PLAYING first and
# those checks early-return rather than whistling the goal dead.
func _check_goal_crossing() -> void:
	# Non-PLAYING phases never award goals; drills own their own detection. Reset
	# so the next live tick starts a fresh segment rather than spanning the gap.
	if _state_machine.current_phase != GamePhase.Phase.PLAYING \
			or NetworkManager.is_drill_mode():
		_has_prev_puck_pos = false
		return
	# Both loose AND carried pucks are tracked: the puck is pinned to the carry
	# target each tick (Puck._physics_process), so a stick tuck-in — the carrier
	# pushing the puck across the line from the front of the mouth — is a real
	# crossing. The net exclusion clamp (NetClampRules) is what gates whether the
	# blade can get there; here we just watch the puck's path.
	var curr: Vector3 = puck.global_position
	var carried: bool = puck.carrier != null
	# Reseed on a cold tracker or a loose->carried transition: the pickup snaps
	# the puck to the blade discontinuously, and spanning that jump could
	# fabricate a crossing. The carried->loose direction is NOT reseeded — a
	# release repositions the puck by at most the carry offset plus one tick of
	# shot travel, a real path. Reseeding it opened a one-tick blind window
	# that swallowed point-blank crossings: a shot released within a tick's
	# travel of the goal line finished crossing inside the skipped segment,
	# and the puck then sat in the net permanently "already across" — a
	# visible no-count goal. (The teleport guard below still catches resets.)
	var was_carried: bool = _puck_was_carried
	if not _has_prev_puck_pos or (carried and not was_carried):
		_prev_puck_pos = curr
		_has_prev_puck_pos = true
		_puck_was_carried = carried
		return
	_puck_was_carried = carried
	# Teleport guard: an implausible jump is never a real crossing — reseed and
	# skip. Pinned-on-both-ends segments get the tight carried bound (see
	# _GOAL_MAX_CARRIED_TICK_TRAVEL); the transition tick out of carry keeps the
	# loose bound, since a released shot legitimately travels a tick of shot
	# speed plus the release reposition.
	var max_travel: float = _GOAL_MAX_CARRIED_TICK_TRAVEL \
			if carried and was_carried else _GOAL_MAX_TICK_TRAVEL
	if _prev_puck_pos.distance_to(curr) <= max_travel:
		for goal: HockeyGoal in goals:
			goal.check_goal_crossing(_prev_puck_pos, curr, carried)
	_prev_puck_pos = curr


func _apply_ghost_state(delta: float) -> void:
	# Tutorial gates offsides detection to the OFFSIDES step. Other steps
	# (notably one-timer, where the player legitimately stands deep in the
	# O-zone while the puck is stashed off-rink during the prefire delay)
	# would otherwise trip offsides and ghost the player. Force-clear any
	# stale ghost while the gate is closed so the previous step's ghost
	# doesn't bleed into the next one.
	if NetworkManager.is_tutorial_mode and not _tutorial_offsides_active:
		for peer_id: int in _registry.all():
			var record: PlayerRecord = _registry.get_record(peer_id)
			if record != null and record.skater != null and record.skater.is_ghost:
				record.skater.set_ghost(false)
				_last_ghost_state[peer_id] = false
		return
	var positions: Dictionary = _positions_scratch
	positions.clear()
	var carrier_peer_id: int = -1
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		positions[peer_id] = record.skater.global_position
		if puck.carrier != null and record.skater == puck.carrier:
			carrier_peer_id = peer_id
	var ghosts: Dictionary = _state_machine.compute_ghost_state(
			positions, carrier_peer_id, puck.global_position, delta)
	_state_machine.update_delayed_offside(positions, puck.global_position, carrier_peer_id)
	for peer_id in ghosts:
		var r: PlayerRecord = _registry.get_record(peer_id)
		if r != null:
			var new_ghost: bool = ghosts[peer_id]
			r.skater.set_ghost(new_ghost)
			# A skater who ghosts (icing, etc.) while carrying must lose the puck —
			# set_ghost only severs collision/interaction layers, so without this a
			# ghosted carrier would keep the puck pinned to their blade and skate it
			# around untouchable. Drop it loose so play continues.
			if new_ghost and puck.carrier == r.skater:
				puck.drop()
			if new_ghost != _last_ghost_state.get(peer_id, false):
				_last_ghost_state[peer_id] = new_ghost
				NetworkManager.send_ghost_state_to_all(peer_id, new_ghost)


# ── Network Callbacks ─────────────────────────────────────────────────────────
func on_host_started() -> void:
	# Resolve the match's bot difficulty before any bot spawns or the first
	# snapshot publishes. Host + offline + tutorial + free-play all enter here,
	# and GameManager is an autoload that survives between matches, so this must
	# re-read PlayerPrefs each match (not lazy-init-once).
	bot_skill_profile = BotSkillProfile.for_difficulty(PlayerPrefs.bot_difficulty)
	# Free play has its own goalie difficulty (a personal-sandbox knob, default
	# Easy) distinct from the hosted/lobby setting — see PlayerPrefs.
	var goalie_diff: int = PlayerPrefs.freeplay_goalie_difficulty \
			if NetworkManager.is_free_play_mode else PlayerPrefs.goalie_difficulty
	goalie_skill_profile = GoalieSkillProfile.for_difficulty(goalie_diff)
	# Sync the bots' shot model to the tier — otherwise they score their shots
	# against a Hard goalie's reads and pass up looks that beat a weaker one.
	AIActionScoring.set_goalie_profile(goalie_skill_profile)
	_carrier_belief.reset()
	_spawn_world()
	if not NetworkManager.pending_lobby_slots.is_empty():
		var my_slot: Dictionary = NetworkManager.pending_lobby_slots.get(1, {})
		var team_id: int = my_slot.get("team_id", 0)
		var team_slot: int = my_slot.get("team_slot", 0)
		if team_id == GameRules.SPECTATOR_TEAM_ID:
			_spectator_peers[1] = true
			_become_local_spectator()
		else:
			_state_machine.register_remote_assigned_player(1, team_slot, team_id)
			_spawn_local(1, team_slot, teams[team_id])
		_push_lobby_assignments_to_clients()
	else:
		var assignment: Dictionary = _state_machine.register_host(1)
		_spawn_local(1, assignment.team_slot, teams[assignment.team_id])
	_spawn_bots_from_lobby()
	# Registry is fully populated by this point — capture roster + open file.
	_open_replay_file_writer()
	# Open the match with a faceoff countdown rather than dropping straight
	# into PLAYING. Tutorial scripts its own intro; free play is a casual
	# warmup that shouldn't gate the player behind a countdown — both stay
	# in PLAYING from the start. The opening prep is extended so the pre-game
	# intro (camera sweep + matchup card) plays before the countdown.
	if not NetworkManager.is_drill_mode() and not NetworkManager.is_free_play_mode:
		_state_machine.begin_faceoff_prep(GameRules.CENTER_ICE_DOT,
				GameRules.PREGAME_INTRO_DURATION if _pregame_intro_eligible() else 0.0)
		_phase_coord.handle_phase_entered()


func on_connected_to_server() -> void:
	pass


func on_slot_assigned(team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color) -> void:
	# `_state_machine != null` means the world is already spawned → this is a
	# mid-game spectator-to-player promotion, not the initial scene load.
	var is_mid_game_promote: bool = _state_machine != null
	if not is_mid_game_promote:
		_spawn_world()
	# Flush stashed roster/spawn payloads now that the world exists — before
	# the spectator branch, since spectators need the existing skaters spawned
	# too (previously the spectator early-return skipped the flush entirely).
	_flush_pending_player_syncs()
	var peer_id: int = NetworkManager.local_peer_id()
	if team_id == GameRules.SPECTATOR_TEAM_ID:
		_become_local_spectator()
		return
	if _is_local_spectator:
		_teardown_spectator_camera()
	var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_slot, team_id)
	_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
	_registry.spawn(peer_id, team_slot, teams[team_id],
			jersey_color, helmet_color, pants_color,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			NetworkManager.local_is_left_handed, NetworkManager.local_player_name, true,
			NetworkManager.local_jersey_number,
			NetworkManager.get_peer_attributes(peer_id))


# Drains every queue of player data that landed before _spawn_world ran: the
# GameManager sync queue (RPC arrived after scene load, while _state_machine
# was null), NetworkManager.pending_join_players (RPC arrived during scene
# transition but pending_join_slot was empty when game_scene._ready ran), and
# queued spawn_remote_skater bursts (game-start fan-out racing the scene load).
func _flush_pending_player_syncs() -> void:
	if not _pending_existing_players.is_empty():
		var queued: Array = _pending_existing_players
		_pending_existing_players = []
		sync_existing_players(queued)
	if not NetworkManager.pending_join_players.is_empty():
		var deferred: Array = NetworkManager.pending_join_players
		NetworkManager.pending_join_players = []
		sync_existing_players(deferred)
	if not _pending_remote_spawns.is_empty():
		var spawns: Array[Array] = _pending_remote_spawns
		_pending_remote_spawns = []
		for args: Array in spawns:
			callv("spawn_remote_skater", args)


func on_player_connected(peer_id: int) -> void:
	if not NetworkManager.is_host or _state_machine == null:
		return
	var config: Dictionary = {
		"num_periods": _state_machine.num_periods,
		"period_duration": _state_machine.period_duration,
		"ot_enabled": _state_machine.ot_enabled,
		"ot_duration": _state_machine.ot_duration,
		"home_color_slot": NetworkManager.pending_home_color_slot,
		"away_color_slot": NetworkManager.pending_away_color_slot,
		"rule_set": _state_machine.rule_set,
		"team_size": _state_machine.team_size,
	}
	# Reconnect branch: a peer whose Steam ID matches a live reservation reclaims
	# its held team/slot/stats instead of going through fresh auto-balance.
	var steam_id: int = NetworkManager.get_peer_steam_id(peer_id)
	if steam_id != 0 and _reserved_slots.has(steam_id):
		_restore_reserved_player(peer_id, steam_id, config)
		return
	# Spectator branch: declared via pending_lobby_slots[peer_id].team_id == -1.
	# Mid-game joiners always come in as players (existing auto-balance flow);
	# joining-as-spectator is a lobby-only choice for v1.
	var pending_slot: Dictionary = NetworkManager.pending_lobby_slots.get(peer_id, {})
	if pending_slot.get("team_id", 0) == GameRules.SPECTATOR_TEAM_ID:
		_spectator_peers[peer_id] = true
		NetworkManager.send_join_in_progress(peer_id, config)
		NetworkManager.send_slot_assignment(peer_id,
				pending_slot.get("team_slot", 0), GameRules.SPECTATOR_TEAM_ID,
				Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0))
		NetworkManager.send_sync_existing_players(peer_id, _collect_existing_player_data())
		return
	# Roster gate: when both teams are at the latched team size, a mid-game
	# joiner comes in as a spectator instead of overflowing the roster — the
	# state machine would otherwise hand out team_slot == team_size, and the
	# next faceoff indexes FACEOFF_OFFSETS out of bounds in 5v5 (host-side
	# script error). If the spectator gallery is also full, kick with a reason.
	if _state_machine.count_players_on_team(0) >= _state_machine.team_size \
			and _state_machine.count_players_on_team(1) >= _state_machine.team_size:
		if _spectator_peers.size() >= GameRules.MAX_SPECTATORS:
			NetworkManager.kick_peer(peer_id, "Match is full.")
			return
		_spectator_peers[peer_id] = true
		NetworkManager.send_join_in_progress(peer_id, config)
		NetworkManager.send_slot_assignment(peer_id, 0, GameRules.SPECTATOR_TEAM_ID,
				Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0))
		NetworkManager.send_sync_existing_players(peer_id, _collect_existing_player_data())
		return
	var assignment: Dictionary = _state_machine.on_player_connected(peer_id)
	NetworkManager.send_join_in_progress(peer_id, config)
	NetworkManager.send_sync_existing_players(peer_id, _collect_existing_player_data())
	_spawn_player_and_broadcast(peer_id, assignment.team_id, assignment.team_slot,
			NetworkManager.get_peer_handedness(peer_id),
			NetworkManager.get_peer_name(peer_id),
			NetworkManager.get_peer_number(peer_id),
			false)


func on_player_disconnected(peer_id: int) -> void:
	_spectator_peers.erase(peer_id)
	var record: PlayerRecord = _registry.get_record(peer_id) if _registry != null else null
	if record == null:
		return
	# Drop the puck before freeing the controller so puck_released fires while
	# the record is still intact.
	if NetworkManager.is_host and puck != null and puck.carrier == record.skater:
		puck.drop()
	# Hold the slot open for a possible reconnect (host-only, active match, real
	# peer with a Steam ID) before the despawn frees the record.
	_maybe_reserve_slot(peer_id, record)
	_despawn_skater_for_peer(peer_id)


# Host-side: snapshot a dropped player's slot + stats so a reconnecting peer
# (matched by Steam ID) can reclaim them within RECONNECT_RESERVATION_S. No-op
# off-host, for bots, once the match is over, or when the peer has no Steam ID
# (pre-v7 / non-Steam). The team plays short-handed until the window lapses.
func _maybe_reserve_slot(peer_id: int, record: PlayerRecord) -> void:
	if not NetworkManager.is_host or _state_machine == null:
		return
	if record.is_bot:
		return
	if _state_machine.current_phase == GamePhase.Phase.GAME_OVER:
		return
	# A kicked player must not be able to reclaim a slot by rejoining.
	if NetworkManager.was_peer_kicked(peer_id):
		return
	var steam_id: int = NetworkManager.get_peer_steam_id(peer_id)
	if steam_id == 0:
		return
	var team_id: int = record.team.team_id
	var team_slot: int = record.team_slot
	_reservation_token += 1
	var token: int = _reservation_token
	_reserved_slots[steam_id] = {
		"team_id": team_id,
		"team_slot": team_slot,
		"stats": record.stats,
		"attributes": record.attributes,
		"token": token,
	}
	_state_machine.reserve_slot(team_id, team_slot)
	var timer: SceneTreeTimer = get_tree().create_timer(RECONNECT_RESERVATION_S)
	timer.timeout.connect(_expire_reservation.bind(steam_id, token))


# Reconnect window lapsed — free the held slot for real (the next joiner can
# take it). Guarded by token so a re-drop's fresh reservation isn't torn down by
# the previous drop's stale timer, and against a reservation already claimed by a
# successful reconnect.
func _expire_reservation(steam_id: int, token: int) -> void:
	var res: Dictionary = _reserved_slots.get(steam_id, {})
	if res.is_empty() or res.token != token:
		return
	_reserved_slots.erase(steam_id)
	if _state_machine != null:
		_state_machine.release_reserved(res.team_id, res.team_slot)


# Host-side: a peer reconnected into a reserved slot. Restore team/slot, re-seed
# the preserved stats and locked attributes, then spawn + broadcast through the
# normal mid-game path.
func _restore_reserved_player(peer_id: int, steam_id: int, config: Dictionary) -> void:
	var res: Dictionary = _reserved_slots[steam_id]
	_reserved_slots.erase(steam_id)
	var team_id: int = res.team_id
	var team_slot: int = res.team_slot
	# Free the domain hold; _spawn_player_and_broadcast re-registers the peer into
	# the same slot via register_remote_assigned_player.
	_state_machine.release_reserved(team_id, team_slot)
	# Re-lock the attributes the player held at their original join so a drop +
	# prefs edit + rejoin can't swap builds.
	NetworkManager.set_peer_attributes(peer_id, res.attributes)
	NetworkManager.send_join_in_progress(peer_id, config)
	NetworkManager.send_sync_existing_players(peer_id, _collect_existing_player_data())
	_spawn_player_and_broadcast(peer_id, team_id, team_slot,
			NetworkManager.get_peer_handedness(peer_id),
			NetworkManager.get_peer_name(peer_id),
			NetworkManager.get_peer_number(peer_id),
			false)
	# Carry the pre-drop stats forward onto the fresh record; the next world-state
	# broadcast propagates them to all clients.
	var rec: PlayerRecord = _registry.get_record(peer_id)
	if rec != null:
		rec.stats = res.stats


# Tears down host/client-side actor state for a peer whose skater is going
# away (disconnect or mid-game demote). Caller is responsible for any
# host-only side effects that happen *before* the skater is queue_freed
# (puck drop, pending-claim clear) — those need the live record.
func _despawn_skater_for_peer(peer_id: int) -> void:
	if _registry == null or not _registry.has(peer_id):
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if puck != null and record.skater != null:
		puck.remove_skater_cooldown(record.skater)
	if _state_buffer_manager != null:
		_state_buffer_manager.remove_player(peer_id)
	_registry.remove(peer_id)


func sync_existing_players(player_data: Array) -> void:
	if _state_machine == null:
		# RPC arrived between scene-load and on_slot_assigned (which builds
		# _state_machine via _spawn_world). Stash; on_slot_assigned will flush
		# once the world is up. Without this the host record (only delivered
		# through this path) is silently dropped on clients.
		_pending_existing_players = player_data
		return
	for entry: Array in player_data:
		var peer_id: int = entry[0]
		# Idempotency backstop — see spawn_remote_skater. Skip any peer already
		# spawned so a redundant delivery never orphans an existing skater node.
		if _registry.has(peer_id):
			continue
		var team_slot: int = entry[1]
		var team_id: int = entry[2]
		var jersey_color: Color = entry[3]
		var helmet_color: Color = entry[4]
		var pants_color: Color = entry[5]
		var is_left: bool = entry[6] if entry.size() > 6 else true
		var p_name: String = entry[7] if entry.size() > 7 else "Player"
		var p_number: int = entry[8] if entry.size() > 8 else 10
		var attrs: PlayerAttributes
		if entry.size() > 14:
			attrs = PlayerAttributes.new(int(entry[9]), int(entry[10]), int(entry[11]),
					int(entry[12]), int(entry[13]), int(entry[14]))
		else:
			attrs = PlayerAttributes.all_average()
		var tape_code: int = int(entry[15]) if entry.size() > 15 else StickTapeConfig.DEFAULT_CODE
		NetworkManager.set_peer_tape_code(peer_id, tape_code)
		var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_slot, team_id)
		_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
		_registry.spawn(peer_id, team_slot, teams[team_id],
				jersey_color, helmet_color, pants_color,
				colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
				colors.secondary, colors.text, colors.text_outline,
				is_left, p_name, false, p_number, attrs)
	# Client / spectator: registry is now populated with all players the host
	# knew about at the moment we joined. Open the replay file so subsequent
	# world-state broadcasts get recorded. Idempotent — short-circuits if a
	# previous sync already opened it.
	_open_replay_file_writer()


func spawn_remote_skater(peer_id: int, team_slot: int, team_id: int,
		jersey_color: Color, helmet_color: Color, pants_color: Color,
		is_left_handed: bool, player_name: String, jersey_number: int = 10,
		attributes: PlayerAttributes = null) -> void:
	if peer_id == NetworkManager.local_peer_id():
		return
	if _state_machine == null:
		# World not built yet (scene loading) — queue instead of dropping;
		# on_slot_assigned flushes once _spawn_world has run.
		_pending_remote_spawns.append([peer_id, team_slot, team_id,
				jersey_color, helmet_color, pants_color,
				is_left_handed, player_name, jersey_number, attributes])
		return
	# Idempotency guard. The game-start fan-out routes each peer through a single
	# channel (see _push_lobby_assignments_to_clients), so this should not fire
	# there — but it's a cheap backstop against any path that delivers a peer
	# twice (mid-game RPC races, future spawn sites). A second _registry.spawn
	# would overwrite _players[peer_id] and orphan the first skater node in the
	# scene tree as an uncontrolled phantom (host never hits this; clients would).
	if _registry.has(peer_id):
		return
	var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_slot, team_id)
	_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
	_registry.spawn(peer_id, team_slot, teams[team_id],
			jersey_color, helmet_color, pants_color,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			is_left_handed, player_name, false, jersey_number,
			attributes if attributes != null else PlayerAttributes.all_average())


# ── World Spawn ───────────────────────────────────────────────────────────────
func _spawn_world() -> void:
	# Reset host-tick telemetry baseline. Without this, the first tick after a
	# scene change records a huge gap (whatever wall time elapsed during the
	# scene transition) and pollutes the p95/p99 for the first second.
	_last_phys_tick_us = 0
	_seen_first_prep = false  # fresh world → next prep is the opening faceoff
	_ranked_match = false  # re-latches as players spawn (_on_registry_player_added)
	_peak_humans = 0
	_state_machine = GameStateMachine.new()
	if not NetworkManager.pending_game_config.is_empty():
		var cfg: Dictionary = NetworkManager.pending_game_config
		_state_machine.apply_config(cfg.num_periods, cfg.period_duration, cfg.ot_enabled, cfg.ot_duration,
				cfg.get("rule_set", GameRules.DEFAULT_RULE_SET),
				cfg.get("team_size", GameRules.DEFAULT_TEAM_SIZE))
		var cfg_id: String = cfg.get("game_id", "")
		if cfg_id.is_empty() or _is_valid_game_id(cfg_id):
			_game_id = cfg_id
		else:
			push_warning("rejected game_id from config: %s" % cfg_id)
		NetworkManager.pending_game_config = {}
	# Free play / tutorial / drill sessions intentionally leave _game_id
	# empty (their pending config carries none) and downstream consumers
	# (ReplayFileWriter, CareerStatsReporter) treat empty as "don't record".
	# Lobby matches — online AND offline vs bots — always carry one.
	_spawner = ActorSpawner.new()
	_spawner.setup(get_tree().current_scene)
	_create_teams()
	goals = _spawner.find_goals()
	_assign_goals_to_teams()
	_spawn_puck()
	_spawn_goalies()
	_wire_subsystems()
	if NetworkManager.is_host:
		# Fresh session, fresh memo — the danger field's vertices self-heal
		# against goalie motion anyway (per-vertex epsilon validation), this
		# just guarantees no value survives a world respawn.
		AIDangerField.reset()
		team_brains = [
				TeamBrain.new(0, _registry.team_id_by_peer, _registry.caps_by_peer,
						_state_machine.team_size, _registry.position_by_peer,
						_registry.bot_peers),
				TeamBrain.new(1, _registry.team_id_by_peer, _registry.caps_by_peer,
						_state_machine.team_size, _registry.position_by_peer,
						_registry.bot_peers),
		]
		_connect_goal_signals()


func _create_teams() -> void:
	var t0 := Team.new()
	t0.team_id = 0
	t0.color_slot = NetworkManager.pending_home_color_slot
	var t1 := Team.new()
	t1.team_id = 1
	t1.color_slot = NetworkManager.pending_away_color_slot
	teams = [t0, t1]


func _assign_goals_to_teams() -> void:
	for goal: HockeyGoal in goals:
		# facing=+1 → positive-Z end → Team 0 defends it
		# facing=-1 → negative-Z end → Team 1 defends it
		var defending_team_id: int = 0 if goal.facing == 1 else 1
		teams[defending_team_id].defended_goal = goal
		goal.defending_team_id = defending_team_id


func _connect_goal_signals() -> void:
	for team: Team in teams:
		team.defended_goal.goal_scored.connect(func() -> void: _phase_coord.on_goal_scored_into(team))


func _spawn_puck() -> void:
	var result: Dictionary = _spawner.spawn_puck_with_controller(NetworkManager.is_host)
	puck = result.puck
	puck_controller = result.controller
	puck.set_team_resolver(_resolve_skater_team_id)
	puck_controller.set_peer_id_resolver(_resolve_skater_peer_id)
	# team_id_by_skater dict is owned by PlayerRegistry, which doesn't
	# exist yet — wired in `_wire_subsystems` below.
	# Returns the registry's live cached list (rebuilt on roster change) —
	# building a fresh array per call allocated twice per physics tick.
	puck_controller.set_skater_getter(func() -> Array:
		return _registry.skaters() if _registry != null else [])
	# The live goalie list: the host's analytic drive detects goalie contact
	# through it, and the client's Phase-3 loose-puck prediction uses it for the
	# goalie prediction-STOP (dev shadow harnesses also probe through it).
	puck_controller.set_goalie_provider(func() -> Array:
		return goalies)
	puck_controller.puck_picked_up_by.connect(_on_server_puck_picked_up_by)
	puck_controller.puck_released_by_carrier.connect(_on_server_puck_released_by_carrier)
	puck_controller.puck_stripped_from.connect(_on_server_puck_stripped_from)
	puck_controller.puck_poke_checked_by.connect(_on_server_puck_poke_checked_by)
	puck_controller.puck_touched_while_loose.connect(_on_server_puck_touched_while_loose)
	puck_controller.puck_touched_by_goalie.connect(_on_puck_touched_by_goalie)
	if NetworkManager.is_host:
		# Pipes = miss for SOG purposes (NHL). Sound/VFX for the ping are wired
		# separately in _wire_sound_signals.
		puck.puck_touched_post.connect(_on_host_puck_touched_post)


func _spawn_goalies() -> void:
	# Basics tutorial teaches shot mechanics on an empty net with a shot-on-net
	# pass criterion (TutorialManager watches puck position post-release). Skip
	# goalie spawn so the net stays open; the rest of the rink wiring tolerates
	# empty goalies / goalie_controllers arrays.
	if NetworkManager.is_tutorial_mode \
			and not TutorialRegistry.wants_goalies(NetworkManager.tutorial_id):
		return
	# Drills that dress their own net (penalty spawns a lone reactive goalie,
	# accuracy a lone frozen one) skip the pair; a future drill played against
	# live nets can opt back in via the registry.
	if not NetworkManager.drill_id.is_empty() \
			and not DrillRegistry.wants_goalie_pair(NetworkManager.drill_id):
		return
	var result: Dictionary = _spawner.spawn_goalie_pair(puck, NetworkManager.is_host, goalie_skill_profile)
	goalies = [result.top_goalie as Goalie, result.bottom_goalie as Goalie]
	goalie_controllers = [result.top_controller, result.bottom_controller]
	result.top_controller.team_id = 1
	result.bottom_controller.team_id = 0
	teams[1].goalie_controller = result.top_controller
	teams[0].goalie_controller = result.bottom_controller
	for team_id: int in [0, 1]:
		var goalie: Goalie = result.bottom_goalie if team_id == 0 else result.top_goalie
		var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_slot, team_id)
		goalie.apply_uniform(colors)
		goalie.apply_jersey_info(GOALIE_NAMES[team_id], GOALIE_NUMBERS[team_id])


func _wire_subsystems() -> void:
	_registry = PlayerRegistry.new()
	_registry.setup(_spawner, _state_machine, teams,
			get_puck, self, _on_player_spawned)
	# Hand the puck controller a live reference to the registry's
	# Skater -> team_id dict so its poke-check loop can do O(1) lookups
	# instead of going through a Callable that re-scans `_players`.
	if puck_controller != null:
		puck_controller.set_team_id_by_skater(_registry.team_id_by_skater)
	# Goalie controllers need to scan for opposing skaters near the puck for
	# the crease-jam butterfly trigger. Same Callable shape as the puck
	# controller's getter; the registry's live cached list observes roster
	# churn without rebuilding an array per call (this fired 3-5× per goalie
	# per physics tick under crease pressure).
	var goalie_skater_getter: Callable = func() -> Array:
		return _registry.skaters() if _registry != null else []
	for gc: GoalieController in goalie_controllers:
		gc.set_skater_getter(goalie_skater_getter)
		# Cover/freeze resolution is ruleset-split here: NHL whistles a
		# defensive-zone faceoff; ARCADE/OFF let the controller's own
		# hold-and-release play it out (no stoppage — same philosophy as the
		# offside ghost standing in for the offside whistle).
		gc.puck_covered.connect(_on_goalie_covered_puck)
	_registry.player_joined.connect(player_joined.emit)
	_registry.player_left.connect(player_left.emit)
	_registry.player_added.connect(_on_registry_player_added)
	# Replay file roster events — fire whenever the registry changes after
	# the writer is open. The initial roster is captured in the file header
	# so these handlers no-op until _open_replay_file_writer has run, which
	# is only after the registry's initial population (host_started /
	# sync_existing_players) — no double-fire risk.
	_registry.player_added.connect(_on_replay_player_joined_event)
	_registry.player_removed.connect(_on_replay_player_left_event)

	_state_buffer_manager = StateBufferManager.new()
	_state_buffer_manager.setup(_registry, goalie_controllers)

	# Goal-replay cinematic: every peer has its own recorder ring-buffer and
	# driver so host and clients all see the same 8-second instant-replay.
	# Driver is a Node so GameManager owns add_child / queue_free; cinematic
	# logic (start/stop, signal wiring) lives in PhaseCoordinator.
	_recorder = ReplayRecorder.new()
	_recorder.setup()
	_goal_replay_driver = GoalReplayDriver.new()
	add_child(_goal_replay_driver)
	# Shadow each goal's clip as its live cinematic starts so the post-game
	# highlight loop has all of them (the recorder ring only holds ~9 s).
	_goal_replay_store = GoalReplayStore.new()
	_goal_replay_driver.replay_started.connect(_on_goal_replay_started_capture)
	_post_game_replay_driver = PostGameReplayDriver.new()
	add_child(_post_game_replay_driver)
	# Intermission reel: loops the ended period's clips for the fixed break
	# window (the host's INTERMISSION_DURATION timer ends it), replay mode
	# mirrored so every peer's reel brackets together. Its start/stop also
	# flips _in_replay_locally (skip-vote gate), same as the goal cinematic.
	_intermission_replay_driver = PostGameReplayDriver.new()
	_intermission_replay_driver.use_shared_replay_mode = true
	add_child(_intermission_replay_driver)
	_intermission_replay_driver.reel_started.connect(_on_local_replay_started)
	_intermission_replay_driver.clip_started.connect(_on_intermission_clip_started)
	_intermission_replay_driver.reel_stopped.connect(_on_intermission_reel_stopped)
	_intermission_replay_driver.reel_stopped.connect(_on_local_replay_stopped)

	_codec = WorldStateCodec.new()
	_codec.setup(_registry, _state_machine,
			get_puck, _get_puck_controller, _get_goalie_controllers, _state_buffer_manager)
	_codec.phase_changed.connect(_on_remote_phase_changed)
	_codec.game_over_triggered.connect(game_over.emit)
	_codec.period_synced.connect(period_synced.emit)
	_codec.clock_updated.connect(_on_clock_updated_externally)
	_codec.shots_on_goal_changed.connect(shots_on_goal_changed.emit)
	_codec.queue_depth_feedback.connect(NetworkManager.on_queue_depth_received)

	_shot_tracker = ShotOnGoalTracker.new()
	_shot_tracker.setup(_registry, _state_machine)
	_shot_tracker.shots_on_goal_changed.connect(shots_on_goal_changed.emit)

	_hit_tracker = HitTracker.new()
	_hit_tracker.setup(_registry)
	_hit_tracker.impact_landed.connect(_on_impact_landed)
	_hit_tracker.hit_credited.connect(_on_hit_credited)

	# Host-only takeaway / giveaway / faceoff-win attribution off possession
	# changes. Fed by the pickup, strip, and shot hooks below. Every shot RELEASE
	# opens the rebound window (so recovering a missed/wide shot isn't a turnover);
	# a confirmed shot-on-goal refreshes it at the save so the rebound stays
	# covered past the shot's flight.
	_turnover_tracker = TurnoverTracker.new()
	_turnover_tracker.setup(_registry)
	_shot_tracker.shot_attempted.connect(_turnover_tracker.note_shot)
	_shot_tracker.shot_on_goal_recorded.connect(_turnover_tracker.note_shot)

	# Host-only advanced-stat attribution (analytics A1): per-player Corsi/Fenwick
	# off the same shot-event signals. Counters ride the normal stats broadcast.
	_advanced_stats_tracker = AdvancedStatsTracker.new()
	_advanced_stats_tracker.setup(_registry)
	_shot_tracker.shot_resolved.connect(_advanced_stats_tracker.on_shot_resolved)
	# A client's pushed copy belongs to the PREVIOUS match — drop it alongside the
	# fresh host-side buffer this re-wire creates.
	_client_shot_events.clear()

	# Host-only established-possession model (PossessionRules): turnover /
	# faceoff-win crediting and assist-chain breaks key off ESTABLISHMENT
	# (held the puck, or made a deliberate play), never off momentary
	# scramble touches. Fed by the pickup/release/strip hooks below.
	_possession_tracker = PossessionTracker.new()
	_possession_tracker.setup(_registry)
	_possession_tracker.possession_established.connect(_on_possession_established)
	# Catch-all stoppage flush: any phase that isn't live play resolves a
	# still-pending draw and drops pending hits/grace. Covers the paths that
	# don't go through _whistle_and_faceoff — the period horn and game over.
	# `phase_changed` is GameManager's own signal and GameManager is a
	# persistent autoload, so this connection survives across matches — unlike
	# the fresh-per-match collaborator signals wired above. `_wire_subsystems`
	# re-runs on every `_spawn_world` (boot free-play → hosted match, rematch,
	# offline restart), so guard against the duplicate connect. The handler
	# reads GameManager's live `_*_tracker` fields, which the surrounding
	# re-wire refreshes, so one persistent connection stays correct.
	if not phase_changed.is_connected(_on_stoppage_flush_stat_trackers):
		phase_changed.connect(_on_stoppage_flush_stat_trackers)

	_pickup_claim = PickupClaimResolver.new()
	_pickup_claim.setup(_registry, _state_buffer_manager, get_puck, _get_puck_controller)
	# Claim-vs-present-time pickup arbitration (see arbitrate_present_grab):
	# the present-time grant consults the pending lag-comp claim by stamp
	# instead of silently discarding it via the grant-path clear().
	if puck_controller != null:
		puck_controller.set_present_grab_arbiter(_pickup_claim.arbitrate_present_grab)

	_poke_claim = PokeClaimResolver.new()
	_poke_claim.setup(_registry, _state_buffer_manager, get_puck, _get_puck_controller)

	_stick_lift_claim = StickLiftClaimResolver.new()
	_stick_lift_claim.setup(_registry, _state_buffer_manager, get_puck, _get_puck_controller)

	_hit_claim = HitClaimResolver.new()
	_hit_claim.setup(_registry, _state_buffer_manager, _hit_tracker, _get_puck_controller)

	_phase_coord = PhaseCoordinator.new()
	# Every peer captures a goal frame of its own POV at goal time —
	# host-authoritative on the host; client-interpolated on clients.
	# Without the client side, client .mreplay files waited for the next
	# dead-puck broadcast (up to 200 ms back when dead-puck phases
	# broadcast at 5 Hz).
	var force_record: Callable = func() -> void:
		var goal_frame: PackedByteArray = _codec.encode_world_state()
		if goal_frame.is_empty():
			return
		# Host stamps with session-relative local_time(); clients with
		# estimated_host_time() so the goal frame's timestamp lines up
		# with the host_ts of surrounding broadcast frames in the file.
		var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
				else NetworkManager.estimated_host_time()
		_recorder.record_frame(goal_frame, ts)
		# Also enqueue to the .mreplay file so the puck-in-net moment
		# lands in the recording deterministically. Without this, the
		# first dead-puck broadcast (the only frame `_should_record_to_file`
		# admits while movement-locked) is what represents "goal" in the
		# file — a tick after the actual entry. Update
		# `_last_recorded_phase` so the natural broadcast pipeline doesn't
		# duplicate this frame on its next tick.
		if _replay_file_writer != null and _should_record_to_file():
			_replay_file_writer.enqueue_frame(ts, goal_frame)
			if _state_machine != null:
				_last_recorded_phase = _state_machine.current_phase
	_phase_coord.setup(_state_machine, _registry, teams,
			get_puck, _get_goalie_controllers, _shot_tracker, _drop_puck_if_carried,
			_recorder, _goal_replay_driver, _codec,
			get_tree(), NetworkManager.is_host, force_record,
			_is_pregame_intro_faceoff)
	_phase_coord.goal_scored.connect(goal_scored.emit)
	_phase_coord.goal_scored.connect(_on_goal_for_replay_event)
	_phase_coord.goal_scored.connect(_stash_goal_clip_meta)
	_phase_coord.goal_scored.connect(_trigger_scorer_celebration)
	_phase_coord.goal_scored.connect(_on_goal_resolve_faceoff)
	_phase_coord.score_changed.connect(score_changed.emit)
	_phase_coord.phase_changed.connect(phase_changed.emit)
	# Record period-end markers into the .mreplay event stream (like goals) so the
	# offline viewer can tick each period boundary. Uses the GameManager-level
	# phase_changed so it fires on host (via _phase_coord) and client (via the
	# codec decode path) alike, matching the goal-event recording. Guarded because
	# phase_changed is GameManager's OWN signal (autoload, persists across
	# matches), unlike the _phase_coord signals above which are re-created each
	# _spawn_world — without the guard a second match double-connects.
	if not phase_changed.is_connected(_on_phase_changed_for_replay_event):
		phase_changed.connect(_on_phase_changed_for_replay_event)
	_phase_coord.period_break_started.connect(_on_period_break_for_intermission)
	_phase_coord.faceoff_prep_announced.connect(_on_faceoff_prep_announced_from_coord)
	_phase_coord.period_break_started.connect(period_break_started.emit)
	_phase_coord.replay_started.connect(replay_started.emit)
	_phase_coord.replay_stopped.connect(replay_stopped.emit)
	_phase_coord.period_synced.connect(period_synced.emit)
	_phase_coord.clock_updated.connect(_on_clock_updated_externally)
	_phase_coord.game_over.connect(game_over.emit)
	_phase_coord.stats_need_sync.connect(_sync_stats_to_clients)
	_phase_coord.faceoff_positions_ready.connect(NetworkManager.send_faceoff_positions)
	_phase_coord.goal_broadcast_needed.connect(NetworkManager.notify_goal_to_all)

	_swap_coord = SlotSwapCoordinator.new()
	_swap_coord.setup(_registry, _state_machine, teams)
	_swap_coord.stats_updated.connect(stats_updated.emit)
	_swap_coord.carrier_swap_needs_drop.connect(_drop_puck_if_carried)

	_telemetry = NetworkTelemetry.new()
	NetworkTelemetry.instance = _telemetry
	_net_session_reported = false
	_debug_overlay = NetworkDebugOverlay.new()
	add_child(_debug_overlay)

	var _home_c := TeamColorRegistry.get_colors(teams[0].color_slot, 0)
	var _away_c := TeamColorRegistry.get_colors(teams[1].color_slot, 1)
	team_colors_ready.emit(_home_c.primary, _home_c.secondary, _away_c.primary, _away_c.secondary)

	_wire_sound_signals()


func _wire_sound_signals() -> void:
	# Per-game connections: puck / puck_controller / _phase_coord are recreated
	# each match by _spawn_world, so these always get freshly wired here.
	_phase_coord.goal_scored.connect(
		func(_t: Team, _s: String, _a1: String, _a2: String) -> void:
			SoundManager.play_crowd(SoundManager.Sound.GOAL_HORN, -6.0))
	if NetworkManager.is_host:
		puck.puck_hit_boards.connect(func() -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_BOARDS, puck.get_puck_position(), _puck_speed_volume(spd), 0.05)
			puck.fire_board_impact_vfx(spd)
			NetworkManager.send_board_hit_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_boards", puck.get_puck_position(), spd))
		puck.puck_hit_goal_body.connect(func() -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_GOAL_BODY, puck.get_puck_position(), _puck_speed_volume(spd), 0.06)
			NetworkManager.send_goal_body_hit_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_goal_body", puck.get_puck_position(), spd))
		puck.puck_touched_loose.connect(func(_s: Skater) -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_DEFLECTION, puck.get_puck_position(), _puck_speed_volume(spd), 0.06, _deflection_pitch(spd))
			NetworkManager.send_deflection_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_deflection", puck.get_puck_position(), spd))
		puck.puck_body_blocked.connect(func(_s: Skater) -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_BODY_BLOCK, puck.get_puck_position(), _puck_speed_volume(spd), 0.07)
			NetworkManager.send_body_block_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_body_block", puck.get_puck_position(), spd))
		puck_controller.puck_stripped_from.connect(func(_pid: int, _stripper: int) -> void:
			var spd: float = puck.linear_velocity.length()
			var pos: Vector3 = puck.get_puck_position()
			if puck_controller.is_processing_stick_lift():
				# Distinct stick-lift cue instead of the generic puck-strip thud.
				SoundManager.play_world(SoundManager.Sound.STICK_LIFT, pos, _puck_speed_volume(spd), 0.06)
				puck.fire_stick_lift_vfx()
				NetworkManager.send_stick_lift_to_all(pos)
				_record_replay_audio_event("stick_lift", pos, spd)
			else:
				SoundManager.play_world(SoundManager.Sound.PUCK_STRIP, pos, _puck_speed_volume(spd), 0.06)
				NetworkManager.send_puck_strip_to_all(pos)
				_record_replay_audio_event("puck_strip", pos, spd))
	else:
		# Client-side predicted contact cues: the loose-puck prediction detects
		# post / net / board / goalie contacts analytically (the puck has no
		# physics body, so there are no engine contact signals on any peer), and
		# these fire the cue the same instant the host hears its own sim —
		# instead of waiting ~RTT for the host's broadcast. The broadcast still
		# arrives and is echo-suppressed via the _local_*_cue_at stamps below.
		puck_controller.predicted_post_contact.connect(
			func(pos: Vector3, spd: float) -> void:
				SoundManager.play_world(SoundManager.Sound.PUCK_POST, pos, _puck_speed_volume(spd) + _POST_SAVE_VOLUME_BUMP_DB, 0.04, _post_pitch(spd))
				if puck != null:
					puck.fire_post_ping_vfx(spd)
				_local_post_cue_at = NetworkManager.local_time())
		puck_controller.predicted_net_contact.connect(
			func(pos: Vector3, spd: float) -> void:
				SoundManager.play_world(SoundManager.Sound.PUCK_GOAL_BODY, pos, _puck_speed_volume(spd), 0.06)
				_local_net_cue_at = NetworkManager.local_time())
		puck_controller.predicted_board_contact.connect(
			func(pos: Vector3, spd: float) -> void:
				SoundManager.play_world(SoundManager.Sound.PUCK_BOARDS, pos, _puck_speed_volume(spd), 0.05)
				if puck != null:
					puck.fire_board_impact_vfx(spd)
				_local_boards_cue_at = NetworkManager.local_time())
		puck_controller.predicted_goalie_contact.connect(
			func(pos: Vector3, spd: float) -> void:
				SoundManager.play_world(SoundManager.Sound.PUCK_GOALIE, pos, _puck_speed_volume(spd) + _PAD_SAVE_VOLUME_BUMP_DB, 0.05)
				_local_goalie_cue_at = NetworkManager.local_time())
	puck.puck_touched_goalie.connect(
		func(_g: Goalie) -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_GOALIE, puck.get_puck_position(), _puck_speed_volume(spd) + _PAD_SAVE_VOLUME_BUMP_DB, 0.05)
			_local_goalie_cue_at = NetworkManager.local_time()
			if NetworkManager.is_host:
				NetworkManager.send_goalie_hit_to_all(puck.get_puck_position())
				_record_replay_audio_event("puck_goalie", puck.get_puck_position(), spd))
	puck.puck_touched_post.connect(
		func() -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_POST, puck.get_puck_position(), _puck_speed_volume(spd) + _POST_SAVE_VOLUME_BUMP_DB, 0.04, _post_pitch(spd))
			puck.fire_post_ping_vfx(spd)
			_local_post_cue_at = NetworkManager.local_time()
			if NetworkManager.is_host:
				NetworkManager.send_post_hit_to_all(puck.get_puck_position())
				_record_replay_audio_event("puck_post", puck.get_puck_position(), spd))

	# Persistent connections: NetworkManager autoload + GameManager self-signals
	# survive across rematches; wire once.
	if _persistent_sound_signals_wired:
		return
	_persistent_sound_signals_wired = true
	NetworkManager.local_puck_pickup_confirmed.connect(_on_local_pickup_sound)
	NetworkManager.remote_carrier_changed.connect(_on_remote_carrier_sound)
	NetworkManager.goal_received.connect(
		func(_tid: int, _s0: int, _s1: int, _sn: String, _a1: String, _a2: String) -> void:
			SoundManager.play_crowd(SoundManager.Sound.GOAL_HORN, -6.0))
	NetworkManager.board_hit_received.connect(
		func(pos: Vector3) -> void:
			if _cue_is_echo(_local_boards_cue_at):
				return  # already played locally off this peer's predicted contact
			var spd: float = puck.linear_velocity.length() if puck != null else 0.0
			SoundManager.play_world(SoundManager.Sound.PUCK_BOARDS, pos, _puck_speed_volume(spd), 0.05)
			if puck != null:
				puck.fire_board_impact_vfx(spd))
	NetworkManager.goal_body_hit_received.connect(
		func(pos: Vector3) -> void:
			if _cue_is_echo(_local_net_cue_at):
				return  # already played locally off this peer's predicted contact
			SoundManager.play_world(SoundManager.Sound.PUCK_GOAL_BODY, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.06))
	NetworkManager.post_hit_received.connect(
		func(pos: Vector3) -> void:
			if _cue_is_echo(_local_post_cue_at):
				return  # already played locally off this peer's predicted contact
			var spd: float = puck.linear_velocity.length() if puck != null else 0.0
			SoundManager.play_world(SoundManager.Sound.PUCK_POST, pos, _puck_speed_volume(spd) + _POST_SAVE_VOLUME_BUMP_DB, 0.04, _post_pitch(spd))
			if puck != null:
				puck.fire_post_ping_vfx(spd))
	NetworkManager.goalie_hit_received.connect(
		func(pos: Vector3) -> void:
			if _cue_is_echo(_local_goalie_cue_at):
				return  # already played locally off this peer's predicted contact
			SoundManager.play_world(SoundManager.Sound.PUCK_GOALIE, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0) + _PAD_SAVE_VOLUME_BUMP_DB, 0.05))
	NetworkManager.deflection_received.connect(
		func(pos: Vector3) -> void:
			var spd: float = puck.linear_velocity.length() if puck != null else 0.0
			SoundManager.play_world(SoundManager.Sound.PUCK_DEFLECTION, pos, _puck_speed_volume(spd), 0.06, _deflection_pitch(spd)))
	NetworkManager.body_block_received.connect(
		func(pos: Vector3) -> void: SoundManager.play_world(SoundManager.Sound.PUCK_BODY_BLOCK, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.07))
	NetworkManager.puck_strip_received.connect(
		func(pos: Vector3) -> void: SoundManager.play_world(SoundManager.Sound.PUCK_STRIP, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.06))
	NetworkManager.body_check_landed.connect(_on_body_check_landed)
	NetworkManager.smart_ping_received.connect(_on_smart_ping_received)
	NetworkManager.stick_lift_received.connect(
		func(pos: Vector3) -> void:
			SoundManager.play_world(SoundManager.Sound.STICK_LIFT, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.06)
			if puck != null:
				puck.fire_stick_lift_vfx())
	NetworkManager.nudge_received.connect(func(pos: Vector3) -> void: _play_nudge_cue(pos))
	NetworkManager.shot_sound_received.connect(
		func(pos: Vector3, is_slapper: bool) -> void:
			var snd: SoundManager.Sound = SoundManager.Sound.SHOT_SLAPPER if is_slapper else SoundManager.Sound.SHOT_WRISTER
			SoundManager.play_world(snd, pos, 0.0, 0.04))
	# Period-end buzzer fires only when a period actually ends — END_OF_PERIOD for
	# regulation periods, GAME_OVER for the final one. (Not period_synced, which
	# re-emits on every FACEOFF_PREP, i.e. every faceoff including post-goal.)
	# Named + guarded so a rematch doesn't stack a second lambda on GameManager's
	# persistent phase_changed and double-fire the buzzer (see the note above).
	if not phase_changed.is_connected(_on_phase_changed_period_buzzer):
		phase_changed.connect(_on_phase_changed_period_buzzer)


func _on_phase_changed_period_buzzer(p: GamePhase.Phase) -> void:
	if p == GamePhase.Phase.END_OF_PERIOD or p == GamePhase.Phase.GAME_OVER:
		SoundManager.play_crowd(SoundManager.Sound.PERIOD_BUZZER, -10.0)


func _on_local_pickup_sound() -> void:
	var record := _registry.get_local() if _registry != null else null
	if record != null and record.skater != null:
		SoundManager.play_world(SoundManager.Sound.PUCK_PICKUP, record.skater.global_position, 0.0, 0.05)
		if NetworkManager.is_host:
			_record_replay_audio_event("puck_pickup", record.skater.global_position, 0.0)


func _on_remote_carrier_sound(new_carrier_peer_id: int) -> void:
	if _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(new_carrier_peer_id)
	if record != null and record.skater != null:
		SoundManager.play_world(SoundManager.Sound.PUCK_PICKUP, record.skater.global_position, 0.0, 0.05)
		if NetworkManager.is_host:
			_record_replay_audio_event("puck_pickup", record.skater.global_position, 0.0)


# Host-only: shadow a transient audio/VFX event into the in-memory recorder
# AND the .mreplay file writer so both replay paths (post-goal cinematic +
# offline file viewer) can re-fire the sound/VFX at the right virtual time.
# Audio-only events use kind ∈ { puck_boards, puck_goal_body, puck_deflection,
# puck_body_block, puck_strip, puck_goalie, puck_post, puck_pickup, shot };
# body_check carries extra payload via _record_body_check_replay_event.
func _record_replay_audio_event(kind: String, position: Vector3, speed: float,
		extra: Dictionary = {}) -> void:
	if not NetworkManager.is_host:
		return
	# Don't shadow live events into the replay buffer while a replay is
	# actively playing — the cinematic is the consumer, not the producer.
	# Same gate for GOAL_CELEBRATION: those events belong to live gameplay,
	# not the clip (which ends at the goal-moment frame).
	if NetworkManager.is_replay_mode() or _is_celebration_phase():
		return
	var ts: float = NetworkManager.local_time()
	var event: Dictionary = {
		"kind": kind,
		"pos": [position.x, position.y, position.z],
		"speed": speed,
	}
	for k: Variant in extra:
		event[k] = extra[k]
	if _recorder != null:
		_recorder.record_event(ts, event)
	if _replay_file_writer != null and _should_record_to_file():
		_replay_file_writer.enqueue_event(ts, JSON.stringify(event).to_utf8_buffer())
	# Mirror the event onto every client / spectator so their recorders see
	# the same timeline. Required for the goal-replay cinematic to use the
	# same shot anchor + adaptive clip start everywhere.
	NetworkManager.notify_replay_event_to_all(ts, event)


# Client / spectator side: host broadcast each event it recorded; we mirror
# it into our local recorder so our goal-replay clip carries the same
# timeline (shot anchor, pickup chain, audio cues). Same gates the host
# applies to its own recording — skip while a cinematic is already playing.
func _on_replay_event_received(host_ts: float, event: Dictionary) -> void:
	if _recorder == null:
		return
	if NetworkManager.is_replay_mode() or _is_celebration_phase():
		return
	_recorder.record_event(host_ts, event)
	# Persist into the client's own .mreplay file too — clients write replay
	# files (the writer isn't host-gated) but only ever recorded world-state
	# frames here, so client-saved replays played back silent. Mirror the host's
	# file-write (_record_replay_audio_event) so the events land on disk.
	if _replay_file_writer != null and _should_record_to_file():
		_replay_file_writer.enqueue_event(host_ts, JSON.stringify(event).to_utf8_buffer())


# Client / spectator side: the host mirrors its replay-mode flag here when it
# enters (true) / leaves (false) the goal cinematic. The host's GOAL_SCORED
# phase never arrives via world state (it stops broadcasting the instant it
# freezes for the replay), so this edge is what drives the client's own
# GoalReplayDriver. On `true` we kick off the local cinematic — the recorder
# already holds the clip and on_goal_received has set the defending-goal Z for
# the inside-net cam. On `false` we tear it down so the client's replay ends
# in lockstep with the host (which only resumes broadcasting / advances to
# FACEOFF_PREP after its own cinematic finishes), instead of overrunning into
# the live faceoff data on its independent outro timer.
func _on_remote_replay_mode_changed(active: bool) -> void:
	if NetworkManager.is_host or _phase_coord == null:
		return
	if active:
		# Which cinematic depends on where the game is: a replay-mode edge
		# during the period break is the intermission reel (the host waits
		# INTERMISSION_SETTLE after the horn, so the END_OF_PERIOD phase byte
		# has long since landed here); any other edge is the post-goal
		# cinematic.
		if _state_machine != null \
				and _state_machine.current_phase == GamePhase.Phase.END_OF_PERIOD:
			_start_client_intermission_replay()
		else:
			_phase_coord.start_goal_replay()
	else:
		if _goal_replay_driver != null:
			_goal_replay_driver.stop()
		if _intermission_replay_driver != null:
			_intermission_replay_driver.stop()


# ── Post-game highlight reel ──────────────────────────────────────────────────
# Delay from game-over to the highlight loop kicking in — matches the HUD's
# final-horn beat so the reel is already rolling behind the score card as it
# fades in (HUD._GAME_OVER_PRESENT_DELAY is 2.2 s).
const _POST_GAME_REPLAY_DELAY: float = 2.0

# Stamp the goal credit + period onto the clip that is about to be captured
# for this goal (the cinematic starts a beat after the goal signal). Fires on
# every peer alongside the goal broadcast, so each peer's store copy carries
# the same meta the intermission band captions with.
func _stash_goal_clip_meta(scoring_team: Team, scorer_name: String,
		assist1_name: String, assist2_name: String) -> void:
	_pending_clip_meta = {
		"period": _state_machine.current_period if _state_machine != null else 0,
		"scoring_team_id": scoring_team.team_id,
		"scorer_name": scorer_name,
		"assist1_name": assist1_name,
		"assist2_name": assist2_name,
	}


# Copy the just-started goal cinematic's clip into the persistent store so the
# post-game loop can replay every goal, not just the last few in the ring
# buffer. Fires on every peer (each runs its own GoalReplayDriver).
func _on_goal_replay_started_capture() -> void:
	if _goal_replay_store == null or _goal_replay_driver == null:
		return
	# Free play is an endless sandbox with no game-over screen — capturing its
	# goals would just grow the store for a reel that never plays. Drills route
	# around the cinematic entirely, but guard both for clarity.
	if NetworkManager.is_free_play_mode or NetworkManager.is_drill_mode():
		return
	var clip: Dictionary = _goal_replay_driver.get_active_clip()
	clip.merge(_pending_clip_meta)
	_goal_replay_store.add(clip)


func _schedule_post_game_replay() -> void:
	if _post_game_replay_driver == null or _goal_replay_store == null:
		return
	# Nothing scored (0-0) — leave the frozen final frame behind the card.
	if _goal_replay_store.is_empty():
		return
	_post_game_replay_timer = get_tree().create_timer(_POST_GAME_REPLAY_DELAY)
	_post_game_replay_timer.timeout.connect(_start_post_game_replay)


func _start_post_game_replay() -> void:
	_post_game_replay_timer = null
	# The game may have been reset (rematch / leave) during the delay.
	if _post_game_replay_driver == null or _goal_replay_store == null \
			or _goal_replay_store.is_empty():
		return
	if _codec == null or puck == null or _registry == null:
		return
	_post_game_replay_driver.setup(_codec, _registry, puck, goalie_controllers)
	_post_game_replay_driver.start(_goal_replay_store.clips())


func _stop_post_game_replay() -> void:
	if _post_game_replay_timer != null:
		if _post_game_replay_timer.timeout.is_connected(_start_post_game_replay):
			_post_game_replay_timer.timeout.disconnect(_start_post_game_replay)
		_post_game_replay_timer = null
	if _post_game_replay_driver != null:
		_post_game_replay_driver.stop()


# ── Intermission (between-period break presentation) ─────────────────────────
# Every break is a fixed INTERMISSION_DURATION. INTERMISSION_SETTLE after the
# horn (the chyron + skate-off beat, and the window that guarantees clients
# have the END_OF_PERIOD phase byte before the replay-mode RPC lands) every
# peer raises the intermission band + countdown; when the ended period has
# goals the host also starts the looping reel behind it — replay mode then
# freezes the SM timer and the host's end timer (or a unanimous skip vote)
# stops the reel, whose reel_stopped rolls the next period via
# GameStateMachine.finish_period_break. A scoreless period holds just the
# band over the wide rink and rides the SM's INTERMISSION_DURATION timer.

func _on_period_break_for_intermission(_duration: float) -> void:
	if _state_machine == null:
		return
	_skip_votes.clear()  # the break is a fresh skippable window
	_intermission_timer = get_tree().create_timer(GameRules.INTERMISSION_SETTLE)
	_intermission_timer.timeout.connect(_on_intermission_settle_elapsed)


# The settle beat is over: raise the band everywhere; host starts the reel
# (no-op for a scoreless period) and re-baselines the skip tally clients see.
func _on_intermission_settle_elapsed() -> void:
	_intermission_timer = null
	# The break may have been cut short (reset / return-to-lobby) during the
	# settle beat.
	if _state_machine == null \
			or _state_machine.current_phase != GamePhase.Phase.END_OF_PERIOD:
		return
	intermission_started.emit(_state_machine.current_period,
			GameRules.INTERMISSION_DURATION - GameRules.INTERMISSION_SETTLE)
	if NetworkManager.is_host:
		var total: int = _total_skip_voters()
		NetworkManager.notify_skip_replay_vote_to_all(0, total)
		skip_replay_vote_updated.emit(0, total)
		_start_intermission_replay()


func _start_intermission_replay() -> void:
	if _intermission_replay_driver == null or _goal_replay_store == null \
			or _codec == null or puck == null or _registry == null:
		return
	var clips: Array[Dictionary] = _goal_replay_store.clips_for_period(
			_state_machine.current_period)
	if clips.is_empty():
		return  # scoreless break — the band stands alone over the live rink
	_show_all_skaters()
	_intermission_replay_driver.setup(_codec, _registry, puck, goalie_controllers)
	_intermission_replay_driver.start(clips)
	_intermission_end_timer = get_tree().create_timer(
			GameRules.INTERMISSION_DURATION - GameRules.INTERMISSION_SETTLE)
	_intermission_end_timer.timeout.connect(_end_intermission_replay)


# Host: the fixed intermission window is up — stop the looping reel, whose
# reel_stopped handler advances to the next period's prep.
func _end_intermission_replay() -> void:
	_intermission_end_timer = null
	if _intermission_replay_driver != null and _intermission_replay_driver.is_active():
		_intermission_replay_driver.stop()


# Client-side reel: loop OUR captured copies of this period's goals while the
# host's sim is frozen; the host's mirror-false (break over / skip) tears it
# down. A mid-game joiner may hold fewer clips (or none) — its shorter
# playlist just wraps sooner.
func _start_client_intermission_replay() -> void:
	if _intermission_replay_driver == null or _goal_replay_store == null \
			or _codec == null or puck == null or _registry == null \
			or _state_machine == null:
		return
	var clips: Array[Dictionary] = _goal_replay_store.clips_for_period(
			_state_machine.current_period)
	if clips.is_empty():
		return
	_show_all_skaters()
	_intermission_replay_driver.setup(_codec, _registry, puck, goalie_controllers)
	_intermission_replay_driver.start(clips)


# External teardown (scene exit / reset / return-to-lobby). Suppresses the
# host's advance-on-stop: reel_stopped would otherwise run finish_period_break
# + phase-entry side effects against a world that is being torn down. The
# end-timer and skip-vote paths stop the driver directly and do advance.
var _suppress_intermission_advance: bool = false

func _stop_intermission_replay() -> void:
	if _intermission_timer != null:
		if _intermission_timer.timeout.is_connected(_on_intermission_settle_elapsed):
			_intermission_timer.timeout.disconnect(_on_intermission_settle_elapsed)
		_intermission_timer = null
	if _intermission_end_timer != null:
		if _intermission_end_timer.timeout.is_connected(_end_intermission_replay):
			_intermission_end_timer.timeout.disconnect(_end_intermission_replay)
		_intermission_end_timer = null
	if _intermission_replay_driver != null:
		_suppress_intermission_advance = true
		_intermission_replay_driver.stop()
		_suppress_intermission_advance = false


func _on_intermission_clip_started(clip: Dictionary) -> void:
	intermission_clip_started.emit(
			int(clip.get("scoring_team_id", -1)),
			String(clip.get("scorer_name", "")),
			String(clip.get("assist1_name", "")),
			String(clip.get("assist2_name", "")))


# ── Period-break bench hiding ────────────────────────────────────────────────
# During the skate-off, a skater that reaches its bench door "steps off the
# ice": near-door players would otherwise finish their short glide and stand
# frozen for the rest of the break. Derived locally on every peer from
# position alone (host-driven approaches land exactly on the door; client
# remotes interpolate onto it), so no wire change. The pass self-restores:
# any phase/replay-mode edge away from the live break (the reel repositions
# every body, the next prep teleports them) unhides everyone — with explicit
# unhides at reel start so bodies never miss the reel's first frame.

# Planar distance-to-door within which a skater is considered "through the
# bench door" (approaches target the door exactly; this absorbs interpolation
# residue on remote skaters).
const _BENCH_HIDE_DIST_SQ: float = 0.75 * 0.75
var _any_bench_hidden: bool = false

func _update_period_break_hiding() -> void:
	if _registry == null or _state_machine == null:
		return
	var in_live_break: bool = \
			_state_machine.current_phase == GamePhase.Phase.END_OF_PERIOD \
			and not NetworkManager.is_replay_mode()
	if not in_live_break:
		if _any_bench_hidden:
			_show_all_skaters()
		return
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record == null or record.skater == null or not record.skater.visible:
			continue
		var door: Vector3 = PlayerRules.bench_start_position(
				record.team.team_id, record.team_slot)
		var dx: float = record.skater.global_position.x - door.x
		var dz: float = record.skater.global_position.z - door.z
		if dx * dx + dz * dz < _BENCH_HIDE_DIST_SQ:
			record.skater.visible = false
			_any_bench_hidden = true


func _show_all_skaters() -> void:
	_any_bench_hidden = false
	if _registry == null:
		return
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record != null and record.skater != null:
			record.skater.visible = true


# Fires when the reel stops: the host's end timer, skip-vote unanimity, or
# teardown. On the host the stop is what rolls the next period's faceoff prep
# (mirrors PhaseCoordinator._on_goal_replay_stopped).
func _on_intermission_reel_stopped() -> void:
	intermission_ended.emit()
	if not NetworkManager.is_host or _suppress_intermission_advance:
		return
	if _state_machine != null and _state_machine.finish_period_break() \
			and _phase_coord != null:
		_phase_coord.handle_phase_entered()


# Recorder-recording gate. During GOAL_CELEBRATION we skip writing to the
# recorder (both frames and events) so the clip ends cleanly at the puck-
# in-net moment captured via PhaseCoordinator._capture_goal_moment_frame.
# The celebration itself is live gameplay; its frames don't belong in the
# replay clip.
func _is_celebration_phase() -> bool:
	return is_in_goal_celebration()


# Public phase query for controllers (the AIController uses this to drop
# bot input during the celebration beat — bots coast on residual velocity
# instead of trying to play during a stopped puck). Same value as the
# internal _is_celebration_phase recorder gate.
func is_in_goal_celebration() -> bool:
	return _state_machine != null \
			and _state_machine.current_phase == GamePhase.Phase.GOAL_CELEBRATION


func _record_body_check_replay_event(checker_peer_id: int, victim: Skater,
		force: float, hit_dir: Vector3) -> void:
	var victim_peer_id: int = _registry.resolve_peer_id(victim) if _registry != null and victim != null else -1
	var checker_pos: Vector3 = Vector3.ZERO
	if _registry != null:
		var rec: PlayerRecord = _registry.get_record(checker_peer_id)
		if rec != null and rec.skater != null:
			checker_pos = rec.skater.global_position
	_record_replay_audio_event("body_check", checker_pos, force, {
		"checker_peer_id": checker_peer_id,
		"victim_peer_id": victim_peer_id,
		"hit_dir": [hit_dir.x, hit_dir.y, hit_dir.z],
	})


# Local peer is a spectator. Set the flag so HUD chrome can hide local-only
# elements, and mount a CameraDirector tracking the puck. No skater is
# created — the spectator renders the active 6 via the existing remote-controller
# path that all clients already use. The director owns broadcast / chase /
# free cameras and the input handlers that switch between them.
func _become_local_spectator() -> void:
	_is_local_spectator = true
	if _camera_director == null:
		_camera_director = CameraDirector.new()
		get_tree().current_scene.add_child(_camera_director)
		_camera_director.setup(
			func() -> Vector3:
				return puck.global_position if puck != null else Vector3.ZERO,
			func() -> Array[Skater]:
				var out: Array[Skater] = []
				if _registry == null:
					return out
				for record: PlayerRecord in _registry.all().values():
					if record != null and record.skater != null and is_instance_valid(record.skater):
						out.append(record.skater)
				return out)
		_camera_director.activate_initial()
	local_spectator_state_changed.emit(true)


func is_local_spectator() -> bool:
	return _is_local_spectator


func get_camera_director() -> CameraDirector:
	return _camera_director


func get_game_id() -> String:
	return _game_id


# Host-only accurate. Clients only know their own spectator status (via
# is_local_spectator), so callers iterating peer IDs should be host-gated.
func is_spectator_peer(peer_id: int) -> bool:
	return _spectator_peers.has(peer_id)


func spectator_peer_count() -> int:
	return _spectator_peers.size()


# ── Mid-game spectator ↔ player swap ─────────────────────────────────────────
# Both directions branch out of `_on_slot_swap_requested` (host-only). The
# demote path despawns the skater everywhere via `notify_spectator_demoted`;
# the promote path spawns a fresh skater everywhere by reusing the
# spawn_remote_skater + assign_player_slot RPCs that mid-game joins use.

func _demote_player_to_spectator(peer_id: int) -> void:
	if _registry == null or not _registry.has(peer_id):
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	# Drop the puck before broadcasting so the carrier change goes out while
	# the controller still exists (mirrors on_player_disconnected). The
	# pending pickup claim self-cleans at apply time via registry lookup,
	# so no extra mirror-clear is needed here.
	if puck != null and puck.carrier == record.skater:
		puck.drop()
	NetworkManager.send_spectator_demoted_to_all(peer_id)


# Runs on every peer (host + clients) when a demotion is broadcast. Despawns
# the demoted peer's skater locally; the demoted peer additionally tears down
# its LocalController and mounts SpectatorCamera.
func _on_spectator_demoted_received(peer_id: int) -> void:
	var is_local_demote: bool = peer_id == NetworkManager.local_peer_id()
	if is_local_demote:
		# Stop input batches before the controller is queue_freed — the Callable
		# would otherwise reference a dead object.
		NetworkManager.set_input_batch_provider(Callable())
	_despawn_skater_for_peer(peer_id)
	_spectator_peers[peer_id] = true
	if is_local_demote:
		_become_local_spectator()


# Host-only. Spawns a skater for a peer that's currently a spectator and tells
# every peer to do the same (clients via spawn_remote_skater, the promoted peer
# via assign_player_slot). Validation is inline because `try_swap_slot` only
# operates on peers already in `_state_machine.players`.
func _promote_spectator_to_player(peer_id: int, new_team_id: int, new_slot: int) -> void:
	if _state_machine == null or _registry == null:
		return
	if new_team_id < 0 or new_team_id > 1:
		return
	if new_slot < 0 or new_slot >= _state_machine.team_size:
		return
	# Liveness guard: a swap-request RPC can still be in flight when the requesting
	# spectator disconnects. Without this the host would spawn + broadcast a skater
	# for a gone peer that no disconnect will ever clean up (phantom on all clients).
	if peer_id != NetworkManager.local_peer_id() and peer_id not in NetworkManager.connected_peer_ids():
		return
	for other_id: int in _state_machine.players:
		var p: Dictionary = _state_machine.players[other_id]
		if p.team_id == new_team_id and p.team_slot == new_slot:
			return
	# Don't promote into a slot held for a reconnecting player (see try_swap_slot).
	if _state_machine.is_slot_reserved(new_team_id, new_slot):
		return
	if _state_machine.count_players_on_team(new_team_id) >= _state_machine.team_size:
		return
	_spectator_peers.erase(peer_id)
	var is_local: bool = peer_id == NetworkManager.local_peer_id()
	if is_local and _is_local_spectator:
		# Host promoting itself: tear down the spectator camera before the
		# LocalController spawns its own camera.
		_teardown_spectator_camera()
	_spawn_player_and_broadcast(peer_id, new_team_id, new_slot,
			NetworkManager.get_peer_handedness(peer_id),
			NetworkManager.get_peer_name(peer_id),
			NetworkManager.get_peer_number(peer_id),
			is_local)


func _teardown_spectator_camera() -> void:
	if _camera_director != null:
		_camera_director.teardown()
		_camera_director = null
	if _is_local_spectator:
		_is_local_spectator = false
		local_spectator_state_changed.emit(false)


# ── Vote-to-skip (goal replay + intermission) ────────────────────────────────
# Rocket-League-style unanimous skip over one host-owned tally scoped to "the
# current skippable window": the goal cinematic, or the between-period break
# (reel or not). The window opening clears the tally; a vote adds the peer and
# broadcasts the count; unanimity runs the window's end action
# (_end_skip_window). Clients mirror by stopping their own driver when they
# receive (N, N). In offline / free-play the local player is the only voter,
# so a single press instantly resolves to (1, 1) → end.

# Which peers have voted to skip the current window. Host-authoritative;
# cleared at every window open (goal replay start, break entry).
var _skip_votes: Dictionary[int, bool] = {}

func _on_local_replay_started() -> void:
	_in_replay_locally = true
	# A goal cinematic (or intermission reel) is a fresh skippable window.
	_skip_votes.clear()
	# Reset HUD prompt immediately. On the host this is also the first
	# authoritative broadcast of the voter total so clients see (0/N) right
	# when their own driver starts.
	if NetworkManager.is_host:
		var total: int = _total_skip_voters()
		NetworkManager.notify_skip_replay_vote_to_all(0, total)
		skip_replay_vote_updated.emit(0, total)


func _on_local_replay_stopped() -> void:
	_in_replay_locally = false


func is_in_replay_locally() -> bool:
	return _in_replay_locally


# HUD entry point. Called from _unhandled_input when the player presses
# skip_replay during a skippable window: the goal cinematic, or any part of
# the between-period break (whose band is up whether or not a reel plays).
func request_local_skip_vote() -> void:
	if not _in_replay_locally and not is_period_break():
		return
	if NetworkManager.is_host:
		_register_skip_vote(NetworkManager.local_peer_id())
	else:
		NetworkManager.send_skip_replay_request()


func _on_remote_skip_replay_request(peer_id: int) -> void:
	_register_skip_vote(peer_id)


# Host-only: add the vote to the window tally, broadcast it, and end the
# window at unanimity. Late votes (window closed before the RPC landed) are
# dropped silently — broadcasting (0, total) would reset client HUDs that are
# already transitioning to FACEOFF. Bots aren't in connected_peer_ids() so
# they never count toward the total; spectators do (they have an ENet
# connection).
func _register_skip_vote(peer_id: int) -> void:
	if not NetworkManager.is_host or not _is_skip_window_open():
		return
	_skip_votes[peer_id] = true
	var current: int = _skip_votes.size()
	var total: int = _total_skip_voters()
	NetworkManager.notify_skip_replay_vote_to_all(current, total)
	skip_replay_vote_updated.emit(current, total)
	if current >= total:
		_end_skip_window()


func _is_skip_window_open() -> bool:
	if _goal_replay_driver != null and _goal_replay_driver.is_active():
		return true
	if _intermission_replay_driver != null and _intermission_replay_driver.is_active():
		return true
	return is_period_break()


# The unanimity action for whichever window is open. Stopping a driver runs
# its normal end flow (goal replay → post-goal advance via PhaseCoordinator;
# intermission reel → finish_period_break via reel_stopped); a reel-less
# break has no driver, so the break is finished directly.
func _end_skip_window() -> void:
	if _goal_replay_driver != null and _goal_replay_driver.is_active():
		_goal_replay_driver.stop()
		return
	if _intermission_replay_driver != null and _intermission_replay_driver.is_active():
		_intermission_replay_driver.stop()
		return
	if _state_machine != null and _state_machine.finish_period_break() \
			and _phase_coord != null:
		_phase_coord.handle_phase_entered()


# Client-side handler for the host's tally broadcast. Forwards to HUD via the
# local signal; on unanimity, also stops the local driver so every peer leaves
# the cinematic at the same wall-clock moment. stop() no-ops on whichever
# driver isn't running.
func _on_remote_skip_replay_vote(current: int, total: int) -> void:
	if NetworkManager.is_host:
		return  # host emits locally in _register_skip_vote
	skip_replay_vote_updated.emit(current, total)
	if total > 0 and current >= total:
		if _goal_replay_driver != null:
			_goal_replay_driver.stop()
		if _intermission_replay_driver != null:
			_intermission_replay_driver.stop()


func _total_skip_voters() -> int:
	return 1 + NetworkManager.connected_peer_ids().size()


# ── Replay file recording ────────────────────────────────────────────────────
# Opened once per game on every peer, after the registry has been populated
# from lobby assignments / sync_existing_players. Idempotent — safe to call
# repeatedly from both the host and client setup paths; the second call
# short-circuits.
func _open_replay_file_writer() -> void:
	if _replay_file_writer != null:
		return
	if _game_id.is_empty():
		return  # free play / tutorial / drill — see _game_id doc
	if not PlayerPrefs.replay_recording_enabled:
		return
	# Purge oldest first so the new file is never the one we delete next game.
	# keep_count - 1 because we're about to add a new file.
	ReplayFileIndex.purge_oldest(ReplayFileIndex.REPLAY_DIR,
			maxi(PlayerPrefs.replay_keep_count - 1, 0))
	var path: String = ReplayFileIndex.REPLAY_DIR.path_join(_game_id + ReplayFileIndex.REPLAY_EXT)
	var writer := ReplayFileWriter.new()
	if not writer.open(path, _build_replay_header()):
		return
	_replay_file_writer = writer
	_last_file_frame_ts = -INF


func _close_replay_file_writer() -> void:
	if _replay_file_writer == null:
		return
	_replay_file_writer.close_async(_build_replay_footer())
	_replay_file_writer = null


# Rematch path: close the current .mreplay (writes its footer with the
# previous game's final scores) and open a new one against new_game_id so
# the rematch lands in a separate file. Empty new_game_id (offline /
# tutorial / recording disabled) is a no-op — there's no writer to roll.
# Note: between the host's notify_reset_to_all and the client receiving
# it, a couple of post-reset world-state frames may land in the OLD file
# instead of the new one. They're recorded with reset state (0-0, period
# 1) and show up as a brief "score-reset glitch" at the very end of the
# old file's playback. Acceptable for v1; the alternative is throttling
# host broadcasts during rollover, which adds complexity for marginal
# benefit.
func _rollover_replay_file_to(new_game_id: String) -> void:
	if new_game_id.is_empty():
		return
	if not _is_valid_game_id(new_game_id):
		push_warning("rejected new_game_id: %s" % new_game_id)
		return
	_close_replay_file_writer()
	_last_recorded_phase = -1
	_game_id = new_game_id
	_open_replay_file_writer()


# Game IDs are UUIDs minted by PlayerPrefs.generate_uuid (hex + dashes). This
# guard runs on the path concatenation surface so a malicious host can't ship
# `../etc/passwd` via notify_game_reset and have a client write outside the
# replays folder. Belt-and-braces: the only legitimate source is already
# UUIDs, but the wire format permits arbitrary strings.
const _MAX_GAME_ID_LEN: int = 64
static func _is_valid_game_id(s: String) -> bool:
	if s.is_empty() or s.length() > _MAX_GAME_ID_LEN:
		return false
	for i: int in s.length():
		var c: String = s.substr(i, 1)
		if not (c >= "a" and c <= "z") \
				and not (c >= "A" and c <= "Z") \
				and not (c >= "0" and c <= "9") \
				and c != "-" and c != "_":
			return false
	return true


# Roster captured at game-start; mid-game joiners aren't in here but the viewer
# can still observe them appearing in later world-state packets.
func _build_replay_header() -> Dictionary:
	var roster: Array[Dictionary] = []
	if _registry != null:
		for peer_id: int in _registry.all():
			var r: PlayerRecord = _registry.get_record(peer_id)
			roster.append({
				"peer_id": peer_id,
				"player_name": r.player_name,
				"jersey_number": r.jersey_number,
				"team_id": r.team.team_id if r.team != null else 0,
				"team_slot": r.team_slot,
				"is_left_handed": r.is_left_handed,
				"is_local": peer_id == NetworkManager.local_peer_id(),
				# Build (height / weight / gear) so the viewer can re-apply the
				# player's attributes — otherwise replay skaters render at the
				# neutral frame and their re-derived lean/reach no longer matches
				# the host's lean-compensated blade positions (stick off the ice).
				"build": r.attributes.to_dict() if r.attributes != null else {},
			})
	return {
		"game_id": _game_id,
		"started_at": Time.get_unix_time_from_system(),
		"build_version": BuildInfo.VERSION,
		"num_periods": _state_machine.num_periods if _state_machine != null else GameRules.NUM_PERIODS,
		"period_duration": _state_machine.period_duration if _state_machine != null else GameRules.PERIOD_DURATION,
		"ot_enabled": _state_machine.ot_enabled if _state_machine != null else GameRules.OT_ENABLED,
		"rule_set": _state_machine.rule_set if _state_machine != null else GameRules.DEFAULT_RULE_SET,
		"team_size": _state_machine.team_size if _state_machine != null else GameRules.DEFAULT_TEAM_SIZE,
		"home_color_slot": NetworkManager.pending_home_color_slot,
		"away_color_slot": NetworkManager.pending_away_color_slot,
		"recorded_by_peer_id": NetworkManager.local_peer_id(),
		"roster": roster,
	}


func _build_replay_footer() -> Dictionary:
	var footer: Dictionary = {}
	if _state_machine != null:
		footer["final_score_home"] = _state_machine.scores[0]
		footer["final_score_away"] = _state_machine.scores[1]
		# Period-by-period scores, same shape the scoreboard / career screen use:
		# [[home p1, p2, …], [away p1, p2, …]]. Lets the local replay browser draw
		# the period breakdown without any backend.
		footer["period_scores"] = _state_machine.period_scores
	# Per-player box score, keyed by peer_id so the browser can join it to the
	# header roster for names. Every peer has all players' stats (the live
	# scoreboard renders from the same broadcast), so this is complete on any
	# recording peer. Mirrors career_stats columns minus the career-only fields.
	var players: Array[Dictionary] = []
	if _registry != null:
		for peer_id: int in _registry.all():
			var r: PlayerRecord = _registry.get_record(peer_id)
			if r == null or r.stats == null:
				continue
			players.append({
				"peer_id": peer_id,
				"team_id": r.team.team_id if r.team != null else 0,
				"goals": r.stats.goals,
				"assists": r.stats.assists,
				"shots_on_goal": r.stats.shots_on_goal,
				"hits": r.stats.hits,
				"shots_blocked": r.stats.shots_blocked,
				"hits_taken": r.stats.hits_taken,
				"takeaways": r.stats.takeaways,
				"giveaways": r.stats.giveaways,
				"faceoff_wins": r.stats.faceoff_wins,
				"faceoff_losses": r.stats.faceoff_losses,
				"toi_seconds": roundi(r.stats.toi_seconds),
			})
	footer["players"] = players
	# Shot log (analytics B1), so a .mreplay is SELF-CONTAINED for the post-game
	# analytics views — shot map, xG flow, and the advanced half of the tape all
	# regenerate from this without any backend. That matters most exactly where
	# the backend isn't available: stat sharing off, Steam signed out, or a game
	# that simply failed to upload. Host-only, like the Supabase batch.
	var shot_rows: Array = []
	if _advanced_stats_tracker != null:
		shot_rows = ShotEvent.encode_list(_advanced_stats_tracker.get_shot_events())
	footer["shot_events"] = shot_rows
	# Roster size, so the browser can badge the mode without the backend.
	footer["team_size"] = _state_machine.team_size if _state_machine != null else 0
	footer["ended_at"] = Time.get_unix_time_from_system()
	return footer


# Goals don't appear in the world-state packet (they're broadcast via the
# notify_goal RPC on a separate channel), so the viewer has no way to render
# the goal banner / jump-to-goal buttons unless we capture them as events
# alongside the frame stream. Fires on every peer when phase_coord re-emits
# goal_scored locally — host detects + emits, clients receive notify_goal +
# emit. JSON payload because goals are infrequent (~10/game) and the field
# set is small enough that the byte overhead doesn't matter.
func _on_goal_for_replay_event(scoring_team: Team, scorer: String,
		assist1: String, assist2: String) -> void:
	if _replay_file_writer == null or _state_machine == null:
		return
	var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
			else NetworkManager.estimated_host_time()
	var payload: PackedByteArray = JSON.stringify({
		"kind": "goal",
		"scoring_team_id": scoring_team.team_id,
		"score0": _state_machine.scores[0],
		"score1": _state_machine.scores[1],
		"period": _state_machine.current_period,
		"scorer": scorer,
		"assist1": assist1,
		"assist2": assist2,
	}).to_utf8_buffer()
	_replay_file_writer.enqueue_event(ts, payload)


# Record a period-end marker for the .mreplay viewer's timeline. END_OF_PERIOD
# marks a regulation period boundary (the buzzer point); GAME_OVER is the end of
# the bar and needs no tick. current_period at this edge is the period that just
# ended. Recorded on every peer, like goals.
func _on_phase_changed_for_replay_event(new_phase: GamePhase.Phase) -> void:
	if new_phase != GamePhase.Phase.END_OF_PERIOD:
		return
	if _replay_file_writer == null or _state_machine == null:
		return
	var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
			else NetworkManager.estimated_host_time()
	var payload: PackedByteArray = JSON.stringify({
		"kind": "period_end",
		"period": _state_machine.current_period,
	}).to_utf8_buffer()
	_replay_file_writer.enqueue_event(ts, payload)


# Roster events for the .mreplay viewer. Header captures the initial roster;
# these fire only for mid-game changes (joins, demotes, promotes,
# disconnects) so the viewer can spawn / despawn actors instead of leaving
# them stuck or invisible. _replay_file_writer is null during the initial
# registry-population pass (writer opens AFTER registry stabilizes), so the
# `if _replay_file_writer == null: return` guard naturally suppresses the
# initial spawns.
func _on_replay_player_joined_event(record: PlayerRecord) -> void:
	if _replay_file_writer == null:
		return
	var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
			else NetworkManager.estimated_host_time()
	var payload: PackedByteArray = JSON.stringify({
		"kind": "player_joined",
		"peer_id": record.peer_id,
		"player_name": record.player_name,
		"jersey_number": record.jersey_number,
		"team_id": record.team.team_id if record.team != null else 0,
		"team_slot": record.team_slot,
		"is_left_handed": record.is_left_handed,
		# Same build carry-through as the header roster — a mid-game arrival needs
		# its attributes re-applied so its lean/reach match too (see _build_replay_header).
		"build": record.attributes.to_dict() if record.attributes != null else {},
	}).to_utf8_buffer()
	_replay_file_writer.enqueue_event(ts, payload)


func _on_replay_player_left_event(record: PlayerRecord) -> void:
	if _replay_file_writer == null:
		return
	var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
			else NetworkManager.estimated_host_time()
	var payload: PackedByteArray = JSON.stringify({
		"kind": "player_left",
		"peer_id": record.peer_id,
	}).to_utf8_buffer()
	_replay_file_writer.enqueue_event(ts, payload)


# Common path shared by every host-side player-spawn site:
#   - register the slot in the state machine
#   - send_slot_assignment to the joining peer (skipped if the peer is the
#     local host, who already has its slot)
#   - broadcast spawn_remote_skater to all peers (handler short-circuits
#     for the local peer) — unless `broadcast` is false
#   - _registry.spawn locally
#
# `broadcast` defaults true (mid-game join, where existing clients learn the
# new peer only through this broadcast). The game-start lobby push passes false
# because it fans the full roster out through a single sync_existing_players
# instead — broadcasting there would double-deliver and orphan phantom skaters.
#
# Returns the resolved colors dict so callers can reuse it for adjacent
# bookkeeping. Adjacent RPCs that vary by call site (send_join_in_progress,
# send_sync_existing_players, spectator-camera teardown) stay inline at
# the caller — this helper owns only the shared shape.
func _spawn_player_and_broadcast(peer_id: int, team_id: int, team_slot: int,
		is_left: bool, p_name: String, p_number: int, is_local: bool,
		broadcast: bool = true) -> Dictionary:
	var team: Team = teams[team_id]
	var colors: Dictionary = TeamColorRegistry.get_colors(team.color_slot, team_id)
	var attrs: PlayerAttributes = NetworkManager.get_peer_attributes(peer_id)
	_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
	if not is_local:
		NetworkManager.send_slot_assignment(peer_id, team_slot, team_id,
				colors.jersey, colors.helmet, colors.pants)
	if broadcast:
		NetworkManager.send_spawn_remote_skater(peer_id, team_slot, team_id,
				colors.jersey, colors.helmet, colors.pants, is_left, p_name, p_number, attrs)
	_registry.spawn(peer_id, team_slot, team,
			colors.jersey, colors.helmet, colors.pants,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe,
			colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			is_left, p_name, is_local, p_number, attrs)
	return colors


func _spawn_local(peer_id: int, team_slot: int, team: Team) -> void:
	var colors: Dictionary = TeamColorRegistry.get_colors(team.color_slot, team.team_id)
	_registry.spawn(peer_id, team_slot, team,
			colors.jersey, colors.helmet, colors.pants,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			NetworkManager.local_is_left_handed, NetworkManager.local_player_name, true,
			NetworkManager.local_jersey_number,
			NetworkManager.get_peer_attributes(peer_id))


# ── Spawn wire-up (callback invoked by PlayerRegistry after spawn) ───────────
func _on_player_spawned(record: PlayerRecord) -> void:
	# Machine-authority flags for the body-check transfer gate (Lever D). Set once
	# here where the registry record + NetworkManager are in scope, so Skater never
	# reaches into an autoload itself.
	record.skater.is_host_machine = NetworkManager.is_host
	record.skater.is_local_skater = record.is_local
	# Analytic skater-vs-goalie body block (move_and_slide is gone) reads the same
	# host-refreshed goalie pose cache the blade clamp uses. get_goalie_data returns
	# empty until goalies exist (tutorial dummy / test), so the block no-ops there.
	record.skater.set_goalie_data_provider(get_goalie_data)
	if record.is_local:
		var local_ctrl: LocalController = record.controller as LocalController
		local_ctrl.set_goal_context(
				teams[0].defended_goal, teams[1].defended_goal, _get_puck_carrier_team_id)
		local_ctrl.puck_release_requested.connect(_on_puck_release_requested)
		local_ctrl.nudge_requested.connect(_on_nudge_requested)
		local_ctrl.hit_received.connect(func(impulse: Vector3) -> void:
			local_player_hit.emit(impulse.length())
			# Victim Δv scale (m/s), the same magnitude the stagger keys off:
			# ~0.6 stagger floor, ~1.35 a full check, ~1.8 a knockdown, up to ~3.1
			# maximal (BodyCheckRules). Kick the camera along the shove, from nothing
			# at a sub-stagger bump up to full by a knockdown. The old 5.0/11 floor
			# predated the inelastic-resolver rewrite (Δv shrank ~2×) and never fired.
			local_player_impact.emit(impulse, clampf((impulse.length() - 0.6) / 1.5, 0.0, 1.0)))
		NetworkManager.set_input_batch_provider(local_ctrl.get_input_batch)
		# Historical positions of the OTHER skaters for the reconcile replay's
		# body-check re-resolution (Slice C) — sampled from each remote's
		# interpolation buffer at the replayed input's host timestamp.
		local_ctrl.set_historical_others_provider(_sample_historical_others)
	# AI bots release shots through the same signal as humans, but they live
	# only on the host (record.is_local is false). Without this connection
	# the wrister state machine transitions to FOLLOW_THROUGH but the puck
	# never leaves the blade — _do_release emits puck_release_requested
	# into the void.
	if record.is_bot:
		record.controller.puck_release_requested.connect(_on_puck_release_requested)
		record.controller.nudge_requested.connect(_on_nudge_requested)
	# Remote human on the host: its RemoteController runs the shot state machine from
	# the replayed input stream and computes a host-derived shot, emitting
	# puck_release_requested. This is the ONLY path that fires a remote human's shot —
	# there is no shot RPC; the host derives and fires it from the inputs it replays.
	if NetworkManager.is_host and not record.is_local and not record.is_bot:
		# Shot Power Sensitivity the client sent at join — the host fires this
		# player's wrister at the same power their own client predicted.
		record.controller.net_shot_power_sensitivity = \
				NetworkManager.get_peer_shot_sensitivity(record.peer_id)
		record.controller.puck_release_requested.connect(
				_on_remote_derived_release.bind(record.peer_id))
		record.controller.nudge_requested.connect(
				_on_remote_derived_nudge.bind(record.peer_id))
	# Deflection one-timer (release without possession) is a contested, lag-comp-
	# arbitrated CLAIM — like pickup/poke — not a possessed shot, so for a remote human
	# it fires ONLY via on_remote_one_timer_release (the RPC rewinds the puck for the
	# range check). Connect the sim-emit firing only for the local player (whose client
	# branch sends that claim RPC) and bots (host-local, no lag-comp needed). Connecting
	# remote controllers here made the host ALSO fire from its live-puck sim emit — no
	# lag-comp, and an intermittent double with the RPC.
	if record.is_local or record.is_bot:
		record.controller.one_timer_release_requested.connect(
				_on_one_timer_release_requested.bind(record.skater))
	var pid: int = record.peer_id
	record.skater.body_checked_player.connect(
		func(v: Skater, f: float, d: Vector3) -> void: _on_hit_landed(pid, v, f, d)
	)
	# Impact burst + sound + replay recording are NOT driven here — they fire from
	# the host-authoritative body_check_landed broadcast (_on_body_check_landed)
	# once the contact validates (HitTracker.impact_landed), so they read
	# identically on every client AND the replay captures only the credited,
	# deduped hits that actually played (not this raw per-contact signal). This
	# closure only routes the contact into the credit/claim path
	# (_on_hit_landed → HitClaimResolver).
	if NetworkManager.is_host:
		# NHL delayed offside: any skater-skater contact can end it (Rule 83.3),
		# not just a puck touch — see notify_offside_contact. Host-only: the host
		# simulates every skater, so this fires reliably for any pair regardless
		# of who's local, unlike prediction-only contact events.
		record.skater.body_checked_player.connect(
			func(v: Skater, _f: float, _d: Vector3) -> void:
				_on_skater_contact_for_offside(pid, v)
		)
	var snd := SkaterSoundController.new()
	record.skater.add_child(snd)
	snd.setup(record.skater)


func _on_registry_player_added(record: PlayerRecord) -> void:
	stats_updated.emit()
	if NetworkManager.is_host:
		_sync_stats_to_clients()
	if _state_buffer_manager != null:
		_state_buffer_manager.add_player(record.peer_id)
	_refresh_ranked_match()


# Populates per-frame AI caches on the live snapshot — a per-team peer-id
# roster + closest-teammate-to-puck. Bots and brains read these instead of
# re-partitioning `snapshot.skater_states` and re-scanning for the closest
# teammate every tick. Called once per host physics frame; lag-comp rewind
# snapshots are NOT enriched (they don't feed AI).
func _enrich_snapshot_for_ai(snap: WorldSnapshot) -> void:
	snap.teammate_ids_by_team.clear()
	snap.closest_to_puck_by_team.clear()
	if _registry == null:
		return
	var team_map: Dictionary = _registry.team_id_by_peer
	for pid: int in snap.skater_states:
		var team_id: int = team_map.get(pid, -1)
		if team_id == -1:
			continue
		if not snap.teammate_ids_by_team.has(team_id):
			snap.teammate_ids_by_team[team_id] = []
		var ids: Array = snap.teammate_ids_by_team[team_id]
		ids.append(pid)
	if snap.puck_state == null:
		return
	var puck_pos: Vector3 = snap.puck_state.position
	var puck_vel: Vector3 = snap.puck_state.velocity
	# A locked loose puck is DEAD — a goalie smother (COVERING hold) or a phase
	# lock (faceoff prep / celebration). Publishing a -1 election makes every
	# bot exit/skip CHASE_PUCK and play its positional role instead of crowding
	# a puck nothing can touch; the next enrichment after the release/unlock
	# elects a fresh chaser immediately.
	var puck_playable: bool = not (puck != null and puck.pickup_locked \
			and puck.get_carrier() == null)
	for team_id: int in snap.teammate_ids_by_team:
		var ids: Array = snap.teammate_ids_by_team[team_id]
		# Election-side eligibility (see AILoosePuckChase.elect): humans
		# can't be assigned by an election (they only suppress the bots
		# while demonstrably playing the puck), and a one-timer camper has
		# opted out of loose-puck work (its camp veto would refuse the
		# chase while nobody else was elected — the frozen-team pickup).
		var human_ids: Array = []
		var camped_ids: Array = []
		var brain: TeamBrain = team_brains[team_id] \
				if team_id >= 0 and team_id < team_brains.size() else null
		for pid: int in ids:
			var rec: PlayerRecord = _registry.get_record(pid)
			if rec != null and not rec.is_bot:
				human_ids.append(pid)
			elif brain != null and brain.is_one_timer_ready(pid):
				camped_ids.append(pid)
		# Momentum-aware + hysteretic election (see AILoosePuckChase):
		# the teammate who actually arrives first keeps the role unless
		# a challenger clearly beats them, instead of the raw-nearest bot
		# flickering frame-to-frame.
		var best_pid: int = AILoosePuckChase.elect(
				snap.skater_states, ids, puck_pos, puck_vel,
				_prev_chase_by_team.get(team_id, -1), _registry.caps_by_peer,
				puck_playable, human_ids, camped_ids)
		# Smart-ping GET_PUCK: a live retrieval order replaces the natural
		# election for its duration — the ordered bot chases (the state
		# machine's decline gates are bypassed for it too) and nobody else
		# doubles up on the puck.
		if puck_playable and team_id >= 0 and team_id < team_brains.size():
			var pinged_chaser: int = team_brains[team_id].ping_chase_peer()
			if pinged_chaser != -1 and ids.has(pinged_chaser):
				best_pid = pinged_chaser
		_prev_chase_by_team[team_id] = best_pid
		snap.closest_to_puck_by_team[team_id] = best_pid


# ── Puck / Puck controller signal handlers ───────────────────────────────────
func _resolve_skater_team_id(skater: Skater) -> int:
	return _registry.resolve_team_id(skater) if _registry != null else -1


func _get_puck_carrier_team_id() -> int:
	if puck_controller != null:
		var local_carrier: Skater = puck_controller.get_local_carrier()
		if local_carrier != null:
			return _resolve_skater_team_id(local_carrier)
	if puck != null:
		var carrier: Skater = puck.get_carrier()
		if carrier != null:
			return _resolve_skater_team_id(carrier)
	return -1


func _resolve_skater_peer_id(skater: Skater) -> int:
	return _registry.resolve_peer_id(skater) if _registry != null else -1


func _on_server_puck_picked_up_by(peer_id: int) -> void:
	# clear_for_grant, not clear(): if a different peer's claim was pending,
	# NACK it so their optimistic pin rolls back now (covers every
	# authoritative grant path, including the one-timer catch).
	_pickup_claim.clear_for_grant(peer_id)
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null:
		return
	# Read the phase BEFORE on_pickup transitions FACEOFF -> PLAYING, so the
	# tracker knows this pickup won the draw.
	var was_faceoff: bool = _state_machine != null \
			and _state_machine.current_phase == GamePhase.Phase.FACEOFF
	_shot_tracker.on_pickup(peer_id)
	# Carrying again — a hit landing now must wait for a FRESH possession loss,
	# not credit off the stale just-released grace from their last touch.
	if _hit_tracker != null:
		_hit_tracker.note_possession_gained(peer_id)
	_phase_coord.on_pickup(peer_id)
	# Compute the turnover/faceoff candidate now (context is freshest at the
	# pickup) — the stat credits later, when this carrier ESTABLISHES
	# possession (_on_possession_established). Scramble touches credit nothing.
	if _turnover_tracker != null:
		_turnover_tracker.on_carrier_gained(peer_id, was_faceoff)
	if _possession_tracker != null:
		_possession_tracker.on_pickup(peer_id)
	record.controller.on_puck_picked_up_network()
	if not record.is_local:
		NetworkManager.send_puck_picked_up(peer_id)
	NetworkManager.send_carrier_changed_to_all(peer_id)
	# NHL delayed-offside: pickup by an offending-team attacker whistles the
	# play dead. Consume immediately so the faceoff fires before the next
	# physics frame.
	_state_machine.notify_puck_touch(peer_id)
	_consume_pending_faceoff()
	# Carrier just changed — force both team brains to recompute
	# possession state + role assignments on the next physics frame
	# instead of waiting up to TeamBrain.TICK_PERIOD (~166 ms). The
	# natural cadence is fine for steady-state, but a pickup flips
	# both teams' possession state and the previous-carrier-team's
	# CARRIER slot is now stale.
	_force_retick_team_brains()


func _on_ghost_state_received(peer_id: int, is_ghost: bool) -> void:
	if _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null or record.is_local:
		return
	(record.controller as RemoteController).apply_ghost_rpc(is_ghost)


# Client: host NACK'd our pickup claim — roll the optimistic pin back now.
func _on_pickup_claim_rejected() -> void:
	if puck_controller != null:
		puck_controller.notify_claim_rejected()


func _on_pickup_claim_received(peer_id: int, host_timestamp: float, interp_delay_ms: float,
		input_lead_ms: float, blade_curr: Vector3, blade_prev: Vector3, top_hand: Vector3) -> void:
	if not NetworkManager.is_host:
		return
	_pickup_claim.receive_claim(peer_id, host_timestamp, interp_delay_ms, input_lead_ms,
			blade_curr, blade_prev, top_hand)


func _on_poke_claim_received(peer_id: int, host_timestamp: float, interp_delay_ms: float,
		input_lead_ms: float, expected_carrier_peer_id: int, blade_curr: Vector3, blade_prev: Vector3) -> void:
	if not NetworkManager.is_host:
		return
	_poke_claim.receive_claim(peer_id, host_timestamp, interp_delay_ms, input_lead_ms,
			expected_carrier_peer_id, blade_curr, blade_prev)


func _on_stick_lift_claim_received(peer_id: int, host_timestamp: float, interp_delay_ms: float,
		input_lead_ms: float, expected_carrier_peer_id: int, blade_curr: Vector3) -> void:
	if not NetworkManager.is_host:
		return
	_stick_lift_claim.receive_claim(peer_id, host_timestamp, interp_delay_ms, input_lead_ms,
			expected_carrier_peer_id, blade_curr)


func _on_server_puck_released_by_carrier(peer_id: int) -> void:
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null:
		return
	# Deliberate release (pass/shot) — a pending body check on this carrier
	# did NOT dispossess them (they played through it), so it cancels; the
	# just-released grace still starts so a check finishing through the
	# release credits (see HitTracker). Involuntary losses arrive via
	# _on_server_puck_stripped_from, which runs first on a strip. Gated to
	# live play: a whistle drop() also lands here, and arming the grace off
	# it would score a post-whistle shove as a finished check.
	if _hit_tracker != null and _state_machine != null \
			and _state_machine.current_phase == GamePhase.Phase.PLAYING:
		_hit_tracker.note_possession_released(peer_id)
	# A non-shot release with no teammate in its flight corridor is a dump / clear
	# / rim, not a pass — mark the dump window so recovering it reads as a
	# concession, not a giveaway (mirrors the shot window). Gated to live play (a
	# whistle drop lands here too); shots already opened the window via note_shot,
	# so skip when a shot is pending to keep the pass/dump geometry off them.
	if _turnover_tracker != null and _state_machine != null \
			and _state_machine.current_phase == GamePhase.Phase.PLAYING \
			and (_shot_tracker == null or not _shot_tracker.has_pending_shot()) \
			and _is_dump_release(peer_id):
		_turnover_tracker.note_dump(peer_id)
	if _possession_tracker != null:
		_possession_tracker.on_puck_lost(peer_id)
	record.controller.on_puck_released_network()
	NetworkManager.send_carrier_changed_to_all(-1)
	# Carrier released — possession state likely flips (TRANS_DO →
	# NEUTRAL or TRANS_DO → TRANS_OD on a steal). See pickup hook
	# for rationale.
	_force_retick_team_brains()


# Host: was `peer_id`'s just-fired non-shot release a dump/clear/rim (no teammate
# positioned to receive) rather than a pass? Reads the puck's queued launch and
# the releaser's teammates' positions; the pure geometry is TurnoverRules. Runs
# on a release event (not the hot per-tick path), so the small teammate gather is
# fine. get_release_velocity (not linear_velocity) — release() queues the launch
# for the next drive step, so linear_velocity reads ~zero in this same-frame window.
func _is_dump_release(peer_id: int) -> bool:
	if puck == null or _registry == null:
		return false
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.team == null:
		return false
	var vel: Vector3 = puck.get_release_velocity()
	var launch_dir: Vector2 = Vector2(vel.x, vel.z)
	if launch_dir.length() < 0.001:
		return false
	var launch_pos: Vector3 = puck.get_puck_position()
	var launch: Vector2 = Vector2(launch_pos.x, launch_pos.z)
	var team_id: int = record.team.team_id
	var teammates: Array[Vector2] = []
	for pid: int in _registry.all():
		if pid == peer_id:
			continue
		var r: PlayerRecord = _registry.get_record(pid)
		if r == null or r.team == null or r.team.team_id != team_id or r.skater == null:
			continue
		var pos: Vector3 = r.skater.global_position
		teammates.append(Vector2(pos.x, pos.z))
	return TurnoverRules.is_dump_release(launch, launch_dir, teammates)


# Forces both team brains to re-evaluate possession state + role
# assignments on the next physics frame, bypassing the natural
# TeamBrain.TICK_PERIOD rate-limit. Called from the puck pickup /
# release hooks where the carrier change makes the current role
# assignment immediately stale. Both teams re-tick because a carrier
# change affects both possession states symmetrically.
func _force_retick_team_brains() -> void:
	for brain: TeamBrain in team_brains:
		brain.force_retick()


func _on_server_puck_stripped_from(peer_id: int, stripper_peer_id: int) -> void:
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null:
		return
	# Dispossessed — resolves any pending body check on this carrier into a
	# credited hit (the strip path a check-knocked-loose puck goes through).
	if _hit_tracker != null:
		_hit_tracker.note_possession_stripped(peer_id)
	# The takeaway credits the defender who made the play (stripper), not
	# whoever recovers the loose puck. -1 (goalie strip) credits nobody.
	if _turnover_tracker != null:
		_turnover_tracker.note_strip(peer_id, stripper_peer_id)
	if _possession_tracker != null:
		_possession_tracker.on_puck_lost(peer_id)
	_state_machine.notify_icing_contact()
	if not record.is_local:
		# Tell the victim's client whether this was a stick lift so it can pop
		# their own blade up locally (their prediction never saw the host force).
		NetworkManager.send_puck_stolen(peer_id, puck_controller.is_processing_stick_lift())


# Host: a defender poke-checked the carrier. Record the poker as the most recent
# toucher so a puck poked straight off the carrier's stick into the net is
# credited to the poker (get_last_toucher) rather than resolving to the victim
# as an own goal. The shot tracker flags it a poke so it never earns an assist.
func _on_server_puck_poke_checked_by(peer_id: int) -> void:
	if _shot_tracker != null:
		_shot_tracker.on_poke_check(peer_id)


# Host: the carrier ESTABLISHED possession (held it, or made a deliberate
# play) — land the stat credits that key off establishment: the pending
# turnover / faceoff win, and the assist-chain possession upgrade.
func _on_possession_established(peer_id: int, team_id: int) -> void:
	if _shot_tracker != null:
		_shot_tracker.on_possession_established(peer_id)
	# Sync immediately when a turnover/faceoff stat lands so the HUD stat feed
	# (and client scoreboards) see it now, not on the next unrelated stat event.
	if _turnover_tracker != null \
			and _turnover_tracker.on_possession_established(peer_id):
		_sync_stats_to_clients()
	# NHL/ARCADE offside: the defending team ESTABLISHING possession (this
	# same signal — held it or made a deliberate play, not a raw touch) voids
	# an active offside in their own zone. Reuses the identical "control"
	# standard stat attribution already uses rather than a looser one keyed
	# off a bare puck.carrier assignment.
	if _state_machine != null and puck != null:
		_state_machine.notify_possession_established(team_id, puck.global_position.z)
		_consume_pending_faceoff()


# Host: a goal ends any still-unresolved draw scramble — the draw goes to the
# scoring team (they won the scramble emphatically). Clients no-op: their
# trackers are never fed, so has_pending_faceoff is always false there.
func _on_goal_resolve_faceoff(scoring_team: Team,
		_scorer: String, _assist1: String, _assist2: String) -> void:
	if not NetworkManager.is_host:
		return
	if _turnover_tracker != null \
			and _turnover_tracker.resolve_pending_faceoff(scoring_team.team_id):
		_sync_stats_to_clients()
	# Post-goal play restarts at a faceoff — neutral possession.
	if _possession_tracker != null:
		_possession_tracker.reset()


func _on_server_puck_touched_while_loose(peer_id: int) -> void:
	# A loose-puck touch during FACEOFF (deflect / body redirect) makes the puck
	# live — end the faceoff so a goal off the deflection counts (see P2-2).
	_phase_coord.on_puck_touched_live()
	_state_machine.notify_icing_contact()
	# Deflection or body-block by an offending-team attacker also counts as a
	# touch that whistles a delayed offside.
	_state_machine.notify_puck_touch(peer_id)
	_consume_pending_faceoff()
	if _shot_tracker.on_block(peer_id):
		_sync_stats_to_clients()
		return
	_shot_tracker.on_deflection(peer_id)
	# The deflect/body-block handlers set the puck's redirected velocity before
	# emitting, so this reads the NEW flight — a tip can put a wide shot on net
	# (or take an on-net shot wide).
	_note_shot_trajectory()


func _on_puck_touched_by_goalie(goalie: Goalie) -> void:
	if not NetworkManager.is_host:
		return
	var defending_team_id: int = _defending_team_id_for_goalie(goalie)
	_shot_tracker.on_goalie_touch(defending_team_id)
	_sync_stats_to_clients()


func _defending_team_id_for_goalie(goalie: Goalie) -> int:
	for team: Team in teams:
		if team.goalie_controller != null and team.goalie_controller.goalie == goalie:
			return team.team_id
	return -1


# ── Puck release / one-timer ─────────────────────────────────────────────────
func _on_puck_release_requested(direction: Vector3, power: float, is_slapper: bool) -> void:
	var sound: SoundManager.Sound = SoundManager.Sound.SHOT_SLAPPER if is_slapper else SoundManager.Sound.SHOT_WRISTER
	SoundManager.play_world(sound, puck.get_puck_position(), 0.0, 0.04)
	if NetworkManager.is_host:
		_record_replay_audio_event("shot", puck.get_puck_position(), power, {"is_slapper": is_slapper})
	if NetworkManager.is_host:
		# Host-local (or bot) shot: every client needs the cue. No shooter to
		# exclude — the host already played it locally above.
		NetworkManager.send_shot_to_all(puck.get_puck_position(), is_slapper)
		_start_pending_shot_from_carrier()
		puck.release(direction, power)
		_note_shot_trajectory()
	else:
		var record := _registry.get_local()
		if record != null:
			record.controller.on_puck_released_network()
		# Seed local puck prediction only. The host fires the authoritative shot from
		# THIS client's input-stream release (host-derived, _on_remote_derived_release),
		# so there is no shot RPC — the inputs the host already replays carry it.
		puck_controller.notify_local_release(direction, power)


# Nudge (self-tap nutmeg setup). Mirrors the shot-release split — host fires the
# authoritative tap, a client seeds local puck prediction — but it is NOT a
# shot: no shot-on-goal tracking, no shot RPC, and a soft stick-lift cue rather
# than a wrister/slapper crack. The host re-derives a remote player's nudge from
# the replayed input stream via _on_remote_derived_nudge (no RPC), same as shots.
func _on_nudge_requested(velocity: Vector3) -> void:
	# The actor's own machine plays the cue immediately (this runs on the local
	# player's client, or on the host for a host-local player / bot).
	_play_nudge_cue(puck.get_puck_position())
	if NetworkManager.is_host:
		puck.nudge(velocity)
		var pos: Vector3 = puck.get_puck_position()
		_record_replay_audio_event("nudge", pos, velocity.length())
		# Fan the cue to the clients — this host/bot already played it locally.
		NetworkManager.send_nudge_to_all(pos)
	else:
		var record := _registry.get_local()
		if record != null:
			record.controller.on_puck_released_network()
		puck_controller.notify_local_nudge(velocity)


# Host-side authoritative nudge derived from a remote player's replayed input.
# The velocity arrives computed from the host's authoritative skater state (the
# controller emitted it during live remote-input processing), so it's used
# directly — no client trust. Guards mirror _on_remote_derived_release.
func _on_remote_derived_nudge(velocity: Vector3, nudger_peer_id: int) -> void:
	if not NetworkManager.is_host:
		return
	if puck == null or _registry == null or puck.carrier == null:
		return
	var record: PlayerRecord = _registry.get_record(nudger_peer_id)
	if record == null or record.skater == null:
		return
	if _registry.resolve_peer_id(puck.carrier) != nudger_peer_id:
		return
	puck.nudge(velocity)
	var pos: Vector3 = puck.get_puck_position()
	# The host plays the remote player's nudge, and every OTHER client hears it —
	# the nudger already played it locally the instant they tapped.
	_play_nudge_cue(pos)
	_record_replay_audio_event("nudge", pos, velocity.length())
	NetworkManager.send_nudge_to_all(pos, nudger_peer_id)


# Single nudge cue path so the sound/VFX stays identical for everyone (local
# play, host fan-out, and remote receivers all route here). Uses the quick-shot
# (wrister) sound — a nudge is a soft self-pass — at a reduced fixed volume so it
# reads as a quiet tap rather than a real shot.
func _play_nudge_cue(pos: Vector3) -> void:
	SoundManager.play_world(SoundManager.Sound.SHOT_WRISTER, pos, -6.0, 0.04)
	if puck != null:
		puck.fire_stick_lift_vfx()


func _on_one_timer_release_requested(direction: Vector3, power: float, skater: Skater) -> void:
	# One-timers are always slappers (release_slapper at full charge); record the
	# shot sound + replay event here so the goal-replay driver can find the last
	# "shot" event when scanning the clip — otherwise the slo-mo trims back to
	# the start of the play instead of the moment of release.
	SoundManager.play_world(SoundManager.Sound.SHOT_SLAPPER, puck.get_puck_position(), 0.0, 0.04)
	if NetworkManager.is_host:
		_record_replay_audio_event("shot", puck.get_puck_position(), power, {"is_slapper": true})
	if not NetworkManager.is_host:
		# Client path: seed local puck prediction, then tell the host.
		var origin: Vector3 = puck.get_puck_position()
		if puck_controller != null:
			var record := _registry.get_local()
			if record != null:
				origin = puck_controller.notify_local_release(direction, power)
		NetworkManager.send_one_timer_release(direction, power, origin)
		return
	# Host's own one-timer: shooter is local, no client-view rewind needed.
	# rtt_ms=0 short-circuits the goalie rewind branch entirely; ZERO origin is unused.
	NetworkManager.send_shot_to_all(puck.get_puck_position(), true)
	_host_release_one_timer(direction, power, skater, 0.0, 0.0, 0.0, Vector3.ZERO)


# direction is kept as a fallback only (used if the host's own locked aim is
# degenerate); _power is unused — the host always derives power itself (still on
# the wire to avoid a PROTOCOL_VERSION bump for no saving).
func on_remote_one_timer_release(direction: Vector3, _power: float, peer_id: int,
		host_timestamp: float, rtt_ms: float, interp_delay_ms: float, client_origin: Vector3) -> void:
	if not NetworkManager.is_host or puck == null or _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null:
		return
	# Host-side eligibility gate (ShotReleaseRules). The client already checked
	# locally, so a rejection here is either a forged RPC or a race (the puck
	# was picked up / the phase locked just before this landed) — silently
	# dropping is correct for both. Without these checks a client could fire
	# `release_puck_one_timer` at any moment and `puck.set_carrier` would
	# teleport the puck off anyone's stick to the shooter's blade.
	if puck.carrier != null or puck.pickup_locked or is_movement_locked() or record.skater.is_ghost:
		return
	var controller: SkaterController = record.controller
	var safe_rtt_ms: float = ShotReleaseRules.clamp_rtt_ms(
			rtt_ms, float(NetworkManager.get_peer_ping_ms(peer_id)))
	# Range gate against the puck the shooter saw — puck_view_time: the loose
	# puck renders predicted at ~host present, so the rewind reads the claim
	# stamp itself; live puck when the stamp is stale. This is the ONLY part of
	# the one-timer the client gets a say in — "did I connect with the puck I
	# saw" — and it stays lag-comped. The shot itself (below) is host-derived.
	# Anti-cheat: bound the self-reported render delay against the measured link
	# before any rewind reads it (see LagCompRewind.plausible_interp_delay_ms).
	interp_delay_ms = LagCompRewind.plausible_interp_delay_ms(
			interp_delay_ms, float(NetworkManager.get_peer_ping_ms(peer_id)))
	var now: float = NetworkManager.estimated_host_time()
	var view_puck_pos: Vector3 = puck.get_puck_position()
	if _state_buffer_manager != null and _state_buffer_manager.is_ready() \
			and ShotReleaseRules.is_timestamp_fresh(now, host_timestamp):
		var snap: WorldSnapshot = _state_buffer_manager.get_state_at(
				LagCompRewind.puck_view_time(host_timestamp))
		if snap != null and snap.puck_state != null:
			view_puck_pos = snap.puck_state.position
	var zone_world: Vector3 = record.skater.get_slapper_zone_global_position()
	var zone_xz := Vector2(zone_world.x, zone_world.z)
	var view_puck_xz := Vector2(view_puck_pos.x, view_puck_pos.z)
	var puck_speed: float = Vector2(puck.linear_velocity.x, puck.linear_velocity.z).length()
	if not ShotReleaseRules.one_timer_in_range(
			zone_xz, view_puck_xz,
			controller.slapper_zone_radius, puck_speed, controller.one_timer_leniency_time):
		return
	# HOST-AUTHORITATIVE direction: fire along the shooter's OWN locked slapper aim,
	# which the host's RemoteController derived from the replayed wind-up — not the
	# client-sent vector. Fall back to the (sanitized) client direction only if the
	# host lock is degenerate (e.g. a snap release on a fast link before the input
	# stream delivered the press).
	var locked: Vector2 = controller.get_locked_slapper_dir()
	var safe_direction: Vector3 = ShotReleaseRules.sanitize_direction(Vector3(locked.x, 0.0, locked.y))
	if safe_direction == Vector3.ZERO:
		safe_direction = ShotReleaseRules.sanitize_direction(direction)
		if safe_direction == Vector3.ZERO:
			return
	# HOST-AUTHORITATIVE power: the shooter's max slapper power with the center bonus
	# from the REWOUND puck the host arbitrated against — same formula the client
	# predicted with, but off the host's puck read. Clamp as defense-in-depth.
	var safe_power: float = ShotReleaseRules.clamp_power(
			ShotReleaseRules.one_timer_power(controller.max_slapper_power,
					controller.one_timer_center_power_bonus, zone_xz, view_puck_xz, controller.slapper_zone_radius),
			controller.max_slapper_power * (1.0 + controller.one_timer_center_power_bonus))
	# Sound/replay event below the validation so a rejected RPC can't spam
	# phantom shot sounds (mirrors _fire_remote_shot).
	var shot_pos: Vector3 = puck.get_puck_position()
	SoundManager.play_world(SoundManager.Sound.SHOT_SLAPPER, shot_pos, 0.0, 0.04)
	_record_replay_audio_event("shot", shot_pos, safe_power, {"is_slapper": true})
	# Fan the cue out to the other clients (the shooter already played it locally).
	NetworkManager.send_shot_to_all(shot_pos, true, peer_id)
	_host_release_one_timer(safe_direction, safe_power, record.skater, host_timestamp, safe_rtt_ms, interp_delay_ms, client_origin)


func _host_release_one_timer(direction: Vector3, power: float, skater: Skater,
		host_timestamp: float, rtt_ms: float, interp_delay_ms: float, client_origin: Vector3) -> void:
	# A one-timer is a possession-less engagement — if it fires during FACEOFF it
	# makes the puck live, so end the faceoff or the resulting goal is voided (P2-2).
	_phase_coord.on_puck_touched_live()
	var pid: int = _registry.resolve_peer_id(skater)
	# One-timers skip the normal pickup flow, so the shooter is never recorded
	# in the carrier history. Record them as a deflection (the shooter redirects
	# a moving puck without possessing it) so goal attribution and assist credit
	# work — without this, get_last_toucher() returns the passer at goal time.
	_shot_tracker.on_deflection(pid)
	_shot_tracker.on_shot_started(pid, true)  # one-timer tag → One-Timer achievement
	# Lag-comp the goalie reaction trigger (see _fire_remote_shot for the
	# full rationale). One-timers go through the same RPC-back-date flow.
	# clamp_back_date also zeroes the host's own path (host_timestamp = 0 →
	# stale → 0) — previously that computed `now - 0` and back-dated the goalie
	# by the whole session on every host one-timer.
	var release_back_date: float = ShotReleaseRules.clamp_back_date(
			NetworkManager.estimated_host_time(), host_timestamp)
	for gc: GoalieController in goalie_controllers:
		gc.set_pending_reaction_back_date(release_back_date)
	var saved_goalie_positions: Array[Vector3] = []
	var saved_goalie_rotations: Array[float] = []
	var rewound_origin: Vector3 = Vector3.ZERO
	var have_rewound_origin: bool = false
	if rtt_ms > 0.0 and skater != null:
		# Shot ORIGIN (SELF view) — see _fire_remote_shot for the full
		# rationale. Fire the one-timer from the redirect point the client sent,
		# clamped to the shooter's stick reach, not from where the blade drifted
		# to during RPC transit.
		rewound_origin = ShotReleaseRules.clamp_origin(client_origin, skater.global_position)
		have_rewound_origin = true
	if _state_buffer_manager != null and _state_buffer_manager.is_ready() and rtt_ms > 0.0 \
			and ShotReleaseRules.is_timestamp_fresh(NetworkManager.estimated_host_time(), host_timestamp):
		# Goalie was REMOTE-view from the shooter — clients render the goalie
		# from buffered host snapshots at host_time - interp_delay, so the
		# shooter saw the goalie at that earlier moment. Rewind to that snapshot
		# for fair puck/goalie geometry at the release. See LagCompRewind.
		# Anti-cheat: delay bounded against the shooter's measured link first.
		interp_delay_ms = LagCompRewind.plausible_interp_delay_ms(
				interp_delay_ms, float(NetworkManager.get_peer_ping_ms(pid)))
		var rewind_time: float = LagCompRewind.remote_view_time(host_timestamp, interp_delay_ms)
		var snap: WorldSnapshot = _state_buffer_manager.get_state_at(rewind_time)
		for gc: GoalieController in goalie_controllers:
			saved_goalie_positions.append(gc.goalie.global_position)
			saved_goalie_rotations.append(gc.goalie.get_goalie_rotation_y())
			var gs: GoalieNetworkState = snap.goalie_states.get(gc.team_id)
			if gs != null:
				gc.goalie.set_goalie_position(gs.position_x, gs.position_z)
				gc.goalie.set_goalie_rotation_y(gs.rotation_y)
	puck.set_carrier(skater)
	puck.release(direction, power)
	# Reposition to the (client-sent, clamped) origin — no forward advance; the host
	# fires authoritatively from here. Rewind only the horizontal origin to preserve
	# release()'s elevation y.
	if have_rewound_origin:
		var origin: Vector3 = puck.get_puck_position()
		origin.x = rewound_origin.x
		origin.z = rewound_origin.z
		puck.set_puck_position(origin)
	_note_shot_trajectory()
	if not saved_goalie_positions.is_empty():
		for i: int in goalie_controllers.size():
			goalie_controllers[i].goalie.global_position = saved_goalie_positions[i]
			goalie_controllers[i].goalie.set_goalie_rotation_y(saved_goalie_rotations[i])


# Fires a remote human's authoritative shot on the host. Called only from
# _on_remote_derived_release (the input-stream release) — there is no shot RPC. The
# direction/power are host-derived; origin is the host's live blade; rtt/interp_delay
# drive the goalie lag-comp rewind. The carrier guard + sanitize/clamp stay as
# defense-in-depth even though the host now sources all the params itself.
func _fire_remote_shot(direction: Vector3, power: float, is_slapper: bool, shooter_peer_id: int, host_timestamp: float, rtt_ms: float, interp_delay_ms: float, client_origin: Vector3) -> void:
	# Sender must be the current carrier on the host.
	# A `puck.carrier == null` here means a different code path already released the
	# puck; ignore the duplicate. The shot sound stays below the validation.
	if NetworkManager.is_host:
		if puck == null or _registry == null:
			return
		if puck.carrier == null:
			return
		if _registry.resolve_peer_id(puck.carrier) != shooter_peer_id:
			return
	# Clamp every client-supplied parameter before it touches the sim
	# (ShotReleaseRules): direction normalized + elevation-capped, power capped
	# to the shooter's attribute-scaled maximum, rtt capped against the host's
	# own ping measurement (an unclamped rtt forward-teleports the puck tens of
	# meters via the release advance below).
	if NetworkManager.is_host:
		direction = ShotReleaseRules.sanitize_direction(direction)
		if direction == Vector3.ZERO:
			return
		var shooter: PlayerRecord = _registry.get_record(shooter_peer_id)
		if shooter != null and shooter.controller != null:
			var max_power: float = shooter.controller.max_slapper_power if is_slapper \
					else shooter.controller.max_wrister_power
			power = ShotReleaseRules.clamp_power(power, max_power)
		rtt_ms = ShotReleaseRules.clamp_rtt_ms(
				rtt_ms, float(NetworkManager.get_peer_ping_ms(shooter_peer_id)))
	var sound: SoundManager.Sound = SoundManager.Sound.SHOT_SLAPPER if is_slapper else SoundManager.Sound.SHOT_WRISTER
	var shot_pos: Vector3 = puck.get_puck_position() if puck != null else Vector3.ZERO
	SoundManager.play_world(sound, shot_pos, 0.0, 0.04)
	if NetworkManager.is_host:
		_record_replay_audio_event("shot", shot_pos, power, {"is_slapper": is_slapper})
		# Fan the cue out to the other clients (the shooter already played it
		# locally the instant they released).
		NetworkManager.send_shot_to_all(shot_pos, is_slapper, shooter_peer_id)
	if NetworkManager.is_host:
		_start_pending_shot_from_carrier()
		# Lag-comp the goalie reaction trigger: back-date the reaction timers
		# by the one-way trip (now - shooter's host_timestamp) so the goalie
		# gets the same effective reaction window the shooter perceived
		# locally. Without this, the host's reaction starts RTT/2 after the
		# shooter saw the puck leave the stick, eating ~28% of the arm delay
		# on a 100ms RTT and flipping close-range saves into goals. Clamped so
		# a forged/stale stamp (or pre-warmup zero stamp) earns no back-date.
		var release_back_date: float = ShotReleaseRules.clamp_back_date(
				NetworkManager.estimated_host_time(), host_timestamp)
		for gc: GoalieController in goalie_controllers:
			gc.set_pending_reaction_back_date(release_back_date)
		var saved_goalie_positions: Array[Vector3] = []
		var saved_goalie_rotations: Array[float] = []
		var rewound_origin: Vector3 = Vector3.ZERO
		var have_rewound_origin: bool = false
		var origin_anchor: PlayerRecord = _registry.get_record(shooter_peer_id)
		if rtt_ms > 0.0 and origin_anchor != null and origin_anchor.skater != null:
			# Shot ORIGIN (SELF view): the shooter released from their locally-predicted
			# blade and SENT that exact point in the RPC. The host can't reconstruct it
			# itself — the release pose lands in the state buffer ~INPUT_LEAD_SEC in the
			# FUTURE relative to this immediate release RPC, so a self-view buffer rewind
			# reads the stale pre-release blade (the bug this replaces). Trust the
			# client's point but VALIDATE it: clamp to the shooter's stick reach of their
			# host-live body (stable in the RPC window, unlike the swinging blade) so a
			# forged origin can't fire from across the rink. This is the authoritative
			# fire point: the host simulates forward from here (no advance) and the
			# shooter's three-zone reconcile aligns its prediction to it.
			rewound_origin = ShotReleaseRules.clamp_origin(client_origin, origin_anchor.skater.global_position)
			have_rewound_origin = true
		if _state_buffer_manager != null and _state_buffer_manager.is_ready() and NetworkManager.is_real_peer(shooter_peer_id) and rtt_ms > 0.0 \
				and ShotReleaseRules.is_timestamp_fresh(NetworkManager.estimated_host_time(), host_timestamp):
			# Goalie is REMOTE-view from the shooter — the shooter saw the goalie at
			# host_time - interp_delay (the buffered render path); rewind to that
			# snapshot for fair puck/goalie geometry at the release moment.
			# Anti-cheat: delay bounded against the shooter's measured link first.
			interp_delay_ms = LagCompRewind.plausible_interp_delay_ms(
					interp_delay_ms, float(NetworkManager.get_peer_ping_ms(shooter_peer_id)))
			var rewind_time: float = LagCompRewind.remote_view_time(host_timestamp, interp_delay_ms)
			var snap: WorldSnapshot = _state_buffer_manager.get_state_at(rewind_time)
			for gc: GoalieController in goalie_controllers:
				saved_goalie_positions.append(gc.goalie.global_position)
				saved_goalie_rotations.append(gc.goalie.get_goalie_rotation_y())
				var gs: GoalieNetworkState = snap.goalie_states.get(gc.team_id)
				if gs != null:
					gc.goalie.set_goalie_position(gs.position_x, gs.position_z)
					gc.goalie.set_goalie_rotation_y(gs.rotation_y)
		puck.release(direction, power)
		# Reposition to the (client-sent, clamped) origin — no forward advance. The
		# host is authoritative and simulates forward from here; the shooter
		# reconciles its prediction to this. puck.release() snaps global_position to
		# ex_carrier.get_blade_contact_global() (carrier is still set at call time),
		# so this must run AFTER release(). Rewind only the horizontal origin —
		# release() set y for the elevation launch (ice_height + lift), keep it.
		if have_rewound_origin:
			var origin: Vector3 = puck.get_puck_position()
			origin.x = rewound_origin.x
			origin.z = rewound_origin.z
			puck.set_puck_position(origin)
		_note_shot_trajectory()
		if not saved_goalie_positions.is_empty():
			for i: int in goalie_controllers.size():
				goalie_controllers[i].goalie.global_position = saved_goalie_positions[i]
				goalie_controllers[i].goalie.set_goalie_rotation_y(saved_goalie_rotations[i])
		return
	puck.release(direction, power)


# Host-authoritative remote shot. The host's RemoteController reached the shooter's
# release input and computed its OWN dir/power via _release_wrister, emitting
# puck_release_requested. Fire the authoritative puck from that — host-derived params,
# the host's LIVE blade as origin (no client origin), the release input's host_timestamp
# and an rtt-derived interp_delay for the goalie rewind. This is the only path that
# fires a remote human's shot (no shot RPC).
func _on_remote_derived_release(direction: Vector3, power: float, is_slapper: bool, shooter_peer_id: int) -> void:
	if not NetworkManager.is_host:
		return
	if puck == null or _registry == null or puck.carrier == null:
		return
	var record: PlayerRecord = _registry.get_record(shooter_peer_id)
	if record == null or record.skater == null or record.controller == null:
		return
	if _registry.resolve_peer_id(puck.carrier) != shooter_peer_id:
		return
	# Origin: the host's authoritative blade contact at the release tick (not a
	# client-sent point). Timestamp: the release input the host just processed.
	var origin: Vector3 = record.skater.get_blade_contact_global()
	var release_ts: float = record.controller.last_processed_host_timestamp
	var rtt_ms: float = float(NetworkManager.get_peer_ping_ms(shooter_peer_id))
	# Approximate the shooter's interpolation delay from the rtt the host already
	# measures plus one broadcast interval — the two dominant terms of the client's
	# get_target_interpolation_delay. The dropped term is the client's adaptive jitter
	# cushion (small except on jittery links); for beatable goalies it's close enough,
	# and it keeps the host-derived release purely input-driven (nothing extra on the
	# wire). Bounds mirror _compute_target_interpolation_delay's clamp.
	var interp_delay_ms: float = clampf(
			rtt_ms * 0.5 + 1000.0 / float(Constants.STATE_RATE), 16.0, 200.0)
	_fire_remote_shot(
			direction, power, is_slapper, shooter_peer_id, release_ts, rtt_ms, interp_delay_ms, origin)


func _start_pending_shot_from_carrier() -> void:
	if puck == null or puck.carrier == null:
		return
	var shooter_peer_id: int = _registry.resolve_peer_id(puck.carrier)
	# A pass/shot from carry is a deliberate play — instant possession
	# establishment (PossessionRules), even off a one-touch. Runs while the
	# carrier is still set, before release() fires the generic release signal.
	if _possession_tracker != null:
		_possession_tracker.on_deliberate_release(shooter_peer_id)
	_shot_tracker.on_shot_started(shooter_peer_id)


# Re-reads the pending shot's on-net flag from the puck's live ballistic
# trajectory (ShotOnNetRules against both goal mouths — on_goalie_touch's
# own-team gate sorts out direction). Called right after every authoritative
# release (post origin-rewind, so the projection starts from the true fire
# point) and after each mid-flight deflection, whose handlers emit with the
# post-redirect velocity already applied.
func _note_shot_trajectory() -> void:
	if puck == null or _shot_tracker == null or not _shot_tracker.has_pending_shot():
		return
	var pos: Vector3 = puck.get_puck_position()
	# get_release_velocity, NOT linear_velocity: release() queues the launch
	# vector for Jolt's next dynamic step, so linear_velocity reads ZERO in the
	# same-frame window this runs in (every shot would project as off-net).
	# Mid-flight (deflection re-reads) the pending vector is spent and this
	# returns live linear_velocity.
	var vel: Vector3 = puck.get_release_velocity()
	# A shot attempt is a puck directed at the OPPONENT'S net — Corsi/Fenwick/xG
	# only ever count attacking-net attempts. Both mouths pass the same ballistic
	# test (it only requires the puck to travel toward that end), so without this
	# gate a D-zone clearing whack or a breakout pass that happened to line up with
	# the shooter's OWN net logged a shot attempt for the DEFENDING team, priced its
	# xG off that net's geometry, and painted a point-blank chance at the wrong end
	# of the shot map. Falls back to reading both goals when the shooter's team
	# can't be resolved (drills, unassigned goals) — over-crediting beats swallowing
	# real shots.
	var shooter_team: int = -1
	if _registry != null:
		shooter_team = _registry.resolve_team_id_for_peer(_shot_tracker.get_shooter_peer_id())
	var on_net: bool = false
	var directed: bool = false
	var directed_line_z: float = 0.0
	for goal: HockeyGoal in goals:
		if shooter_team != -1 and goal.defending_team_id == shooter_team:
			continue  # the shooter's own net — never an attempt for their team
		var line_z: float = goal.goal_line_z()
		if ShotOnNetRules.is_on_net(pos, vel, line_z):
			on_net = true
			directed = true
			directed_line_z = line_z
			break
		# Wider Corsi/Fenwick mouth: a shot that misses within the margin is still
		# an attempt (is_on_net ⊆ is_directed_at_net, so only check when off net).
		if ShotOnNetRules.is_directed_at_net(pos, vel, line_z):
			directed = true
			directed_line_z = line_z
	_shot_tracker.note_trajectory(on_net)
	_shot_tracker.note_directed_at_net(directed)
	# Release position for the shot map (B1). Noted UNCONDITIONALLY: an undirected
	# release still resolves into a plotted event when it goes in off someone (an
	# own goal is credited to the other team via on_goal_confirmed), and gating this
	# on `directed` parked those dots at centre ice.
	_shot_tracker.note_shot_origin(pos)
	# Release CONTEXT for the shot log (the defending goalie's situation plus the
	# shooter's). Location alone cannot be compared to a public xG model, because a
	# fitted model has the context baked into its location term — see ShotEvent.
	# Sampled here because this is the release tick and everything below is already
	# computed for the goalie's own read.
	_note_shot_context(vel, shooter_team)
	# xG (A2): evaluate this shot's expected goals from the REAL goalie geometry at
	# release, and hold it on the pending shot to commit when it resolves. Only
	# directed shots can become counted attempts, so only they need an xG — an
	# undirected release keeps xG 0, which is honest: we never evaluated it.
	if directed:
		var xg: float = AIActionScoring.expected_goals(
				pos, Vector3(0.0, 0.0, directed_line_z),
				_defending_goalie_pos(directed_line_z),
				GameRules.NET_HALF_WIDTH, vel.length(),
				0.0, -1.0, false, 0.0, false, 0.0,
				Vector4.INF, Vector4.INF, 1.0, _shot_release_spread())
		_shot_tracker.note_xg(xg)


# The pending shot's release-difficulty spread — the "can you hit it" half of the
# xG model. Reads the shot's CONTEXT (which hand, how fast the shooter is moving),
# never the shooter's skill: a weaker player drawing lower xG on an identical
# chance would make goals-above-expected circular. Falls back to the settled
# reference when the shooter's actors aren't resolvable.
# v1 note: on a mid-flight tip this still reads the ORIGINAL shooter's hand — the
# tipper's own release context isn't captured. Minor; tips carry their own tag.
func _shot_release_spread() -> float:
	if _shot_tracker == null or _registry == null:
		return AIActionScoring.XG_BASE_SPREAD_RAD
	var rec: PlayerRecord = _registry.get_record(_shot_tracker.get_shooter_peer_id())
	if rec == null or rec.skater == null or rec.controller == null:
		return AIActionScoring.XG_BASE_SPREAD_RAD
	var horizontal := Vector3(rec.skater.velocity.x, 0.0, rec.skater.velocity.z)
	return AIActionScoring.xg_release_spread(
			rec.controller.last_release_hand == "BH", horizontal.length())


# The position of the goalie defending the net at `line_z` (same end, matched by
# z-sign), for the release-time xG geometry. Falls back to the goal centre when
# no goalie is present (drills / degenerate setups).
func _defending_goalie_pos(line_z: float) -> Vector3:
	for gc: GoalieController in goalie_controllers:
		if gc != null and gc.goalie != null \
				and signf(gc.goalie.global_position.z) == signf(line_z):
			return gc.goalie.global_position
	return Vector3(0.0, 0.0, line_z)


# Sum of individual xG (PlayerStats.xg_for) over a team's players — the team xGF
# for a game, and (for the opponent) the team xGA. Read at game-over for the
# career xGF% columns; every peer has all rows via the stats broadcast.
# The host pushed its per-game shot log at game-over (analytics B1). Clients keep
# it so the post-game analytics views read from the same list the host has.
func _on_shot_events_received(data: Array) -> void:
	_client_shot_events = ShotEvent.decode_list(data)


# The game's shot log, whichever role this peer is: the host's live buffer, or a
# client's pushed copy. The seam the post-game shot map / xG-flow read from.
func get_shot_events() -> Array[ShotEvent]:
	if NetworkManager.is_host and _advanced_stats_tracker != null:
		return _advanced_stats_tracker.get_shot_events()
	return _client_shot_events


func _team_xg_sum(team_id: int) -> float:
	var total: float = 0.0
	if _registry == null:
		return total
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record != null and record.team != null and record.team.team_id == team_id \
				and record.stats != null:
			total += record.stats.xg_for
	return total


# Host-side: a shot off the pipes is a miss in NHL scoring — drop the pending
# shot's on-net read so a goalie touch on the ricochet doesn't confirm a SOG.
func _on_host_puck_touched_post() -> void:
	if _shot_tracker != null:
		_shot_tracker.on_post_hit()


# ── Puck network events ──────────────────────────────────────────────────────
func _on_remote_carrier_changed(new_carrier_peer_id: int) -> void:
	if puck_controller == null:
		return
	if new_carrier_peer_id == -1:
		puck_controller.notify_remote_carrier_changed(-1)
		return
	# Pin the puck to the carrier's interpolated blade so it shares one render
	# timeline with the stick instead of interpolating from its own buffer. Fall
	# back to the plain carrier-changed path (stop predicting, no pin) when the
	# carrier is the local player — handled by on_local_player_picked_up_puck —
	# or their skater isn't spawned on this client yet.
	var record: PlayerRecord = _registry.get_record(new_carrier_peer_id) if _registry != null else null
	if record == null or record.skater == null or record.is_local:
		puck_controller.notify_remote_carrier_changed(new_carrier_peer_id)
		return
	puck_controller.notify_remote_pickup(record.skater, new_carrier_peer_id)


func on_carrier_puck_dropped() -> void:
	var local_record := _registry.get_local() if _registry != null else null
	if local_record != null:
		local_record.controller.on_puck_released_network()
		puck_controller.notify_local_puck_dropped()


func on_local_player_picked_up_puck() -> void:
	var record := _registry.get_local() if _registry != null else null
	if record != null:
		record.controller.on_puck_picked_up_network()
		puck_controller.notify_local_pickup(record.skater)


func on_local_player_puck_stolen(was_stick_lift: bool = false) -> void:
	var local_record := _registry.get_local() if _registry != null else null
	if local_record != null:
		local_record.controller.on_puck_released_network()
		puck_controller.notify_local_puck_dropped()
		# Stick-lift victim cue: pop our own blade up so the strip reads as a
		# lift on our screen too (the host forced it, but our local prediction
		# of our own skater never saw that). Reuses the exact lift mechanic.
		if was_stick_lift and local_record.skater != null:
			local_record.skater.force_blade_lift(PuckController.STICK_LIFT_FORCED_LIFT_S)


# ── Goal received (client-side RPC) ──────────────────────────────────────────
func _on_goal_received(scoring_team_id: int, score0: int, score1: int,
		scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	if _phase_coord == null:
		return
	_phase_coord.on_goal_received(scoring_team_id, score0, score1,
			scorer_name, assist1_name, assist2_name)


func _on_faceoff_positions_received(positions: Array) -> void:
	if _phase_coord != null:
		_phase_coord.on_faceoff_positions(positions)


func _on_puck_out_of_play_received() -> void:
	# Client-side mirror of the host's OOB-confirmed moment. The FACEOFF_PREP
	# phase change still arrives via world state; this just lights up the
	# whistle + toast for clients at the same beat the host plays them.
	puck_out_of_play.emit()
	SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)


func _on_icing_called_received() -> void:
	icing_called.emit()
	SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)


func _on_goalie_freeze_called_received() -> void:
	goalie_freeze_called.emit()
	SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)


func _on_offside_called_received() -> void:
	offside_called.emit()
	SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)


# ── Input batches from peers (host only) ─────────────────────────────────────
# NetworkManager emits `input_batch_received` from its receive_input_batch RPC;
# we route to the matching RemoteController. Drops batches for unregistered
# peers or freed controllers (peer left mid-flight).
func _on_input_batch_received(peer_id: int, inputs: Array[InputState]) -> void:
	if not NetworkManager.is_host or _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or not is_instance_valid(record.controller):
		return
	var remote: RemoteController = record.controller as RemoteController
	if remote == null:
		return
	remote.receive_input_batch(inputs)


# ── World state & stats RPC forwarding ───────────────────────────────────────
func _on_world_state_received(data: PackedByteArray) -> void:
	if _codec != null:
		_codec.decode_world_state(data)  # updates _state_machine.current_phase
	if data.size() < 6:
		return
	# u32 0.1ms wire units — must match WorldStateCodec's header encoding.
	var host_ts: float = float(data.decode_u32(2)) / Constants.TIME_WIRE_SCALE
	# Feed the in-memory ring buffer so this peer's GoalReplayDriver has a
	# clip to extract when a goal fires. Skipped during the cinematic itself
	# (NetworkManager.is_replay_mode is mirrored to clients) so we don't
	# overwrite the live pre-goal frames with frozen mid-replay state.
	if _recorder != null and not NetworkManager.is_replay_mode() \
			and not _is_celebration_phase():
		_recorder.record_frame(data, host_ts)
	# Tee the broadcast into the local .mreplay file (throttled to
	# REPLAY_FILE_RATE). Use the host_ts encoded in the packet so timestamps align
	# across host + client recordings — local_time() differs per peer.
	_record_world_state_to_file(host_ts, data)


func _on_stats_received(data: Array) -> void:
	if _codec != null:
		_codec.decode_stats(data)
	stats_updated.emit()


func _on_remote_phase_changed(new_phase: GamePhase.Phase) -> void:
	_last_emitted_clock_secs = -1
	# Clients mirror the host's period-break skate-off off the WS phase byte —
	# there's no reliable RPC for END_OF_PERIOD, and the multi-second break makes
	# the unreliable channel safe (idempotence guarded inside the coordinator).
	if new_phase == GamePhase.Phase.END_OF_PERIOD and _phase_coord != null:
		_phase_coord.on_period_break_entered()
	phase_changed.emit(new_phase)
	# Note: the client's goal-replay cinematic is NOT triggered here. The host
	# enters GOAL_SCORED and replay mode in the same frame, gating off its own
	# world-state broadcasts before any packet carries GOAL_SCORED — so this
	# handler never observes that phase. The client trigger lives in
	# _on_remote_replay_mode_changed, driven by the reliable notify_replay_mode
	# RPC the host sends when its cinematic starts.


func _on_clock_updated_externally(t: float) -> void:
	_last_emitted_clock_secs = -1
	clock_updated.emit(t)


func _observe_telemetry() -> void:
	var skater_buf: int = 0
	var extrapolating: bool = false
	if _registry != null:
		for peer_id: int in _registry.all():
			var r: PlayerRecord = _registry.get_record(peer_id)
			if r == null or r.is_local:
				# The local skater's reconciles are counted at their per-world-state
				# source (LocalController.reconcile), not sampled here per rendered
				# frame — per-frame sampling undercounted on sub-120fps clients.
				continue
			var rc := r.controller as RemoteController
			if rc != null:
				skater_buf = rc.get_buffer_depth()
				extrapolating = extrapolating or rc.is_extrapolating
	var puck_buf: int = puck_controller.get_buffer_depth() if puck_controller != null else 0
	var goalie_buf: int = 0
	for gc: GoalieController in goalie_controllers:
		goalie_buf = gc.get_buffer_depth()
		extrapolating = extrapolating or gc.is_extrapolating
	if puck_controller != null:
		extrapolating = extrapolating or puck_controller.is_extrapolating
	_telemetry.observe_actors(skater_buf, puck_buf, goalie_buf, extrapolating)
	# Host-stall attribution context (see NetworkTelemetry.current_phase). Phase
	# name resolves only on a transition — GamePhase.Phase.keys() allocates, so the
	# dirty check keeps it off the per-frame path. Actor count is a cached size.
	if _state_machine != null and _state_machine.current_phase != _last_telemetry_phase_id:
		_last_telemetry_phase_id = _state_machine.current_phase
		_telemetry.current_phase = GamePhase.Phase.keys()[_state_machine.current_phase]
	_telemetry.current_actor_count = (_registry.skaters().size() if _registry != null else 0) + goalie_controllers.size()
	# Connection facts the static record_* path doesn't carry — sampled by the
	# session fold at window rollover. Clients refresh their link-to-host reads;
	# the host refreshes its per-peer view instead (its own RTT/loss are 0).
	if not NetworkManager.is_offline_mode:
		if NetworkManager.is_host:
			var peers: PackedInt32Array = NetworkManager.connected_peer_ids()
			_telemetry.current_peer_count = peers.size()
			var worst_rtt: float = 0.0
			var worst_loss: float = 0.0
			for pid: int in peers:
				worst_rtt = maxf(worst_rtt, float(NetworkManager.get_peer_ping_ms(pid)))
				worst_loss = maxf(worst_loss, NetworkManager.get_peer_loss_rate(pid))
			_telemetry.current_worst_peer_rtt_ms = worst_rtt
			_telemetry.current_worst_peer_loss_pct = worst_loss
		else:
			_telemetry.current_rtt_ms = NetworkManager.get_rtt_ms()
			_telemetry.current_delay_spread_ms = NetworkManager.get_packet_delay_spread_ms()
			_telemetry.current_clock_correction_ms = NetworkManager.get_clock_correction_ms()
			# The lead servo's live EXTRA (total stamp lead − the static
			# INPUT_LEAD_SEC). Observability for the servo's equilibrium under
			# the post-C1 honest capture labels — nothing else reports it, and
			# the F3 latency budget shows only the static base.
			_telemetry.current_input_lead_extra_ms = NetworkManager.get_input_lead_ms() \
					- NetworkManager.INPUT_LEAD_SEC * 1000.0


func _sync_stats_to_clients() -> void:
	stats_updated.emit()
	if not NetworkManager.is_host or _codec == null:
		return
	NetworkManager.send_stats_to_all(_codec.encode_stats())


# ── Slot swap ─────────────────────────────────────────────────────────────────
func _on_slot_swap_requested(peer_id: int, new_team_id: int, new_slot: int) -> void:
	if not NetworkManager.is_host or _swap_coord == null:
		return
	# Player → spectator: any peer requesting a spectator slot.
	if new_team_id == GameRules.SPECTATOR_TEAM_ID:
		_demote_player_to_spectator(peer_id)
		return
	# Spectator → player: peer is in the spectator set, requesting a player slot.
	# `try_swap_slot` won't validate this because the peer isn't in
	# `_state_machine.players` yet, so we run a dedicated promotion path.
	if _spectator_peers.has(peer_id):
		_promote_spectator_to_player(peer_id, new_team_id, new_slot)
		return
	var carrier: Skater = puck.carrier if puck != null else null
	var confirmation: Dictionary = _swap_coord.request_swap(peer_id, new_team_id, new_slot, carrier)
	if confirmation.is_empty():
		return
	NetworkManager.send_confirm_slot_swap(peer_id,
			confirmation.old_team_id, confirmation.old_slot,
			confirmation.new_team_id, confirmation.new_slot,
			confirmation.jersey, confirmation.helmet, confirmation.pants)


func _on_slot_swap_confirmed(peer_id: int, old_team_id: int, old_slot: int,
		new_team_id: int, new_slot: int,
		jersey: Color, helmet: Color, pants: Color) -> void:
	if _swap_coord != null:
		_swap_coord.apply_confirmed_swap(peer_id, old_team_id, old_slot,
				new_team_id, new_slot, jersey, helmet, pants)
	# Update the local controller's team context (camera flip, move vector, shot
	# direction) when the local player is the one who swapped.
	if _registry != null:
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record != null and record.is_local:
			var local_ctrl: LocalController = record.controller as LocalController
			if local_ctrl != null:
				local_ctrl.set_local_team_id(new_team_id)


func _on_hit_landed(hitter_peer_id: int, victim: Skater, impulse_magnitude: float,
		hit_dir: Vector3) -> void:
	_hit_claim.notify_local_hit(hitter_peer_id, victim, impulse_magnitude)
	# Only the local player's own deliveries drive the "you landed a hit" feedback,
	# and this signal fires on the deliverer's machine, so gate on local peer.
	if hitter_peer_id == NetworkManager.local_peer_id():
		local_player_landed_hit.emit(impulse_magnitude)
		# Kick the camera along the direction you drove the hit (follow-through),
		# ramping from nothing at the register-a-hit floor to full one span above
		# it — so an ordinary lined-up check kicks, not only head-on collisions
		# (the old 6.0/14 floor missed every one-sided check). The impact_force
		# scale's landmarks live on HitRules. The span is a hand-set camera FEEL
		# value, not a landmark: it tops out a bit past KNOCKDOWN_IMPULSE so only
		# the hardest hits max the kick.
		const KICK_FULL_SPAN: float = 4.0
		local_player_impact.emit(hit_dir, clampf(
				(impulse_magnitude - HitRules.MIN_HIT_IMPULSE) / KICK_FULL_SPAN, 0.0, 1.0))
		# Live achievement — excluded in free play / drills (no achievements there).
		if _achievements != null and _achievements_active():
			_achievements.on_local_hit(impulse_magnitude)


# Host-only (impact_landed fires only on the host, from the deduped contact
# path). Broadcast the authoritative impact at CONTACT time — the burst/thud
# can't wait on the possession-loss verdict that gates the stat — and self-fire
# locally since the RPC reaches only remote peers (and so offline/free-play
# still gets the impact).
func _on_impact_landed(hitter_peer_id: int, victim_peer_id: int,
		force: float, hit_dir: Vector3) -> void:
	NetworkManager.send_body_check_to_all(hitter_peer_id, victim_peer_id, force, hit_dir)
	_on_body_check_landed(hitter_peer_id, victim_peer_id, force, hit_dir)


# Host-only. The hit stat may land up to POSSESSION_LOSS_WINDOW_S after the
# contact (it waits for the victim to lose the puck — see HitTracker), so this
# only syncs stats; the impact broadcast already fired from _on_impact_landed.
func _on_hit_credited(_victim_peer_id: int, _force: float, _hit_dir: Vector3) -> void:
	_sync_stats_to_clients()


# Drives the body-check VFX + sound on every machine (clients via the RPC signal,
# host via the self-fire above). The burst self-positions at the victim, so the
# victim's VFX node is the right owner. `force` is VFX-scale impact force, fed
# straight into SkaterVFX.check_* — the same path the replay system uses. Local
# victim camera shake is NOT driven here: it already fires immediately off the
# predicted body_check_impulse_applied → local_player_hit path.
func _on_body_check_landed(hitter_peer_id: int, victim_peer_id: int,
		force: float, hit_dir: Vector3) -> void:
	if _registry == null:
		return
	var victim_rec: PlayerRecord = _registry.get_record(victim_peer_id)
	if victim_rec == null or victim_rec.skater == null:
		return
	var vfx: SkaterVFX = victim_rec.skater.get_node_or_null("VFX") as SkaterVFX
	if vfx != null:
		vfx.fire_body_check_burst(victim_rec.skater, force, hit_dir)
	# Record the replay audio/burst event from THIS authoritative funnel — the
	# same credited-and-deduped contact that plays live — rather than the raw
	# body_checked_player signal, which fires on every closing contact (bumps,
	# uncommitted collisions, per-tick re-fires) and made replays thud far more
	# than was ever heard. Self-gates to host + not-replaying (see the helper);
	# the replayer's own check_sound_audible gate then matches the live silence
	# floor for soft hits, while the burst still fires for every credited check.
	_record_body_check_replay_event(hitter_peer_id, victim_rec.skater, force, hit_dir)
	# The burst fires for every credited check, but the thud is reserved for
	# stagger-class-or-harder hits — a committed bump / board rub bursts faintly
	# and stays silent (see SkaterVFX.check_sound_audible).
	if SkaterVFX.check_sound_audible(force):
		SoundManager.play_world(SoundManager.Sound.BODY_CHECK, victim_rec.skater.global_position,
				SkaterVFX.check_sound_volume_db(force), 0.08, SkaterVFX.check_sound_pitch_scale(force))
	body_check_broadcast.emit(force)
	# The hitter's check-delivery body pose (shoulder drive through the contact)
	# rides the same broadcast as the burst/thud so all three land the identical
	# frame on every machine. Intensity shares the VFX hardness curve.
	var hitter_rec: PlayerRecord = _registry.get_record(hitter_peer_id)
	if hitter_rec != null and hitter_rec.controller != null:
		hitter_rec.controller.start_check_drive(hit_dir, SkaterVFX.check_intensity(force))
	# Lever B: lead the knockback on a remotely-interpolated victim so the hit reads
	# punchy instead of mushy-late. No-op for the local (predicted) victim — its
	# controller isn't a RemoteController — and on the host (guarded inside).
	var rc: RemoteController = victim_rec.controller as RemoteController
	if rc != null:
		rc.start_knockback_lead(hit_dir, force)


func _on_hit_claim_received(hitter_peer_id: int, victim_peer_id: int, host_timestamp: float,
		interp_delay_ms: float, input_lead_ms: float) -> void:
	if not NetworkManager.is_host:
		return
	_hit_claim.receive_claim(hitter_peer_id, victim_peer_id, host_timestamp, interp_delay_ms, input_lead_ms)


# Relay for PhaseCoordinator.faceoff_prep_announced that recognizes the
# OPENING faceoff (first prep since world setup / reset) and fires the
# pre-game intro signal first, so HUD/camera/crowd listeners can set up
# before the countdown wiring reacts. Runs on host and clients alike —
# both sides' prep announcement funnels through here.
func _on_faceoff_prep_announced_from_coord() -> void:
	var opening: bool = not _seen_first_prep
	_seen_first_prep = true
	if opening and _pregame_intro_eligible():
		pregame_intro_started.emit(GameRules.PREGAME_INTRO_DURATION)
	elif _phase_coord != null and _phase_coord.last_prep_was_period_intro:
		# Period-start bench intro: camera sweep + period card over the extended
		# prep, mirroring the opening intro's presentation path. The period comes
		# from the coordinator's break-time stash, not the state machine — a
		# client's replicated current_period may not have advanced yet.
		period_intro_started.emit(
				_phase_coord.period_after_break, GameRules.PERIOD_INTRO_DURATION)
	elif _phase_coord != null and _phase_coord.last_prep_preroll > 0.0:
		# Period / stoppage skate-in: hold the countdown for the skate window so
		# it lands on the extended drop. Guarded by the intro branch above so the
		# opening faceoff never double-counts (its pre-roll is the intro's).
		faceoff_skate_in_started.emit(_phase_coord.last_prep_preroll)
	faceoff_prep_announced.emit()


# Whether the faceoff PhaseCoordinator is currently placing is the opening/
# rematch intro — the one where skaters skate out from their benches. Same
# condition that fires the pre-game intro, evaluated BEFORE this prep's announce
# flips _seen_first_prep (placement runs first on both host and client). Injected
# into PhaseCoordinator as a Callable so it can pick bench vs current-position
# skate-in starts without reaching back into GameManager's flags directly.
func _is_pregame_intro_faceoff() -> bool:
	return (not _seen_first_prep) and _pregame_intro_eligible()


# Whether the opening-faceoff pre-game intro should play. Beyond the mode
# gates, the fresh-match check keeps a mid-game joiner's FIRST prep (some
# later stoppage, normal-length window) from playing a 4 s intro over a 2 s
# prep. The clock counts up in infinite-time mode, down otherwise.
func _pregame_intro_eligible() -> bool:
	if NetworkManager.is_free_play_mode or NetworkManager.is_drill_mode() \
			or NetworkManager.is_replay_mode():
		return false
	if _state_machine == null:
		return false
	if _state_machine.current_period != 1:
		return false
	if _state_machine.scores[0] != 0 or _state_machine.scores[1] != 0:
		return false
	if _state_machine.infinite_time:
		return _state_machine.time_remaining <= 0.01
	return _state_machine.time_remaining >= _state_machine.period_duration - 0.01


# Three Stars of the Game, ranked best first, computed locally from the
# replicated stat counters. Every machine sees the same counters (including
# the host-stamped game-winning-goal flag) and the same sorted-peer-id
# candidate order, and StarOfGameRules breaks ties explicitly, so selection
# is deterministic without an RPC. The GWG bonus scales with the final margin
# (a one-goal winner is the story of the night, a blowout GWG is trivia),
# losing-team stat lines are discounted at selection, and the first star
# always comes from the winning team; humans and bots compete on equal
# footing. The two AI goalies are candidates too (after the skaters in the
# stable order), rated on goals saved above the Mitts-average expectation —
# team shots and scores are replicated, so their scores are as deterministic
# as the skaters'. Can return fewer than three entries (empty when nobody
# registered a counting stat).
func get_stars_of_game() -> Array[PlayerRecord]:
	var result: Array[PlayerRecord] = []
	if _registry == null:
		return result
	var goal_margin: int = 0
	var winning_team: int = -1
	if _state_machine != null:
		goal_margin = absi(_state_machine.scores[0] - _state_machine.scores[1])
		if goal_margin > 0:
			winning_team = 0 if _state_machine.scores[0] > _state_machine.scores[1] else 1
	var peer_ids: Array[int] = []
	for pid: int in _registry.all().keys():
		peer_ids.append(pid)
	peer_ids.sort()
	var scores: Array[float] = []
	var on_losing_team: Array[bool] = []
	for pid: int in peer_ids:
		var rec: PlayerRecord = _registry.get_record(pid)
		scores.append(StarOfGameRules.score(rec.stats, goal_margin))
		on_losing_team.append(winning_team != -1 and rec.team != null
				and rec.team.team_id != winning_team)
	var goalie_candidates: bool = _state_machine != null and teams.size() == 2
	if goalie_candidates:
		for team_id: int in 2:
			scores.append(StarOfGameRules.goalie_score(
					_state_machine.team_shots[1 - team_id],
					_state_machine.scores[1 - team_id]))
			on_losing_team.append(winning_team != -1 and team_id != winning_team)
	for star_idx: int in StarOfGameRules.pick_stars(scores, on_losing_team):
		if star_idx < peer_ids.size():
			result.append(_registry.get_record(peer_ids[star_idx]))
		else:
			result.append(_goalie_star_record(star_idx - peer_ids.size()))
	return result


# A starred goalie has no roster record, so the podium gets a synthesized
# one carrying just what the HUD reads (name, number, team, is_goalie). The
# negative peer id is a sentinel — this record never enters the registry.
func _goalie_star_record(team_id: int) -> PlayerRecord:
	var rec := PlayerRecord.new(-(team_id + 1), 0, false, teams[team_id])
	rec.player_name = GOALIE_NAMES[team_id]
	rec.jersey_number = GOALIE_NUMBERS[team_id]
	rec.is_bot = true
	rec.is_goalie = true
	return rec


# Replicated team shots-on-goal (NHL convention: goals count as shots). The
# HUD reads this at podium time to caption a starred goalie's saves line.
func get_team_shots(team_id: int) -> int:
	if _state_machine == null:
		return 0
	return _state_machine.team_shots[team_id]


# ── Scene exit & reset ───────────────────────────────────────────────────────
func _on_game_over() -> void:
	# Highlight reel runs for every game-over (online + Play vs Bots), so it's
	# scheduled before the career/telemetry early-returns below.
	_schedule_post_game_replay()
	# Ship the game's shot log to clients (analytics B1) — same reasoning: the
	# post-game analytics views are a LOCAL view of the match everyone just
	# played, so this rides ahead of the Supabase upload gates below (those gate
	# what leaves the machine, not what a peer sees of its own game). No-op with
	# no peers, so offline / Play vs Bots costs nothing.
	if NetworkManager.is_host and _advanced_stats_tracker != null:
		NetworkManager.send_shot_events_to_all(
				ShotEvent.encode_list(_advanced_stats_tracker.get_shot_events()))
	if _state_machine == null or _registry == null or _career_reporter == null:
		return
	var local: PlayerRecord = _registry.get_local()
	var team_id: int = -1
	var gf: int = 0
	var ga: int = 0
	var outcome: String = "draw"
	if local != null and local.team != null:
		team_id = local.team.team_id
		gf = _state_machine.scores[team_id]
		ga = _state_machine.scores[1 - team_id]
		if gf > ga:
			outcome = "win"
		elif gf < ga:
			outcome = "loss"
		# Achievements + Steam career stats count any real match — online OR a
		# configured "Play vs Bots" game — but never free play or tutorial/drill
		# practice (see _achievements_active). Steam Stats are the player's own
		# account data, so they're NOT gated on share_gameplay_stats or online;
		# increment first, then evaluate against the updated totals so a threshold
		# unlocks on the game that crosses it. No Supabase dependency.
		if _achievements_active():
			if _achievements != null:
				_achievements.evaluate_single_game(local.stats, outcome, gf, ga)
				# Roster achievements — read the live Steam lobby membership so any
				# machine (host or client) can award "played a game with X".
				_achievements.evaluate_roster(
						SteamManager.lobby_member_steam_ids(), SteamManager.steam_id)
			if _stat_recorder != null:
				_stat_recorder.record_game(local.stats, outcome)
				if _achievements != null:
					_achievements.evaluate_career(_stat_recorder.totals())
	# Supabase career row: EVERY real match counts, offline vs bots exactly like
	# online. Most play happens offline, and a career page that ignores it isn't
	# the player's career. The online/offline distinction is preserved as a column
	# (`is_online`) rather than as an upload gate, so a human-only leaderboard
	# stays possible later without having thrown the data away.
	# Free play, tutorial, and drills are still excluded — game_over doesn't fire
	# in those lobby-less modes, and `_achievements_active` is the established
	# "this was a real match" predicate, so state it rather than rely on that.
	if not _achievements_active():
		return
	# Privacy opt-out: with stat sharing off, no career row is uploaded to Supabase.
	# The Career screen's history reads from that backend data, so it stays empty by
	# the player's choice (see PlayerPrefs.share_gameplay_stats). Local replays and
	# Steam achievements/stats above are unaffected — they never touch the backend.
	if not PlayerPrefs.share_gameplay_stats:
		return
	# Network-quality row: online only — an offline match has no link to measure.
	# (The helper re-checks its own gates.)
	if not NetworkManager.is_offline_mode:
		_report_net_session("completed")
	if local == null or local.team == null:
		return
	# Every backend row keys on steam_id. Online sessions always have one; an
	# offline session without Steam running does not, and a row we can't attribute
	# is unreadable by the career screen and pure pollution — so skip it.
	if SteamManager.steam_id == 0:
		return
	# Archival, not gates. `is_online` is the session type; `_peak_humans` is the
	# stronger signal — an online lobby nobody joined is a bot game with extra
	# steps. Stored as a COUNT rather than a "was it ranked" flag: Mitts has no
	# ranked mode, and a count lets a future filter choose its own bar (1 = solo,
	# 2+ = a real opponent, 6 = a full lobby) instead of inheriting this one.
	var is_online: bool = not NetworkManager.is_offline_mode
	_career_reporter.report(local, gf, ga, outcome,
			_game_id, team_id, _state_machine.period_scores, _state_machine.num_periods,
			_state_machine.team_shots[team_id], _state_machine.team_shots[1 - team_id],
			_team_xg_sum(team_id), _team_xg_sum(1 - team_id), is_online, _peak_humans,
			_state_machine.team_size, _state_machine.rule_set,
			roundi(_state_machine.period_duration))
	# Shot-event log (B1) — host-only: it holds the authoritative per-game buffer,
	# so a single batch from the host avoids per-peer duplication. Offline the
	# local player IS the host, so bot games log their shots too (which is what
	# fills the career heatmap). Same share gate as the career row, applied above.
	if NetworkManager.is_host and _advanced_stats_tracker != null:
		_career_reporter.report_shot_events(
				_advanced_stats_tracker.get_shot_events(), _game_id,
				NetworkManager.get_peer_steam_id, _state_machine.team_size)


# One network-quality row per game, guarded so the game-over and scene-exit
# paths can both call it without double-posting. `end_reason`: "completed"
# (game over), "quit" (local player left mid-game), or a client-side abnormal
# end from NetworkManager ("host_lost" / "host_ended" / "kicked"). Applies the
# same offline + privacy gates as career stats; the reporter's own 30 s floor
# still filters rage-quit warmups.
func _report_net_session(end_reason: String) -> void:
	if _net_session_reported or _telemetry == null or _net_session_reporter == null:
		return
	if NetworkManager.is_offline_mode or not PlayerPrefs.share_gameplay_stats:
		return
	_net_session_reported = true
	var role: String = "host" if NetworkManager.is_host else "client"
	_net_session_reporter.report(_telemetry.session, role, NetworkSimManager.enabled,
			_game_id, end_reason)


# True for a real match that should award achievements + Steam career stats: any
# online or "Play vs Bots" game, but never free play (a casual endless sandbox)
# or tutorial / penalty-drill practice.
func _achievements_active() -> bool:
	return not NetworkManager.is_free_play_mode and not NetworkManager.is_drill_mode()


# Called from the tutorial-completion paths (TutorialManager / TutorialHUD) each
# time a tutorial is marked complete. Fires the "Student of the Game" achievement
# once the whole course is done. Deliberately outside _achievements_active — the
# course runs in tutorial mode, where that gate is closed, so the meta hook is
# called directly. Idempotent downstream (AchievementService de-dupes).
func notify_tutorial_completed() -> void:
	if _achievements == null:
		return
	for id: String in TutorialRegistry.ALL_IDS:
		if not PlayerPrefs.is_tutorial_complete(id):
			return
	_achievements.on_tutorials_complete()


# Latches _ranked_match (see its doc) once two humans share the match, and tracks
# the PEAK human headcount for the career row. Called from
# _on_registry_player_added so both the initial roster population and a mid-match
# join re-evaluate it; _apply_reset re-runs it for rematches.
# Peak rather than final: someone who plays three periods and drops before the
# horn still made it a human game, and a headcount taken at game-over would miss
# them. Counted offline too (the local player is a human), where it reads 1.
func _refresh_ranked_match() -> void:
	if _registry == null:
		return
	var humans: int = 0
	for record: PlayerRecord in _registry.all().values():
		if not record.is_bot:
			humans += 1
	_peak_humans = maxi(_peak_humans, humans)
	if _ranked_match or NetworkManager.is_offline_mode:
		return
	_ranked_match = humans >= 2


# Window-close hook — closes the replay file cleanly when the user clicks
# the OS window's X. Without this, a quit mid-game leaves the .mreplay
# without END_OF_RECORDS or the footer, and the OS may signal mid-write
# leaving the last record torn. NOTIFICATION_WM_CLOSE_REQUEST fires before
# Godot's auto-quit cascade so we have time to drain the worker thread
# synchronously via close_async (which blocks on wait_to_finish). The
# in-game scene-transition path (back to main menu, rematch) already
# closes via on_scene_exit; this only catches the OS-level close case.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_close_replay_file_writer()
	# Release process-lifetime GPU caches before the RenderingServer finalizes.
	# HockeyRink._build_cache (ice/stripe ImageTextures) and ArenaStands'
	# _crowd_material / _layout_cache live in static vars that survive scene
	# changes for perf; a static var is freed at script-unload, AFTER the server,
	# so at exit their RIDs are reported as leaked. As an autoload, GameManager's
	# EXIT_TREE fires only at real app shutdown — covering both the menu-Quit
	# (get_tree().quit()) and window-close paths — while WM_CLOSE covers the
	# window close before the quit cascade. release_shared_cache is idempotent.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		HockeyRink.release_shared_cache()
		ArenaStands.release_shared_cache()
		# Join the AI worker thread at app shutdown (no-op unless threaded and
		# started) so a live Thread is never leaked past exit.
		_ai_coordinator.shutdown()


func on_scene_exit() -> void:
	set_input_blocked(false)
	# Drain + flush the replay file before tearing down state — close_async
	# blocks until the worker exits, so we must call this while the registry
	# (used to build the footer) is still intact.
	_close_replay_file_writer()
	_last_recorded_phase = -1
	# Session-scoped — a scene exit mid goal-replay must not carry a stale
	# "in replay" flag into the next session (a fresh driver is created there, so
	# a leftover true would let a skip vote fire before any replay is running).
	_in_replay_locally = false
	if _shot_tracker != null:
		_shot_tracker.clear_state()
	if _registry != null:
		_registry.clear_state()
	_state_machine = null
	_spawner = null
	# Stale stashes must not survive into the next session — a sync that
	# landed just as a host vanished mid-join would otherwise be flushed by
	# the next on_slot_assigned and spawn the wrong roster.
	_pending_existing_players = []
	_pending_remote_spawns = []
	_reserved_slots.clear()
	_last_ghost_state.clear()
	teams.clear()
	puck = null
	goals.clear()
	goalies.clear()
	goalie_controllers.clear()
	puck_controller = null
	_registry = null
	_codec = null
	_state_buffer_manager = null
	current_snapshot = null
	team_brains = []
	# Stop + join the AI worker thread (no-op unless threaded and started), so a
	# torn-down match never leaves a live thread referencing freed controllers.
	_ai_coordinator.shutdown()
	# Null PhaseCoordinator's _state_machine before stopping the driver so
	# any replay_stopped signal that fires during teardown returns early from
	# _on_goal_replay_stopped's guard rather than calling handle_phase_entered
	# against partially-torn-down state.
	if _phase_coord != null:
		_phase_coord.cleanup()
	if _goal_replay_driver != null:
		_goal_replay_driver.stop()
		_goal_replay_driver.queue_free()
		_goal_replay_driver = null
	_stop_post_game_replay()
	if _post_game_replay_driver != null:
		_post_game_replay_driver.queue_free()
		_post_game_replay_driver = null
	_stop_intermission_replay()
	if _intermission_replay_driver != null:
		_intermission_replay_driver.queue_free()
		_intermission_replay_driver = null
	_goal_replay_store = null
	_recorder = null
	_shot_tracker = null
	_pickup_claim = null
	_poke_claim = null
	_stick_lift_claim = null
	_hit_claim = null
	_phase_coord = null
	_swap_coord = null
	if _debug_overlay:
		_debug_overlay.queue_free()
		_debug_overlay = null
	# Mid-game exits (quit to free play, host lost, host ended, kicked) still
	# ship a network-quality row — the sessions that end badly are the most
	# diagnostic ones, and the game-over-only path never saw them. No-op when
	# the game already reported at game-over (the _net_session_reported guard).
	# The take() runs unconditionally so a stale reason never survives teardown.
	var abnormal_reason: String = NetworkManager.take_session_end_reason()
	_report_net_session(abnormal_reason if not abnormal_reason.is_empty() else "quit")
	_telemetry = null
	NetworkTelemetry.instance = null
	_last_emitted_clock_secs = -1
	_puck_oob_timer = 0.0
	_teardown_spectator_camera()
	_spectator_peers.clear()
	_game_id = ""
	NetworkManager.prepare_for_new_game()


func reset_game() -> void:
	# Host-authoritative (offline/free-play are is_host too). A stray client call
	# would reset only that client's SM/stats and fork it from the host; the
	# notify_reset_to_all RPC below is authority-gated so no remote harm, but guard
	# for symmetry with return_to_lobby.
	if not NetworkManager.is_host:
		return
	_drop_puck_if_carried()
	_apply_reset()
	# Each rematch gets its own .mreplay so the viewer doesn't render two
	# games concatenated as one continuous file with a visible score reset
	# in the middle. Host mints the new game_id and ships it so every peer
	# rolls over to the same filename.
	var new_id: String = ""
	if not _game_id.is_empty():
		new_id = PlayerPrefs.generate_uuid()
	NetworkManager.notify_reset_to_all(new_id)
	_rollover_replay_file_to(new_id)
	# A rematch is a fresh match — its opening faceoff gets the intro too.
	_state_machine.begin_faceoff_prep(GameRules.CENTER_ICE_DOT,
			GameRules.PREGAME_INTRO_DURATION if _pregame_intro_eligible() else 0.0)
	_phase_coord.handle_phase_entered()
	game_reset.emit()


func on_game_reset(new_game_id: String = "") -> void:
	# The rematch RPC can land while this client is mid scene-transition
	# (lobby return / disconnect teardown) — guard like sibling RPC handlers.
	if _state_machine == null:
		return
	_apply_reset()
	_rollover_replay_file_to(new_game_id)
	# Clear client-side carry state so PuckController stops pinning to blade.
	var local_record := _registry.get_local() if _registry != null else null
	if local_record != null and local_record.controller.has_puck:
		local_record.controller.on_puck_released_network()
		puck_controller.notify_local_puck_dropped()
	game_reset.emit()


func _apply_reset() -> void:
	# A rematch is a fresh match: fresh telemetry session (its row keys to the
	# new game_id minted by the rollover) and a re-armed reporter guard, so each
	# game posts exactly one row that aggregates only its own play.
	if _telemetry != null:
		_telemetry.reset_session()
	_net_session_reported = false
	# End any highlight reel (post-game loop or a mid-break intermission cut
	# short by the rematch) and drop the previous match's clips so a rematch's
	# screens only reel their own goals.
	_stop_post_game_replay()
	_stop_intermission_replay()
	if _goal_replay_store != null:
		_goal_replay_store.clear()
	_pending_clip_meta = {}
	_state_machine.reset_all()  # also clears the domain-side reserved_slots mirror
	# Clear the host-side reservation store in lockstep with the domain mirror.
	# reset_all() frees the domain slots, so a leftover _reserved_slots entry would
	# force a reconnecting peer into a slot that a rematch joiner/swapper can now
	# retake (double-booking) AND carry the PREVIOUS match's stats into the fresh
	# 0-0 game. Host-only dict; a no-op on clients. Pending expiry timers are token-
	# guarded, so they harmlessly no-op after the clear.
	_reserved_slots.clear()
	_seen_first_prep = false  # next prep is a rematch's opening faceoff
	_last_emitted_clock_secs = -1
	_last_ghost_state.clear()
	_hit_claim.reset_throttle()
	_puck_oob_timer = 0.0
	score_changed.emit(0, 0)
	period_synced.emit(1)
	clock_updated.emit(_state_machine.period_duration)
	_registry.reset_all_stats()
	_shot_tracker.reset_all()
	if _phase_coord != null:
		_phase_coord.reset_goal_log()
	if _turnover_tracker != null:
		_turnover_tracker.reset()
	if _possession_tracker != null:
		_possession_tracker.reset()
	stats_updated.emit()
	# A rematch is a fresh match for ranking purposes: re-derive the two-human
	# latch from who's actually still here.
	_ranked_match = false
	_peak_humans = 0
	_refresh_ranked_match()


# ── Return to Lobby ──────────────────────────────────────────────────────────
func return_to_lobby() -> void:
	if not NetworkManager.is_host:
		return
	_drop_puck_if_carried()
	# Rebuild pending_bot_slots from registry's bot records so the lobby
	# reloads with the same bot configuration the host took into the game.
	# Bots are stripped from the roster (they're not real peers) and instead
	# round-trip as bot-slot markers; this is what restores the "X" action
	# on the host's slot cards. Identities are reconstructed from the
	# PlayerRecord so the lobby card shows the same name/number the bot
	# wore in the previous match instead of falling back to "BOT".
	var bot_slots: Dictionary[int, bool] = {}
	var bot_identities: Dictionary[int, Dictionary] = {}
	if _registry != null:
		for peer_id: int in _registry.all():
			var r: PlayerRecord = _registry.get_record(peer_id)
			if r == null or not r.is_bot or r.team == null:
				continue
			var slot_key: int = LobbySlotKey.encode(r.team.team_id, r.team_slot)
			bot_slots[slot_key] = true
			var bot_identity: Dictionary = r.attributes.to_dict()
			bot_identity["name"] = r.player_name
			bot_identity["number"] = r.jersey_number
			bot_identity["is_left_handed"] = r.is_left_handed
			bot_identities[slot_key] = bot_identity
	NetworkManager.pending_bot_slots = bot_slots
	NetworkManager.pending_bot_identities = bot_identities
	for peer_id: int in NetworkManager.connected_peer_ids():
		NetworkManager.send_bot_slots_to(peer_id, bot_slots, bot_identities)
	NetworkManager.send_return_to_lobby_to_all(_build_lobby_roster_array())


func _on_return_to_lobby(_roster: Array) -> void:
	on_scene_exit()
	NetworkSimManager.clear_pending()
	get_tree().change_scene_to_file(Constants.SCENE_LOBBY)


# Live-update the local skater + record when the player edits their identity
# via the SideMenu's player card. Only safe in offline contexts (free play);
# online identity changes would also need an RPC for peers to mirror, which
# is out of scope for the current free-play work.
func _on_local_identity_changed(p_name: String, p_number: int, p_is_left: bool) -> void:
	if _registry == null:
		return
	var record: PlayerRecord = _registry.get_local()
	if record == null:
		return
	record.player_name = p_name
	record.jersey_number = p_number
	record.is_left_handed = p_is_left
	if record.skater != null:
		record.skater.set_player_name(p_name)
		record.skater.set_jersey_info(p_name, p_number)
		record.skater.is_left_handed = p_is_left


# Repaints the local skater's tape job live. Cosmetic and local-only — remote
# peers keep rendering the tape code from this session's join handshake.
func _on_local_tape_changed(tape_code: int) -> void:
	if _registry == null:
		return
	var record: PlayerRecord = _registry.get_local()
	if record == null:
		return
	record.tape_code = tape_code
	if record.skater != null:
		record.skater.set_tape_config(StickTapeConfig.from_code(tape_code))


# Pushes new attribute multipliers into the live local controller. Always
# updates the record (so the next respawn lands the new values), but only
# touches the running controller when we're not in an active online match —
# online play locks attributes at join time to keep both peers simulating
# the same numbers.
func _on_local_attributes_changed(attrs: PlayerAttributes) -> void:
	if _registry == null or attrs == null:
		return
	var record: PlayerRecord = _registry.get_local()
	if record == null:
		return
	record.attributes = attrs
	# Customized your build — a meta achievement, fired directly (this signal only
	# fires from the free-play picker Apply, where the game-over sweep never runs).
	if _achievements != null:
		_achievements.on_build_edited()
	if NetworkManager.is_in_online_match():
		return
	if record.controller != null:
		(record.controller as SkaterController).apply_attributes(attrs)
		# Refresh the memoized per-peer caps so bots model this player's new build.
		_registry.refresh_caps(record.peer_id)


# Re-tint home (and possibly away) when the local player picks a new
# favorite team palette from the SideMenu's player card. The local skater
# is always on the home team in free play, so we re-skin its uniform and
# the home goalie. If apply_preferred_color also re-rolled the away color
# to avoid a collision, the away goalie gets re-tinted too.
func _on_local_preferred_color_changed(home_color_slot: int, away_color_slot: int) -> void:
	if teams.size() < 2:
		return
	var home_changed: bool = teams[0].color_slot != home_color_slot
	var away_changed: bool = teams[1].color_slot != away_color_slot
	if not home_changed and not away_changed:
		return
	teams[0].color_slot = home_color_slot
	teams[1].color_slot = away_color_slot
	if home_changed:
		_apply_team_colors_to_actors(0)
	if away_changed:
		_apply_team_colors_to_actors(1)
	var home_c: Dictionary = TeamColorRegistry.get_colors(teams[0].color_slot, 0)
	var away_c: Dictionary = TeamColorRegistry.get_colors(teams[1].color_slot, 1)
	team_colors_ready.emit(home_c.primary, home_c.secondary, away_c.primary, away_c.secondary)


func _apply_team_colors_to_actors(team_id: int) -> void:
	var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_slot, team_id)
	# `goalies` is stored positionally ([top, bottom]) while team_id is
	# semantic (0 = home = bottom net, 1 = away = top net) — indexing the
	# array directly by team_id flips the two. Route through the team's
	# goalie_controller, which is the authoritative team-to-goalie binding
	# set up in _spawn_goalies.
	var gc: GoalieController = teams[team_id].goalie_controller
	if gc != null and gc.goalie != null:
		gc.goalie.apply_uniform(colors)
	if _registry == null:
		return
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record == null or record.skater == null or record.team == null:
			continue
		if record.team.team_id != team_id:
			continue
		record.jersey_color = colors.jersey
		record.helmet_color = colors.helmet
		record.pants_color = colors.pants
		record.socks_color = colors.socks
		record.jersey_stripe_color = colors.jersey_stripe
		record.pants_stripe_color = colors.pants_stripe
		record.socks_stripe_color = colors.socks_stripe
		record.text_color = colors.text
		record.text_outline_color = colors.text_outline
		record.secondary_color = colors.secondary
		record.skater.set_uniform(colors)
		record.skater.set_jersey_info(record.player_name, record.jersey_number)


func _build_lobby_roster_array() -> Array:
	var result: Array = []
	if _registry == null:
		return result
	for peer_id: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(peer_id)
		# Bots are not real peers — they round-trip through pending_bot_slots,
		# not the roster. Including them here would render them as human-filled
		# cards in the lobby with no remove action.
		if r.is_bot:
			continue
		var team_id: int = r.team.team_id if r.team != null else 0
		result.append([peer_id, team_id, r.team_slot, r.player_name,
				r.is_left_handed, r.jersey_number])
	# Spectators aren't in _registry, so without this they'd come back to the
	# lobby as orphan peers — no slot, no name, no jersey number — and the
	# host's identity lookup would default everything to "Player" / 10. Append
	# them explicitly using the names/handedness/numbers tracked by
	# NetworkManager from request_join. Spectator slots are reassigned 0..N
	# since the original index isn't preserved across the game session.
	var spec_idx: int = 0
	for peer_id: int in _spectator_peers:
		result.append([peer_id, GameRules.SPECTATOR_TEAM_ID, spec_idx,
				NetworkManager.get_peer_name(peer_id),
				NetworkManager.get_peer_handedness(peer_id),
				NetworkManager.get_peer_number(peer_id)])
		spec_idx += 1
	return result


# Re-read the free-play goalie difficulty and push it onto the live crease
# goalies without a match reload. Free play is effectively the main menu (no
# reload path), so the options-panel goalie dropdown tunes the running goalies in
# place. No-op outside free play and on peers with no host-side goalie controllers.
func refresh_freeplay_goalie_difficulty() -> void:
	if not NetworkManager.is_free_play_mode:
		return
	goalie_skill_profile = GoalieSkillProfile.for_difficulty(PlayerPrefs.freeplay_goalie_difficulty)
	AIActionScoring.set_goalie_profile(goalie_skill_profile)
	for gc: GoalieController in goalie_controllers:
		gc.apply_skill_profile(goalie_skill_profile)


func return_to_free_play() -> void:
	# Free play is the new "home" — there is no main menu screen to land on.
	# Tear down whatever activity the player was in (lobby, match, tutorial,
	# replay), re-arm offline mode with the player's favorite home palette
	# and a random away, and drop them back on the ice. The SideMenu
	# (opened with Escape) is where they pick a new activity.
	on_scene_exit()
	NetworkSimManager.clear_pending()
	NetworkManager.reset()
	NetworkManager.start_free_play()
	get_tree().change_scene_to_file(Constants.SCENE_HOCKEY)


# ── Helpers ──────────────────────────────────────────────────────────────────
func _puck_speed_volume(speed: float) -> float:
	return lerpf(-10.0, 0.0, clampf((speed - 1.0) / 20.0, 0.0, 1.0))


# Base loudness bumps layered on top of the speed curve for the two save cues.
# `_puck_speed_volume` ceilings at 0 dB (it only attenuates), so a hard clang off
# the iron or a fat pad save was never louder than the stream baseline; the bump
# lets a save carry the way it should. Post rings brighter/louder than the
# damped pad thump. Kept in sync with ReplayEventReplayer's mirrored constants.
const _POST_SAVE_VOLUME_BUMP_DB: float = 4.0
const _PAD_SAVE_VOLUME_BUMP_DB: float = 2.0


# Pitch for a puck-off-the-post cue. A hard shot rings the iron bright and
# sharp; a slow puck clunks dull. Speed-driven off the same replicated puck
# velocity the volume uses, so host and remote peers ring a given post alike.
# Kept in sync with ReplayEventReplayer._post_pitch.
func _post_pitch(speed: float) -> float:
	return lerpf(0.9, 1.12, clampf((speed - 5.0) / 25.0, 0.0, 1.0))


# True if a broadcast contact cue arriving now is the echo of a local (predicted)
# play this peer already made — see the _local_*_cue_at doc-block. The window is
# the expected echo delay: the local play leads the host's broadcast by ~one RTT
# (the client's prediction runs ahead, the host echoes back a round-trip later),
# the same RTT-based hand-off the puck predictor's post-contact window uses.
# Clamped so a normal RTT can't under-cover the echo and a lag spike can't gate a
# genuinely separate second contact. `local_cue_at` starts far in the past, so a
# peer that never played locally (never predicted the contact) is never suppressed.
func _cue_is_echo(local_cue_at: float) -> bool:
	var window: float = clampf(NetworkManager.get_latest_rtt_ms() / 1000.0 + 0.05, 0.08, 0.5)
	return NetworkManager.local_time() - local_cue_at < window


# Pitch for a blade deflection cue. A low-speed result is a bobble (the blade
# smothered the puck) and reads duller; a faster exit is a live redirect and reads
# sharp. Speed-driven off the same replicated puck velocity the volume uses, so
# host and remote peers classify a given deflect identically. `puck` may be null
# when a remote cue arrives between spawns — fall back to the redirect pitch.
func _deflection_pitch(speed: float) -> float:
	if puck != null and speed < puck.bobble_speed_threshold:
		return 0.85
	return 1.2


# Drops a carried puck and notifies the remote carrier. Returns the carrier
# peer_id (-1 if no carrier). Host-only — safe to call from dead phases.
func _drop_puck_if_carried() -> int:
	if puck == null or puck.carrier == null:
		return -1
	var carrier_peer_id: int = _resolve_skater_peer_id(puck.carrier)
	puck.drop()
	if carrier_peer_id != -1 and NetworkManager.connected_peer_ids().has(carrier_peer_id):
		NetworkManager.notify_puck_dropped_to_carrier(carrier_peer_id)
	return carrier_peer_id


func _push_lobby_assignments_to_clients() -> void:
	var slots: Dictionary = NetworkManager.pending_lobby_slots
	# Two-phase fan-out. Phase 1 spawns every assigned player on the host and
	# tells each client its own slot — but does NOT broadcast spawn_remote_skater.
	# Phase 2 then sends every connected peer a single sync_existing_players
	# carrying the complete roster minus themselves. Routing every peer through
	# exactly one delivery channel is what prevents the double-spawn that
	# orphaned phantom skaters on clients (a broadcast spawn plus the same peer
	# inside a later client's sync). It also lets the sync carry full attributes
	# via _collect_existing_player_data — the old incremental append dropped them.
	for peer_id: int in slots:
		if peer_id == 1:
			continue
		var entry: Dictionary = slots[peer_id]
		var team_id: int = entry.team_id
		var team_slot: int = entry.team_slot
		if team_id == GameRules.SPECTATOR_TEAM_ID:
			# Spectators get the slot-assignment RPC so they take the SpectatorCamera
			# path on the client. No state-machine slot is reserved and no skater is
			# spawned; the phase-2 sync below renders the player actors for them.
			_spectator_peers[peer_id] = true
			NetworkManager.send_slot_assignment(peer_id, team_slot, team_id,
					Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0))
			continue
		_spawn_player_and_broadcast(
				peer_id, team_id, team_slot,
				entry.get("is_left_handed", true),
				entry.get("player_name", "Player"),
				entry.get("jersey_number", 10), false, false)
	# Phase 2: registry now holds the full roster. Sync it to each peer,
	# excluding their own record (clients spawn their own skater locally via
	# on_slot_assigned, so re-sending it would spawn a remote-controlled twin).
	var full: Array[Array] = _collect_existing_player_data()
	for peer_id: int in slots:
		if peer_id == 1:
			continue
		NetworkManager.send_sync_existing_players(peer_id, _roster_excluding(full, peer_id))
	NetworkManager.pending_lobby_slots = {}


# Returns a copy of a roster array (as built by _collect_existing_player_data)
# with the given peer's entry removed. Used so a client's existing-players sync
# never contains itself.
func _roster_excluding(roster: Array[Array], peer_id: int) -> Array[Array]:
	var out: Array[Array] = []
	for entry: Array in roster:
		if entry[0] != peer_id:
			out.append(entry)
	return out


func _spawn_bots_from_lobby() -> void:
	# Host-only. Iterates pending_bot_slots (set by lobby toggles), spawns an
	# AIController-driven skater per marked slot, and broadcasts a remote-skater
	# spawn so clients render each bot through their existing RemoteController
	# pipeline. Synthetic peer_ids from BOT_ID_BASE (10000) upward avoid
	# colliding with real peers; send_slot_assignment is skipped because it
	# targets peer_ids and bots have no peer connection.
	if not NetworkManager.is_host:
		return
	if NetworkManager.pending_bot_slots.is_empty():
		return
	# Identities were chosen at lobby-toggle time and synced to clients so
	# the lobby UI could preview them — just read them back here.
	var bot_id: int = 0
	for slot_key: int in NetworkManager.pending_bot_slots:
		if not NetworkManager.pending_bot_slots[slot_key]:
			continue
		# Slot keys for non-spectator slots: team*MAX_PER_TEAM+slot (the fixed
		# capacity stride — see LobbySlotKey). Spectator keys are >= 100 and
		# bots can't occupy them; skip defensively.
		if slot_key < 0 or slot_key >= PlayerRules.MAX_PER_TEAM * 2:
			continue
		var team_id: int = LobbySlotKey.team_id(slot_key)
		var team_slot: int = LobbySlotKey.slot(slot_key)
		# 3v3 never fields the D slots even if a stale bot toggle survives a
		# mode flip — the latched size is the roster authority.
		if team_slot >= _state_machine.team_size:
			continue
		# Refuse to overwrite a slot that a human already claimed.
		if _slot_already_taken(team_id, team_slot):
			continue
		var team: Team = teams[team_id]
		var colors: Dictionary = TeamColorRegistry.get_colors(team.color_slot, team_id)
		var identity: Dictionary = NetworkManager.pending_bot_identities.get(slot_key, {})
		var record: PlayerRecord = _registry.spawn_bot(bot_id, team_slot, team, identity)
		_state_machine.register_remote_assigned_player(record.peer_id, team_slot, team_id)
		# Bot visible to clients: same RPC humans use. Clients spawn it as a
		# RemoteController-driven skater because peer_id is not their own.
		# This broadcast is the bot's *sole* delivery channel — bots spawn after
		# _push_lobby_assignments_to_clients runs, so they're never in any
		# sync_existing_players payload. Unlike the human spawn broadcast (removed
		# from the lobby push to stop double-delivery), there's no overlapping
		# channel here, so this must stay. Don't "consolidate" it away.
		NetworkManager.send_spawn_remote_skater(record.peer_id, team_slot, team_id,
				colors.jersey, colors.helmet, colors.pants,
				record.is_left_handed, record.player_name, record.jersey_number, record.attributes)
		bot_id += 1
	# Clear after spawning so a return-to-lobby + restart starts fresh; the
	# host will re-toggle bot slots in the next lobby session if desired.
	NetworkManager.pending_bot_slots = {}
	NetworkManager.pending_bot_identities = {}


func _slot_already_taken(team_id: int, team_slot: int) -> bool:
	for peer_id: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(peer_id)
		if r.team.team_id == team_id and r.team_slot == team_slot:
			return true
	return false


# Public AI-facing snapshot accessor. Captured snapshots and query timestamps
# both live in `NetworkManager.local_time()` (session-relative) — same time
# base as world-state broadcast headers and client claim RPCs, so callers
# can mix host-internal and client-supplied timestamps freely. Pass 0 for
# the freshest captured state.
func get_state_delayed(delay_seconds: float) -> WorldSnapshot:
	if _state_buffer_manager == null:
		return null
	var ts: float = NetworkManager.local_time() - delay_seconds
	return _state_buffer_manager.get_state_at(ts)


# Historical {skater, position, velocity, hit, ghost} for every skater EXCEPT
# `exclude_skater` at `host_ts`, sampled from each remote's interpolation buffer.
# Wired to the local player's LocalController as the reconcile replay's
# body-check re-resolution source (Slice C) — it re-derives contact against where
# the host actually had the others, replacing the old recorded-impulse bridge.
#
# HOT PATH: called once per replayed input during a reconcile (120 Hz × unacked
# window, worst exactly when the network is bad — the case CLAUDE.md forbids
# allocating in). So it fills a persistent scratch Array from a pooled set of
# reused Dictionaries and iterates the roster by key (avoiding the fresh array
# `.values()` copies), instead of allocating an Array + per-other Dictionary each
# call. The caller (LocalController._replay_resolve_body_checks) consumes the
# result read-only within a single call and never retains it across calls, so a
# shared cleared-and-refilled buffer is safe.
var _hist_others_scratch: Array = []
var _hist_others_pool: Array[Dictionary] = []

func _sample_historical_others(exclude_skater: Skater, host_ts: float) -> Array:
	_hist_others_scratch.clear()
	if _registry == null:
		return _hist_others_scratch
	var players: Dictionary = _registry.all()
	for peer_id: int in players:
		var rec: PlayerRecord = players[peer_id]
		if rec.skater == null or rec.skater == exclude_skater:
			continue
		var remote: RemoteController = rec.controller as RemoteController
		if remote == null:
			continue
		var state: SkaterNetworkState = remote.sample_state_at(host_ts)
		if state == null:
			continue
		var idx: int = _hist_others_scratch.size()
		var entry: Dictionary
		if idx < _hist_others_pool.size():
			entry = _hist_others_pool[idx]
		else:
			entry = {}
			_hist_others_pool.append(entry)
		entry["skater"] = rec.skater
		entry["position"] = state.position
		entry["velocity"] = state.velocity
		entry["hit"] = state.hit_committed
		entry["ghost"] = state.is_ghost
		_hist_others_scratch.append(entry)
	return _hist_others_scratch


# Bots' discrete-event reaction delay. Positions/velocities on `snap` stay
# real time; only the puck's CARRIER signal is debounced, so the AI keeps
# acting on its prior read of who-controls-the-puck for carrier_reaction_delay
# seconds after the puck actually changes hands (a pass release, reception, or
# strip) before recognising it — the human "can't react to a pass within a
# tick" model. Self-possession is exempted: the real carrier is stashed on the
# snapshot so a bot reads its OWN possession instantly (see SkaterAgentState-
# Machine have_puck).
#
# The commit rule (and why it is bounded rather than restart-on-change) lives on
# CarrierBelief. Shared across all bots — difficulty is a global match setting
# and a possession change affects both teams symmetrically (matching how the
# team brains are reticked together).
#
# This belief is TEAM SHAPE only. Whether a bot goes and gets a live puck is
# individual reactivity and reads the REAL carrier on its own clock
# (SkaterAgentStateMachine._loose_elapsed_s) — gating that on this lagged belief
# is what used to freeze the whole team off a loose puck for the full window.
func _apply_bot_carrier_reaction_delay(snap: WorldSnapshot, delta: float) -> void:
	if snap.puck_state == null:
		return
	var real_carrier: int = snap.puck_state.carrier_peer_id
	snap.real_puck_carrier_peer_id = real_carrier
	# StateBufferManager._interpolate_puck returns the live ring-buffer object
	# directly when the query is at/after the newest sample (the common case for
	# get_state_delayed(0.0)). Writing the debounced carrier into it would
	# corrupt the authoritative buffer that lag-comp rewind + reconcile read, so
	# the AI snapshot points at a private scratch copy whose carrier we debounce.
	_ai_puck_scratch.copy_from(snap.puck_state)
	snap.puck_state = _ai_puck_scratch
	var delay: float = bot_skill_profile.carrier_reaction_delay_s if bot_skill_profile != null else 0.0
	snap.puck_state.carrier_peer_id = _carrier_belief.update(real_carrier, delay, delta)


func _collect_existing_player_data() -> Array[Array]:
	var existing: Array[Array] = []
	for peer_id: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(peer_id)
		var attrs: PlayerAttributes = r.attributes if r.attributes != null else PlayerAttributes.all_average()
		existing.append([peer_id, r.team_slot, r.team.team_id,
				r.jersey_color, r.helmet_color, r.pants_color,
				r.is_left_handed, r.player_name, r.jersey_number,
				attrs.height, attrs.weight, attrs.profile,
				attrs.curve, attrs.flex, attrs.length,
				r.tape_code])
	return existing


# ── Getters passed as Callables to collaborators ─────────────────────────────
func _get_puck_controller() -> PuckController:
	return puck_controller


func _get_goalie_controllers() -> Array:
	return goalie_controllers


# ── World state (NetworkManager provider callback) ───────────────────────────
func get_world_state() -> PackedByteArray:
	var state: PackedByteArray = _codec.encode_world_state() if _codec != null else PackedByteArray()
	if state.is_empty():
		return state
	var ts: float = NetworkManager.local_time()
	# In-memory recorder feeds GoalReplayDriver. Gated by is_replay_mode (the
	# cinematic is the consumer, not the producer) AND by GOAL_CELEBRATION
	# (the celebration beat is live gameplay; we don't want its frames in the
	# replay clip, which should end at the puck-in-net moment captured via
	# _capture_goal_moment_frame).
	if _recorder != null and not NetworkManager.is_replay_mode() \
			and not _is_celebration_phase():
		_recorder.record_frame(state, ts)
	# File writer throttles to REPLAY_FILE_RATE and skips dead-puck phase ticks
	# past the first one — see _record_world_state_to_file / _should_record_to_file.
	# The first frame on each phase transition captures the puck-in-net moment /
	# faceoff snap / etc.
	_record_world_state_to_file(ts, state)
	return state


# Tee a broadcast world-state frame into the .mreplay file, throttled to
# REPLAY_FILE_RATE. The viewer interpolates between snapshots, so the steady
# PLAYING stream is decimated from STATE_RATE (120 Hz) to ~30 Hz — a ~4x file-
# size cut at no perceptible playback cost. Phase-transition frames bypass the
# throttle (the first frame of a new phase is a keyframe — faceoff snap, the
# resume after a movement-locked gap — and must never be dropped). The goal
# moment is recorded full-rate via force_record, which calls enqueue_frame
# directly rather than this helper. Mirrors the old inline record block: also
# advances _last_recorded_phase so _should_record_to_file's "first frame of a
# locked phase only" gate keeps working.
func _record_world_state_to_file(host_ts: float, data: PackedByteArray) -> void:
	if _replay_file_writer == null or not _should_record_to_file():
		return
	var phase_did_change: bool = _state_machine != null \
			and _state_machine.current_phase != _last_recorded_phase
	if not phase_did_change \
			and host_ts - _last_file_frame_ts < 1.0 / float(Constants.REPLAY_FILE_RATE):
		return
	_replay_file_writer.enqueue_frame(host_ts, data)
	_last_file_frame_ts = host_ts
	if _state_machine != null:
		_last_recorded_phase = _state_machine.current_phase


func _should_record_to_file() -> bool:
	if NetworkManager.is_replay_mode():
		return false
	if _state_machine == null:
		return true
	var phase: int = _state_machine.current_phase
	# FACEOFF_PREP is movement-locked for INPUT, but the skaters actively skate in
	# to the dot over the "2 → 1 → DROP" countdown (PhaseCoordinator.begin_approach).
	# Record it at the normal throttled rate so the replay plays the walk-up —
	# capturing only the first (pre-approach) frame made the viewer teleport
	# straight from there to the drop. The crossing bracket into FACEOFF_PREP is
	# still a clean cut in FileReplayDriver (_is_faceoff_reset_bracket), so the
	# puck's reset-to-dot doesn't smear; the intra-prep brackets interpolate.
	if phase == GamePhase.Phase.FACEOFF_PREP:
		return true
	if PhaseRules.is_movement_locked(phase):
		# Capture only the first frame of each movement-locked phase. Goal:
		# the puck-in-net moment on GOAL_SCORED entry — without this, the
		# last recorded frame before the gap is the previous PLAYING tick,
		# which usually shows the puck still approaching the net rather
		# than inside it. Subsequent ticks at 5 Hz are duplicate static
		# state and add nothing.
		return phase != _last_recorded_phase
	return true


# ── Public API consumed by controllers, HUD, camera, scoreboard ──────────────
func is_host() -> bool:
	return NetworkManager.is_host


func is_movement_locked() -> bool:
	if _state_machine == null:
		return false
	return _state_machine.is_movement_locked()


# True during the FACEOFF_PREP countdown. Read by SkaterController's gait
# (via the game_state interface) to pose the faceoff ready stance — phase is
# replicated, so every machine answers identically.
func is_faceoff_prep() -> bool:
	if _state_machine == null:
		return false
	return _state_machine.current_phase == GamePhase.Phase.FACEOFF_PREP


# True during the between-period break (END_OF_PERIOD). Read by
# SkaterController.tick_faceoff_approach (via the game_state interface) so the
# period-break skate-off glide runs under the same movement lock that freezes
# everything else — same replicated-phase determinism as is_faceoff_prep.
func is_period_break() -> bool:
	if _state_machine == null:
		return false
	return _state_machine.current_phase == GamePhase.Phase.END_OF_PERIOD


# Seconds until the puck drops during FACEOFF_PREP (0 otherwise). Read by the AI
# center to time its draw swing to crest on the drop (AIController).
func faceoff_time_until_drop() -> float:
	if _state_machine == null:
		return 0.0
	return _state_machine.faceoff_prep_time_until_drop()


# Cosmetic: the scorer raises the stick and bounces through the
# GOAL_CELEBRATION beat. goal_scored is emitted locally on every machine (host
# detects, clients get notify_goal), so the timer starts EVERYWHERE for the
# scorer's record: machines that simulate the skater apply the raised-stick
# pose (which rides the hand/blade wire state outward — including the host's
# sim of a remote human scorer, which previously never fired, leaving their
# celebration invisible to everyone else), and every machine's gait reads the
# same timer for the celebration leg bounce (legs are computed locally per
# machine and never ride the wire).
func _trigger_scorer_celebration(_team: Team, scorer_name: String,
		_assist1: String, _assist2: String) -> void:
	if scorer_name.is_empty():
		return
	for record: PlayerRecord in _registry.all().values():
		if record.player_name != scorer_name or record.controller == null:
			continue
		record.controller.start_celebration(GameRules.GOAL_CELEBRATION_DURATION)
		return


func allows_blade_aim_during_lock() -> bool:
	if _state_machine == null:
		return false
	return _state_machine.allows_blade_aim_during_lock()


func is_input_blocked() -> bool:
	return _input_blocked


func set_input_blocked(blocked: bool) -> void:
	_input_blocked = blocked


func get_skater_team(skater: Skater) -> Team:
	return _registry.resolve_team(skater) if _registry != null else null


# The scorer's live Skater, resolved by name (same lookup the celebration uses).
# Null if the name doesn't match a record — callers fall back. Used by the goal
# hero-cam to frame/follow the scorer.
func get_scorer_skater(scorer_name: String) -> Skater:
	if _registry == null or scorer_name.is_empty():
		return null
	for record: PlayerRecord in _registry.all().values():
		if record.player_name == scorer_name:
			return record.skater
	return null


func get_puck() -> Puck:
	return puck


# Tutorial-only: enable offsides ghosting on/off for the active step. The
# OFFSIDES step turns it on; every other step (including one-timer, which
# legitimately positions the player deep in the O-zone) leaves it off.
func set_tutorial_offsides_active(active: bool) -> void:
	_tutorial_offsides_active = active


# Tutorial-only: put the puck on a skater's stick through the same grant path
# as a real pickup (PuckController bookkeeping + controller notify). A bare
# Puck.set_carrier skips PuckController's carrier tracking, so the release
# that follows never notifies the controller — has_puck leaks true and the
# player can "shoot" a puck that isn't on their stick.
func tutorial_give_puck(record: PlayerRecord) -> void:
	if puck == null or puck_controller == null or record == null \
			or not is_instance_valid(record.skater):
		return
	if puck.carrier == record.skater:
		return
	if puck.carrier != null:
		puck.drop()
	puck_controller.apply_lag_comp_pickup(record.skater)


# Spawn an AI-controlled bot in scripted/puppet mode for tutorial
# demonstrations — an opponent on team 1 (default) or a teammate on team 0
# for the passing drills. The bot uses the same spawn path as normal bots
# (so team_id resolver, jersey colors, etc. all wire up correctly — this is
# what fixes the stickcheck/body-check unreliability the static dummy
# suffered from), then is flipped into scripted_mode and excluded from
# TeamBrain role assignment.
#
# Returns the PlayerRecord so the tutorial can hold a reference for
# script_* commands and free it later via despawn_tutorial_bot.
func spawn_tutorial_bot(position: Vector3, bot_id: int = 0, team_id: int = 1) -> PlayerRecord:
	if _registry == null or teams.size() < 2:
		return null
	var team: Team = teams[team_id]
	# The tutorial player occupies team 0 slot 0, so a teammate puppet takes
	# slot 1; opponent puppets keep slot 0 on team 1.
	var team_slot: int = 1 if team_id == 0 else 0
	var identity: Dictionary = {"name": "Tutorial", "number": 99, "is_left_handed": false}
	var record: PlayerRecord = _registry.spawn_bot(bot_id, team_slot, team, identity)
	if record == null:
		return null
	# Position the bot at the requested location (spawn_bot places it at the
	# faceoff position by default).
	if record.skater != null:
		record.skater.global_position = position
	var ai_ctrl: AIController = record.controller as AIController
	if ai_ctrl != null:
		ai_ctrl.set_scripted_mode(true)
	if team.team_id < team_brains.size():
		team_brains[team.team_id].exclude_skater(record.peer_id)
	return record


# Tear down a puppeted bot spawned by spawn_tutorial_bot. Drops the puck
# first if the bot was carrying it so the carrier pointer doesn't dangle,
# re-includes the peer in its TeamBrain (defensive — the registry remove
# will also drop the slot), and frees the skater + controller nodes.
func despawn_tutorial_bot(record: PlayerRecord) -> void:
	if record == null or _registry == null:
		return
	if puck != null and puck.carrier == record.skater:
		puck.drop()
	if record.team != null and record.team.team_id < team_brains.size():
		team_brains[record.team.team_id].include_skater(record.peer_id)
	_registry.remove(record.peer_id)


# Spawns a single goalie in the net the tutorial player attacks (team 0 shoots
# toward -Z). Two modes:
#   live=false (default) — STATIONARY shooting target for the "Beat the Goalie"
#     drill: is_server=false wires no puck-reaction signals and the AI tick is
#     disabled, so it freezes in the crease (where setup() places it). Its
#     collision still saves shots, so the corners and five-hole are the only gaps.
#   live=true — the FINALE goalie: is_server=true wires the puck-reaction signals
#     and the AI tick is left running, and it gets the beginner-tuned EASY profile
#     so it tracks, positions, and saves like a real goalie while staying scorable.
#     (The optional skater-getter is left unset — crease-jam / screen reads guard
#     on is_valid() and simply no-op solo, which is correct in a 1-shooter drill.)
# Idempotent: a second call while one exists is a no-op.
func spawn_tutorial_goalie(live: bool = false) -> void:
	if _tutorial_goalie != null:
		return
	if _spawner == null or puck == null:
		return
	var result: Dictionary = _spawner.spawn_single_goalie(puck, -GameRules.GOAL_LINE_Z, live)
	_tutorial_goalie = result.goalie as Goalie
	_tutorial_goalie_controller = result.controller as GoalieController
	if live:
		_tutorial_goalie_controller.apply_skill_profile(GoalieSkillProfile.easy())
	else:
		_tutorial_goalie_controller.set_physics_process(false)
		_tutorial_goalie_controller.set_process(false)
		# Frozen AI never ticks the pose builder, so force the upright stance
		# once — otherwise the goalie holds the scene-default pose with its pads
		# together, hiding the five-hole the drill asks the player to shoot at.
		# open_five_hole widens the pads and lifts the paddle off the ice so the
		# low centre shot the drill teaches has a real lane through.
		_tutorial_goalie_controller.snap_to_standing_pose(true)
	if teams.size() > 1:
		var colors: Dictionary = TeamColorRegistry.get_colors(teams[1].color_slot, 1)
		_tutorial_goalie.apply_uniform(colors)
		_tutorial_goalie.apply_jersey_info("WARD", 35)


func despawn_tutorial_goalie() -> void:
	if _tutorial_goalie_controller != null:
		_tutorial_goalie_controller.queue_free()
		_tutorial_goalie_controller = null
	if _tutorial_goalie != null:
		_tutorial_goalie.queue_free()
		_tutorial_goalie = null


# Reactive goalie defending the -Z net (the one team 0 attacks) for the penalty
# drill. Unlike the tutorial goalie, AI ticks normally so it challenges and
# saves the breakaway. Difficulty follows the match goalie_skill_profile.
# Idempotent: a second call while one exists is a no-op.
func spawn_penalty_goalie() -> void:
	if _penalty_goalie != null:
		return
	if _spawner == null or puck == null:
		return
	var result: Dictionary = _spawner.spawn_single_goalie(
			puck, -GameRules.GOAL_LINE_Z, true, goalie_skill_profile)
	_penalty_goalie = result.goalie as Goalie
	_penalty_goalie_controller = result.controller as GoalieController
	# The -Z net belongs to team 1 (the side team 0 attacks); match the pair's
	# wiring so the AI's threat/facing logic reads the breakaway correctly.
	_penalty_goalie_controller.team_id = 1
	if teams.size() > 1:
		var colors: Dictionary = TeamColorRegistry.get_colors(teams[1].color_slot, 1)
		_penalty_goalie.apply_uniform(colors)
		_penalty_goalie.apply_jersey_info("WARD", 35)


func despawn_penalty_goalie() -> void:
	if _penalty_goalie_controller != null:
		_penalty_goalie_controller.queue_free()
		_penalty_goalie_controller = null
	if _penalty_goalie != null:
		_penalty_goalie.queue_free()
		_penalty_goalie = null


# Drops the penalty-drill goalie back into its crease between attempts.
func reset_penalty_goalie() -> void:
	if _penalty_goalie_controller != null:
		_penalty_goalie_controller.reset_to_crease()


func get_goalie_data() -> Array[Dictionary]:
	return _cached_goalie_data


# Rebuilds `_cached_goalie_data` from the live goalies array. Reuses each
# Dictionary in place so the steady-state per-tick cost is three key
# writes per goalie rather than a full Array+Dictionary allocation. The single-
# net drill goalies (tutorial / penalty), kept out of the `goalies` array, are
# appended when present so the analytic blade AND body clamps hold the skater
# clear of them too — otherwise the move_and_slide removal would let a skater
# walk through the drill goalie into the net.
func _refresh_goalie_data_cache() -> void:
	var n: int = goalies.size()
	var extra: int = 0
	if _tutorial_goalie != null:
		extra += 1
	if _penalty_goalie != null:
		extra += 1
	var total: int = n + extra
	while _cached_goalie_data.size() < total:
		_cached_goalie_data.append({})
	while _cached_goalie_data.size() > total:
		_cached_goalie_data.pop_back()
	for i: int in range(n):
		_write_goalie_data_entry(_cached_goalie_data[i], goalies[i], goalie_controllers[i])
	var idx: int = n
	if _tutorial_goalie != null:
		_write_goalie_data_entry(_cached_goalie_data[idx], _tutorial_goalie, _tutorial_goalie_controller)
		idx += 1
	if _penalty_goalie != null:
		_write_goalie_data_entry(_cached_goalie_data[idx], _penalty_goalie, _penalty_goalie_controller)
		idx += 1


func _write_goalie_data_entry(entry: Dictionary, g: Goalie, gc: GoalieController) -> void:
	entry["position"] = g.global_position
	entry["rotation_y"] = g.get_goalie_rotation_y()
	entry["is_butterfly"] = gc.is_butterfly() if gc != null else false


func get_slot_roster() -> Array[Dictionary]:
	return _registry.get_slot_roster() if _registry != null else []


func get_local_player() -> PlayerRecord:
	return _registry.get_local() if _registry != null else null


func get_players() -> Dictionary[int, PlayerRecord]:
	if _registry == null:
		var empty: Dictionary[int, PlayerRecord] = {}
		return empty
	return _registry.all()


# ── Smart ping (context-sensitive team message) ──────────────────────────────
# HUD input → try_send_smart_ping resolves the local cursor context
# (PingRules.resolve on the pinger's rendered world) and hands the tiny
# resolved payload to NetworkManager's vote-shaped relay. Every peer's
# smart_ping_received then lands in _on_smart_ping_received: teammates see
# the bubble / marker, and the host routes the bot directive into the
# pinger's TeamBrain.

func try_send_smart_ping() -> void:
	if NetworkManager.is_replay_mode() or is_local_spectator():
		return
	var rec: PlayerRecord = get_local_player()
	if rec == null or rec.skater == null:
		return
	var lc := rec.controller as LocalController
	if lc == null:
		return
	var input: InputState = lc.get_current_input()
	if input == null:
		return
	var my_team: int = _registry.team_id_by_peer.get(rec.peer_id, -1)
	if my_team == -1:
		return
	var res: PingRules.Resolution = PingRules.resolve(
			input.mouse_world_pos, rec.peer_id, my_team,
			_collect_skater_positions(), _registry.team_id_by_peer,
			puck_controller.get_carrier_peer_id() if puck_controller != null else -1,
			puck.global_position if puck != null else Vector3.ZERO)
	if res == null:
		return
	NetworkManager.send_smart_ping(res.type, res.target_peer, res.world_pos)


func _on_smart_ping_received(sender_peer_id: int, ping_type: int,
		target_peer_id: int, world_pos: Vector3) -> void:
	if _registry == null or not PingRules.is_valid_type(ping_type):
		return
	var sender_team: int = _registry.team_id_by_peer.get(sender_peer_id, -1)
	if sender_team == -1:
		return  # unknown / spectator sender — nothing to show or obey

	# Display is team-only: a ping is a team message, and hiding it from the
	# opponents keeps "Pass to me!" from telegraphing the play.
	var local_team: int = _registry.team_id_by_peer.get(NetworkManager.local_peer_id(), -1)
	if local_team == sender_team and not NetworkManager.is_replay_mode():
		if ping_type == PingRules.Type.GO_THERE:
			_spawn_ping_marker(world_pos, tr(PingRules.message_key_for(ping_type)))
		else:
			var sender_rec: PlayerRecord = _registry.get_record(sender_peer_id)
			if sender_rec != null and sender_rec.skater != null:
				sender_rec.skater.show_ping_bubble(tr(PingRules.message_key_for(ping_type)))
		SoundManager.play_ui(SoundManager.Sound.UI_CLICK)

	# Bot obedience is host-only (bots are host-simulated; offline free play
	# runs the full host path, so this covers solo too).
	if not NetworkManager.is_host or team_brains.is_empty():
		return
	if sender_team < 0 or sender_team >= team_brains.size():
		return
	var positions: Dictionary = _collect_skater_positions()
	var bot_peers: Array = []
	var players: Dictionary[int, PlayerRecord] = get_players()
	for pid: int in players:
		if players[pid].is_bot \
				and _registry.team_id_by_peer.get(pid, -1) == sender_team:
			bot_peers.append(pid)
	var carrier_pid: int = puck_controller.get_carrier_peer_id() \
			if puck_controller != null else -1
	var obeyer: int = PingRules.choose_obeyer(
			ping_type, target_peer_id, world_pos, sender_peer_id, carrier_pid,
			puck.global_position if puck != null else Vector3.ZERO,
			bot_peers, positions)
	team_brains[sender_team].apply_ping(
			ping_type, sender_peer_id, target_peer_id, obeyer, world_pos)


func _collect_skater_positions() -> Dictionary:
	var positions: Dictionary = {}
	var players: Dictionary[int, PlayerRecord] = get_players()
	for pid: int in players:
		var r: PlayerRecord = players[pid]
		if r.skater != null:
			positions[pid] = r.skater.global_position
	return positions


func _spawn_ping_marker(pos: Vector3, text: String) -> void:
	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return
	scene_root.add_child(PingMarker.create(pos, text))


func get_period_duration() -> float:
	return _state_machine.period_duration if _state_machine != null else GameRules.PERIOD_DURATION


func get_num_periods() -> int:
	return _state_machine.num_periods if _state_machine != null else GameRules.NUM_PERIODS


func get_rule_set() -> int:
	return _state_machine.rule_set if _state_machine != null else GameRules.DEFAULT_RULE_SET


func get_team_size() -> int:
	return _state_machine.team_size if _state_machine != null else GameRules.DEFAULT_TEAM_SIZE


func get_period_scores() -> Array:
	if _state_machine == null:
		return GameStateMachine._make_period_scores(GameRules.NUM_PERIODS)
	return _state_machine.period_scores


func apply_stats(data: Array) -> void:
	_on_stats_received(data)


# Gathers the release context for the shot log. The defending goalie is the one
# whose net the shooter is attacking; an unresolved team or a goalie-less mode
# (drills, tutorial) leaves the array empty, which keeps ShotEvent's neutral
# defaults rather than logging a fabricated set keeper.
func _note_shot_context(vel: Vector3, shooter_team: int) -> void:
	if shooter_team != 0 and shooter_team != 1:
		return
	var defending: int = 1 - shooter_team
	if defending >= teams.size():
		return
	var gc: GoalieController = teams[defending].goalie_controller
	if gc == null:
		return
	var shooter_speed: float = 0.0
	if _registry != null:
		var rec: PlayerRecord = _registry.get_record(_shot_tracker.get_shooter_peer_id())
		if rec != null and rec.skater != null:
			shooter_speed = Vector2(rec.skater.velocity.x, rec.skater.velocity.z).length()
	_shot_tracker.note_goalie_context([
		gc.stance(), gc.unset_fraction(), gc.challenge_radius(), gc.lateral_x(),
		gc.screen_delay_for(vel), shooter_speed, gc.seconds_since_last_save(),
		absf(vel.x),
	])
