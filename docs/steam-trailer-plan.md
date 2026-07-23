# Mitts — Steam Trailer Production Plan

Working doc for the launch trailer. Theme: **player control & freedom of
expression** — carry that spine through the dangers, the shots, the passes.
Iterate freely; nothing here is load-bearing on the game code.

---

## 1. Capture pipeline — what actually records

Grounded in how the game writes footage today, so we don't chase angles that
can't exist:

- **`.mreplay` files are written only for lobby matches** — an offline match
  vs bots *and* online games both qualify (they carry a `game_id`). **Free
  play, tutorials, and drills do NOT record** (no `game_id` →
  `_open_replay_file_writer` bails). So "skate around in free play" gives you
  live footage only, never a replay.
- Recording is gated by **Options → `replay_recording_enabled`** (make sure
  it's on) and capped by **`replay_keep_count`** (oldest `.mreplay` is purged
  first — copy keepers out of `user://replays/` before they roll off).
- Replays are opened from **Career Stats screen → Replays tab → Watch**, which
  launches the **Replay Viewer** (its own scene, free-fly camera, scrubber).

### The three capture modes

| # | Mode | How | Best for |
|---|------|-----|----------|
| **A** | **Replay free-cam** *(primary)* | Play an **offline match vs bots** → it auto-records → watch it in the Replay Viewer | Precise, **re-shootable** hero angles. This is how the whole trailer should be cut. |
| **B** | **Spectator free-cam** | Take a **spectator slot** in a lobby with bot-filled teams (or a 2nd human plays) | Organic **live** bot action, hand-flown cam, no re-shoot |
| **C** | **Live self-play POV** | Free play or a match, press **H** to hide UI, capture with an external recorder | First-person "this is how it feels to control" shots |

**Default workflow: A.** Play a full match vs bots (the bots are strong — they
dangle, hit, one-time, and feed), let it record, then live in the Replay Viewer
flying angles. Re-shoot any angle as many times as you want off the same clip.

---

## 2. Replay Viewer control cheat sheet

| Key | Action |
|-----|--------|
| **C** | Cycle camera: Broadcast → Chase → POV → **Free** |
| **↑ / ↓** | Cycle tracked player (Chase / POV modes) |
| **Free cam:** WASD | Move on camera plane |
| **Free cam:** Q / E | Descend / ascend (world Y) |
| **Free cam:** hold **Shift** | Boost speed |
| **Free cam:** hold **RMB** | Mouse-look (yaw/pitch) |
| **Space** | Play / pause |
| **`[` / `]`** | Speed down / up — **0.25× · 0.5× · 1× · 2× · 4×** |
| **`,` / `.`** | Frame-step back / forward (while paused) |
| **← / →** | Seek ∓5 s |
| **Tab** | Full stats board |
| **H** | **Hide UI (clean capture)** — new |
| **Esc** | Pause menu / exit |

**Money move for a hero shot:** pause on the moment → frame-step (`,` `.`) to
the exact frame → **H** to strip the UI → **C** to Free cam → fly the angle →
resume at **0.25×** for the slow-mo beat.

---

## 3. The narrative spine

A ~60–75 s arc that escalates. Every section is the same promise — *you're in
full control* — shown at a higher stakes:

1. **Cold open (control):** one long, unbroken dangle through traffic. No cuts,
   no UI. Establishes "this is a real puck on a real stick."
2. **Freedom of expression:** rapid-fire variety — backhand toe-drag, saucer
   flip, a give-and-go, a between-the-legs-ish blade swing. Show that the input
   space is deep.
3. **Danger:** open-ice hits, a stagger, a shot-block, a poke-check scramble.
   The physicality beat.
4. **Shots:** wrister rip → slapshot wind-up → **one-timer** → top-corner snipe.
   Build to the loudest release.
5. **Passes:** the pretty stuff — stretch pass to a streaking receiver, a
   saucer over a stick, a back-door one-timer feed that finishes section 4's
   promise.
6. **Button (freedom, paid off):** a single highlight-reel goal that chains
   dangle → feed → finish, then hard cut to logo + "Wishlist now."

---

## 4. Shot list (beat → stage → camera)

Each beat: **what it shows · how to stage it · camera + speed.** All mechanics
below are real (see `CLAUDE.md` for the exact tunables).

### Control / dangles
- **Long carry through traffic** — carry the puck at 3v3 through the neutral
  zone into contact; the blade chases the cursor continuously. *Chase cam low
  and tight, or Free cam tracking alongside at skate height; 1× then 0.5×.*
- **Backhand toe-drag / dangle texture** — sweep the cursor forehand↔backhand
  across the puck; the small lift through center is the "dangling" tell. *Free
  cam low front-quarter, 0.25×.*
- **Reception read** — catch a hard feed by squaring the blade (a hard incoming
  puck bobbles on a bad angle, corrals on a squared one). *Front angle so the
  blade face reads.*

