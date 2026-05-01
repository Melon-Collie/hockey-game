# AI_SKATER_SPEC.md

## MVP skater AI for 3v3 arcade hockey

This document specifies the v1 implementation of AI-controlled skaters for a 3v3 arcade hockey game built in Godot 4.6.2 (GDScript, Jolt Physics, 240 Hz physics tick). It is the sibling of `GOALIE_AI_SPEC.md` and follows the same house style: opinionated, implementation-ready, explicit about what is deferred. The target is grounded-feeling three-on-three play — forwards that triangulate around the puck, stay above it, don't chase behind the opposing net, and don't run into their own teammates — without trying to ship the whole tactical dictionary up front.

### Philosophy

Skater AI is a **pure function** from `(tick_index, world_snapshot, agent_state)` to `InputState`. Bots are peers of `LocalController` and `RemoteController`: they emit the same input struct a human emits, every physics tick, and all downstream systems (shot mechanics, skating, IK) treat them identically. The AI lives in one place — the host — and clients see it through existing remote-skater plumbing. Everything else (perception latency, decision smoothing, tactical layers) sits behind that interface so we can rip and replace without touching `SkaterController`.

---

## 1. Architecture overview

```
                        ┌────────────────────────┐
                        │      TeamBrain         │  (scene-tree Node, ~6 Hz Timer)
                        │  - role assignment     │
                        │  - team blackboard     │
                        │  - influence maps      │
                        └──────────┬─────────────┘
                                   │ blackboard read (pull)
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
┌───────▼────────┐        ┌────────▼───────┐         ┌────────▼───────┐
│  SkaterAgent   │        │  SkaterAgent   │         │  SkaterAgent   │
│  (per-bot,     │        │                │         │                │
│   240 Hz)      │        │                │         │                │
│                │        │                │         │                │
│ perception ──► │        │                │         │                │
│ utility    ──► │        │                │         │                │
│ steering   ──► │        │                │         │                │
│ → InputState   │        │                │         │                │
└───────┬────────┘        └────────┬───────┘         └────────┬───────┘
        │                          │                          │
┌───────▼────────┐        ┌────────▼───────┐         ┌────────▼───────┐
│  AIController  │        │  AIController  │         │  AIController  │
│  extends       │        │                │         │                │
│  SkaterController      │                │         │                │
│  (calls _process_input │                │         │                │
│   with AI InputState)  │                │         │                │
└───────┬────────┘        └────────┬───────┘         └────────┬───────┘
        │                          │                          │
        └───────────► Skater (physics, shot, IK) ◄────────────┘

                        ┌────────────────────────┐
                        │   PerceptionBuffer     │  (ring buffer, world snapshots)
                        │   written by host each │
                        │   physics tick         │
                        └────────────────────────┘
                                   ▲
                        Read by SkaterAgent with a
                        per-agent tick-delay offset.
```

The flow each physics tick, per bot: `AIController._physics_process` pulls a snapshot from `PerceptionBuffer` at `tick_index - reaction_delay_ticks`, hands it to its `SkaterAgent`, which consults the current `TeamBrain` blackboard (read-only), runs perception → utility → steering, and returns an `InputState`. `AIController` then calls `SkaterController._process_input(input_state)` exactly as `LocalController` does. No new API on the base class.

**On multiplayer vs offline**: AI runs wherever the skater is locally simulated. On the host, all six skaters have their controllers attached locally; bot controllers are `AIController`, human controllers are `LocalController`. Remote clients instantiate `RemoteController` for every non-self skater, human or bot — they see the AI's emitted `InputState` through the same `receive_input_batch` path. In offline (single-machine) mode, the host is the client, so AI runs locally. **Nothing differs between the two cases** because the AI writes `InputState` via the same `SkaterController._process_input` path that `NetworkManager` reads from for replication; bots are a drop-in `LocalController` replacement. The one thing to verify during implementation is that `NetworkManager` serializes `InputState` from `AIController` instances on the host with the same code path as from `LocalController` — grep for how `LocalController` publishes input to the tick buffer and make sure `AIController` either reuses that publish step or calls `super()` so it's unchanged.

---

## 2. MVP scope

**In v1 (ship this, in order):**

1. `AIController extends SkaterController` — peer of `LocalController`/`RemoteController`, emits `InputState` each tick.
2. `WorldSnapshot` POD + `PerceptionBuffer` ring buffer with tick-delayed reads and per-agent deterministic positional noise (low-pass, no Kalman).
3. `TeamBrain` as a scene-tree Node (child of the match scene), ticking at 6 Hz via a child `Timer`. Holds per-team blackboard: role assignments (F1/F2/F3), influence map handles, flags ("puck possessed by team", "in offensive zone").
4. Role assignment by brute-force six-permutation enumeration with transition cost and hysteresis. `n=3`, so 6 permutations per team per brain tick — trivially cheap.
5. One influence map (`opponent_presence`) as a `PackedFloat32Array`, 120×60, 0.5 m cells, updated on the TeamBrain tick. Everything else we can hand-compute from the snapshot for v1.
6. Role anchors — `F1` on puck / gap line; `F2` triangle apex ~3 m from carrier on strong side; `F3` above-the-puck toward own net. Computed each TeamBrain tick and posted to blackboard.
7. Potential-field steering for `move_vector`: attract to anchor, repel from opponents, teammates, and boards. Flat 8-direction context ring for danger-side gating, evaluated at 60 Hz (every 4 ticks), interpolated otherwise.
8. On-puck utility: `SHOOT | PASS_i | CARRY | DUMP | PROTECT` with hysteresis and quiet-eye commit of 8–12 ticks.
9. Shot aim: midpoint of the larger open arc past the goalie + deterministic wobble whose amplitude shrinks with skill.
10. Three hard constraints, encoded as gates and cost penalties: role assignment by puck distance (F1 is always whoever is closest among teammates who are above the puck); stay above the puck (ys enforced on anchors); triangle maintenance (pair-wise distance floors).
11. Teammate-polite rules: role-yield to humans, pass-to-human bias 1.25×, never attempt puck theft from teammate, no shot-line blocks of teammate, check-into-teammate gate.
12. Deterministic "noise" via a sine-sum seeded by `(tick, agent_id)` — but *only* applied to aim and hysteresis thresholds, never to physics input components that cross platforms (see §11).
13. Debug visualization: anchor markers, role labels over head, utility scores as a UI panel, influence map as a `TextureRect` overlay with `FORMAT_RF`.

**Explicitly out of v1 (noted below under Growth paths):**

Authored breakouts and set plays; selectable forecheck variants (2-1, 1-2, 1-1-1); pinch decisions; body-checking tactics beyond a simple gate; LimboAI behavior trees; learned xG; Kalman filters; Hungarian assignment; an AI Director; coordinated screens; line changes; ML policies.

**Philosophy on the cut line**: if a feature requires a second moving part to make sense (e.g., a "pinch" requires a forecheck configuration to sit on top of), defer until that configuration exists. V1 ships one implicit forecheck (1-2-2 by geometry, not by name) and one implicit defensive structure (above-the-puck triangle).

---

## 3. AIController

Signature and setup:

