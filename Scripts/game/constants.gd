extends Node

# Engine-facing constants only. Game-rule constants (rink geometry, faceoffs,
# icing, ice friction) live in Scripts/domain/config/game_rules.gd. RENDER layers
# are engine-facing but live in render_layers.gd, because @tool scripts set them
# while building geometry in the editor, where autoloads don't exist.

# ── Collision Layers ──────────────────────────────────────────────────────────
# Identity tags on the goalie's StaticBody3D parts, NOT collision filters —
# nothing in the game collides through the physics server, and the goalie is the
# only actor carrying colliders at all (ARCHITECTURE.md → Collision Layers).
# GoalieContactDetector reads those shapes directly and skips any part whose
# collision_layer is 0, which is how set_stick_collision_enabled takes the stick
# out of play mid-sweep.
const LAYER_GOALIE_STICK: int   = 4
const LAYER_GOALIE_BODIES: int  = 128

# ── Network (transport-level) ─────────────────────────────────────────────────
# Client input batches are sent once per physics tick. Matching PHYSICS_TICK
# minimizes the batch-send wait folded into ClockSync.INPUT_LEAD_SEC, which
# derives BATCH_INTERVAL from this constant.
const INPUT_RATE: int = 120
# World-state broadcast rate — deliberately HALF INPUT_RATE. How fresh a client
# feels does not ride this rate: the loose puck re-predicts from the newest
# snapshot to host-present every frame on the shared solver (so a sparser stream
# costs a slightly larger residual when a host-side bounce/save/deflect lands
# between packets, not staleness), the local player is predicted and reconciled
# on acks, and remote interpolation cushions include one broadcast_interval so
# they widen automatically. Halving it halves host per-tick encode/send cost and
# upload — a 3-human playtest measured ~140 KB/s at 2 peers against a
# ~60 KB/s-per-peer guide, and 5v5 would otherwise need ~5 Mbps of host upload.
# PHYSICS_TICK must stay an integer multiple (_state_tick_divisor).
const STATE_RATE: int = 60
# Rate at which world-state snapshots are written to the .mreplay file, below
# STATE_RATE: the viewer interpolates between snapshots (ReplayPlaybackEngine),
# so 30 Hz keeps playback smooth at a fraction of the file size. Only the steady
# PLAYING stream is throttled — phase-transition keyframes and the goal moment
# are always recorded (GameManager._record_world_state_to_file).
const REPLAY_FILE_RATE: int = 30
# Client-side render delay when interpolating buffered snapshots. Shared default
# for RemoteController / PuckController / GoalieController; each controller
# still exposes it as @export so individual actors can be tuned independently.
const NETWORK_INTERPOLATION_DELAY: float = 0.075
# How far a remote skater is intent-integrated from its interpolated-past base
# toward this client's render instant, as a fraction of (interp_delay + input
# lead): 0.0 = pure interpolate-in-the-past, no integration at all; 1.0 = the
# body lands on estimated_host_time() + lead, the same instant this client's own
# predicted skater occupies (the one clock the whole rendered scene shares — see
# Scripts/networking/CLAUDE.md). READ BY BOTH the client render
# (RemoteController) AND every carrier-anchored host claim rewind (hit, poke,
# stick-lift — LagCompRewind.forward_predict_skater / forward_predict_ticks):
# all consumers MUST use the same fraction, or render stops equalling rewind.
# Dial toward 0.5 / 0.0 if remote skaters overshoot on hard cuts (extrapolation
# snap-back) or contested-hit feel regresses.
const REMOTE_FORWARD_PREDICT_FRACTION: float = 1.0
# Ticks over which the forward prediction's assumed (held) move-intent fades
# linearly to 0, so the far end of the window coasts on friction instead of
# thrusting in a possibly-stale direction. A SMALL lever: at skating speed thrust
# nearly balances friction, so momentum dominates and the decay moves only ~2-6%
# of the predicted displacement (90-degree stale intent at RTT 200: 68 mm of
# lateral drift at decay 0 vs 24 mm at 5, against ~1.03 m of forward travel) —
# REMOTE_FORWARD_PREDICT_FRACTION is the dominant lever. Read by BOTH the client
# render (RemoteController) and the host claim rewind (HitClaimResolver) via
# SkaterMovementRules.integrate_forward, so the decay is identical on both.
# 0 = no decay (full intent every tick); ~5 fades over the near half of a
# full-lead (~9-tick) window.
const FORWARD_PREDICT_INTENT_DECAY_TICKS: int = 5
# Depth cap on the client-side loose-puck prediction (Scripts/networking/
# CLAUDE.md → puck modes): a snapshot older than this — deep packet loss, clock
# warmup — is too stale to predict from, and the client falls back to the
# interpolation path, whose extrapolation cap + hold handle starvation
# gracefully.
const PUCK_PREDICT_MAX_S: float = 0.35
# Wire encoding for session-relative timestamps: u32 in 0.1 ms units (seconds ×
# this scale), constant-precision over a ~119-hour range. Encode with roundi so
# round-trips through the grid are exact; bump BuildInfo.PROTOCOL_VERSION and
# ReplayFileWriter.FORMAT_VERSION if this representation ever changes.
const TIME_WIRE_SCALE: float = 10000.0

# ── Physics ───────────────────────────────────────────────────────────────────
# Single source of truth for the GDScript-side tick rate: every tick-derived
# timing constant (clock-sync input lead, AI charge/cooldown windows, telemetry
# windows) preloads this file and divides PHYSICS_TICK, so they all track it.
# The ENGINE steps at project.godot's physics/common/physics_ticks_per_second,
# which is a SEPARATE knob — to change the tick rate, edit BOTH. `_ready()` below
# push_errors at boot if they drift (a mismatch silently dilates the sim).
const PHYSICS_TICK: int = 120
# One physics step, in seconds. Derived here so the tick-domain clocks (the sim
# clock in NetworkManager, ClockSync's lead servo) and the rules that quantize to
# the tick grid all read the same value PHYSICS_TICK defines.
const TICK_DURATION: float = 1.0 / float(PHYSICS_TICK)

# ── Scenes ────────────────────────────────────────────────────────────────────
const SCENE_BOOT: String          = "res://Scenes/Boot.tscn"
const SCENE_HOCKEY: String        = "res://Scenes/Hockey.tscn"
const SCENE_LOBBY: String         = "res://Scenes/Lobby.tscn"
const SCENE_REPLAY_VIEWER: String = "res://Scenes/ReplayViewer.tscn"


func _ready() -> void:
	var engine_tick: int = int(ProjectSettings.get_setting(
			"physics/common/physics_ticks_per_second", PHYSICS_TICK))
	if engine_tick != PHYSICS_TICK:
		push_error(("Constants.PHYSICS_TICK (%d) != project.godot " +
				"physics_ticks_per_second (%d) — update both to change the tick rate.") %
				[PHYSICS_TICK, engine_tick])
