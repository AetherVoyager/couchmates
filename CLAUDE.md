# CLAUDE.md

Couchmates: a Rust Cloudflare Worker **Hub** in front of an unchanged Telegram-Stremio server and LiveKit, and
a Flutter **app** (Windows now, Android later) forked from Plezy. See `README.md` for the layout and `docs/` for
the admin and user guides.

## Layout and boundaries

| Part | Folder | Notes |
|---|---|---|
| Core | `core/` | Rust. The app API's shapes (`src/api.rs`) and shared rules. **The contract** |
| Hub Core | `hub/core/` | Rust. D1 store, auth, Telegram-Stremio, LiveKit, TMDB, trackers, updates, app API handlers |
| Hub UI | `hub/ui/` | Rust + maud. Pure: data in, HTML out. Never touches the store or network |
| Hub Worker | `hub/worker/` | Routing (`src/lib.rs`), admin handlers (`src/admin.rs`), hourly cron |
| App Core | `app/core/` | Dart package `couchmates_core`. Logic only: no widgets |
| App UI | `app/ui/` | Flutter app (package `couchmates`). Screens, widgets, `lib/mpv` (Plezy's player, keep as is) |

Dependencies point one way: UI → Core → shared Core.

## Changing the app API

Every app call needs all four, or a test fails:
1. the Rust types and the table at the top of `core/src/api.rs`,
2. a JSON sample in `core/contract/` plus a `round_trips` line in `core/src/api.rs`,
3. the Dart mirror in `app/core/lib/src/hub/api.dart` plus a `roundTrips` line in `app/core/test/contract_test.dart`,
4. the handler in `hub/core/src/api.rs`, its route in `hub/worker/src/lib.rs`, and a check in `hub/dev/e2e.py`.

## Commands

Rust (repo root):

```bash
cargo test                                                  # every crate
cargo build --target wasm32-unknown-unknown -p couchmates-hub  # what the Worker actually compiles
cargo fmt --all                                             # rustfmt.toml: 120 columns
```

Flutter. Use the pinned SDK, and enable long paths or git dependencies fail:

```bash
export PATH=/c/dev/flutter-3.47.1/bin:$PATH GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.longpaths GIT_CONFIG_VALUE_0=true
cd app/core && flutter analyze && flutter test
cd app/ui && flutter analyze && flutter test && flutter build windows --release
dart format -l 120 lib test                                 # the project's line length
```

Hub locally (`hub/`): `npm run migrate:local`, `python dev/fake_servers.py 8899` (stand-in Telegram-Stremio +
LiveKit + addon with sample clips), `npx wrangler dev --port 8787`, then `python dev/seed_local.py` (2FA, connects
the fakes, adds `alice` / `local-app-pass`) or `python dev/e2e.py` (needs a fresh local DB; clear the tables first,
see the docstring of `seed_local.py`). Restarting `fake_servers.py` forgets its tokens: reseed.

## Rules that bit before

- **Never print or commit secrets.** Cloudflare credentials are User env vars: read them inside the command with
  PowerShell `[Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN','User')` and
  `...('CLOUDFLARE_ACCOUNT_ID','User')`. The admin password is in `hub/admin-password.local.txt` (git-ignored).
  Don't ask the user to paste tokens into chat. Never enter real credentials into the live Hub.
- **Hub secrets are sealed** with `HUB_SECRET`: any new secret setting must be added to `SECRET_KEYS` in
  `hub/core/src/store.rs`. Check it landed. An edit that missed this once left a secret in plain text.
- **Verify scripted edits landed.** Several multi-step edit scripts stopped at an assertion halfway and the
  rest silently never ran, while everything still compiled. After applying one, grep for each change, or
  check the live route (a new app route should answer 401 without sign-in, not 404).
- **Shell heredocs mangle long scripts** with quotes or backslashes. Write the script to the scratchpad with the
  Write tool and run `python -I file.py`.
- **CI costs money**: Windows runners bill double on this private repo. `.github/workflows/build.yml` builds only on
  `v*` tags or by hand. Run every suite locally before tagging.
- **`flutter test` in `app/core` sometimes fails to load a test file** on the first run after edits (a compile race).
  Rerun before concluding anything.
- **Telegram-Stremio**: the addon lives at `<server>/stremio/<token>/…`. Its "Hide Catalog" setting hides catalogs
  from every token (despite its label), and titles that aren't public are hidden from non-owner tokens; the Hub's
  Check catalog explains both. Its admin API is cookie-based (`POST /login`, `/api/...`).
- **Windows video** is drawn on a native layer under the Flutter surface: the player route must stay transparent.
  Full screen goes through the runner's `plezy/window` channel, not a plugin.
- **The workspace `cargo fmt`** must use `rustfmt.toml`; without it everything is rewrapped at 100 columns.

## Releasing

1. Run all suites (Rust, App Core, App UI) and the Hub e2e locally.
2. Bump `version:` in `app/ui/pubspec.yaml` (the updater compares it), commit, push.
3. `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`. CI tests, builds, and publishes the release with
   `couchmates-windows-setup.exe` and a portable `.7z`. Apps update through the Hub, which needs the GitHub token in
   Hub Settings.
4. Hub changes deploy separately: from `hub/`, `npx wrangler d1 migrations apply couchmates-hub --remote` when there's
   a new migration, then `npx wrangler deploy`. Check `/api/health` afterwards.

Commit messages end with the co-author line the session asks for. Commit only when asked; never push tags or deploy
unless asked.
