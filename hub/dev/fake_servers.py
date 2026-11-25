"""A stand-in for Telegram-Stremio's admin API and LiveKit's RoomService, for
trying the Hub locally without either.

    python dev/fake_servers.py            # listens on http://127.0.0.1:8899

Telegram-Stremio: admin login `admin` / `admin-pass`; its Stremio addon is at
`/stremio/<token>/` with a sample movie and show (short public clips).
Public add-ons: `/addons/free/manifest.json` and `/addons/torrents/manifest.json`.
LiveKit: URL `ws://127.0.0.1:8899`, key `devkey`, secret `devsecret`.
"""

import base64
import hashlib
import hmac
import json
import secrets
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERNAME, PASSWORD = "admin", "admin-pass"
LK_KEY, LK_SECRET = "devkey", "devsecret"
SESSIONS: set[str] = set()
ADMIN_SETTINGS = {"hide_catalog": False, "replace_mode": False, "duplicate_protection": True}
TOKENS: dict[str, dict] = {}

# The catalog every token sees: one movie and a two-episode show. Artwork from
# Google's sample bucket; video from test-videos.co.uk's short public clips.
_SAMPLES = "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample"
FAKE_LIBRARY = {
    "tt1254207": {
        "id": "tt1254207", "type": "movie", "name": "Big Buck Bunny", "year": "2008", "releaseInfo": "2008",
        "poster": "https://upload.wikimedia.org/wikipedia/commons/c/c5/Big_buck_bunny_poster_big.jpg",
        "background": f"{_SAMPLES}/images/BigBuckBunny.jpg", "logo": "", "genres": ["Animation"],
        "imdbRating": "6.4", "runtime": "10 min", "cast": [],
        "description": "A giant rabbit takes revenge on three bullying rodents.",
    },
    "tt9999990": {
        "id": "tt9999990", "type": "series", "name": "Blender Shorts", "year": "2008-2010",
        "releaseInfo": "2008-2010", "poster": "", "background": f"{_SAMPLES}/images/Sintel.jpg", "logo": "",
        "genres": ["Animation"], "imdbRating": "", "runtime": "", "cast": [],
        "description": "Open movies from the Blender Foundation, as a show.",
        "videos": [
            {"id": "tt9999990:1:1", "title": "Elephants Dream", "season": 1, "episode": 1,
             "released": "2008-01-01T00:00:00Z", "thumbnail": f"{_SAMPLES}/images/ElephantsDream.jpg",
             "overview": "Two people explore a strange machine."},
            {"id": "tt9999990:1:2", "title": "Sintel", "season": 1, "episode": 2,
             "released": "2010-01-01T00:00:00Z", "thumbnail": f"{_SAMPLES}/images/Sintel.jpg",
             "overview": "A girl searches for her dragon."},
        ],
    },
}
_CLIPS = "https://test-videos.co.uk/vids"
FAKE_STREAMS = {
    "tt1254207": f"{_CLIPS}/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_5MB.mp4",
    "tt9999990:1:1": f"{_CLIPS}/jellyfish/mp4/h264/720/Jellyfish_720_10s_5MB.mp4",
    "tt9999990:1:2": f"{_CLIPS}/sintel/mp4/h264/720/Sintel_720_10s_5MB.mp4",
}
FAKE_SIZES = {url: 100_000_000 + i for i, url in enumerate(FAKE_STREAMS.values())}


