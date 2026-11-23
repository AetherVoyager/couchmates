# Couchmates

Watch together with voice chat. A **Hub** (a Rust Cloudflare Worker) sits in front of an unchanged
[Telegram-Stremio](https://github.com/weebzone/Telegram-Stremio) server and a LiveKit voice server. The
**app** (Flutter, Windows now and Android later) signs in to the Hub with a username and password, shows what's
in Telegram-Stremio, and plays it with the mpv player from [Plezy](https://github.com/edde746/plezy), which it
was forked from. Plex and Jellyfin support is gone.

## Layout

| Part | Folder | Language | What's in it |
|---|---|---|---|
| **Core** | [`core/`](core) | Rust | What the Hub and app agree on: the app API's shapes (`src/api.rs`), shared rules (`src/rules.rs`), and JSON samples in `contract/` that both sides test against |
| **Hub Core** | [`hub/core/`](hub/core) | Rust | Database, admin 2FA, password hashing, Telegram-Stremio, LiveKit, the app API |
| **Hub UI** | [`hub/ui/`](hub/ui) | Rust (maud) | Dashboard pages. They take data and return HTML |
| Hub Worker | [`hub/worker/`](hub/worker) | Rust | Cloudflare entry point: routing, admin handlers, the hourly job |
| **App Core** | [`app/core/`](app/core) | Dart | App logic without UI: Hub session, Stremio catalog client, watch party rooms, voice |
| **App UI** | [`app/ui/`](app/ui) | Flutter | Screens and widgets, with Plezy's mpv player layer |

Dependencies point one way: UI → Core → shared Core. Hub UI never touches the database, and App Core never
imports Flutter widgets.

## Docs

| For | Read |
|---|---|
| Setting up the Hub and users | [`docs/admin-guide.md`](docs/admin-guide.md) |
| Friends using the app | [`docs/user-guide.md`](docs/user-guide.md) |
| Working on the code (people and Claude) | [`CLAUDE.md`](CLAUDE.md) |
| The app API | [`core/README.md`](core/README.md) |
| The bot API for answering requests | [`docs/bot-api.md`](docs/bot-api.md) |
| Each part | [`hub/README.md`](hub/README.md), [`app/core/README.md`](app/core/README.md), [`app/ui/README.md`](app/ui/README.md) |

## Checks

```bash
cargo test                                  # Core, Hub Core, Hub UI, Worker
cd app/core && flutter test                 # App Core, including the shared contract samples
cd app/ui && flutter test                   # App UI
cd hub && python dev/e2e.py                 # Hub end to end, with the Hub and fake servers running (hub/README.md)
```

Changing the app API means changing `core/src/api.rs`, its sample in `core/contract/`, and
`app/core/lib/src/hub/api.dart`. Both test suites fail until all three agree.

## CI

`.github/workflows/build.yml` runs every test suite and builds the Windows app when a `v*` tag is pushed, then
publishes a release with the setup `.exe` and a portable `.7z`. It can also be run by hand from the Actions tab.
Pushes to `main` don't build, to save CI minutes; run the tests locally first (see Checks). The release steps
are in `CLAUDE.md`.

## Running and deploying

- Hub: [`hub/README.md`](hub/README.md)
- App: [`app/ui/README.md`](app/ui/README.md). Windows builds need Flutter 3.47.1 with the patched engine.

The app is GPL-3.0 like Plezy (see `LICENSE`).
