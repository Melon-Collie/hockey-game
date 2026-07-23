# Arena Atmosphere Spec

**Correction (this supersedes the original "darkened stage" version).** A first
pass tried a cinematic *darkened-bowl / spotlit-ice* look — that was wrong for
hockey. Real rinks are **flooded with bright, even light**: the whole sheet,
boards and corners included, reads near-white. Darkening the ambient just
starved the corners (the ceiling-spot rig only pools light centrally) and, on
this game's **top-down camera**, volumetric fog can't show its god-ray shafts —
those only read from a side angle — so it added grey haze for no payoff. That
pass is reverted.

**What's applied now** — the genuinely useful, top-down-friendly additions:

- **SSR** (screen-space reflections) on the ice — skaters reflect on the sheet,
  sharpest viewed across the ice. Default on.
- **SSAO** (contact shadows) — grounds skaters/goal to the ice. Default on
  (it was silently *off* before — the `.tscn` set `ssao_radius`/`ssao_intensity`
  but never `ssao_enabled`).
- **Ice roughness tune** — `ice_roughness_head_on` 0.20 → 0.15 in
  `hockey_rink.gd` so reflections hold together looking down.
- Bright even lighting **restored** to the original values (ambient `0.25`, bowl
  fills `0.25`, glow threshold `1.3`).
- **Volumetric fog** kept as an **opt-in** toggle, **default off**, thin density
  (`0.008`) — a faint atmosphere for anyone who wants it, not the default look.

All three passes are per-effect toggles in **Options → Video → Performance**
(`PlayerPrefs` bools, applied in `apply_video()`).

Since none of this can be verified without running the game, **eyeball it and
tell me what to nudge** — every value here is a one-line change.

---

## ⚠️ The runtime graphics authority

`PlayerPrefs.apply_video()` runs on scene load and drives these from prefs:

- `volumetric_fog_enabled` ← `volumetric_fog_enabled` pref (default **false**)
- `ssr_enabled` ← `reflections_enabled` pref (default true)
- `ssao_enabled` ← `ambient_occlusion_enabled` pref (default true)
- `sdfgi_enabled` ← `gi_mode` (default `OFF`)
- adjustment LUT, shadows, AA

The `.tscn` carries the **parameters** (fog density/albedo, SSR steps, SSAO
intensity, per-light fog contribution); `apply_video()` only flips the enables.
So a toggle off drops that effect; the base lighting is untouched.

Note **SDFGI is off by default** (`gi_mode` defaults to `GI_MODE_OFF`), so the
`.tscn`'s `sdfgi_enabled = true` is overridden off at runtime — the direct
spot/omni rig + ambient is the whole lighting model for most players.

---

## Current environment values (`Scenes/RinkArena.tscn`)

`WorldEnvironment` → `Environment`:

| Property | Value | Note |
|---|---|---|
| `ambient_light_energy` | `0.25` | Restored. The even-fill floor — **raise this first** if the rink still reads too dim/uneven at the boards. |
| `ssr_enabled` | `true` | Ice reflections. |
| `ssr_max_steps` | `56` | |
| `ssao_enabled` | `true` | Contact shadows. |
| `ssao_intensity` | `1.2` | Drop toward `1.0` if it adds grime. |
| `glow_hdr_threshold` | `1.3` | Restored. |
| `volumetric_fog_enabled` | `false` | Opt-in; overridden by the pref at runtime anyway. |
| `volumetric_fog_density` | `0.008` | Faint, for when it's toggled on. |

Lights (unchanged from ship except the fog-contribution lines, inert while fog
is off): 8 overhead `SpotLight3D` @ `2.2`, 6 `DasherSpotLight` @ `1.4`, 4
`BowlLight` omni @ `0.25`.

---

## Board lighting (applied)

The board walls read dark from the top-down camera no matter how bright the
ceiling rig is — they're near-vertical, so straight-down light grazes past them.
Cranking the ceiling rig to compensate just blew out the ice and washed the
crowd (an overhead-spill dead end). The right fix is to make the boards show
their *own* color:

- **Board bands self-emit** (`hockey_rink.gd`): `wall_emission_energy 0→0.15`,
  `kickplate_emission_energy 0→0.5` (gold lip), `cap_rail_emission_energy 0→0.5`
  (navy top rail). Each band emits its own color, so the boards read correctly
  top-down with **zero** light spilled onto ice or crowd. Kept under the glow
  HDR threshold so they don't bloom.
- **Behind-goal dashers stay off** (`DasherSpotLight5/6`, `light_energy = 0`) —
  they threw a warm patch behind the net and spilled onto the crowd.
- **Overhead rig left at ship values** (`spot_angle 50`, both attenuations `0.5`)
  — flattening them over-brightened the ice and washed the crowd, so that's
  reverted. The mild center pooling is accepted; if it bugs you, the fix is a
  small **ambient** bump (`0.25→0.30`), which evens without the overhead spill.

Dials: board emission energies (up = boards pop more / risk bloom, down =
subtler); a `0.03` ambient nudge for center pooling. All one-liners.

## If it still isn't bright/even enough

The stated target is a **bright, even NHL sheet**. Levers, in order of impact:

1. **`ambient_light_energy`** — the dominant even-fill. Push `0.25 → 0.32 → 0.40`
   until the corners read as bright as center. This is the main dial.
2. **Flatten the center hotspot** — if the ice looks "spotlit" (bright middle,
   dim ends) rather than evenly flooded, the fix is to lower the ceiling-spot
   `light_energy` (`2.2 → ~1.6`) *and* raise ambient, trading a punchy central
   pool for flat even coverage. That's the real "arena flood" look.
3. **Boards/edges specifically** — the `DasherSpotLight` rig (rinkside, `1.4`)
   lights the perimeter; raising those or widening their `spot_angle` lifts the
   board area.

Tell me the direction (brighter overall? flatter? warmer/cooler?) and I'll dial
it — these are all one-line value edits I can make directly.

---

## Cohesion pass (applied)

Two changes that unify the frame and make the figures read as intentional:

- **Broadcast color grade is now the default.** The `COLOR_GRADE_BROADCAST`
  preset (teal-shadow split-tone + mild S-curve + slight desat, in
  `_apply_grade_broadcast`) already existed but the load default was `NEUTRAL`,
  so returning testers saw no grade. Load default → `BROADCAST`, matching the
  var initializer and the reset-to-defaults value. Still switchable in
  Options → Video → Color Grade.
- **Rim light on skaters + goalie.** A subtle Fresnel edge highlight so the
  rounded primitive forms read as lit volumes from top-down rather than flat
  blobs. Skaters: `rim_enabled` on every body material via the two factories
  (`_make_solid_mat` / `_make_texture_material`) + the inline torso/shoulder
  mats (`_RIM_STRENGTH 0.4`, `_RIM_TINT 0.35` in `skater_uniform_coordinator`).
  Goalie: a matching Fresnel emission term in `goalie_jersey.gdshader`. Dials:
  the rim constants (up = stronger edge) and the goalie's `rim * 0.2`.

## Options wiring (done)

Per-effect toggles in **Options → Video → Performance** — "Volumetric Fog"
(default off), "Reflections" (on), "Ambient Occlusion" (on) — each a
`PlayerPrefs` bool applied in `apply_video()`.
