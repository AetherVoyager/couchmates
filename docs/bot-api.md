# Bot API

Let your own program answer title requests (see Requests in [`admin-guide.md`](admin-guide.md)). The Hub only keeps
requests and their answers; how your program gets a title onto Telegram-Stremio is up to you.

## Set up

On the dashboard's **Requests** page, under **Bot access**:

1. **Make a token.** It's shown once (it starts with `cmb_`). The Hub keeps only its SHA-256, so if you lose it,
   **Replace token**; the old one stops working. **Turn off bot access** removes it.
2. Optionally save a **webhook address** (https). Each new request, and each declined one asked for again, is POSTed
   there the moment it's made. Without one, poll the list instead.

Every call sends `Authorization: Bearer <token>`. Failures answer with a 4xx status and `{"error": "<sentence>"}`.

## Calls

| Call | Body | Answer |
|---|---|---|
| `GET /api/bot/requests?status=open` | | `{"requests": [MediaRequest, ...]}`, most recently changed first |
| `POST /api/bot/requests/update` | `{"id", "status", "note"?}` | the `MediaRequest` as it is now |
| `POST /api/bot/status` | `{"state", "activity"?, "version"?, "events"?}` | `{"ok": true}` |

- `status=` is `pending`, `approved`, `added`, `declined`, `open` (pending or approved; the default) or `all`.
- An update's `status` is `pending`, `approved`, `added` or `declined`. Without `note` the request keeps its note;
  `""` clears it. Notes are cut at 300 characters. Friends see the status and note in the app.
- A `MediaRequest` is the app API's shape (`core/src/api.rs`, sample `core/contract/media_request.json`):
  `id`, `kind` (`movie` or `series`), `title_id` (usually the IMDb id), `name`, `year`, `poster`, `status`, `note`,
  `requested_by` (display names), `created_at`, `updated_at`.
- **Shows are requested by episode.** A series request has `season` and `episode` (numbers) and often
  `episode_title`; each episode is its own request with its own id and status, so add and answer them one at a
  time (sample `core/contract/media_request_episode.json`). The Stremio video id is `<title_id>:<season>:<episode>`.
  A series request without `season` and `episode` is a whole show, from an app older than 0.7.

## Status, so you can see what the bot is doing

Report about every 30 seconds and the Overview page's **Request bot** card shows it: online, working or in error,
what it's doing, and the latest events. A bot that hasn't reported for 2½ minutes shows as **Offline**.

- `state` is `idle`, `working` or `error`. `activity` is one sentence (cut at 200 characters). `version` is yours.
- `events` is what happened since the last report: `{"at": <unix seconds>, "level": "info" | "error", "message": "…"}`.
  Up to 20 per report; the Hub keeps the latest 50. A missing or future `at` becomes the time the Hub got it.
- **Turn off bot access** clears the status and events.

```python
call("/api/bot/status", {"state": "working", "activity": "Adding Dune", "events": [
    {"at": int(time.time()), "level": "error", "message": "Search bot didn't answer"}]})
```

## Webhook

`POST <your address>` with `content-type: application/json`, `x-couchmates-event: request.created` and a body like
`core/contract/bot_webhook.json`: `{"event": "request.created", "request": MediaRequest}`. Asking for several
episodes at once sends one webhook per new episode, all at the same moment. Answer with any 2xx
within 4 seconds; the Hub doesn't retry, so poll now and then as well to catch anything missed.

`x-couchmates-signature` is `sha256=` plus the hex HMAC-SHA256 of the raw body, keyed with the hex SHA-256 of your
token. Check it before trusting the body:

```python
import hashlib, hmac

def signed(body: bytes, header: str, token: str) -> bool:
    key = hashlib.sha256(token.encode()).hexdigest().encode()
    return hmac.compare_digest(header, "sha256=" + hmac.new(key, body, hashlib.sha256).hexdigest())
```

## A minimal poller

```python
import json, time, urllib.request

HUB, TOKEN = "https://your-hub.example", "cmb_..."

def call(path, body=None):
    req = urllib.request.Request(HUB + path, data=json.dumps(body).encode() if body else None,
                                 headers={"authorization": f"Bearer {TOKEN}", "content-type": "application/json"})
    return json.load(urllib.request.urlopen(req))

while True:
    for r in call("/api/bot/requests?status=pending")["requests"]:
        call("/api/bot/requests/update", {"id": r["id"], "status": "approved", "note": "On it"})
        # ... your program adds the title, then:
        # call("/api/bot/requests/update", {"id": r["id"], "status": "added"})
    time.sleep(60)
```
