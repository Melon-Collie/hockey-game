# Mitts

A 3v3 hockey game built in Godot 4.6.2 (Jolt Physics). Online multiplayer — each player runs their own client, with their own camera.

> **Early development.** Expect rough edges.

---

## Download & Play

1. Go to the [latest release](../../releases/tag/latest) and download the zip for your platform (Windows and Linux only — no macOS build yet)
   - **Windows:** `Windows Desktop.zip` → extract and run `mitts.exe`
   - **Linux:** `LinuxX11.zip` → extract, `chmod +x mitts.x86_64`, then run it
2. The game launches straight onto the ice in free play (first launch runs a short tutorial). Press **Esc** for the menu — set your name and attributes on the player card, start or join games under **Play**, run the tutorial course under **Tutorial** or the score-X-of-N drills under **Drills**, or browse your career stats and replays under **Career**.

**Online play uses Steam** — Steam must be running on every machine (host and joiners). **Start Game** opens your lobby (offline vs bots until you flip its visibility to Friends or Public), the **Play** popup lists open public games to join, and Steam friend invites work too. No port forwarding needed.

---

## Feedback & Bug Reports

Use the in-game **Report Bug** button (bottom-right corner) — it attaches your version and connection telemetry automatically. If the game crashed or something went visibly wrong, also grab the newest log file and include it however you're sending feedback:

- **Windows:** `%APPDATA%\Godot\app_userdata\Mitts\logs\godot.log`
- **Linux:** `~/.local/share/godot/app_userdata/Mitts/logs/godot.log`

**Alpha limitations to know about:** if the host leaves, the match ends for everyone (no host migration); if you disconnect mid-match you get a Reconnect prompt — rejoin within about a minute and your slot and stats are held, after that you come back fresh; no in-game chat; a team plays shorthanded if someone drops mid-match.

---

## Controls

| Input | Action |
|-------|--------|
| **WASD** | Skate |
| **Mouse** | Blade position |
| **E** | Quick pass — instant snap toward the cursor |
| **Left click (hold + flick)** | Wrister — the drag direction is your aim, and how fast the cursor is moving when you release is your power |
| **Right click (hold)** | Slapshot — charge the wind-up, release to shoot |
| **Q (hold, no puck)** | Deflect — redirect an incoming puck off the blade instead of catching it (at high loft it doubles as a stick-lift) |
| **Q (tap, with puck)** | Nudge / self-pass |
| **Shift (hold)** | Sprint — stamina-gated top-speed burst; wider turns while held |
| **Space** | Brake (hard friction) |
| **Ctrl (hold, no puck)** | Shot-block stance — crouch, widen block area, slow movement, face puck |
| **Ctrl (during wind-up)** | Cancel shot — abort a wrister or slapshot wind-up without firing |
| **Scroll up / down** | Step shot loft up / down (flat → saucer → high) |
| **Tab** | Toggle scoreboard |

---

## How It Plays

Your blade follows your mouse at all times. Move it toward the puck to pick it up — the puck attaches automatically when your blade gets close enough. Once you have it, tap **E** for a quick pass or snap shot, or hold **left click** and flick for a wrister.

Pucks coming in fast deflect off your blade instead of sticking. Square your blade to the incoming puck — or give ground by skating with it — to soften the reception and catch it; a poorly-angled blade against a hard puck deflects it away. Opposing blades can poke-check the puck loose — stick battles are momentum-based. Skate hard into a puck carrier to body check them — a big enough hit knocks the puck loose and staggers them. Get in the way of a shot and it deflects off your body. Opponents can't poke their stick through you — position your body to shield the puck.

Rules are picked in the lobby. The default **Arcade** set runs a fast-paced, whistle-free offside: cross the blue line before the puck and you're ghosted (can't interact with the puck or other players) until you tag back up at the line. The **NHL** set instead plays true delayed offside and icing with real stoppages and faceoffs, and **Off** disables infractions entirely.

You can charge up a one-timer without the puck by holding right click. If you release while the puck is in your shooting zone, you'll fire off a one-timer.

---

## Planned

- Goalie improvements. Better positioning, more realistic recoveries, and an actual stick
- Visual improvements. Better VFX, better animations and models. Better jersey textures.
- Sound improvements. Skating sound effects, better sound effects, missing sound effects.
- More netcode improvements. Always more netcode improvements.

## Later

- Characters with unique abilities (deferred until game feel is right)
- 5v5?
- Different rinks
