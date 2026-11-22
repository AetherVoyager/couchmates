# Couchmates app (App UI)

The Flutter app: sign in to the Hub, browse what's in Telegram-Stremio, play with mpv, and watch together
with voice chat. The logic lives in [`../core`](../core) (App Core); this package is screens and the player.

| Folder | What's in it |
|---|---|
| `lib/screens` | Sign-in, home (a side pane with the catalogue; a featured title over rows), catalog grid, search, details (backdrop, logo, actions, version/audio/subtitle pickers in `media_tracks.dart`, info, cast, episodes, extras), the player and its media info panel, profile, settings |
| `lib/watch_together` | The room state the screens share, the sheet to start or join a room, and the mpv adapter that lets a room drive the player |
| `lib/widgets` | Posters, grids, messages, the voice button |
| `lib/services` | Preferences-backed stores, the device name, and the updater |
| `lib/mpv` | Plezy's mpv player layer (Windows, Android, Linux, macOS), kept as it was |
| `windows`, `android`… | Native runners, including Plezy's mpv plugin |

How it fits together:

- **Signing in** goes to the Hub (`/api/app/login`). The app keeps the Hub address and a device token, and the
  Hub's config says where the user's catalog is.
- **Browsing** reads the user's Telegram-Stremio addon directly: one home row per catalog, details from
  `/meta`, streams from `/stream`.
- **Watch together** uses Open Watch Party rooms. The host shares what they play; everyone else's app finds the
  same title in their own catalog by its IMDb id and opens it. Play, pause and seek go through the room.
- **Voice chat** joins the room's LiveKit channel with a token from the Hub, muted at first. Each person's volume
  is in the room sheet's Voice check; overall volume, the microphone, and lowering the movie while people talk are
  in Settings → Voice chat.
- **Updates**: on start the app asks the Hub for the newest release, then downloads and runs the installer.

## Build

Windows needs Flutter 3.47.1 with Plezy's patched engine (DirectComposition video), at `C:\dev\flutter-3.47.1`:

```bash
export PATH=/c/dev/flutter-3.47.1/bin:$PATH GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.longpaths GIT_CONFIG_VALUE_0=true
flutter test
flutter build windows --release      # build/windows/x64/runner/Release/couchmates.exe
```

## Try it locally

Run the Hub with its stand-in servers (see [`hub/README.md`](../../hub/README.md)), then
`python hub/dev/seed_local.py`. It prints a test sign-in for the app against `http://127.0.0.1:8787`, with a
sample movie and show.

Forked from [Plezy](https://github.com/edde746/plezy) (GPL-3.0). See `TRADEMARKS.md` for its name and logo.
