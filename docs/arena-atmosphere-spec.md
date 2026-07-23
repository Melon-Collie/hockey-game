# Arena Atmosphere Spec

Turning the flat solid-color void behind the boards into a **spotlit broadcast
arena**: thin haze catching the overhead-light cones (god rays), a darkened
bowl so the ice reads as the lit stage, real screen-space reflections of the
skaters on the ice, and grounded contact shadows under the players.

**Status: applied.** The environment/light values below are set in
`Scenes/RinkArena.tscn`, the ice-roughness tune is in `hockey_rink.gd`, and the
three expensive passes (fog, reflections, ambient occlusion) are now toggleable
in **Options → Video** (default on). This doc is the reference for *what* was
set and *how to tune* it — the tables are the dials, not a to-do list.

Since none of this can be verified without running the game, **eyeball it in a
session and tell me what to nudge** — every value here is a one-line change.

---

## ⚠️ Read first — the runtime graphics authority

`PlayerPrefs.apply_video()` runs on scene load (`game_scene.gd`, `boot.gd`,
`replay_viewer.gd`) and **overrides a subset of Environment settings every
time**. It sets:

- `adjustment_enabled` + the color-correction LUT (from `gamma` /
  `color_grade_preset`)
- `sdfgi_enabled = (gi_mode == GI_MODE_SDFGI)`
- shadow-casting on the ceiling spots (shadow-quality tier)
- MSAA / TAA / FXAA

It does **not** touch SSAO, SSR, volumetric fog, glow, tonemap, or ambient — so
everything in this spec **persists from the `.tscn`** and won't be clobbered.

Two consequences worth knowing:

1. **SDFGI is OFF by default.** `gi_mode` defaults to `GI_MODE_OFF`, so despite
   the `.tscn` shipping `sdfgi_enabled = true`, `apply_video()` turns it back
   off for anyone who hasn't opted into GI. That means the flat
   `ambient_light_energy = 0.25` is the *only* fill light in the default look —
   which is exactly why darkening it (below) gives such a strong stage effect.
   No global bounce fills the shadows back in.
2. **The expensive passes are Video options.** `volumetric_fog_enabled`,
   `reflections_enabled` (SSR), and `ambient_occlusion_enabled` (SSAO) are
   `PlayerPrefs` bools (default on), gated in `apply_video()` and toggled in the
   Video tab. The `.tscn` carries all the *parameters* (fog density/albedo, SSR
   steps, SSAO intensity, per-light fog contribution, darkened ambient); the
   toggles only flip the pass on/off. Turning a pass off drops that effect but
   keeps the darkened-bowl mood (ambient + fill dimming are baked, not gated).

---

## Pass 1 — Darken the bowl (the stage look)

Select `WorldEnvironment` → `Environment`:

| Property | From | To | Why |
|---|---|---|---|
| `ambient_light_energy` | `0.25` | **`0.13`** | Halve the only fill light so the stands/shell fall into shadow while the 2.2-energy overhead spots keep the ice bright. This is the single biggest mood change. |

Then the 4 corner fill omnis — `BowlLight_NE / NW / SE / SW`:

| Property | From | To | Why |
|---|---|---|---|
| `light_energy` | `0.25` | **`0.16`** | Keep a faint warm rim on the crowd so the bowl isn't pitch black, but let it recede. |

Eyeball it: the ice should look like a lit sheet in a dim building. If the
crowd vanishes entirely, nudge `ambient_light_energy` up to `0.15–0.16`. Real
arenas dim the bowl during play, so lean dark.

---

## Pass 2 — Volumetric fog + light shafts (god rays)

This is the showpiece. The 8 overhead `SpotLight3D`s already point straight down
at the ice from Y=22 — enable volumetric fog and they cast visible cones.

`WorldEnvironment` → `Environment` → **Volumetric Fog**:

