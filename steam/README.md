# Steam (SteamPipe) build upload

How to hand-upload a Mitts build to Steam for the closed beta. This is the
**manual** path — get it working end-to-end by hand first; automating it in CI
comes later, once the cadence justifies it.

App ID: **4892600** (the technical App ID used by SteamPipe and the Steam API —
distinct from store-item ID 1230738, which is a different identifier). Builds
publish to a **private beta branch**, never to
`default`/`public`, until launch.

```
steam/
  app_build.vdf       app-level script: appid, depots, setlive branch
  depot_windows.vdf   Windows content depot
  depot_linux.vdf     Linux content depot
  content/            (gitignored) staged export output — you create this
    windows/          full Godot Windows export goes here
    linux/            full Godot Linux export goes here
  output/             (gitignored) steamcmd logs + chunk cache
```

The `.vdf` scripts are version-controlled; `content/` and `output/` are not.

---

## One-time setup (Steamworks website — can't be scripted)

Do these once in the Steamworks app admin for App ID 4892600. The SDK can't do
them for you:

1. **Create two depots** (SteamPipe → Depots): one Windows, one Linux. Set each
   depot's **operating system** accordingly. Steam assigns the depot IDs here.
2. **Put the real depot IDs into the `.vdf` files.** Replace the placeholder
   `1230739` / `1230740` in `app_build.vdf`, `depot_windows.vdf`, and
   `depot_linux.vdf` with what Steamworks gave you. (They're often AppID+1/+2,
   but confirm — a wrong ID fails the upload.)
3. **Set launch options** (Installation → General Installation): executable
   `mitts.exe` for the Windows depot, `mitts.x86_64` for Linux, so Steam knows
   what to run.
4. **Create the private beta branch** (SteamPipe → Builds, branches are managed
   there) and give it a password. Name it e.g. `beta`.
5. **Builder account**: use an account with publishing access to the app. A
   dedicated build-only account is recommended (especially before CI), so your
   main account's Steam Guard isn't entangled with automated uploads.

You do not need the Common Redistributables (VC++/DirectX) depots — Mitts
renders through Vulkan and has no such runtime dependency.

---

## Per-upload steps

### 1. Export both platforms from Godot into `content/`

Export each platform into its **own** folder (both presets emit a `mitts.pck`,
so they'd collide in one directory):

- Windows export → `steam/content/windows/`
- Linux export → `steam/content/linux/`

Stage the **entire** export output, not hand-picked files — Godot places the
GDExtension libraries and their Steam dependency next to the binary, and you
want all of it.

### 2. Verify the Steam libraries are present

The game won't initialize Steam on a clean machine without these. Confirm:

- `content/windows/` contains **`steam_api64.dll`**
- `content/linux/` contains **`libsteam_api.so`**

(Both come from `addons/godotsteam/` via the `.gdextension` dependency block and
should be copied automatically on export. If they're missing, the export didn't
bundle the GDExtension — fix that before uploading.)

`steam_appid.txt` may also land in these folders from a local run; that's fine,
the depot scripts exclude it from the actual upload.

### 3. First login (interactive — Steam Guard)

The first time on a given machine, log in on its own so you can answer the Steam
Guard challenge. steamcmd lives in the SDK under
`tools/ContentBuilder/builder/steamcmd.exe` (Windows) or
`builder_linux/steamcmd.sh` (Linux).

```
steamcmd +login <builder_account> +quit
```

Enter the password and the Steam Guard code once. steamcmd caches the
credentials, so subsequent uploads from this machine won't prompt.

### 4. Upload

Run steamcmd **with its working directory set to `steam/`** so the relative
paths in the scripts resolve (`content/`, `output/`):

```
cd /path/to/mitts/steam
/path/to/sdk/tools/ContentBuilder/builder/steamcmd.exe \
    +login <builder_account> \
    +run_app_build "$(pwd)/app_build.vdf" \
    +quit
```

Watch for `Successfully finished AppID 4892600 build` (or similar) and a build
number. If paths fail to resolve, make `buildoutput`/`contentroot`/`ContentRoot`
absolute as a fallback.

### 5. Set the build live on the beta branch

`app_build.vdf` ships with `setlive` empty, so the upload does **not** publish
anything. In Steamworks → SteamPipe → Builds, find the build you just uploaded
and **Set Build Live** on the `beta` branch, then confirm/publish the change.
(Once you trust the pipeline you can instead put `"setlive" "beta"` in the
script to publish automatically — but never `default`.)

### 6. Test as a real player

This is the milestone that proves the AppID switch works in players' hands:

1. Generate a key for the **"Mitts for Beta Testing"** package (1698543) and
   activate it on a **second** Steam account (not your dev-comp account).
2. Install Mitts through Steam on that account, opt into the `beta` branch with
   the password (right-click the game → Properties → Betas).
3. Launch **through Steam** (not the raw exe) and confirm a P2P lobby connects
   under App ID 4892600.

If online works there, distribution is real.

---

## Playtest app (4893650)

`playtest/` holds a parallel set of VDFs for the **Mitts Playtest** child app
(4893650, depots 4893652 Windows / 4893653 Linux). It exists so the beta can go
out *now*: Playtest keys aren't subject to the ~30-day wait the main app's keys
have, and no live store page is required.

It reuses the **same staged content** as the main app — one export works for both,
because the game adopts whichever App ID Steam launches it under
(`steam_manager.gd`). So the only differences from the main upload are the working
directory and the App ID / depots.

**One-time (Steamworks, app 4893650):** create + OS-tag the two depots, reference
them in the Playtest package (done), and set **launch options** (`mitts.exe` /
`mitts.x86_64`) so Steam knows what to run.

**Per upload:**
1. Stage the build into `content/windows` + `content/linux` as usual. If you just
   did the main-app upload, it's the *same* content — nothing to re-export.
2. Upload from the playtest folder:
   ```
   cd steam/playtest
   steamcmd +login <acct> +run_app_build "$pwd/app_build.vdf" +quit
   ```
3. Set the build live (SteamPipe → Builds on app 4893650).
4. Generate **Playtest keys** (Steamworks → the Playtest app → Manage Keys), hand
   them to testers. They activate, install "Mitts Playtest", and launch through
   Steam — the build initializes under 4893650, so P2P lobbies connect among
   playtesters.

---

## Notes

- **Keys grant permanent ownership.** A Beta Testing key means that account
  keeps Mitts at launch, and Steam excludes key-activated copies from your
  store review score. Hand them out deliberately.
- **Version the `desc`.** Update `app_build.vdf`'s `desc` to match the build so
  the Steamworks build list stays legible.
- **Don't commit `content/` or `output/`** — they're gitignored. Only the `.vdf`
  scripts and this README are tracked.
