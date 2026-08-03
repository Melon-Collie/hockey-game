extends Node

# Engine-facing constants only. Game-rule constants (faceoff timings, rink
# geometry, puck position, icing duration, faceoff positions, max players,
# ice friction) live in Scripts/domain/config/game_rules.gd as a class_name
# const class.

# ── Collision Layers ──────────────────────────────────────────────────────────
# NOTHING IN THE GAME COLLIDES THROUGH THE PHYSICS SERVER. Every contact — puck
# vs. geometry, skater vs. skater, skater vs. boards / net / goalie, blade vs.
# puck — is solved analytically in GDScript, no code anywhere runs a ray, shape,
# or overlap query, and every collision_mask in the project is 0. The rink, the
# nets, and the actors carry no colliders at all; the goalie is the sole
# exception, and only because his parts ARE the save geometry.
#
# So a layer here is not a collision filter. It is an IDENTITY TAG on the goalie's
# StaticBody3D parts, whose shapes and transforms GoalieContactDetector reads
# directly — and a NONZERO tag is what marks a part live, since the detector skips
# any part whose collision_layer is 0 (that is how set_stick_collision_enabled
# takes the stick out of play mid-sweep).
#
# Layer 1 (bit 0, value  1) — tutorial/drill obstacle walls
# Layer 3 (bit 2, value  4) — goalie stick
# Layer 8 (bit 7, value 128) — goalie bodies (pads/body/head/glove/blocker)
# Layers 2, 4, 5, 6, 7 are free: they tagged the skater blade Area3Ds, the puck
# RigidBody3D, the skater CharacterBody3Ds, the boards, and the net, none of
# which exist any more.
const LAYER_WALLS: int          = 1
const LAYER_GOALIE_STICK: int   = 4
const LAYER_GOALIE_BODIES: int  = 128

