# Admin guide

Setting up and running Couchmates for your friends. You need a Telegram-Stremio server, and optionally a LiveKit
server for voice. The Hub is at `https://couchmates-hub.watch2gether.workers.dev`.

## First sign-in

1. Open the Hub and sign in with the admin password (`hub/admin-password.local.txt`). Leave the code empty.
2. Scan the QR code with an authenticator app (Google Authenticator, 1Password, Bitwarden, Aegis…) and enter a code.
   From now on, signing in needs the password **and** a code.

Lost the phone? From `hub/`:
`npx wrangler d1 execute couchmates-hub --remote --command "DELETE FROM settings WHERE key LIKE 'totp%'; DELETE FROM admin_sessions;"`
then sign in with the password and set it up again.

## Settings

Everything here is tested before it's saved, and secrets are stored encrypted. Where to get each key, and the
Hub's own secrets: [secrets.md](secrets.md).

| Card | What to enter | Needed for |
|---|---|---|
| **Telegram-Stremio** | Your server's address (the one you install the Stremio addon from, without `/stremio/…`) and its admin login | Everything |
| **LiveKit voice chat** | URL, API key and secret (LiveKit Cloud → Settings → API keys) | Voice chat |
| **App updates** | Repository `AetherVoyager/couchmates` and a fine-grained GitHub token: this repo only, Contents read-only | Apps updating themselves |
| **Trackers** | Trakt client ID + secret, Simkl client ID (register Couchmates on each site; the card links there) | Scrobbling (optional) |
| **Cast photos (TMDB)** | A free TMDB key or read access token | Cast photos, age ratings, taglines, trailers (optional) |

### Telegram-Stremio settings that matter

- **Hide Catalog must be off.** Its label says it hides the catalog "from unauthenticated users", but it hides
  every catalog from every token, including your users'. The app then shows "lists no catalogs". The Hub warns
  about it and has a **Turn off Hide Catalog** button.
- **Visibility:** users get ordinary tokens, which only see titles whose visibility is public (or that allow their
  token). Your own owner token sees everything, so Stremio can look fine to you while friends see nothing.

## Users

**Users → Add a user**: display name, username, and a password (leave it blank to generate one). Send them the
Hub address, username and password; the generated password is shown once.

On a user's page:
- **Details:** name, username and daily or monthly data limits.
- **Password:** set or generate a new one. This signs them out everywhere.
- **Devices:** see where they're signed in, and sign devices out.
- **Trackers:** which Trakt or Simkl accounts they linked.
- **Check catalog:** reads their catalog with their own token and says why it would be empty: Hide Catalog,
  titles not public, a wrong server address, or a rejected token.
- **Access:** disable (stops playback now) or enable; delete.

## Overview

Users and active devices, live streams, the library, Telegram bot health, data used per user (with a 7-day chart),
and **Voice chat now**: every voice room with each person's mic as *mic on*, *muted* or *no mic*, straight from
LiveKit.

## Releasing a new app version

See "Releasing" in `CLAUDE.md`. In short: bump the version, tag `vX.Y.Z`, push the tag. CI builds the installer
and the Hub offers it to apps once the GitHub token is saved.
