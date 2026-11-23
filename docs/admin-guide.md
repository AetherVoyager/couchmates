# Admin guide

Setting up and running Couchmates for your friends. You need a Telegram-Stremio server, and optionally a LiveKit
server for voice. The Hub is at the `workers.dev` address `npx wrangler deploy` prints (or your own domain).

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

## Add-ons

**Add-ons** adds public Stremio add-ons to the app, after your Telegram-Stremio catalog. Paste an add-on's
`https://…/manifest.json` (or `stremio://…`) link, or use one of the suggested ones. Their catalogs become home rows
after yours, and their details, streams, subtitles and "watch elsewhere" links are merged with your server's. The app
calls them directly; changes reach apps when they next start.

Each add-on is checked when you add it, and again with **Check again**. The check reads the manifest and tries a few
catalogs, a details page, streams and subtitles for a sample title. It marks each one **Works**, **Partly** or
**Won't work**, and says why. For example, it flags torrent streams (the app doesn't play them), add-ons that use their
own ids instead of IMDb ids (they won't match your library or watch parties), and add-ons that need configuring first.
An add-on where nothing works is added turned off. **Move up / down** sets the order of rows and which add-on gets the
first say on details. Links to configured add-ons can hold keys, so the Hub stores them encrypted.

## Requests

The app's **Search** finds any movie or show: your library first, then your add-ons and Stremio's Cinemeta catalog.
Titles that aren't in the library have a **Request** button. **Requests** lists them, with who asked (friends asking
for the same title share one request). Answer with **Approve**, **Mark added** or **Decline**, and an optional note;
whoever asked sees the status and note in the app. A declined title asked for again goes back to pending.

A request never downloads anything. Getting the title is up to you: add it to Telegram-Stremio the usual way, then
mark it added, or let the Hub do it: once an hour it asks Telegram-Stremio about every waiting request and marks
the ones it now has **Added** (**Check library now** does the same at once). The Overview shows how many requests
are waiting.

To let your own program answer requests, make a bot token under **Bot access** on the same page. The calls, the
webhook and an example are in [`bot-api.md`](bot-api.md).

## Overview

Users and active devices, live streams, the library, your request bot (online or offline, what it's doing, recent
events and errors, when it reports through the bot API), Telegram bot health, data used per user (with a 7-day chart),
and **Voice chat now**: every voice room with each person's mic as *mic on*, *muted* or *no mic*, straight from
LiveKit.

## Releasing a new app version

See "Releasing" in `CLAUDE.md`. In short: bump the version, tag `vX.Y.Z`, push the tag. CI builds the installer
and the Hub offers it to apps once the GitHub token is saved.