# ── Network (transport-level) ─────────────────────────────────────────────────
const PORT: int = 7777
# Client input batches are sent once per physics tick. Matching PHYSICS_TICK
# minimizes the batch-send wait folded into ClockSync.INPUT_LEAD_SEC (which
# derives BATCH_INTERVAL from this constant) — at 60 Hz the worst-case wait was
# a full 16.7 ms of client→host latency on every input.
const INPUT_RATE: int = 120
# World-state broadcast rate. 60, NOT the 120 that INPUT_RATE runs at — the
# determinism work (shared analytic puck step + predict-to-host-present, and
# render == rewind) decoupled how fresh a client FEELS from how often packets
# arrive, so the extra 60 Hz was paying host cost and bandwidth for very little:
#   • The loose puck re-predicts from the newest snapshot to host-present every
#     frame on the shared solver, so a sparser snapshot stream costs only a
#     slightly larger residual when a host-side event (bounce, save, deflect)
#     lands between packets — not staleness.
#   • The local player is predicted + reconciled on acks, so it is rate-free.
#   • Remote skaters interpolate, and their cushion follows automatically:
#     _compute_target_interpolation_delay includes one broadcast_interval, so
#     the delay grows ~8.3 ms and render == rewind still holds (the claim
#     rewinds read the same adapted delay).
# What it buys: host per-tick encode/send cost and upload both halve (a 3-human
# playtest measured ~140 KB/s at 2 peers, over the ~60 KB/s-per-peer guide), and
# 5v5 stops needing ~5 Mbps of host upload. The host stalls that drive input
# backlog → drains → client reconcile churn are exactly the per-tick cost this
# relieves. PHYSICS_TICK must stay an integer multiple (_state_tick_divisor).
const STATE_RATE: int = 60
# Rate at which world-state snapshots are written to the .mreplay file, well
# below STATE_RATE: the replay viewer interpolates between snapshots (see
# ReplayPlaybackEngine), so recording every 120 Hz broadcast is ~4x redundant on
# disk. 30 Hz keeps playback smooth at roughly a quarter the file size. Only the
# steady PLAYING stream is throttled — phase-transition keyframes and the goal
# moment are always recorded (GameManager._record_world_state_to_file).
const REPLAY_FILE_RATE: int = 30
# Client-side render delay when interpolating buffered snapshots. Shared default
# for RemoteController / PuckController / GoalieController; each controller
# still exposes it as @export so individual actors can be tuned independently.
const NETWORK_INTERPOLATION_DELAY: float = 0.075
# Stage-3 remote forward-prediction (see docs/netcode-forward-prediction-plan.md).
# How far a remote skater is intent-integrated from its interpolated-past base
# toward host-present, as a fraction of interp_delay: 0.0 = legacy interpolate-in-
# the-past (render == rewind exactly, the shipped behavior); 1.0 = full ~interp_delay
# of forward prediction (remote bodies render at ~present). READ BY BOTH the client
# render (RemoteController) AND every carrier-anchored host claim rewind (hit, poke,
# stick-lift — via LagCompRewind.forward_predict_skater / forward_predict_ticks), so
# render stays == rewind at any value — all consumers MUST use the same fraction. Set to 1.0 (full ~interp_delay of forward
# prediction, remote bodies at ~present) for the experimental Steam playtest build.
# Dial toward 0.5 / 0.0 if remote skaters overshoot on hard cuts (extrapolation
# snap-back) or contested-hit feel regresses; 0.0 restores exact render == rewind.
const REMOTE_FORWARD_PREDICT_FRACTION: float = 1.0
# Rocket-League-style input decay for the forward prediction: over this many ticks
# the assumed (held) move-intent fades linearly to 0, so the far end of the
# prediction window coasts on friction instead of thrusting in a possibly-stale
# direction. This is what tames overshoot when a remote player CUTS mid-window —
# the single biggest quality lever on the skater lead. Read by BOTH the client
# render (RemoteController) and the host claim rewind (HitClaimResolver) via
# SkaterMovementRules.integrate_forward, so the decay is identical and render ==
# rewind holds. 0 = no decay (full intent every tick). ~5 fades over the near half
# of a full-lead (~9-tick) window; lower = more conservative (less overshoot, less
# catch-up), higher = more aggressive. Tune alongside REMOTE_FORWARD_PREDICT_FRACTION.
const FORWARD_PREDICT_INTENT_DECAY_TICKS: int = 5
# Phase-3/4b determinism migration (docs/netcode-determinism-migration.md):
# every client runs the SAME analytic sim the host drives the loose puck with,
# forward to its estimate of host present — real predict-and-reconcile; the
# loose puck is never interpolated except as the stale-data fallback. The
# source is the newest authoritative snapshot, or — for the shooter's own
# release, until the host's snapshots reflect it — the local release seed
# (PuckController._release_seed_*). Static geometry (boards, posts, crossbar,
# net) is fully predicted via the shared PuckAuthorityRules step; goalie
# contact is a prediction STOP (hold at the contact — the save outcome is a
# host decision, never re-derived client-side). Host claim rewinds for the
# LOOSE puck (pickup, one-timer range gate) read the claim stamp — see
# LagCompRewind.puck_view_time — so render == rewind holds at present.
# Prediction depth cap: a snapshot older than this (deep packet loss) is too
# stale to predict from — the client falls back to the legacy interpolation
# path, whose extrapolation cap + hold already handle starvation gracefully.
const PUCK_PREDICT_MAX_S: float = 0.35
# Wire encoding for session-relative timestamps: u32 in 0.1 ms units
# (seconds × this scale). Replaces f32 seconds, whose ULP degraded with host
# uptime — ~1 ms error at 2.3 h (visible interpolation jitter), ~2 ms at
# 4.6 h (per-tick input stamps quantize equal and get dropped as duplicates).
# u32 @ 0.1 ms gives constant precision over a ~119-hour range. Encode with
# roundi so round-trips through the grid are exact; bump
# BuildInfo.PROTOCOL_VERSION and ReplayFileWriter.FORMAT_VERSION if this
# representation ever changes again.
const TIME_WIRE_SCALE: float = 10000.0

# ── Physics ───────────────────────────────────────────────────────────────────
# Single source of truth for the GDScript-side tick rate: every tick-derived
# timing constant (clock-sync input lead, AI charge/cooldown windows, telemetry
# windows) preloads this file and divides PHYSICS_TICK, so they all track it.
# The ENGINE steps at project.godot's physics/common/physics_ticks_per_second,
# which is a SEPARATE knob — to change the tick rate, edit BOTH. `_ready()` below
# push_errors at boot if they drift (a mismatch silently dilates the sim).
const PHYSICS_TICK: int = 120

# ── Scenes ────────────────────────────────────────────────────────────────────
const SCENE_BOOT: String          = "res://Scenes/Boot.tscn"
const SCENE_HOCKEY: String        = "res://Scenes/Hockey.tscn"
const SCENE_LOBBY: String         = "res://Scenes/Lobby.tscn"
const SCENE_REPLAY_VIEWER: String = "res://Scenes/ReplayViewer.tscn"


func _ready() -> void:
	# Guard the two-knob coupling: the engine steps at project.godot's rate while
	# all GDScript timing derives from PHYSICS_TICK. If they disagree the sim
	# silently dilates against the wall clock that clock-sync and broadcast
	# cadence depend on — catch it loudly at boot instead of in the field.
	var engine_tick: int = int(ProjectSettings.get_setting(
			"physics/common/physics_ticks_per_second", PHYSICS_TICK))
	if engine_tick != PHYSICS_TICK:
		push_error(("Constants.PHYSICS_TICK (%d) != project.godot " +
				"physics_ticks_per_second (%d) — update both to change the tick rate.") %
				[PHYSICS_TICK, engine_tick])
