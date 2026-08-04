# Music

Tracks are loaded by name from this directory by `MusicManager`
(`Scripts/game/music_manager.gd`). A missing file is not an error — every
`MusicManager` call is a no-op when its track is absent, so the game runs
unscored and each track becomes live the moment its file lands here.

| Track | File | Played by |
|---|---|---|
| `Track.TITLE` | `title.ogg` | The boot title card, faded out on the transition to the rink |

## Adding a file

Drop the audio in and let Godot import it. **Use `.ogg` or `.mp3`** —
`MusicManager` forces the loop flag on those two formats, so a track loops
without anyone remembering to tick the box in the import dock. `.wav` will play
but stops at the end of the file.

Mix so the track sits under gameplay: the Music slider defaults to 60%, and
`MusicManager.play()` takes a `volume_db` trim for a track mastered hotter or
quieter than the others.

## Adding a track

Add the `Track` enum entry and its `_TRACK_PATHS` row in
`Scripts/game/music_manager.gd`, then call `MusicManager.play(Track.X)` from the
screen that owns it and `MusicManager.stop()` where it should end. The manager
is an autoload, so a track keeps playing across a scene change until something
stops it.

Record licence and attribution for anything shipped in `Sounds/CREDITS.md`.
