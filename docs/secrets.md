# Secrets and accounts

Every secret Couchmates needs, where it comes from and where it's kept. None of them is in the repo:
`.gitignore` blocks the local files below, and the Hub keeps its settings encrypted in D1.

## For deploying the Hub (on the admin's computer)

| Secret | Where to get it | Kept in |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard → My Profile → API Tokens → Create Token: the "Edit Cloudflare Workers" template plus Account → D1 → Edit | A Windows **User** environment variable, never a file |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard → Workers & Pages, right-hand side (not secret, but kept with the token) | A Windows **User** environment variable |

Read them inside a command, so they're never printed:

```powershell
$env:CLOUDFLARE_API_TOKEN = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN','User')
$env:CLOUDFLARE_ACCOUNT_ID = [Environment]::GetEnvironmentVariable('CLOUDFLARE_ACCOUNT_ID','User')
```

## The Hub Worker's own secrets

| Secret | What it is | Kept in |
|---|---|---|
| `ADMIN_PASSWORD` | The Hub admin password. Choose a long one | Cloudflare (`npx wrangler secret put ADMIN_PASSWORD` from `hub/`), plus `hub/admin-password.local.txt` on the admin's computer (git-ignored) |
| `HUB_SECRET` | 64 hex characters that encrypt every secret in Settings. Generate with `python -c "import secrets; print(secrets.token_hex(32))"` | Cloudflare (`npx wrangler secret put HUB_SECRET`). **Also keep a copy in a password manager**: Cloudflare can't show it again, and changing or losing it makes every saved setting below unreadable |

For local development, `hub/.dev.vars` holds test values for both (copy `hub/.dev.vars.example`). It's git-ignored.

## Entered in the Hub's Settings (encrypted with `HUB_SECRET`)

| Setting | Where to get it |
|---|---|
| Telegram-Stremio admin login | Your Telegram-Stremio server's admin username and password |
| LiveKit API key and secret | LiveKit Cloud → Settings → API keys (or your own LiveKit server's config) |
| Voice relay password or shared secret | The relay's `/etc/turnserver.conf` (`user=name:password`, or `static-auth-secret`). On the Oracle relay only the fixed user works: coturn 4.5.2 turns fixed users off when `use-auth-secret` is on, which would lock DuoDoku out. Signed-in apps get it in direct mode |
| GitHub token (app updates) | GitHub → Settings → Developer settings → Fine-grained tokens: repository `AetherVoyager/couchmates` only, **Contents: read-only**. Renew it before it expires, or apps stop seeing updates |
| Trakt client ID and secret | trakt.tv → Settings → Your API Apps → New application |
| Simkl client ID | simkl.com → Settings → Developer → New app |
| TMDB key or read access token | themoviedb.org → Settings → API |
| Add-on links (Add-ons page) | The add-on's own site. Configured add-ons can carry keys in their link; they're sent to signed-in apps, which call the add-on |
| Authenticator (2FA) | Made by the Hub on first sign-in; scan its QR code. Lost phone: see the admin guide |

## GitHub Actions

The build needs no repository secrets: publishing a release uses the automatic `GITHUB_TOKEN`.

## If a secret leaks

- Cloudflare token: delete it in the dashboard and make a new one.
- `ADMIN_PASSWORD`: `npx wrangler secret put ADMIN_PASSWORD`, and update `hub/admin-password.local.txt`.
- A Settings secret: rotate it at its service, then save the new value in Hub Settings.
- `HUB_SECRET`: set a new one, then re-enter every Settings secret, set up the authenticator again, and ask
  users to re-link their trackers.