### Freedom of expression
- **Saucer pass** — a **LOW-loft quick pass** (scroll to LOW, then E): flips
  ~0.26 m, clears a stick, lands flat. *Side-on low so the arc reads against
  the ice.*
- **Give-and-go** — pass to a bot, skate into space, take the return. *Broadcast
  or high Free cam so both players are in frame.*
- **Deflect / tip** — hold **Q** at **LOW** to redirect a low feed up-and-in
  (the "money tip"); at **HIGH** to bat an airborne puck down. *Tight on the
  blade, 0.25×.*

### Danger
- **Open-ice check** — two skaters closing head-on; the hit triggers from
  closing-velocity impulse (no button), and the burst + sound scale with how
  hard it lands. Bigger builds (heavier `weight`) deliver more. *Free cam at
  ice level, perpendicular to the collision line, 0.5× → 0.25× on contact.*
- **Stagger recovery** — hold on the victim after a big hit: the thrust penalty
  eases back over the `stagger_timer`. *Follow the staggered skater.*
- **Shot-block** — Ctrl crouch into a slapshot lane; the puck reflects. *Low
  behind the blocker.*
- **Poke / scramble** — two blades contest a loose puck; it squirts toward the
  stronger momentum. *Top-down-ish, 0.25×.*

### Shots
- **Wrister rip** — LMB hold + a hard flick; power is pure cursor speed. *Behind
  the shooter, then whip to a net-cam as it releases.*
- **Slapshot wind-up** — RMB charge; the pose IS the gauge (blade lift, torso
  coil, quiver at full). *Side profile to catch the wind-up silhouette; hold on
  the coil at 0.5×, snap to 1× on release.*
- **One-timer** — charge the slapshot **off-puck** and let a feed arrive in the
  zone; it fires at whatever charge was built. *Two-shot: feed in frame, then
  net-cam.*
- **Top-corner snipe** — scroll to **HIGH** loft; the arc peaks ~1.12 m and the
  puck tops out ~5 cm under the crossbar — you can roof it but not sail it.
  Beat the (beatable) goalie by picking a corner out of reach. *Net-cam tight on
  the top corner, 0.25× as it crosses the line.*

### Passes
- **Stretch pass** — feed a streaking receiver; it arrives soft in their frame
  (easy catch) precisely because they're skating with it. *High Free cam
  following the puck's flight the length of the ice.*
- **Back-door one-timer feed** — weak-side pass into a charged one-timer (pays
  off the shots section). *Behind the net looking out, so the cross-crease feed
  and the finish are both in frame; 0.5×.*

---

## 5. Staging levers (how to make bots produce the beat)

- **Team size** — **3v3** for open ice, room to dangle, clean 1-on-1s and
  odd-man rushes (the default, best for most beats). **5v5** for the structured,
  crowded looks (net-front scrambles, point shots, D-zone coverage).
- **Ruleset** — keep **ARCADE** (offsides on, icing off) so play flows and
  nothing whistles dead mid-shot.
- **Goalie difficulty** — tune the goalie pref *down* if you want the snipes to
  finish more reliably for the shots/passes sections; the goalie is beatable by
  design, but a lower setting reshoots faster.
- **Bot variety** — bots load curated builds from `data/bot_identities.json`
  (height/weight/gear). If you want an obvious *tank* for the big-hit beat or a
  *small dangler* for the control beat, that's the file to lean on — heavier
  weight = bigger delivery, leaner = quicker first step.
- **Re-shoot, don't pray** — because A records the whole match, you rarely need
  to stage perfectly live. Play a loose scrimmage, then mine the `.mreplay` for
  the beats that actually happened and fly each one.

---

## 6. Edit / delivery notes

- **Steam max is 60 s of usable trailer** in most placements — cut a tight
  ~30 s "hook" version and a ~60–75 s full version.
- **Lead with control, not the logo.** First 3 seconds decide the wishlist.
- **Diegetic audio sells physicality** — the check/impact sounds already scale
  with hit strength; let a big hit's sound punch through the music bed.
- **Slow-mo is your friend but rationed** — 0.25× on the one contact frame of a
  hit, the puck crossing the line, the blade catching a hard feed. Everything
  else at 1×.
- Capture at the **highest resolution/FPS** the machine allows; the Replay
  Viewer honors your video settings on entry.

---

## 7. Open questions / TODO

- [ ] Confirm a **spectator slot is reachable in an offline lobby** (all-bot
      teams) — if so, mode B gives live hand-flown angles with zero re-shoot.
- [ ] Decide 30 s vs 60 s cut (or both).
- [ ] Music: licensed track vs royalty-free bed.
- [ ] Optional engineering adds if we want them later: a dedicated **"trailer
      staging" drill** that spawns a rush / one-timer / big-hit on demand
      (repeatable scenarios), or **cinematic follow-cam presets** for playable
      live variety. Both deferred for now.