```gdscript
class_name AIController
extends SkaterController

## Peer of LocalController / RemoteController. Emits InputState per tick.

@export var agent_id: int = 0                  ## stable per bot, used in RNG seed
@export var team_id: int = 0                   ## 0 or 1
@export_range(0.0, 1.0) var skill: float = 0.6 ## maps to difficulty knobs (see §13)

var agent: SkaterAgent                         ## owned, not a scene child
var _team_brain: TeamBrain                     ## resolved in _ready

func _ready() -> void:
	super()
	_team_brain = get_tree().get_first_node_in_group(&"team_brain_%d" % team_id) as TeamBrain
	assert(_team_brain != null, "TeamBrain for team %d not found" % team_id)
	agent = SkaterAgent.new(self, _team_brain, agent_id, skill)

func _physics_process(delta: float) -> void:
	var tick_index: int = NetworkManager.host_tick   ## pull from GameRules/NetworkManager
	var input_state: InputState = agent.tick(tick_index, delta)
	_process_input(input_state)
	## Base class handles state machine, shot mechanics, IK, input replication.
	## Do NOT call super._physics_process — _process_input is already the contract.
```

Notes on interaction with `SkaterController`:

- `SkaterController._process_input(InputState)` is the contract. `AIController` touches nothing else on the base class. Shot mechanics, IK, state machine — all untouched.
- If `LocalController` publishes input to the NetworkManager tick buffer inside `_process_input` (confirmed in the repo's existing controller hierarchy), `AIController` gets that for free. If it publishes elsewhere, `AIController` must call the same publish step — **flag to verify during implementation**.
- `AIController` never reads `controller-current` state on its own skater. All "what am I doing" state comes from the tick-delayed `WorldSnapshot`. This keeps AI out of the same-frame read-write dependency chain and matches the determinism contract.

---

## 4. WorldSnapshot and PerceptionBuffer

`WorldSnapshot` is a plain data struct. Use a `Resource` subclass for the struct itself (so the inspector can display one for debug) but store snapshots as a pre-allocated ring, never allocating mid-match.

```gdscript
class_name WorldSnapshot
extends RefCounted

var tick: int = 0
var time: float = 0.0

## 6 skaters + 2 goalies. Parallel arrays so we can iterate cache-friendly.
var skater_pos:   PackedVector3Array = PackedVector3Array()   ## size 6
var skater_vel:   PackedVector3Array = PackedVector3Array()   ## size 6
var skater_team:  PackedInt32Array   = PackedInt32Array()     ## size 6
var skater_has_puck: int = -1                                 ## index or -1

var goalie_pos:   PackedVector3Array = PackedVector3Array()   ## size 2
var goalie_team:  PackedInt32Array   = PackedInt32Array()     ## size 2

var puck_pos:     Vector3 = Vector3.ZERO
var puck_vel:     Vector3 = Vector3.ZERO
var puck_height:  float   = 0.0
var puck_possessor: int = -1                                  ## skater index or -1
```

`PerceptionBuffer` is a ring of `N = 64` snapshots (enough for 240 ms at 240 Hz of reaction delay — more than any MVP skill level needs):

```gdscript
class_name PerceptionBuffer
extends Node

const RING_SIZE: int = 64
var _ring: Array[WorldSnapshot] = []
var _write_index: int = 0
var _latest_tick: int = -1

func _ready() -> void:
	_ring.resize(RING_SIZE)
	for i: int in RING_SIZE:
		_ring[i] = WorldSnapshot.new()

## Called once per physics tick by whatever owns perception (TeamBrain or GameManager).
func write(tick: int, snap_source: Object) -> void:
	var dst: WorldSnapshot = _ring[_write_index]
	## Populate dst fields from GameManager (skaters, puck, goalies).
	## Reuse the same WorldSnapshot instance — no allocation.
	_populate(dst, tick, snap_source)
	_latest_tick = tick
	_write_index = (_write_index + 1) % RING_SIZE

## Returns the freshest snapshot <= (latest - delay_ticks). Read-only contract.
func read(delay_ticks: int) -> WorldSnapshot:
	var target_tick: int = _latest_tick - delay_ticks
	var idx: int = ((_write_index - 1 - delay_ticks) % RING_SIZE + RING_SIZE) % RING_SIZE
	return _ring[idx]
```

**Noise injection** happens at *read* time inside the `SkaterAgent`, not at write time. The buffer stores ground truth; each agent applies its own deterministic positional noise based on `(tick, agent_id)` and its `perception_noise_sigma`. Reason: one shared buffer serves both teams, both skill levels, and the debug visualizer sees truth.

The noise function (§11):

```gdscript
static func perceived_pos(truth: Vector3, tick: int, agent_id: int, target_id: int, sigma: float) -> Vector3:
	if sigma <= 0.0:
		return truth
	var n: Vector2 = _sine_noise2(tick, agent_id * 131 + target_id)
	return truth + Vector3(n.x * sigma, 0.0, n.y * sigma)
```

**On the "current controller input" rule**: the agent never touches `LocalController`'s in-flight input or the host's current-tick state. Even on the host, where the puck's current position is *available* on `GameManager.puck.global_position`, the AI must read from `PerceptionBuffer.read(reaction_delay_ticks)`. Doing otherwise gives bots a same-frame advantage and makes deterministic replay impossible.

**Source of truth**: `GameManager.get_world_snapshot(dst)` — *this method needs to be added.* It populates a pre-allocated `WorldSnapshot` in-place. Host calls it once per physics tick (after physics step, before controller process). **Flag**: if `GameManager` doesn't already expose `skaters`, `goalies`, and `puck` as indexable arrays, this touches `GameManager`'s public surface. Keep it read-only.

---

## 5. TeamBrain

**Scene-tree Node, not an autoload.** One per team, parented to the match scene. Rationale: lifetime is match-scoped (reset between matches), we need two instances (one per team), it's trivial to mock in tests, and match-scene teardown cleans it up automatically. Autoloads are for truly global, single-instance, whole-app systems (`GameManager`, `NetworkManager`); `TeamBrain` is none of those.

It ticks at 6 Hz via a child `Timer`. Do not run it on `_process` or `_physics_process` — decouple cadence from frame rate and make it explicit.

**Threading**: TeamBrain runs on the main thread. At 6 Hz with n=3 permutation enumeration and a single influence map stamp-and-blur, it's deep under 1 ms per tick; the cost of snapshotting world state to cross the thread boundary (required in Godot 4.1+ because Node property reads from worker threads throw) would exceed the compute savings. Keep `WorkerThreadPool` in the toolbox for nav baking and scene loading, not for this.

```gdscript
class_name TeamBrain
extends Node

@export var team_id: int = 0
@export var tick_hz: float = 6.0

@onready var _timer: Timer = $Tick                 ## wait_time = 1.0 / tick_hz, autostart

var blackboard: Dictionary = {}                    ## see schema below
var _influence: InfluenceMap                       ## owned

signal blackboard_updated(tick: int)

func _ready() -> void:
	add_to_group(&"team_brain_%d" % team_id)
	_timer.wait_time = 1.0 / tick_hz
	_timer.timeout.connect(_on_tick)
	_influence = InfluenceMap.new(120, 60, 0.5)
	_init_blackboard()

func _on_tick() -> void:
	var snap: WorldSnapshot = GameManager.perception.read(0)   ## brain reads fresh; agents read delayed
	_update_influence(snap)
	_assign_roles(snap)
	_compute_anchors(snap)
	_update_flags(snap)
	blackboard[&"brain_tick"] = snap.tick
	blackboard_updated.emit(snap.tick)
```

Blackboard schema (strict keys, `StringName` constants defined on `TeamBrain`):

| Key | Type | Meaning |
|---|---|---|
| `&"roles"` | `Dictionary[int, int]` | agent_id → role enum (F1, F2, F3, G) |
| `&"anchors"` | `Dictionary[int, Vector3]` | agent_id → target position on ice |
| `&"possession"` | `int` | 0 = none, 1 = own, 2 = opponent |
| `&"puck_zone"` | `int` | 0 = defensive, 1 = neutral, 2 = offensive (from own-team perspective) |
| `&"carrier_id"` | `int` | skater index holding puck, or -1 |
| `&"above_puck_line_z"` | `float` | z coord agents must stay on the own-net side of |
| `&"influence_handle"` | `RID`-ish or array index | read-only handle to the influence map |
| `&"brain_tick"` | `int` | tick at which this blackboard was last updated |

Agents **pull** from the blackboard on their own tick (they read, never write). No signals into agents — each agent's `tick()` begins with `var bb := _team_brain.blackboard`. Reads are same-process, main-thread, no mutex.

**Role assignment** at n=3 is brute force: enumerate the 6 permutations of agents to roles, cost each, pick the min. Cost function is linear in three terms and one hysteresis penalty:

```gdscript
func _role_cost(perm: Array[int], snap: WorldSnapshot) -> float:
	## perm[0] = agent playing F1, perm[1] = F2, perm[2] = F3
	var cost: float = 0.0
	## Hard gate: F1 must be the closest teammate to puck among those above the puck.
	var closest_above: int = _closest_teammate_above_puck(snap)
	if perm[0] != closest_above:
		cost += 1e6
	## Soft: minimize travel distance from current positions to anchors.
	cost += snap.skater_pos[perm[0]].distance_to(_anchor_for(F1, snap))
	cost += snap.skater_pos[perm[1]].distance_to(_anchor_for(F2, snap))
	cost += snap.skater_pos[perm[2]].distance_to(_anchor_for(F3, snap))
	## Hysteresis: penalty for changing role vs last tick.
	for i: int in 3:
		if perm[i] != (blackboard[&"roles"].get(perm[i], -1)):
			cost += hysteresis_window_ticks * 0.05
	return cost
```

Enumerate, sort by cost with a stable tiebreak on `(perm[0], perm[1], perm[2])`, pick the winner. `Array.sort_custom` is **not stable** in Godot — the engine uses introsort — so always tiebreak on a deterministic key when cost values tie. For n=3 we can skip sorting and just min-scan.

Subscription pattern: `SkaterAgent._init()` caches a reference to its `TeamBrain` and reads `blackboard[&"roles"].get(agent_id, F3)` each physics tick. If roles change mid-quiet-eye (rare, since brain is 6 Hz and quiet-eye is 8–12 ticks), the agent respects its commit until the quiet-eye timer expires. Role churn mid-commit is a known MVP bug; log it and move on.

---

## 6. SkaterAgent

The per-bot decision loop. One `SkaterAgent` instance per `AIController`. Owned by the controller, not a scene node.

```gdscript
class_name SkaterAgent
extends RefCounted

enum Role { F1, F2, F3, G }

var _ctrl: AIController
var _brain: TeamBrain
var _id: int
var _skill: float

## Difficulty-derived parameters, resolved from skill at construction (see §13).
var reaction_delay_ticks: int
var perception_noise_sigma: float
var perception_update_period_ticks: int
var decision_horizon_s: float
var shot_aim_cone_deg: float
var lane_detection_strictness: float
var off_puck_awareness_radius: float
var pass_upgrade_weight: float
var hysteresis_window_ticks: int

## Rolling state.
var _last_perception_tick: int = -1
var _cached_snap: WorldSnapshot
var _quiet_eye_remaining: int = 0
var _committed_action: int = OnPuckAction.CARRY
var _committed_target_id: int = -1

## Steering buffers — pre-allocated, never reallocated.
const CONTEXT_DIRS: int = 8
var _interest:  PackedFloat32Array = PackedFloat32Array()
var _danger:    PackedFloat32Array = PackedFloat32Array()

func _init(ctrl: AIController, brain: TeamBrain, id: int, skill: float) -> void:
	_ctrl = ctrl; _brain = brain; _id = id; _skill = skill
	_resolve_skill_knobs()
	_interest.resize(CONTEXT_DIRS)
	_danger.resize(CONTEXT_DIRS)

func tick(tick_index: int, delta: float) -> InputState:
	## Perception: only refresh every perception_update_period_ticks.
	if tick_index - _last_perception_tick >= perception_update_period_ticks:
		_cached_snap = GameManager.perception.read(reaction_delay_ticks)
		_last_perception_tick = tick_index
	var snap: WorldSnapshot = _cached_snap
	var bb: Dictionary = _brain.blackboard
	var role: int = bb.get(&"roles", {}).get(_id, Role.F3)
	var anchor: Vector3 = bb.get(&"anchors", {}).get(_id, _ctrl.global_position)

	var input: InputState = _scratch_input           ## pre-allocated, reused
	_fill_defaults(input, tick_index, delta)

	if snap.puck_possessor == _id:
		_decide_on_puck(snap, bb, input, tick_index)
	else:
		_decide_off_puck(snap, bb, role, anchor, input, tick_index)

	return input
```

Decision loop structure: **perception (gated) → role/anchor read → on-puck vs off-puck branch → steering → aim → `InputState` fill**. All state that survives between ticks (`_quiet_eye_remaining`, `_committed_action`, `_last_perception_tick`) is owned by the agent. No globals.

`_scratch_input` is a single pre-allocated `InputState` per agent, reused every tick. At 240 Hz × 6 bots, allocating an `InputState` per tick would be 1,440 allocations/sec — survivable but pointlessly expensive. `InputState` fields are set in-place; `host_timestamp` and `delta` are the only fields that change unconditionally.

---

## 7. InfluenceMap MVP

One map in v1: `opponent_presence`. A `PackedFloat32Array` of size 120×60 at 0.5 m cells, covering the 60×30 m rink. 7.2 KB per map.

```gdscript
class_name InfluenceMap
extends RefCounted

const WIDTH: int = 120
const HEIGHT: int = 60
const CELL: float = 0.5

var data: PackedFloat32Array = PackedFloat32Array()
var _stamp: PackedFloat32Array = PackedFloat32Array()  ## 9x9 Gaussian, baked once
const STAMP_R: int = 4

func _init() -> void:
	data.resize(WIDTH * HEIGHT)
	_bake_stamp()

func clear() -> void:
	data.fill(0.0)

func stamp(world_pos: Vector3, weight: float) -> void:
	var cx: int = int((world_pos.x + WIDTH * CELL * 0.5) / CELL)
	var cz: int = int((world_pos.z + HEIGHT * CELL * 0.5) / CELL)
	for dy: int in range(-STAMP_R, STAMP_R + 1):
		var y: int = cz + dy
		if y < 0 or y >= HEIGHT: continue
		for dx: int in range(-STAMP_R, STAMP_R + 1):
			var x: int = cx + dx
			if x < 0 or x >= WIDTH: continue
			data[y * WIDTH + x] += weight * _stamp[(dy + STAMP_R) * 9 + (dx + STAMP_R)]

func sample(world_pos: Vector3) -> float:
	var x: int = clampi(int((world_pos.x + WIDTH * CELL * 0.5) / CELL), 0, WIDTH - 1)
	var y: int = clampi(int((world_pos.z + HEIGHT * CELL * 0.5) / CELL), 0, HEIGHT - 1)
	return data[y * WIDTH + x]
```

Update cadence: clear and re-stamp on each TeamBrain tick (6 Hz). No per-tick blur — the 9×9 Gaussian stamp already provides spatial spread. Total cost: ~6 opponents × 81 cells × 6 Hz = ~3,000 float adds/sec. Negligible. Rink constants (width, height, cell size) **pull from GameRules** once `GameRules.RINK_WIDTH_M` et al. exist — currently hardcode with a `## FLAG: pull from GameRules` comment.

No separable blur pass in v1. Stamp-and-blur with a pre-baked Gaussian stamp on a sparse, small rink outperforms propagation or two-pass blur at this scale. If later we need wider influence (e.g., a "shooting lane" map), add a single 1D separable blur pass, still per brain tick.

Debug visualization: one `TextureRect` overlay, `Image.create_from_data(120, 60, false, Image.FORMAT_RF, data.to_byte_array())`, `ImageTexture.create_from_image`, gradient shader on the rect samples R and maps to blue→red. Nearest-neighbor filter for crisp cells. Recreate the image in-place each brain tick.

---

## 8. Role system — F1/F2/F3 anchors and transitions

Roles are indices into a small enum: `F1`, `F2`, `F3`, `G`. MVP skater AI assigns only F1/F2/F3; `G` is opaque (goalie AI is separate).

**F1 — puck pressure.**
- If own team has possession: F1 is the carrier. Anchor is the carrier's current position (agent just plays itself).
- If opponent has possession: F1 is the closest teammate *above the puck* (own-net side). Anchor is the gap line — a point between the carrier and our net, offset ~1.5 m toward the carrier, with a lateral offset to close the most dangerous passing lane. Hard rule: **never chase behind the opposing net**; if the carrier is below the opposing goal line, F1's anchor clamps to the goal line.
- If puck is loose: F1's anchor is the predicted puck position at `decision_horizon_s`, clamped above it.

**F2 — triangle apex, strong side.**
- Anchor is ~3 m from the carrier (own or opponent) on the strong side (the side of the rink the puck is on). In offense, F2 offers a pass lateral/above. In defense, F2 covers the strong-side lane.
- Encoded as: `anchor = carrier_pos + 3.0 * strong_side_unit + 2.0 * above_puck_unit`, where `strong_side_unit` is the unit vector from rink center along X in the direction of the puck's X coordinate, and `above_puck_unit` is the unit vector from the puck toward our own net along Z.

**F3 — above the puck, toward own net.**
- The safety valve. Anchor is 8 m above the puck (Z toward own net), on the weak side. Never crosses below the puck line.
- If the puck is in our defensive zone, F3's anchor clamps to the top of the defensive circles (pull exact coordinate **from GameRules**).

**Transitions**: controlled entirely through `TeamBrain._assign_roles`. The enumeration cost function already includes travel cost + hysteresis. When the puck changes possession, the brain recomputes on the next tick (at most 167 ms of stale role, usually less). The `hysteresis_window_ticks` agent parameter (see §13) applies to *agent-level* commits inside on-puck decisions, not role assignment; role hysteresis is baked into the brain's cost.

**Sprint-by on turnover**: when possession flips and F1 ends up on the wrong side of the puck, the hysteresis is deliberately short — the cost function's hard F1-gate fires, forcing reassignment within one brain tick. The agent who *was* F1 becomes F3 (highest position above puck) and skates hard back above the line. This is emergent from the cost function, not scripted.

---

## 9. On-puck utility

When the agent has the puck, it evaluates actions every physics tick, but **commits** for 8–12 ticks via quiet-eye. Action enum:

```gdscript
enum OnPuckAction { SHOOT, PASS, CARRY, DUMP, PROTECT }
```

Per-tick scoring (all in [0, 1], multiplied then clamped, IAUS-style). Each consideration is a `Curve` resource authored in `res://ai/curves/`, sampled with `sample_baked` at `bake_resolution = 256` — cheap enough, designer-editable.

```gdscript
func _score_shoot(snap: WorldSnapshot, bb: Dictionary) -> float:
	var my_pos: Vector3 = snap.skater_pos[_id]
	var dist: float = my_pos.distance_to(_opp_goal_pos())
	var angle_score: float = _shot_angle_openness(my_pos, snap)       ## [0,1]
	var dist_score: float = _curve_shoot_distance.sample_baked(dist / 25.0)
	var goalie_score: float = _shot_goalie_arc_fraction(my_pos, snap) ## [0,1]
	var pressure: float = 1.0 - _pressure_score(my_pos, snap)          ## inverted
	return angle_score * dist_score * goalie_score * pressure
```

Formulas for v1:

- **SHOOT**: `angle_openness · distance_response · goalie_arc_fraction · (1 - pressure)`. `goalie_arc_fraction` is the fraction of the net not covered by the goalie along the sightline (see §10).
- **PASS_i** (one per teammate): `lane_clear(me, i) · receiver_advancement(i) · receiver_openness(i) · (1 - receiver_pressure(i)) · polite_bias(i)`. `polite_bias = 1.25` if teammate is human, else 1.0.
- **CARRY**: `space_ahead · speed_ok · (1 - pressure)`. Default action; its baseline response is set high (~0.5) so the bot doesn't hesitate when nothing's better.
- **DUMP**: `(own_zone_flag ? 0.0 : 1.0) · pressure · (1 - any_teammate_clear)`. Dumps only when pressured in the neutral or offensive zone and no pass lane exists.
- **PROTECT**: `pressure · boards_adjacent · (1 - pass_or_shoot_available)`. Last resort when cornered.

Hysteresis and quiet-eye: once any action wins, the agent commits for `_quiet_eye_remaining = randi_range_det(8, 12)` ticks. During commit, only a *hard override* (puck lost, shot blocked confirmed, or teammate-polite gate triggered) can break the commit. This prevents per-tick flip-flopping between SHOOT and PASS when scores are close. `randi_range_det` is the deterministic RNG from §11.

Tiebreak: if two actions score within a narrow band (`|a - b| < hysteresis_eps`, default `0.03`), prefer in order: PASS to human teammate → CARRY → SHOOT → PASS to bot teammate → DUMP → PROTECT. This encodes the polite-pass bias beyond the 1.25× score multiplier.

---

## 10. Off-puck positioning — potential field steering

`move_vector` is produced by a sum of attract/repel forces in the XZ plane. Weights in MVP defaults:

| Force | Weight | Source |
|---|---|---|
| Attract to anchor | 1.0 | `bb[&"anchors"][_id]` |
| Repel from opponents | 0.6 | `snap.skater_pos[i]` where `skater_team[i] != team_id`, falloff inverse-square over 4 m |
| Repel from teammates | 0.4 | `snap.skater_pos[i]` where same team and `i != _id`, falloff over 3 m |
| Repel from boards | 0.5 | distance to nearest rink wall, sharp falloff inside 1.5 m |
| Repel from own shot lanes | 0.3 | sightline from any teammate carrier to net — keep out of it |

Sum, normalize, clamp to unit length, write to `input.move_vector`.

**Context-steering outline** (the danger-side gate): every 4 physics ticks, build 8-direction interest (dot with attract-anchor direction) and danger (max of raycast blocks + repel contributions along each direction) rings. Zero out interest in any direction whose danger exceeds a threshold. Pick the highest remaining interest direction, snap `move_vector` toward it. Between evaluations, lerp toward the cached direction. Raycasts at 60 Hz, not 240 Hz — 16 rays × 6 bots × 60 Hz = 5,760 raycasts/sec, well within budget; at 240 Hz it was 23k/sec and starting to show up in profiles.

The potential field alone is local-minima-prone (two opposing repels sum to zero exactly at the midpoint). The 8-direction context ring dominates when the raw potential-field sum is small — if `|force| < 0.1`, use the context ring direction directly. This is a simpler patch than a full flow field and sufficient for an open rink.

`brake` is pressed when approaching anchor within 1 m *and* the agent's velocity exceeds 3 m/s. `elevation_up/down`, `block_held` are not used by v1 skaters off-puck.

---

## 11. Shot/pass/check aim — deterministic wobble

`mouse_world_pos` is the aim point. For a shot, the *ideal* aim is the midpoint of the larger open arc past the goalie:

```
Find goalie center G and radius r_g in the net plane.
The net segment is [L, R] on the goal line.
The goalie projects a shadow [A, B] onto the net from the shooter's vantage.
Two visible arcs: [L, A] and [B, R]. Pick the longer one; aim = midpoint.
```

Concretely, in 2D (XZ, collapsed to the net's line):

```gdscript
func _shot_aim(snap: WorldSnapshot) -> Vector3:
	var shooter: Vector3 = snap.skater_pos[_id]
	var goalie: Vector3 = _opponent_goalie_pos(snap)
	var net_l: Vector3 = _opp_net_left()     ## pull from GameRules
	var net_r: Vector3 = _opp_net_right()
	var a: Vector3 = _project_goalie_shadow_onto_net(shooter, goalie, net_l, net_r, true)
	var b: Vector3 = _project_goalie_shadow_onto_net(shooter, goalie, net_l, net_r, false)
	var left_arc: float = net_l.distance_to(a)
	var right_arc: float = b.distance_to(net_r)
	var aim: Vector3 = (net_l + a) * 0.5 if left_arc >= right_arc else (b + net_r) * 0.5
	return aim + _aim_wobble(shooter)
```

`_aim_wobble` adds a deterministic sine-sum offset scaled by `shot_aim_cone_deg`:

```gdscript
func _aim_wobble(shooter: Vector3) -> Vector3:
	var cone_rad: float = deg_to_rad(shot_aim_cone_deg)
	var n: Vector2 = _sine_noise2(_cached_snap.tick, _id * 97)
	var theta: float = n.x * cone_rad
	var dist: float = shooter.distance_to(_opp_goal_pos())
	var lateral: float = dist * tan(theta)
	return Vector3(lateral, 0.0, 0.0)
```

At higher skill, `shot_aim_cone_deg` shrinks; wobble amplitude shrinks proportionally. **Note on determinism**: `tan` routes through libm. For cross-platform bit-identical aim, precompute a tan lookup; for server-authoritative play with snapshot reconciliation, `tan` is fine because aim is a float that rides on the InputState and the server's result wins anyway. MVP takes the latter path.

For passes, aim is the predicted receiver position at `decision_horizon_s` (simple linear extrapolation of `skater_vel[i]`), plus wobble scaled by `1.0 - lane_detection_strictness`. For body checks (deferred beyond MVP's simple gate), aim at opponent's predicted position same way.

`shoot_pressed` / `shoot_held` / `slap_pressed` / `slap_held`: pressed on the tick commitment fires, held until the shot animation consumes them (read `SkaterController.is_shooting` — flag to verify the exact property name; if not exposed, add one).

---

## 12. Teammate-polite rules — concrete multipliers

These are utility multipliers applied at score computation, not post-hoc gates:

- **Role-yield to humans**: in `_role_cost`, add `+25.0` to permutations that assign F1 to a bot when a human teammate is roughly equidistant from the puck (within 2 m). The human gets first refusal on the puck.
- **Pass-to-human bias**: `PASS_i` score for a human receiver multiplied by `1.25`.
- **No puck-stealing from teammate**: if `snap.puck_possessor` is a teammate, force `F1` anchor to the support triangle apex, not the carrier's position. Encoded as a hard gate in `_anchor_for`.
- **No shot-line blocks**: the "repel from own shot lanes" term in the potential field (§10, weight 0.3) keeps off-puck bots out of the line from the carrier to the opp net.
- **Check-into-teammate gate**: body-check decisions (deferred in v1, but the gate ships now) require the line from bot to target to have no teammate within 1.5 m cylinder; if violated, score = 0.

These are the only place `is_human` matters to the AI. Everywhere else, humans and bots are symmetric.

---

## 13. Difficulty knobs

Per-agent parameters, resolved once at construction from `skill ∈ [0,1]`. All are *deterministic* functions of skill — no runtime randomness, no dynamic difficulty.

| Parameter | Rookie (skill=0.2) | MVP default (skill=0.6) | Pro (skill=0.95) | Unit |
|---|---|---|---|---|
| `reaction_delay_ticks` | 48 (200 ms) | 24 (100 ms) | 8 (33 ms) | physics ticks |
| `perception_noise_sigma` | 1.5 | 0.5 | 0.1 | m |
| `perception_update_period_ticks` | 12 (20 Hz) | 4 (60 Hz) | 1 (240 Hz) | physics ticks |
| `decision_horizon_s` | 0.25 | 0.5 | 0.9 | seconds |
| `shot_aim_cone_deg` | 12.0 | 5.0 | 1.5 | degrees half-angle |
| `lane_detection_strictness` | 0.4 | 0.7 | 0.95 | [0,1] |
| `off_puck_awareness_radius` | 6.0 | 12.0 | 20.0 | m |
| `pass_upgrade_weight` | 0.6 | 1.0 | 1.4 | multiplier on PASS score when receiver is in a better xG spot |
| `hysteresis_window_ticks` | 36 | 24 | 12 | physics ticks |

Resolution is linear interpolation in `skill`. Store the resolved values on `SkaterAgent`; don't re-sample per tick. Difficulty presets ship as three skill values — picking Rookie/Pro/MVP sets every bot on that team to that skill. **Per-bot variation** within a team is out of MVP; add it by jittering `skill` per agent if needed later.

---

## 14. Hockey hard-constraints — encoding

Three rules that *never* bend, even when they produce uglier play than the utility score suggests:

1. **Role assignment by puck distance**: F1 is always the teammate with the minimum `(position - puck).length()` among teammates above the puck line. Encoded as the `1e6` gate in `_role_cost`. If the current F1 is not the minimum-distance above-puck teammate, the permutation costs are dominated by that `1e6` term and F1 is swapped.

2. **Stay above the puck**: computed per-agent anchor adjustment. `anchor.z` is clamped to `min(anchor.z, puck.z + 1.0)` where +z points toward our own net (verify axis convention — **flag to confirm against GameRules**). This runs in `_compute_anchors` on the TeamBrain tick. Agents can't be anchored below the puck. Offensive-zone cycles where a defenseman pinches below the puck are out of MVP.

3. **Triangle maintenance**: after role anchors are computed, enforce a pair-wise minimum distance of 2.5 m between anchors. If F2 and F3 anchors end up within 2.5 m, push them apart perpendicular to their midline. Enforce a pair-wise maximum of 15 m as well — triangle collapsing or spreading beyond these bounds is nonsensical three-on-three hockey.

Encoded in `TeamBrain._compute_anchors` after the raw anchors are computed and before they're written to the blackboard.

---

## 15. Determinism contract

The AI is a pure function of `(tick_index, world_snapshot, agent_state)`. Concrete rules:

**Banned APIs:**

- `randi()`, `randf()`, `randf_range()`, `randi_range()` (global RNG, process-local seed, not restorable).
- `Array.shuffle()` (uses global RNG).
- `RandomNumberGenerator.randfn()` (Box-Muller uses `sqrt`/`log`/`cos` — libm, not cross-platform stable).
- `sin`, `cos`, `tan`, `exp`, `log`, `pow` on any value that goes into *physics-critical* input. Fine for cosmetic aim wobble (MVP accepts server wins). **Not fine** for any input component that must match lockstep between clients.
- `fract(sin(dot(...)))` sine-hash for RNG — uses libm, cross-platform unstable.
- `Array.sort_custom` without an explicit tiebreak key. Introsort is unstable in Godot; identical cost values may order differently across runs.
- Reading `controller-current-tick` state on own skater. Always go through `PerceptionBuffer.read(delay)`.

**Approved APIs:**

- `RandomNumberGenerator` with fixed `seed` and `state` — for pinned Godot versions only, and only when you own the state field. MVP uses its own SplitMix64 instead.
- Integer arithmetic, bit ops (`<<`, `>>`, `^`, `&`), `clampi`, `absi`, `mini`, `maxi` — all cross-platform deterministic.
- `sqrt` — IEEE-required to be correctly rounded; typically bit-identical. Prefer `x * x` over `pow(x, 2)`.
- Vector ops (+, −, *, /) — deterministic within the same compiled binary on the same platform.
- `Array.sort_custom` when given a strict `<` comparator that breaks ties on a stable unique ID (e.g., `agent_id`).

**Noise function** (the only "random" primitive used by MVP):

```gdscript
## SplitMix64 — cross-platform, integer-only, high quality.
static func splitmix64(s: int) -> int:
	s = s + 0x9E3779B97F4A7C15
	var z: int = s
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)

## Deterministic per-tick, per-agent 2D noise in [-1, 1]^2.
static func _sine_noise2(tick: int, agent_salt: int) -> Vector2:
	var a: int = splitmix64((tick * 0x9E3779B97F4A7C15) ^ agent_salt)
	var b: int = splitmix64(a ^ 0xD1B54A32D192ED03)
	## Convert low 32 bits to float in [-1, 1]. Integer-only path until the final cast.
	var fx: float = float(a & 0xFFFFFFFF) / float(0xFFFFFFFF) * 2.0 - 1.0
	var fy: float = float(b & 0xFFFFFFFF) / float(0xFFFFFFFF) * 2.0 - 1.0
	return Vector2(fx, fy)

## Deterministic integer range [lo, hi] inclusive.
static func randi_range_det(tick: int, salt: int, lo: int, hi: int) -> int:
	var u: int = splitmix64((tick * 0x9E3779B97F4A7C15) ^ salt)
	var span: int = hi - lo + 1
	return lo + int((u & 0x7FFFFFFFFFFFFFFF) % span)
```

Despite the name `_sine_noise2`, there is no `sin` call — we use SplitMix64 integer mixing, which is bit-identical across x86 and ARM. The name is historical (the design doc called it "sine-sum"); the implementation is hash-based because `sin` routes through libm.

**Dictionary iteration**: insertion-ordered and stable on the same run. Never use a `Dictionary` for any data whose iteration order matters across save files or across platforms. When iterating the blackboard for cross-checks, sort keys first.

**Jolt cross-platform determinism**: Godot Jolt as shipped in Godot 4.6 does **not** compile Jolt with `CROSS_PLATFORM_DETERMINISTIC=ON`, per the godot-jolt maintainer's own guidance. Treat physics as server-authoritative-with-snapshot-correction, not lockstep. The skater AI determinism contract above assumes server authority: the host's AI input wins, clients replay locally, minor float drift is corrected by the next snapshot. Lockstep rollback multiplayer is out of MVP scope.

**Static typing is mandatory** for all hot code. Typed GDScript is 30–60% faster than untyped per Godot's own benchmarks; at 240 Hz × 6 bots the delta is real. Type every var, argument, return, loop index. Use `:=` where the type is obvious.

---

## 16. Integration points

- `GameManager` (autoload): add `get_world_snapshot(dst: WorldSnapshot) -> void` — populates an existing snapshot in-place from live skater/puck/goalie state. Also add `perception: PerceptionBuffer` as an autoload-owned node, written on the host once per physics tick before controllers process. **These methods need to be added.**
- `NetworkManager` (autoload): AI reads `NetworkManager.host_tick` (or equivalent — verify exact property name in the repo; if it's named differently, rename in this spec). No writes.
- `SkaterController._process_input(InputState)` — the single contract. AI never touches anything else on the base class.
- `SkaterController` signals: if the base emits `shot_fired`, `possession_gained`, `possession_lost`, `hit_received`, the agent should subscribe for free events (useful for hysteresis resets). If these signals don't exist, MVP polls from the snapshot — don't add signals just for AI.
- `GameRules` (autoload / static): rink dimensions, net coordinates, goal line z, zone boundaries, puck speed caps. Every hard-coded constant in this spec marked `## FLAG: pull from GameRules` is a TODO pointer.
- `Skater`, `Puck` — read via `GameManager.get_world_snapshot`. AI never holds direct node references to other skaters.

---

## 17. Debug visualization

All behind a `debug_ai` boolean in a project-level debug config, toggled at runtime by a keybind (suggest F9):

- **Anchor markers**: a `MeshInstance3D` sphere (pooled per team, 6 total) at each agent's current anchor, color-coded by role (F1 red, F2 orange, F3 yellow).
- **Role labels**: a `Label3D` above each bot's head showing the current role name. Updates on blackboard change (subscribe to `blackboard_updated`).
- **Utility scores panel**: a `Control` in a corner with one row per bot, columns for the top 3 action scores and the committed action. Refreshed at 10 Hz, not per tick — screen text at 240 Hz is pointless and flickery.
- **Influence map overlay**: `TextureRect` in a debug viewport showing the current `opponent_presence` map. Toggled independently (F10 suggested).
- **Context steering rings**: optional, per-bot, draws 8-direction interest/danger arrows at the bot's feet as `ImmediateMesh`. Heavy — off by default.
- **Determinism log**: on F11, dump `(tick, agent_id, input_state, committed_action, anchor)` to a JSONL file. Record a second run with the same inputs, diff the logs — should be byte-identical within the same binary on the same machine.

---

## 18. Implementation order

Build in this order. Each milestone is integration-testable:

1. **Skeleton and contract** — `AIController extends SkaterController` that emits an `InputState` of all zeros every tick. Drop into a match, verify the bot skater compiles, spawns, and does nothing visible without crashing. Verify network replication: clients see the AI skater as a remote skater, no errors. *Milestone: a game of "6 frozen bots".*

2. **WorldSnapshot + PerceptionBuffer** — add `get_world_snapshot` on `GameManager`, add `PerceptionBuffer` as a `GameManager` child (not autoload), write once per physics tick. Expose `read(delay)`. Print one snapshot to verify. *Milestone: snapshot buffer writes and reads correctly.*

3. **TeamBrain with no roles** — scene-tree node per team, ticks at 6 Hz, owns an empty blackboard and the influence map. Verify two instances, one per team, via groups. Influence map stamps opponents and debug-renders. *Milestone: influence map visible on screen.*

4. **Role assignment + anchors** — implement F1/F2/F3 roles via permutation enumeration, anchors via the formulas in §8. Debug markers show the three anchors. Manually move a puck around and verify roles/anchors update correctly. *Milestone: three bots stand at their anchors.*

5. **Potential field steering off-puck** — attract-anchor + repel-opponents + repel-teammates + repel-boards. Bots move to anchors, avoid each other, don't hit the boards. No context ring yet. *Milestone: three bots maintain formation while the puck moves.*

6. **Context ring danger gate** — add 8-direction ring at 60 Hz. Verify bots don't get stuck in local minima. *Milestone: bots path around each other smoothly.*

7. **Tick-delay and perception noise** — wire `reaction_delay_ticks`, `perception_noise_sigma`, `perception_update_period_ticks`. Set MVP defaults. *Milestone: rookie bots feel laggy; pro bots feel sharp.*

8. **On-puck utility — SHOOT + CARRY only** — scoring, quiet-eye commit, shot aim with wobble. Give the carrier bot the puck, watch it skate to the slot and shoot. *Milestone: a bot scores a goal against a stationary goalie.*

9. **PASS_i** — per-teammate pass scoring, aim at predicted receiver. *Milestone: two bots complete a tape-to-tape pass.*

10. **DUMP + PROTECT** — with the two pressure-gated actions. *Milestone: pressured bot dumps in offensive zone instead of forcing a bad pass.*

11. **Teammate-polite rules** — wired into role cost and action scoring. *Milestone: bot yields a 50-50 puck to a human teammate.*

12. **Hockey hard-constraints** — above-the-puck clamp, triangle bounds. Playtest with a scripted puck that moves behind the opposing net — bots should never chase behind it. *Milestone: no chase-behind-net incident in a 10-minute playtest.*

13. **Difficulty presets** — three presets, wired to menu. *Milestone: Rookie vs Pro match feels dramatically different.*

14. **Determinism audit** — replay a recorded input stream; diff the log. Fix any non-determinism found. *Milestone: two local runs of the same recorded inputs produce byte-identical AI output logs.*

15. **Debug UI polish** — utility score panel, influence overlay, role labels. *Milestone: a developer can diagnose "why did that bot do that?" in under 30 seconds from the debug overlay.*

Steps 1–5 are plumbing; step 6 is where the AI starts feeling alive; steps 8–10 are where it starts scoring goals; steps 11–13 are where it starts feeling *tuned*.

---

## 19. Testing strategy

**Determinism**: the gold standard is a recorded-input replay test. Record a 30-second match with scripted inputs for the human controllers. Run twice, dump the AI log each time, diff — must be byte-identical on the same binary/platform. Cross-platform is *not* a requirement for MVP; a warning printed if divergence is detected is sufficient.

**Unit-ish tests** via GUT or gdUnit4: `TeamBrain` is a scene-tree node, so `add_child_autofree(team_brain)` in a test, populate a mock blackboard, call `_on_tick()` with a hand-crafted `WorldSnapshot`, assert the roles. `SkaterAgent` is a `RefCounted`; inject a stub `AIController` and `TeamBrain`, call `tick()`, inspect the returned `InputState`. Pure-function tests are easy here and catch most regressions.

**Playtest checklist** (run before any release):

- 10-minute game vs Pro bots: at least 2 goals by each side, no chase-behind-net incidents, no two bots occupying the same cell.
- 10-minute game vs Rookie bots: clearly easier, bots reach for the puck late, take bad shots.
- Human-on-team-with-bots: bots yield 50-50 pucks, pass to human 1.25× as often as to each other with otherwise equal scores.
- Host disconnects mid-game in multiplayer → next host inherits bots cleanly (this tests the "AI runs wherever the skater is locally simulated" invariant).

**Bugs to expect**:

- **Jitter between anchors**: an agent oscillating between two similar-cost roles. Fix: increase `hysteresis_window_ticks` or the per-change penalty in the role cost.
- **Bots clumping on the puck**: weak opponent repulsion. Fix: increase repel weight or widen the Gaussian stamp.
- **Bots skating into the boards**: missing board repel or incorrect rink bounds. Fix: verify rink dimensions from GameRules.
- **Shots going wide**: aim wobble scaled wrong, or net coordinates flipped. Unit-test `_shot_aim` with hand-crafted geometry.
- **Role assigned wrong at faceoff**: puck-possessor is -1, F1 cost gate blows up. Fix: gate the F1 assertion on `puck_possessor != -1`.
- **Role churn when puck possession flips every tick**: bounces between SHOOT/PROTECT. Fix: apply hysteresis to `possession` in blackboard, not just agent-level.
- **Determinism breaks after a Godot version bump**: `RandomNumberGenerator` algorithm changed. Fix: run from your own SplitMix64, which is why the spec mandates it.

---

## 20. Growth paths

Each deferred item, with a one-line note on where it plugs in without refactoring:

- **Authored breakouts / set plays**: add a `TacticOverride` priority layer above `TeamBrain._compute_anchors`. When active, it overrides anchors with scripted positions for N ticks, then releases.
- **Forecheck variants (2-1, 1-2, 1-1-1)**: parameterize the F1/F2/F3 anchor formulas with a `ForecheckConfig` resource; `TeamBrain` reads one and picks it up on the next tick.
- **Pinch decisions**: add a `PINCH` state on the defenseman role; the above-the-puck clamp becomes conditional on a pinch flag set by `TeamBrain` when offensive-zone pressure sustains for N ticks.
- **Body-checking tactics**: extend on-puck off-puck with a `CHECK` action gated on proximity, closing speed, and the existing teammate-safe gate. The gate ships in MVP; the action and targeting layer don't.
- **LimboAI behavior trees**: replace the on-puck if/else cascade with a `BTPlayer` whose tree is authored visually. `SkaterAgent.tick()` becomes `bt_player.update(delta)`. Blackboard bridges to LimboAI's own blackboard.
- **Learned xG model**: replace the `_score_shoot` hand-coded function with a lookup into a baked xG grid (a `PackedFloat32Array` indexed by shooter position / angle). Train offline.
- **Kalman filter perception**: replace the in-place noise application in `SkaterAgent` with a per-target Kalman state; the rest of the pipeline is unchanged because downstream code reads perceived positions from the agent, not the buffer.
- **Hungarian assignment**: when `n > 3` (4v4 bots, line changes bring 5 on ice), replace the enumeration with Hungarian. Cost function is already factored out.
- **AI Director / dynamic difficulty**: a new autoload that adjusts `skill` per bot per minute based on game score. No changes to `SkaterAgent` — it re-resolves knobs on skill changes via a `set_skill` method already planned.
- **Coordinated screens**: add a `SCREEN_GOALIE` off-puck intent that overrides anchor with a net-front position when a teammate is shooting. Gated on the shooter's `_committed_action == SHOOT` from the blackboard.
- **Line changes**: add a bench / active skater roster to `GameManager`; `TeamBrain` role assignment operates on active-only.
- **ML policies**: replace `SkaterAgent.tick` with a policy network inference. Identical input (`InputState`) and output contract. Train offline against the utility AI; ship a static ONNX or similar.

---

## 21. Open questions for the developer

1. **`NetworkManager.host_tick` exact API**: the spec reads this property; confirm the real name. If it's `NetworkManager.current_tick` or `NetworkManager.physics_tick`, search-and-replace.
2. **`LocalController` input publication**: does `SkaterController._process_input` publish `InputState` to the tick buffer, or does `LocalController` do it separately? If the latter, `AIController` must explicitly call the same publish step.
3. **Z-axis convention**: does +Z point toward our own net, the opposing net, or something team-relative? The above-the-puck clamp and F3 anchor formulas assume +Z = own net; if different, flip signs.
4. **`GameRules` location and API shape**: `res://core/game_rules.gd`? A static class, a singleton, or an autoload? All rink, net, and zone constants pull from here.
5. **`SkaterController` shot-consumption signal**: does the base emit a signal or expose a property when a shot animation consumes the `shoot_pressed` input? If neither, AI has to guess the consumption window — a 4-tick held minimum is a safe default but brittle.
6. **Per-bot skill variation**: ship identical skill across a team's bots in v1 (simplest), or jitter skill per agent (more lifelike, very small extra work)? Defaulted to identical in this spec.
7. **Human identification**: how does the AI tell a human teammate apart from a bot teammate? Check for `ctrl is LocalController` on the teammate's skater, or a flag on the `Skater` itself? Spec assumes the latter via `snap.skater_is_human: PackedByteArray` — add to `WorldSnapshot` if not present.
8. **Offline-mode bot ownership**: in offline mode, does the local machine own all six skaters' controllers? Confirmed in the task spec ("AI runs locally"), but worth a line-item confirmation that local controllers and AI controllers coexist on the same machine without conflict in the `NetworkManager.host_tick` logic.
9. **Body-check gate's "1.5 m cylinder"**: what's the actual hit-detection radius in the existing check code? Align to that — do not let the gate be stricter or looser than the physics.
10. **Influence map extents vs rink**: the 120×60 at 0.5 m assumes a 60 × 30 m rink. If the real rink is 61 × 30.5 m (NHL standard), bump to 122×61 and update the projection math.

---

## 22. Phase 6 backlog

Items raised in passing during Phase 6 work but deferred — not blocking
anything, but worth picking up between bigger features. In rough
priority order:

### Active queue (next up)

1. **Smarter shot selection.** Bots currently only fire ground wristers
   away from the goalie shadow. Add intelligence around the rest of
   the toolset:
   - Elevated when the goalie is butterfly / down (use
     `GoalieNetworkState.state` to detect).
   - Slapper when there's time + lane and the bot is in the high slot.
   - Wrister stays the default.

   Each option gets its own utility score; SM picks max.

2. **Offsides — three sub-tasks.**
   - **Awareness.** Bot reads each teammate's offside state from
     existing `Skater.is_ghost` / `OffsideRules` infra. Add a query
     to `TeamBrain` so the SM can ask "is anyone on my team offside?"
   - **Hold-up.** Carrier decelerates approaching the OZ blue line
     if any teammate is across — pull the carry anchor back to the
     NZ side of the line until teammates tag.
   - **Tag-up.** Offside teammate's anchor pulls them back to their
     own side of the blue line before re-engaging the offense.

   Pre-work: quick map of where offsides state actually lives today
   so the AI doesn't duplicate the detector. Don't write a parallel
   offside check on the AI side.

### Parked (revisit after design settles)

3. **Decision-making smoothing.** Tried as Phase 6k (EMA per action
   with α=0.01); reverted because it was premature — would have
   masked latent issues in the score functions while we're still
   iterating. Two candidate models when the bot's behavior is
   stable enough that smoothing is solving a real flicker problem
   rather than hiding one:
   - **EMA per action.** What 6k tried. Cleanest math. Plateau
     issue: thin scores (raw≈0.26) take ~480ms to cross the 0.25
     threshold, which is too slow for legitimate marginal options.
   - **Persistence count.** Each option must be the current winner
     for K consecutive ticks before firing. Hot scores commit
     immediately; flickering between options resets the counter.
     Probably the better fit, but only worth implementing once
     debug visuals make it obvious whether the underlying scores
     are flickering for legitimate reasons (real world change) or
     buggy ones (math noise).

   Pre-req: debug visuals (per the original spec) so we can SEE
   what scores look like in flight. Without that, smoothing is
   guessing.

### Trajectory module extensions

These are extensions to `AITrajectory.predict` that slot into the
existing for-loop without touching call sites:

4. **Puck friction.** `AITrajectory` is constant-velocity today. The
   puck-chase intercept (`_lead_intercept`) would benefit from
   modeling `ICE_FRICTION` so we don't aim ahead of a sliding puck
   that's about to stop.
5. **Skater acceleration.** Skaters don't reach top speed instantly.
   Modeling acceleration in the trajectory (clamped to max-speed)
   gives more realistic mark-lead and chase predictions, especially
   for slow-starting carriers.
6. **Reaction-delay floor.** First N steps of the trajectory keep
   current velocity (the target hasn't reacted yet), then steering
   pull kicks in. Tightens predictions of intent — a defender mid-turn
   isn't yet pursuing.

### Tuning constants

Pure number tweaks; do these in playtest sessions, not standalone:

7. **Adaptive pass-speed estimate.** `PASS_PUCK_SPEED_REF_M_S` is a
   fixed 22 m/s. Real puck speed depends on shooter angle, charge,
   and shot type. A two-tier estimate (slap vs wrister) or a
   distance-dependent table would tighten pass leads.
8. **Crease repel weight playtest.** `CREASE_REPEL_WEIGHT = 0.9`
   shipped untested. Tune up if bots still spam the crease, down if
   they refuse to shoot from the high slot.
9. **Engagement cooldown range.** 100–400ms speed-scaled. Validate
   against post-strip recovery feel.

---

*End of AI_SKATER_SPEC.md. Companion to GOALIE_AI_SPEC.md. Comments welcome in code review, not in docs.*