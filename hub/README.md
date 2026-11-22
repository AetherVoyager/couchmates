# Couchmates Hub

The dashboard and app API for Couchmates. It's a Rust Cloudflare Worker with a D1 database. It sits in front of
an unchanged [Telegram-Stremio](https://github.com/weebzone/Telegram-Stremio) server and a LiveKit voice server.

- **Overview:** users, active devices, live streams, the library, Telegram bot health, data use per user with
  an hourly 7-day chart, and **Voice chat now**: each LiveKit room with every person's mic state.
- **Admin sign-in:** the admin password plus a 6-digit authenticator code (TOTP). The first sign-in leads
  straight to setting up the authenticator app.
- **Users:** each user signs in to the app with a username and password. Behind the scenes they get a
  Telegram-Stremio access token with optional data limits, but they never see it. You can reset a user's
  password (which signs them out everywhere), disable or enable them (which revokes or replaces the token),
  sign out single devices, or delete them. **Check catalog** reads a user's catalog with their own token and
  says why it would be empty (Telegram-Stremio's Hide Catalog, titles that aren't public, a wrong address).
- **Settings:** Telegram-Stremio (address, admin login, and a button to turn off its Hide Catalog), LiveKit, App
  updates (GitHub repo and read-only token), Trackers (Trakt and Simkl keys), and Cast photos (TMDB key). Each is
  tested before saving. Secrets are stored AES-GCM encrypted with `HUB_SECRET`.
- **App API** (`/api/app/*`): sign-in, config, voice tokens, password and profile, devices, updates, trackers and
  scrobbling, and TMDB credits. The calls are listed in [`core/README.md`](../core/README.md); the shapes are in
  `core/src/api.rs`.

Setting it up for friends: [`docs/admin-guide.md`](../docs/admin-guide.md).

## Layout

| Folder | Crate | What's in it |
|---|---|---|
| `../core` | `couchmates-core` | Shared with the app: API shapes, username/password/room rules, JSON samples |
| `core` | `couchmates-hub-core` | Database, sign-in (TOTP, password hashing), Telegram-Stremio, Check catalog, LiveKit, TMDB, trackers, updates, app API |
| `ui` | `couchmates-hub-ui` | Dashboard pages. Take data, return HTML |
| `worker` | `couchmates-hub` | The Worker: routing, admin handlers, hourly job |

Live at `https://couchmates-hub.watch2gether.workers.dev`. The admin password is in `admin-password.local.txt`
(git-ignored).

## Develop

Run these in this `hub` folder.

Requirements: Rust with `wasm32-unknown-unknown`, `cargo install worker-build`, Node.

```bash
npm install
cp .dev.vars.example .dev.vars        # then fill in both values
npm run migrate:local
python dev/fake_servers.py            # stand-in Telegram-Stremio + LiveKit on :8899
npm run dev                           # http://localhost:8787
python dev/e2e.py                     # end-to-end checks; needs a fresh local database
python dev/seed_local.py              # or: set up a fresh local Hub with an app user to try the app
cargo test                            # from the repo root: every Rust crate
```

## Deploy

Set `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. The token needs the "Edit Cloudflare Workers" template plus
Account → D1 → Edit.

```bash
npm run migrate:remote   # after adding a migration
npm run deploy
```

Lost the authenticator phone? Clear it, then sign in with the password and set it up again:

```bash
npx wrangler d1 execute couchmates-hub --remote --command "DELETE FROM settings WHERE key LIKE 'totp%'; DELETE FROM admin_sessions;"
```

Migrations: `0001` the base tables, `0002` usernames and passwords plus admin 2FA, `0003` tracker links.

Secrets persist across deploys. To change one, run `npx wrangler secret put ADMIN_PASSWORD`. Changing
`HUB_SECRET` makes every secret saved in Settings unreadable (Telegram-Stremio password, LiveKit secret, GitHub
token, Trakt secret, TMDB key, the authenticator, linked trackers), so you'd re-enter them and users would re-link
their trackers.