| Property | Value | Notes |
|---|---|---|
| `volumetric_fog_enabled` | **`true`** | |
| `volumetric_fog_density` | **`0.018`** | THIN. Above ~0.04 it becomes pea soup that washes the ice flat. Start here, creep up only if the shafts are too faint. |
| `volumetric_fog_albedo` | **`Color(0.9, 0.94, 1.0)`** | Cool white haze matching the spot color. |
| `volumetric_fog_anisotropy` | **`0.4`** | Forward-scatter so the cones brighten toward the lights (that's the "shaft" read). |
| `volumetric_fog_length` | **`48`** | Distance from camera the fog volume covers; the cam sits ~15–32 m out, so 48 reaches the far boards. If shafts get clipped at range, raise it. |
| `volumetric_fog_gi_inject` | **`0.0`** | GI is off by default — no bounce to inject. |
| `volumetric_fog_ambient_inject` | **`0.0`** | Don't let the flat ambient wash the fog volume grey. |
| `volumetric_fog_emission` | **`Color(0,0,0)`** | No self-glow. |

### Which lights feed the fog

Every Light3D has `light_volumetric_fog_energy` (default `1.0` = full
contribution). Tune per rig so the overhead cones dominate and the fill lights
don't fog up the room:

| Lights | `light_volumetric_fog_energy` | Why |
|---|---|---|
| `SpotLight3D` … `SpotLight3D8` (the 8 overhead) | **`1.0`** (leave default) | These are the shafts. |
| `DasherSpotLight` … `DasherSpotLight6` (6 rinkside) | **`0.3`** | Warm board-level spots — a little floor haze is nice, full strength muddies the ice. |
| `BowlLight_NE/NW/SE/SW` (4 omni fill) | **`0.0`** | Fill only — kill their contribution so you don't get glowing haze-balls in the stands. |

**Perf note:** volumetric fog is a per-frame froxel pass — a render-thread GPU
cost, *not* on the 120 Hz simulation hot path, so it doesn't touch the
networking/tick budget. It's the more expensive of the two additions; if you're
GPU-bound, `volumetric_fog_length` and density are the dials, and the quality
tier (below) is the real answer.

---

## Pass 3 — Ice reflections (SSR)

`WorldEnvironment` → `Environment` → **Screen Space Reflections (SSR)**:

| Property | Value | Notes |
|---|---|---|
| `ssr_enabled` | **`true`** | |
| `ssr_max_steps` | **`56`** | Default 64; 56 is a touch cheaper and still clean on a flat floor. |
| `ssr_fade_in` | `0.15` | Default is fine. |
| `ssr_fade_out` | `2.0` | Default is fine. |
| `ssr_depth_tolerance` | `0.2` | Default is fine. |

The ice material is already tuned to receive it: grazing roughness `0.04` gives
the sharp mirror-streak of a skater's reflection when you look *across* the ice
(the signature hockey-game look), and `ice_roughness_head_on` was dropped
`0.20 → 0.15` (done in `hockey_rink.gd`) so the reflection holds together
looking more directly down, without turning the ice into a full mirror.

**Caveat (inherent to SSR):** it only reflects what's on-screen. A skater whose
feet are off the bottom of the frame won't reflect, and reflections vanish
behind occluders. That's normal and unobjectionable for ice — just don't expect
a perfect mirror of off-screen action.

If reflections feel too strong/glassy, raise `ice_roughness_head_on` back toward
`0.18`; too weak, drop toward `0.10`.

---

## Pass 4 — Contact shadows (SSAO — currently OFF)

Latent bug: the `.tscn` sets `ssao_radius` / `ssao_intensity` but **never sets
`ssao_enabled`**, so SSAO has been off this whole time (the radius/intensity are
inert). Turning it on grounds the skaters to the ice with soft contact shadows —
cheap and high-value now that the bowl is dark.

`WorldEnvironment` → `Environment` → **SSAO**:

| Property | From | To |
|---|---|---|
| `ssao_enabled` | *(unset → false)* | **`true`** |
| `ssao_intensity` | `1.0` | **`1.2`** |
| `ssao_radius` | `0.5` | `0.5` (leave) |

---

## Pass 5 — Optional glow nudge

With the bowl darkened and the ice glinting harder, the existing glow (already
`glow_enabled = true`, strength `0.4`) will read more on its own. If you want the
spotlight hotspots and ice glints to bloom a touch more:

| Property | From | To |
|---|---|---|
| `glow_hdr_threshold` | `1.3` | **`1.1`** |

Optional and taste-dependent — skip if it starts to smear.

---

## Validation checklist

- [ ] Bowl reads dark; ice reads as the lit stage.
- [ ] Visible light cones from the 8 overhead spots down onto the ice.
- [ ] Skaters reflect on the ice, sharpest when viewed across the sheet.
- [ ] Soft contact shadows under skates/goal.
- [ ] Crowd still faintly visible (not pitch black).
- [ ] No pea-soup haze washing out the ice (lower fog density if so).
- [ ] Frame rate acceptable on your target hardware (if not → quality tier).

## Options wiring (done)

The three passes are per-effect toggles in **Options → Video → Performance**
("Volumetric Fog", "Reflections", "Ambient Occlusion"), each a `PlayerPrefs`
bool (default on) applied in `apply_video()`. Kept per-effect rather than one
"Atmosphere" enum so a player can keep cheap SSAO while dropping the costly fog.
If you'd rather collapse them into a single Low/Medium/High tier later, it's a
small change — say the word.