def b64url_decode(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def verify_jwt(token: str) -> dict | None:
    try:
        header, payload, signature = token.split(".")
        expected = hmac.new(LK_SECRET.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(expected, b64url_decode(signature)):
            return None
        claims = json.loads(b64url_decode(payload))
        if claims.get("iss") != LK_KEY or claims.get("exp", 0) < time.time():
            return None
        return claims
    except Exception:
        return None


BOT_HOOKS: list[dict] = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("fake: " + (fmt % args) + "\n")

    def send_json(self, body, status=200, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def body(self) -> bytes:
        return self.rfile.read(int(self.headers.get("content-length") or 0))

    def authed(self) -> bool:
        cookie = self.headers.get("cookie", "")
        return any(part.strip() in SESSIONS for part in cookie.split(";"))

    def stremio(self, token: str, rest: str):
        """Telegram-Stremio's addon, with short public sample clips."""
        if token not in TOKENS:
            return self.send_json({"detail": "Invalid or expired token"}, 401)
        path = urllib.parse.unquote(rest)
        if path == "manifest.json" and ADMIN_SETTINGS["hide_catalog"]:
            return self.send_json({"id": f"telegram.media.{token[:8]}", "name": "Telegram",
                                   "resources": ["stream", "subtitles"], "types": ["movie", "series"], "catalogs": []})
        if path.startswith("catalog/") and ADMIN_SETTINGS["hide_catalog"]:
            return self.send_json({"detail": "Catalog disabled"}, 404)
        if path == "manifest.json":
            return self.send_json({
                "id": f"telegram.media.{token[:8]}", "version": "fake-1.0", "name": "Telegram",
                "types": ["movie", "series"], "resources": ["catalog", "meta", "stream"],
                "catalogs": [
                    {"type": "movie", "id": "latest_movies", "name": "Recently Added",
                     "extra": [{"name": "genre", "isRequired": False, "options": ["Animation"]}, {"name": "skip"}]},
                    {"type": "series", "id": "latest_series", "name": "Recently Added",
                     "extra": [{"name": "skip"}, {"name": "search", "isRequired": False}]},
                ],
                "idPrefixes": ["tt"],
            })
        if path.startswith("catalog/"):
            kind = path.split("/")[1]
            if "skip=" in path:
                return self.send_json({"metas": []})
            items = [m for m in FAKE_LIBRARY.values() if m["type"] == kind]
            return self.send_json({"metas": [{k: v for k, v in m.items() if k != "videos"} for m in items]})
        if path.startswith("meta/"):
            meta_id = path.split("/")[2].removesuffix(".json")
            if meta_id in FAKE_LIBRARY:
                return self.send_json({"meta": FAKE_LIBRARY[meta_id]})
            # Like the real server: details for titles it doesn't have too (from TMDB or Cinemeta).
            if meta_id.startswith("tt"):
                kind = path.split("/")[1]
                videos = [{"id": f"{meta_id}:1:{e}", "title": f"Episode {e}", "season": 1, "episode": e}
                          for e in (1, 2)] if kind == "series" else []
                return self.send_json({"meta": {"id": meta_id, "type": kind, "name": "Somewhere else",
                                                "imdb_id": meta_id, "videos": videos}})
            return self.send_json({"meta": {}})
        if path.startswith("stream/"):
            stream_id = path.split("/")[2].removesuffix(".json")
            url = FAKE_STREAMS.get(stream_id)
            if url is None:
                return self.send_json({"streams": []})
            return self.send_json({"streams": [{
                "name": "Telegram 1080p (Direct)", "title": f"📁 {url.rsplit('/', 1)[-1]}\n💾 sample",
                "url": url, "size_bytes": FAKE_SIZES[url],
                "behaviorHints": {"bingeGroup": "telegram-stremio-1080p-direct"},
            }, {"name": "❤ Support", "title": "Enjoying Telegram Stremio?", "externalUrl": "https://example.com"}]})
        return self.send_json({"detail": "Not Found"}, 404)

    def public_addon(self, kind: str, rest: str):
        """Public Stremio add-ons for the Add-ons page: `free` has a catalog, a
        playable stream and subtitles; `torrents` only finds torrents."""
        path = urllib.parse.unquote(rest)
        if kind == "torrents":
            if path == "manifest.json":
                return self.send_json({"id": "fake.torrents", "name": "Fake Torrents", "version": "1.0.0",
                                       "resources": ["stream"], "types": ["movie", "series"], "catalogs": [],
                                       "idPrefixes": ["tt"]})
            if path.startswith("stream/"):
                return self.send_json({"streams": [{"name": "1080p", "infoHash": "0" * 40}]})
            return self.send_json({"detail": "Not Found"}, 404)
        if path == "manifest.json":
            return self.send_json({
                "id": "fake.free", "name": "Fake Free Films", "version": "2.1.0", "description": "Free sample films.",
                "resources": ["catalog", "meta", "stream", "subtitles"], "types": ["movie"], "idPrefixes": ["tt"],
                "catalogs": [{"type": "movie", "id": "free", "name": "Free films", "extra": [{"name": "search"}]}],
            })
        if path.startswith("catalog/movie/free"):
            return self.send_json({"metas": [{"id": "tt0000001", "type": "movie", "name": "Free Film"}]})
        if path.startswith("meta/movie/"):
            return self.send_json({"meta": {"id": path.split("/")[2].removesuffix(".json"), "type": "movie", "name": "Free Film"}})
        if path.startswith("stream/movie/"):
            return self.send_json({"streams": [{"name": "Free", "url": "https://example.com/free.mp4"}]})
        if path.startswith("subtitles/movie/"):
            return self.send_json({"subtitles": [{"id": "1", "url": "https://example.com/free.srt", "lang": "eng"}]})
        return self.send_json({"detail": "Not Found"}, 404)

    def do_GET(self):
        if self.path == "/bot-hook/last":
            return self.send_json(BOT_HOOKS[-1] if BOT_HOOKS else None)
        if self.path == "/bot-hook/all":
            return self.send_json(BOT_HOOKS)
        if self.path.startswith("/addons/"):
            kind, _, rest = self.path.removeprefix("/addons/").partition("/")
            return self.public_addon(kind, rest)
        if self.path.startswith("/stremio/"):
            token, _, rest = self.path.removeprefix("/stremio/").partition("/")
            return self.stremio(token, rest)
        if self.path == "/stream/stats":
            return self.send_json({"active_streams": [
                {"title": "Big Buck Bunny", "file_name": "bbb.mkv", "status": "active",
                 "total_bytes": 734003200, "instant_mbps": 42.5, "avg_mbps": 38.1},
            ], "recent_streams": []})
        if not self.authed():
            return self.send_json({"detail": "Not authenticated"}, 401)
        if self.path == "/api/system/stats":
            return self.send_json({
                "server_status": "running", "uptime": "3h 12m", "version": "fake-1.0",
                "connected_bots": 2, "movies": 128, "tv_shows": 34,
                "api_tokens": list(TOKENS.values()),
            })
        if self.path == "/api/admin/settings":
            return self.send_json({"settings": ADMIN_SETTINGS})
        if self.path == "/api/admin/system-stats":
            return self.send_json({"total_bots": 2, "bot_workloads": [
                {"display_name": "Bot 1", "current_load": 1, "failures": 0, "avg_mbps": 40.2, "status": "healthy"},
                {"display_name": "Bot 2", "current_load": 0, "failures": 7, "avg_mbps": 12.0, "status": "degraded"},
            ]})
        return self.send_json({"detail": "Not Found"}, 404)

    def do_POST(self):
        if self.path == "/bot-hook":
            # A stand-in for the admin's bot: keeps what the Hub's webhook sent, for e2e.py.
            BOT_HOOKS.append({"body": self.body().decode(), "event": self.headers.get("x-couchmates-event"),
                              "signature": self.headers.get("x-couchmates-signature")})
            return self.send_json({"ok": True})
        if self.path == "/login":
            form = urllib.parse.parse_qs(self.body().decode())
            if form.get("username") == [USERNAME] and form.get("password") == [PASSWORD]:
                cookie = "session=" + secrets.token_urlsafe(24)
                SESSIONS.add(cookie)
                self.send_response(302)
                self.send_header("location", "/")
                self.send_header("set-cookie", f"{cookie}; path=/; Max-Age=1209600; httponly; samesite=lax")
                self.send_header("content-length", "0")
                self.end_headers()
                return
            data = b"<html>Invalid credentials</html>"
            self.send_response(200)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/twirp/livekit.RoomService/ListRooms":
            auth = self.headers.get("authorization", "")
            claims = verify_jwt(auth.removeprefix("Bearer "))
            if not claims or not claims.get("video", {}).get("roomList"):
                return self.send_json({"code": "unauthenticated", "msg": "invalid token"}, 401)
            return self.send_json({"rooms": [{"name": "couchmates-ABC123", "num_participants": 3}]})
        if self.path == "/twirp/livekit.RoomService/ListParticipants":
            claims = verify_jwt(self.headers.get("authorization", "").removeprefix("Bearer "))
            if not claims or not claims.get("video", {}).get("roomAdmin"):
                return self.send_json({"code": "unauthenticated", "msg": "invalid token"}, 401)
            return self.send_json({"participants": [
                {"identity": "u1:d1", "name": "Alice", "tracks": [{"type": "AUDIO", "source": "MICROPHONE", "muted": False}]},
                {"identity": "u2:d2", "name": "Bob", "tracks": [{"type": "AUDIO", "source": "MICROPHONE", "muted": True}]},
                {"identity": "u3:d3", "name": "Carol", "tracks": []},
            ]})
        if not self.authed():
            return self.send_json({"detail": "Not authenticated"}, 401)
        if self.path == "/api/tokens":
            payload = json.loads(self.body() or b"{}")
            token = secrets.token_urlsafe(24)
            TOKENS[token] = {
                "name": payload.get("name"), "token": token,
                "subscription_exempt": payload.get("subscription_exempt"),
                "limits": {"daily_limit_gb": payload.get("daily_limit_gb") or 0,
                           "monthly_limit_gb": payload.get("monthly_limit_gb") or 0},
                "usage": {"total_bytes": 3 * 1024**3, "daily": {"bytes": 512 * 1024**2},
                          "monthly": {"bytes": 3 * 1024**3}},
            }
            return self.send_json(TOKENS[token])
        return self.send_json({"detail": "Not Found"}, 404)

    def do_PUT(self):
        if not self.authed():
            return self.send_json({"detail": "Not authenticated"}, 401)
        if self.path == "/api/admin/settings":
            ADMIN_SETTINGS.update(json.loads(self.body() or b"{}"))
            return self.send_json({"message": "Settings saved successfully.", "reinit": False})
        token = self.path.removeprefix("/api/tokens/")
        if token in TOKENS:
            TOKENS[token]["limits"] = json.loads(self.body() or b"{}")
            return self.send_json({"message": "Limits updated successfully"})
        return self.send_json({"detail": "Token not found."}, 404)

    def do_DELETE(self):
        if not self.authed():
            return self.send_json({"detail": "Not authenticated"}, 401)
        token = self.path.removeprefix("/api/tokens/")
        if TOKENS.pop(token, None):
            return self.send_json({"status": "success", "message": "Token revoked."})
        return self.send_json({"detail": "Token not found."}, 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    print(f"fake Telegram-Stremio + LiveKit on http://127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
