# Mitts

An arcade hockey game built in Godot 4.6.2 (Jolt Physics). Online multiplayer — each player runs their own client, with their own camera.

> **Early development.** Expect rough edges.

---

## Download & Play

1. Go to the [latest release](../../releases/tag/latest) and download the zip for your platform (Windows and Linux only — no macOS build yet)
   - **Windows:** `Windows Desktop.zip` → extract and run `mitts.exe`
   - **Linux:** `LinuxX11.zip` → extract, `chmod +x mitts.x86_64`, then run it
2. The game launches straight onto the ice in free play (first launch runs a short tutorial). Press **Esc** for the menu — set your name and attributes under **Player**, start games under **Online**, replay the tutorial, or browse your career stats.

**Online play uses Steam** — Steam must be running on every machine (host and joiners). **Host Game** creates a lobby, **Join Game** opens a lobby browser, and Steam friend invites work too. No port forwarding needed.

The title screen shows an **"Update available"** notice when your build is behind the latest release. It doesn't patch automatically — grab the new zip from the release page when you see it.

---

## Feedback & Bug Reports

Use the in-game **Report Bug** button (bottom-right corner) — it attaches your version and connection telemetry automatically. If the game crashed or something went visibly wrong, also grab the newest log file and include it however you're sending feedback:

- **Windows:** `%APPDATA%\Godot\app_userdata\Mitts\logs\godot.log`
- **Linux:** `~/.local/share/godot/app_userdata/Mitts/logs/godot.log`

**Alpha limitations to know about:** if the host leaves, the match ends for everyone (no host migration); there's no reconnect — if you disconnect you can rejoin from the lobby browser, but with a fresh slot and stats; no in-game chat; a team plays shorthanded if someone drops mid-match.

---

## Controls

| Input | Action |
|-------|--------|
| **WASD** | Skate |
| **Mouse** | Blade position |
| **Left click (tap)** | Quick shot / pass |
| **Left click (hold + sweep)** | Wrister — sweep blade to charge, release to shoot |
| **Right click (hold)** | Slapshot — charge up, release to shoot |
| **Space** | Brake (hard friction) |
| **Ctrl (hold, no puck)** | Shot-block stance — crouch, widen block area, slow movement, face puck |
| **Ctrl (during wind-up)** | Cancel shot — abort a wrister or slapshot wind-up without firing |
| **Scroll up / down** | Toggle elevated shot |
| **Tab** | Toggle scoreboard |

---

## How It Plays

Your blade follows your mouse at all times. Move it toward the puck to pick it up — the puck attaches automatically when your blade gets close enough. Once you have it, shoot or pass by sweeping your mouse and releasing.

Pucks coming in fast deflect off your blade instead of sticking. Move your stick backward with the puck to absorb a pass and catch it; hold your stick still against a fast puck to deflect it. Opposing blades can poke-check the puck loose — stick battles are momentum-based. Skate hard into a puck carrier to body check them — a big enough hit knocks the puck loose. Get in the way of a shot and it deflects off your body. Opponents can't poke their stick through you — position your body to shield the puck.

A fast-paced version of offsides and icing have been implemented. If you cross the blue line before the puck, you're offsides. You'll be ghosted (can't interact with the puck or other players). Tag back up at the line to exit ghost mode. For icing, if you ice the puck, your whole team will be ghosted for a few seconds or until the opponent picks up the puck.

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
