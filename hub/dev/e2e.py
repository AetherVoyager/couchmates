"""End-to-end checks of the Hub: admin 2FA, users and the app API. Needs a fresh local database."""
import base64, hashlib, hmac, http.cookiejar, json, re, struct, sys, time, urllib.parse, urllib.request

H = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787"
ADMIN_PW = sys.argv[2] if len(sys.argv) > 2 else "local-admin-pass"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Client:
    """Keeps the session cookie by hand (the cookie is Secure; tests use http)."""
    def __init__(self):
        self.opener = urllib.request.build_opener(NoRedirect)
        self.cookie = None


def client():
    return Client()


def call(op, path, form=None, data=None, headers=None, method=None):
    body = None
    h = dict(headers or {})
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
    if data is not None:
        body = json.dumps(data).encode()
        h["content-type"] = "application/json"
    if op.cookie:
        h["cookie"] = op.cookie
    req = urllib.request.Request(H + path, data=body, headers=h, method=method)
    try:
        r = op.opener.open(req)
        status, headers, text = r.status, r.headers, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        status, headers, text = e.code, e.headers, e.read().decode(errors="replace")
    sc = headers.get("set-cookie")
    if sc:
        pair = sc.split(";")[0]
        op.cookie = pair if pair.split("=", 1)[1] else None
    return status, headers, text


def totp(secret_b32, t=None, offset=0):
    key = base64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8))
    step = int((t or time.time()) // 30) + offset
    h = hmac.new(key, struct.pack(">Q", step), hashlib.sha1).digest()
    o = h[-1] & 15
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def ws_open(path, headers):
    """Opens a WebSocket by hand (the standard library has no client). None unless upgraded."""
    import os, socket
    u = urllib.parse.urlparse(H)
    sock = socket.create_connection((u.hostname, u.port or 80), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    extra = "".join(f"{k}: {v}\r\n" for k, v in headers.items())
    sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {u.netloc}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            return None
        head += chunk
    return sock if head.startswith(b"HTTP/1.1 101") else None


def ws_read(sock):
    """The next text frame, or None."""
    def exactly(n):
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data
    try:
        while True:
            b0, b1 = exactly(2)
            size = b1 & 127
            if size == 126:
                size = struct.unpack(">H", exactly(2))[0]
            elif size == 127:
                size = struct.unpack(">Q", exactly(8))[0]
            data = exactly(size)
            if b0 & 15 == 1:
                return data.decode()
    except (EOFError, OSError):
        return None


def ws_send(sock, text):
    import os
    data, mask = text.encode(), os.urandom(4)
    sock.sendall(bytes([0x81, 0x80 | len(data)]) + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))


def check(label, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + label + (f"  [{extra}]" if extra and not cond else ""))
    if not cond:
        check.failed = True


check.failed = False
anon = client()

# --- Admin: first sign-in leads to 2FA setup
a = client()
s, hd, _ = call(a, "/login", form={"password": ADMIN_PW, "code": ""})
check("first login goes to 2FA setup", s == 303 and hd["location"] == "/setup-2fa", f"{s} {hd.get('location')}")
s, hd, _ = call(a, "/")
check("dashboard blocked until 2FA is set up", s == 303 and hd["location"] == "/setup-2fa")
s, _, page = call(a, "/setup-2fa")
m = re.search(r"Enter this key by hand: <code>([A-Z2-7 ]+)</code>", page)
check("setup page shows QR and key", s == 200 and "<svg" in page and m is not None)
secret = m.group(1).replace(" ", "")
s, _, page = call(a, "/setup-2fa", form={"code": "000000" if totp(secret) != "000000" else "111111"})
check("wrong setup code rejected", "didn" in page)
s, hd, _ = call(a, "/setup-2fa", form={"code": totp(secret)})
check("right setup code turns 2FA on", s == 303 and hd["location"].startswith("/?ok="), f"{s} {hd.get('location')}")
s, _, _ = call(a, "/")
check("dashboard opens after setup", s == 200)

# --- Admin: later sign-ins need the code; replay is refused
b = client()
s, _, _ = call(b, "/login", form={"password": ADMIN_PW, "code": ""})
check("login without code refused", s == 401)
s, _, _ = call(b, "/login", form={"password": "nope", "code": totp(secret, offset=1)})
check("wrong password with good code refused", s == 401)
s, _, _ = call(b, "/login", form={"password": ADMIN_PW, "code": totp(secret)})
check("code from setup can't be replayed", s == 401)
s, hd, _ = call(b, "/login", form={"password": ADMIN_PW, "code": totp(secret, offset=1)})
check("password + next code signs in", s == 303 and hd["location"] == "/", f"{s}")

# --- Connect the fake servers
s, _, page = call(b, "/settings/tgs", form={"url": "http://127.0.0.1:8899", "username": "admin", "password": "admin-pass"})
check("connect Telegram-Stremio", "Connected to" in page)
s, _, page = call(b, "/settings/livekit", form={"url": "ws://127.0.0.1:8899", "key": "devkey", "secret": "devsecret"})
check("connect LiveKit", "LiveKit works" in page)
check("settings shows 2FA card", "Two-factor sign-in" in call(b, "/settings")[2])

# --- Users: username + password
s, _hd, page = call(b, "/users", form={"name": "Alice", "username": "Alice", "password": "", "daily_limit_gb": "5", "monthly_limit_gb": "0"})
pw = re.search(r'<span class="code">([a-z0-9-]+)</span>', page)
check("create user shows generated password once", s == 200 and pw is not None and "<code>alice</code>" in page, f"{s} {urllib.parse.unquote_plus(str(_hd.get('location')))} {re.findall(r'flash[^>]*>([^<]*)', page)}")
gen_pw = pw.group(1)
check("no addon link or token on the user page", "manifest" not in page.lower() and "/stremio/" not in page.lower())
s, hd, _ = call(b, "/users", form={"name": "Al2", "username": "alice", "password": "whatever123"})
check("duplicate username refused", "taken" in urllib.parse.unquote_plus(hd.get("location", "")))
s, hd, _ = call(b, "/users", form={"name": "Bob", "username": "bob", "password": "short"})
check("short password refused", "at least" in urllib.parse.unquote_plus(hd.get("location", "")))
s, _, page = call(b, "/users", form={"name": "Bob", "username": "bob", "password": "bob-password-1"})
check("create user with chosen password (not shown)", s == 200 and '<span class="code">' not in page)

# --- App API
s, _, body = call(anon, "/api/app/login", data={"username": "alice", "password": "wrong-pass"})
check("app login wrong password", s == 401)
s, _, body = call(anon, "/api/app/login", data={"username": " ALICE ", "password": gen_pw, "device_name": "Test PC"})
check("app login with generated password", s == 200, body)
tok = json.loads(body)["token"]
auth = {"authorization": "Bearer " + tok}
s, _, body = call(anon, "/api/app/config", headers=auth)
cfg = json.loads(body)
check("config works and names the user", s == 200 and cfg["user"]["username"] == "alice" and cfg["addon"]["manifest_url"].endswith("/manifest.json"))
check("config lists no add-ons yet", "addons" not in cfg, body)

# --- Add-ons page: add, check, turn off, reorder, remove
s, _, page = call(b, "/addons")
check("add-ons page opens with suggestions", s == 200 and "Cinemeta" in page and "Check and add" in page)
s, _, page = call(b, "/addons", form={"url": "not a link"})
check("add-on link must be a link", "manifest.json link" in page)
s, _, page = call(b, "/addons", form={"url": "http://127.0.0.1:8899/addons/free"})
check("free add-on passes the check", "Added Fake Free Films. Works with the app" in page, re.findall(r'flash[^>]*>([^<]*)', page))
check("its check lists what it adds", "1 home row, search, details, streams, subtitles" in page)
s, _, page = call(b, "/addons", form={"url": "http://127.0.0.1:8899/addons/free/manifest.json"})
check("the same add-on can't be added twice", "already on the list" in page)
s, _, page = call(b, "/addons", form={"url": "http://127.0.0.1:8899/addons/torrents/manifest.json"})
check("torrent-only add-on is added but off", "but it&#39;s off" in page or "but it's off" in page, re.findall(r'flash[^>]*>([^<]*)', page))
check("and the check says why", "torrent stream(s)" in page)
s, _, page = call(b, "/addons", form={"url": "http://127.0.0.1:8899/nothing/manifest.json"})
check("a link without an add-on is refused", "Not added." in page)
ids = re.findall(r'action="/addons/([0-9a-f]{16})/check"', page)
check("both add-ons are listed", len(ids) == 2, ids)
s, _, body = call(anon, "/api/app/config", headers=auth)
cfg = json.loads(body)
check("config gives apps only the add-ons that are on",
      [a["name"] for a in cfg.get("addons", [])] == ["Fake Free Films"] and cfg["addons"][0]["base_url"] == "http://127.0.0.1:8899/addons/free", body)
call(b, f"/addons/{ids[1]}/enable", form={})
call(b, f"/addons/{ids[1]}/up", form={})
cfg = json.loads(call(anon, "/api/app/config", headers=auth)[2])
check("turning on and moving up changes the app's order", [a["name"] for a in cfg.get("addons", [])] == ["Fake Torrents", "Fake Free Films"], cfg.get("addons"))
s, _, page = call(b, f"/addons/{ids[0]}/check", form={})
check("check again", s == 200 and "Works with the app" in page)
for i in ids:
    call(b, f"/addons/{i}/delete", form={})
cfg = json.loads(call(anon, "/api/app/config", headers=auth)[2])
check("removed add-ons leave the config", "addons" not in cfg)

s, _, body = call(anon, "/api/app/voice-token", data={"room": "abc123"}, headers=auth)
check("voice token", s == 200 and json.loads(body)["room"] == "couchmates-ABC123")
check("voice token is LiveKit by default", "mode" not in json.loads(body) and json.loads(body)["token"])
s, _, _ = call(anon, "/api/app/voice/peers", data={"room": "abc123"})
check("voice peers needs sign-in", s == 401)
s, _, page = call(b, "/settings/voice", form={"mode": "direct", "server": "turn:203.0.113.5"})
check("direct voice needs a relay login", "Not saved" in page)
s, _, page = call(b, "/settings/voice", form={"mode": "direct", "server": "turn:203.0.113.5", "username": "duo", "password": "relay-pass"})
check("direct voice saved", "Voice chat is now direct, through 203.0.113.5:3478" in page, page[:300])
check("relay password not shown", "relay-pass" not in page)
s, _, body = call(anon, "/api/app/voice-token", data={"room": "abc123"}, headers=auth)
grant = json.loads(body)
turn = [x for x in grant.get("ice_servers", []) if x.get("username")]
check("direct grant", grant.get("mode") == "direct" and grant["token"] == "" and turn and turn[0]["username"] == "duo"
      and "turn:203.0.113.5:3478?transport=udp" in turn[0]["urls"], body)
s, _, body = call(anon, "/api/app/voice/peers", data={"room": "abc123"}, headers=auth)
me = json.loads(body)
check("join direct voice room", s == 200 and me["identity"] == grant["identity"] and me["peers"] == [], body)
s, _, body = call(anon, "/api/app/voice/signal", data={"room": "abc123", "to": "nobody:x", "kind": "offer", "data": "{}"}, headers=auth)
check("signal to someone not in the room", s == 404, body)
s, _, body = call(anon, "/api/app/voice/signal", data={"room": "abc123", "to": me["identity"], "kind": "bogus", "data": ""}, headers=auth)
check("unknown signal kind", s == 400, body)
s, _, body = call(anon, "/api/app/voice/peers", data={"room": "abc123", "leaving": True}, headers=auth)
check("leave direct voice room", s == 200)
s, _, body = call(anon, "/api/app/voice/signal", data={"room": "abc123", "to": me["identity"], "kind": "hello"}, headers=auth)
check("signal after leaving", s == 409, body)
s, _, page = call(b, "/settings/voice", form={"mode": "livekit", "server": "203.0.113.5:3478", "username": "duo"})
check("back to LiveKit keeps the relay", "Voice chat uses LiveKit; the relay 203.0.113.5:3478 is kept" in page, page[:300])
s, _, body = call(anon, "/api/app/voice-token", data={"room": "abc123"}, headers=auth)
check("LiveKit again", "mode" not in json.loads(body))
s, _, body = call(anon, "/api/app/login", data={"username": "alice", "password": gen_pw, "device_name": "Phone"})
tok2 = json.loads(body)["token"]
s, _, body = call(anon, "/api/app/password", data={"current_password": "nope", "new_password": "new-password-9"}, headers=auth)
check("change password needs the current one", s == 401)
s, _, body = call(anon, "/api/app/password", data={"current_password": gen_pw, "new_password": "new-password-9"}, headers=auth)
check("change password", s == 200, body)
s, _, _ = call(anon, "/api/app/config", headers={"authorization": "Bearer " + tok2})
check("other device signed out after change", s == 401)
s, _, _ = call(anon, "/api/app/config", headers=auth)
check("this device stays signed in", s == 200)
s, _, body = call(anon, "/api/app/login", data={"username": "alice", "password": "new-password-9", "device_name": "Laptop"})
check("new password works", s == 200)
tok3 = json.loads(body)["token"]
s, _, body = call(anon, "/api/app/profile", headers=auth)
prof = json.loads(body)
check("profile lists both devices, marking this one", s == 200 and len(prof["devices"]) == 2
      and sum(d["current"] for d in prof["devices"]) == 1, body)
s, _, body = call(anon, "/api/app/profile", data={"name": "  Alice B.  "}, headers=auth)
check("rename", s == 200 and json.loads(body)["user"]["name"] == "Alice B.", body)
s, _, _ = call(anon, "/api/app/profile", data={"name": "   "}, headers=auth)
check("empty name refused", s == 400)
laptop = next(d["id"] for d in prof["devices"] if not d["current"])
s, _, _ = call(anon, "/api/app/devices/sign-out", data={"device_id": laptop}, headers=auth)
s2, _, _ = call(anon, "/api/app/config", headers={"authorization": "Bearer " + tok3})
check("sign out another of my devices", s == 200 and s2 == 401)

# --- Presence and join requests (Alice and Bob)
s, _, body = call(anon, "/api/app/login", data={"username": "bob", "password": "bob-password-1", "device_name": "Bob PC"})
bob = {"authorization": "Bearer " + json.loads(body)["token"]}
s, _, _ = call(anon, "/api/app/presence", data={"watching": None})
check("presence needs sign-in", s == 401)
watching = {"title": "Inception", "meta_type": "movie", "meta_id": "tt1375666", "paused": False, "room": "K7MQ2X"}
s, _, body = call(anon, "/api/app/presence", data={"watching": watching}, headers=bob)
check("bob says what he's watching", s == 200, body)
s, _, body = call(anon, "/api/app/presence", data={"watching": None}, headers=auth)
act = json.loads(body)
bob_row = next((f for f in act["friends"] if f["person"]["name"] == "Bob"), None)
check("alice sees bob watching, without his room code", s == 200 and bob_row and bob_row["online"]
      and bob_row["watching"]["title"] == "Inception" and bob_row["watching"]["in_party"]
      and "K7MQ2X" not in body, body)
bob_id = bob_row["person"]["id"]
s, _, body = call(anon, "/api/app/join-requests", data={"to_user_id": bob_id}, headers=auth)
out = [r for r in json.loads(body)["requests"] if not r["incoming"]]
check("alice asks to join", s == 200 and len(out) == 1 and out[0]["status"] == "pending", body)
s, _, body = call(anon, "/api/app/presence", data={"watching": watching}, headers=bob)
inc = [r for r in json.loads(body)["requests"] if r["incoming"]]
check("bob gets the request", len(inc) == 1 and inc[0]["person"]["name"] == "Alice B.", body)
s, _, body = call(anon, "/api/app/join-requests/answer", data={"id": inc[0]["id"], "accept": True}, headers=bob)
check("bob accepts with his current room", s == 200 and not [r for r in json.loads(body)["requests"] if r["incoming"]], body)
s, _, body = call(anon, "/api/app/presence", data={"watching": None}, headers=auth)
out = [r for r in json.loads(body)["requests"] if not r["incoming"]]
check("alice gets the room code", out and out[0]["status"] == "accepted" and out[0]["room"] == "K7MQ2X", body)
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
s, _, body = call(anon, "/api/app/profile/photo", data={"image": "PHN2Zz48L3N2Zz4="}, headers=bob)
check("a non-image photo is refused", s == 415, body)
s, _, body = call(anon, "/api/app/profile/photo", data={"image": PNG}, headers=bob)
photo = json.loads(body)["user"].get("photo", "")
check("bob sets a photo", s == 200 and photo.startswith("/api/app/photos/" + bob_id + "?v="), body)
s, hd, img = call(anon, photo, headers=auth)
check("alice fetches bob's photo", s == 200 and hd.get("content-type") == "image/png" and "immutable" in hd.get("cache-control", ""), f"{s} {hd}")
s, _, _ = call(anon, photo)
check("photos need sign-in", s == 401)
s, _, body = call(anon, "/api/app/presence", data={"watching": None}, headers=auth)
bob_row = next(f for f in json.loads(body)["friends"] if f["person"]["id"] == bob_id)
check("bob's photo shows in alice's list", bob_row["person"].get("photo") == photo, body)
s, _, body = call(anon, "/api/app/profile/photo/remove", data={}, headers=bob)
check("bob removes it", s == 200 and "photo" not in json.loads(body)["user"], body)
s, _, _ = call(anon, photo, headers=auth)
check("removed photo is gone", s == 404)
TRACKS = [{"kind": "audio", "index": 1, "codec": "AAC", "language": "mal", "channels": 6, "default": True, "forced": False},
          {"kind": "subtitle", "index": 1, "codec": "SRT", "language": "eng", "default": False, "forced": False}]
key = urllib.parse.quote("f:12345:Some Movie.mkv")
s, _, body = call(anon, "/api/app/tracks?key=" + key, headers=auth)
check("an unread file has no tracks", s == 200 and json.loads(body)["tracks"] is None, body)
s, _, _ = call(anon, "/api/app/tracks?key=" + key)
check("tracks need sign-in", s == 401)
s, _, body = call(anon, "/api/app/tracks", data={"key": "f:12345:Some Movie.mkv", "tracks": [{"kind": "data", "index": 1}]}, headers=bob)
check("odd tracks are refused", s == 400, body)
s, _, body = call(anon, "/api/app/tracks", data={"key": "f:12345:Some Movie.mkv", "tracks": TRACKS}, headers=bob)
check("bob shares a file's tracks", s == 200, body)
s, _, body = call(anon, "/api/app/tracks?key=" + key, headers=auth)
check("alice gets them", s == 200 and json.loads(body)["tracks"] == TRACKS, body)
s, _, body = call(anon, "/api/app/join-requests/cancel", data={"id": out[0]["id"]}, headers=auth)
check("alice clears it", s == 200 and not json.loads(body)["requests"], body)
s, _, body = call(anon, "/api/app/join-requests", data={"to_user_id": json.loads(call(anon, "/api/app/config", headers=auth)[2])["user"]["id"]}, headers=bob)
check("can't ask to join yourself... or someone idle", s in (400, 409), body)
s, _, body = call(anon, "/api/app/presence", data={"watching": watching}, headers=bob)
s, _, body = call(anon, "/api/app/presence", data={"watching": None, "leaving": True}, headers=bob)
check("bob closes the app", s == 200, body)
s, _, body = call(anon, "/api/app/presence", data={"watching": None}, headers=auth)
bob_row = next(f for f in json.loads(body)["friends"] if f["person"]["id"] == bob_id)
check("alice sees bob offline at once, not watching", not bob_row["online"] and bob_row["watching"] is None, body)
s, _, body = call(anon, "/api/app/join-requests", data={"to_user_id": bob_id}, headers=auth)
check("and can't ask to join him", s == 409, body)

# --- Tracearr: a read-only Jellyfin look-alike under /jellyfin, with its own key
s, _, body = call(anon, "/jellyfin/System/Info/Public")
check("jellyfin public info answers without a key", s == 200 and json.loads(body)["ProductName"] == "Jellyfin Server", body)
s, _, _ = call(anon, "/jellyfin/Sessions")
check("jellyfin sessions need the key", s == 401)
s, _, page = call(b, "/settings/tracearr/key", form={})
m = re.search(r'<span class="code"[^>]*>([0-9a-f]{32})<', page)
check("the admin makes a Tracearr key, shown once", s == 200 and m is not None)
jf = {"authorization": 'MediaBrowser Client="Tracearr", Device="t", DeviceId="t", Version="1", Token="%s"' % (m.group(1) if m else "")}
s, _, _ = call(anon, "/jellyfin/Sessions", headers={"authorization": 'MediaBrowser Token="' + "0" * 32 + '"'})
check("a wrong jellyfin key is refused", s == 401)
s, _, _ = call(anon, "/jellyfin/Users/Me", headers=jf)
s2, _, _ = call(anon, "/jellyfin/Auth/Keys", headers=jf)
check("the admin check works like an API key's", s == 400 and s2 == 200)
private = {"title": "Severance", "episode": "S1 E3 · In Perpetuity", "meta_type": "series", "meta_id": "tt11280740",
           "paused": False, "private": True,
           "playback": {"position_ms": 60000, "duration_ms": 3000000, "width": 1920, "height": 1080, "video_codec": "hevc"}}
s, _, body = call(anon, "/api/app/presence", data={"watching": private}, headers=bob)
check("bob watches without sharing", s == 200, body)
s, _, body = call(anon, "/api/app/presence", data={"watching": None}, headers=auth)
bob_row = next(f for f in json.loads(body)["friends"] if f["person"]["id"] == bob_id)
check("alice doesn't see what bob watches", bob_row["online"] and bob_row["watching"] is None, body)
s, _, body = call(anon, "/jellyfin/Sessions", headers=jf)
playing = [x for x in json.loads(body) if x.get("NowPlayingItem")]
check("tracearr sees bob's episode", s == 200 and len(playing) == 1 and playing[0]["UserName"] == "Bob"
      and playing[0]["NowPlayingItem"]["SeriesName"] == "Severance" and playing[0]["NowPlayingItem"]["IndexNumber"] == 3
      and playing[0]["DeviceName"] == "Bob PC" and playing[0]["PlayState"]["PositionTicks"] >= 600000000, body)
s, _, body = call(anon, "/jellyfin/Users", headers=jf)
check("tracearr lists the users", s == 200 and {"Alice B.", "Bob"} <= {u["Name"] for u in json.loads(body)}, body)
s, _, body = call(anon, "/jellyfin/Library/VirtualFolders", headers=jf)
check("two empty libraries", s == 200 and len(json.loads(body)) == 2, body)
s, _, body = call(anon, "/jellyfin/Items?Recursive=true", headers=jf)
check("no items", s == 200 and json.loads(body)["TotalRecordCount"] == 0, body)
s, _, _ = call(anon, "/jellyfin/Sessions/" + playing[0]["Id"] + "/Playing/Stop", data={}, headers=jf) if playing else (0, 0, 0)
check("stopping a stream is refused", s == 501)
s, hd, _ = call(b, "/settings/tracearr/revoke", form={})
s2, _, _ = call(anon, "/jellyfin/Sessions", headers=jf)
check("turning Tracearr off stops the key", s == 303 and s2 == 401)
s, _, body = call(anon, "/api/app/presence", data={"watching": watching}, headers=bob)

# --- Chat: public and private, saved, and pushed live over a WebSocket
alice_id = json.loads(call(anon, "/api/app/config", headers=auth)[2])["user"]["id"]
s, _, _ = call(anon, "/api/app/chat")
check("chat needs sign-in", s == 401)
s, _, _ = call(anon, "/api/app/chat/live", headers=auth)
check("live chat wants a WebSocket", s == 426)
live = ws_open("/api/app/chat/live", auth)
check("alice opens the live chat socket", live is not None)
s, _, body = call(anon, "/api/app/chat/send", data={"channel": "public", "text": "  hi 👋 "}, headers=auth)
pub_msg = json.loads(body) if s == 200 else {}
check("alice writes in the public chat", s == 200 and pub_msg["text"] == "hi 👋" and pub_msg["from"]["id"] == alice_id, body)
s, _, body = call(anon, "/api/app/chat/send", data={"channel": "dm:" + alice_id, "text": "psst"}, headers=bob)
dm = json.loads(body) if s == 200 else {}
dm_channel = "dm:" + ":".join(sorted([alice_id, bob_id]))
check("bob messages alice privately", s == 200 and dm["channel"] == dm_channel, body)
frames = [ws_read(live) for _ in range(2)] if live else []
got = [json.loads(f)["message"]["id"] for f in frames if f]
check("both arrive live", got == [pub_msg.get("id"), dm.get("id")], frames)
if live:
    ws_send(live, "ping")
check("the socket answers ping", live is not None and ws_read(live) == "pong")
s, _, body = call(anon, "/api/app/chat", headers=bob)
chans = {c["id"]: c for c in json.loads(body)["channels"]} if s == 200 else {}
check("bob sees alice's public message unread, his own as read",
      chans.get("public", {}).get("unread") == 1 and chans.get(dm_channel, {}).get("unread") == 0
      and chans[dm_channel]["person"]["id"] == alice_id, body)
s, _, body = call(anon, "/api/app/chat", headers=auth)
chans = {c["id"]: c for c in json.loads(body)["channels"]} if s == 200 else {}
check("alice has one unread private message from bob", chans.get(dm_channel, {}).get("unread") == 1
      and chans[dm_channel]["person"]["name"] == "Bob" and chans[dm_channel]["last"]["text"] == "psst", body)
s, _, _ = call(anon, "/api/app/chat/read", data={"channel": dm_channel, "up_to": dm.get("id", 0)}, headers=auth)
chans = {c["id"]: c for c in json.loads(call(anon, "/api/app/chat", headers=auth)[2])["channels"]}
check("reading clears it", s == 200 and chans[dm_channel]["unread"] == 0)
s, _, body = call(anon, f"/api/app/chat/messages?channel={dm_channel}", headers=bob)
check("the private chat is kept", s == 200 and [m["text"] for m in json.loads(body)["messages"]] == ["psst"], body)
s, _, body = call(anon, f"/api/app/chat/messages?channel=public&after={pub_msg.get('id', 0)}", headers=bob)
check("nothing newer than the last message", s == 200 and json.loads(body) == {"messages": [], "more": False}, body)
s, _, _ = call(anon, "/api/app/chat/messages?channel=dm:0000000000000000:ffffffffffffffff", headers=auth)
check("someone else's private chat stays private", s == 404)
s, _, _ = call(anon, "/api/app/chat/send", data={"channel": "public", "text": "   "}, headers=auth)
check("empty messages are refused", s == 400)
s, _, _ = call(anon, "/api/app/chat/send", data={"channel": "dm:" + alice_id, "text": "me"}, headers=auth)
check("no private chat with yourself", s == 404)

# --- Chat moderation: admins (set on the dashboard) delete and mute; a rate limit and blocked words for everyone
def send_chat(who, text, channel="public"):
    s, _, body = call(anon, "/api/app/chat/send", data={"channel": channel, "text": text}, headers=who)
    return s, (json.loads(body) if s == 200 else {})
s, spam = send_chat(bob, "buy my stuff")
check("bob writes in public", s == 200 and not spam["from"].get("admin"))
s, _, _ = call(anon, "/api/app/chat/delete", data={"id": spam.get("id", 0)}, headers=auth)
check("someone else's message can't be deleted", s == 403)
s, _, _ = call(anon, "/api/app/chat/mute", data={"user": alice_id, "minutes": 5}, headers=bob)
check("only chat admins mute", s == 403)
s, _, _ = call(b, f"/users/{alice_id}/chat-admin", form={})
check("the dashboard makes alice a chat admin", s == 303)
check("her page shows it", "Remove chat admin" in call(b, f"/users/{alice_id}")[2])
view = json.loads(call(anon, "/api/app/chat", headers=auth)[2])
check("alice's chat says she's an admin", view.get("admin") is True and "muted_until" not in view, view)
s, mine = send_chat(auth, "be nice 🙂")
check("her messages carry the badge", s == 200 and mine["from"].get("admin") is True, mine)
s, _, _ = call(anon, "/api/app/chat/delete", data={"id": spam.get("id", 0)}, headers=auth)
frames = [ws_read(live) for _ in range(4)] if live else []
kinds = [(json.loads(f)["kind"], json.loads(f).get("message", {}).get("id")) for f in frames if f and f != "pong"]
check("an admin deletes it, and the apps hear", s == 200 and ("deleted", spam.get("id")) in kinds, kinds)
s, _, body = call(anon, f"/api/app/chat/messages?channel=public&after={pub_msg.get('id', 0)}", headers=bob)
check("it's gone for good", s == 200 and spam.get("id") not in [m["id"] for m in json.loads(body)["messages"]], body)
s, _, _ = call(anon, "/api/app/chat/mute", data={"user": bob_id, "minutes": 60}, headers=auth)
s2, _ = send_chat(bob, "hello?")
view = json.loads(call(anon, "/api/app/chat", headers=bob)[2])
check("a muted bob can't write, and knows until when", s == 200 and s2 == 403
      and view.get("muted_until", 0) > time.time() + 3000, view)
s, _, _ = call(anon, "/api/app/chat/mute", data={"user": alice_id}, headers=auth)
check("nobody mutes themselves", s == 400)
check("the users list shows the mute", "Muted in chat" in call(b, "/users")[2])
s, _, _ = call(b, f"/users/{bob_id}/chat-unmute", form={})
s2, back = send_chat(bob, "sorry")
check("lifting the mute on the dashboard lets him write", s == 303 and s2 == 200)
s, _, _ = call(b, "/settings/chat", form={"words": "Heck, darn"})
s2, masked = send_chat(bob, "what the HECK, so darned")
check("blocked words are starred out", s == 303 and masked.get("text") == "what the ****, so darned", masked)
got = [send_chat(bob, f"flood {i}")[0] for i in range(6)]
check("sending too fast is slowed down", 429 in got and got[0] == 200, got)
got = [send_chat(auth, f"admin {i}")[0] for i in range(6)]
check("chat admins aren't", got == [200] * 6, got)
s, _, _ = call(anon, "/api/app/chat/delete", data={"id": back.get("id", 0)}, headers=bob)
check("anyone deletes their own message", s == 200)
call(b, "/settings/chat", form={"words": ""})
call(b, f"/users/{alice_id}/chat-unadmin", form={})
check("alice is an ordinary user again", "admin" not in json.loads(call(anon, "/api/app/chat", headers=auth)[2]))
if live:
    live.close()

# --- Direct voice: the Hub passes connection setup between two devices over their live sockets
call(b, "/settings/voice", form={"mode": "direct", "server": "203.0.113.5:3478", "username": "duo", "password": "relay-pass"})
alice_voice = ws_open("/api/app/chat/live", auth)
bob_voice = ws_open("/api/app/chat/live", bob)
s, _, body = call(anon, "/api/app/voice/peers", data={"room": "vox-123"}, headers=auth)
alice_me = json.loads(body).get("identity", "")
s, _, body = call(anon, "/api/app/voice/peers", data={"room": "vox123"}, headers=bob)
bob_peers = json.loads(body) if s == 200 else {}
check("bob joins and sees alice", [p["identity"] for p in bob_peers.get("peers", [])] == [alice_me], body)
joined = json.loads(ws_read(alice_voice) or "{}") if alice_voice else {}
check("alice hears bob joined", joined.get("kind") == "voice" and joined["voice"]["kind"] == "joined"
      and joined["voice"]["from"] == bob_peers.get("identity") and joined["voice"]["room"] == "couchmates-VOX123", joined)
s, _, body = call(anon, "/api/app/voice/signal", headers=auth,
                  data={"room": "VOX123", "to": bob_peers.get("identity", ""), "kind": "offer", "data": '{"id":1,"sdp":"v=0"}'})
check("alice offers to bob", s == 200, body)
offer = json.loads(ws_read(bob_voice) or "{}") if bob_voice else {}
check("bob gets the offer", offer.get("voice", {}).get("kind") == "offer" and offer["voice"]["from"] == alice_me
      and offer["voice"]["to"] == bob_peers.get("identity") and offer["voice"]["data"] == '{"id":1,"sdp":"v=0"}', offer)
s, _, body = call(anon, "/api/app/voice/peers", data={"room": "vox123", "leaving": True}, headers=bob)
left = json.loads(ws_read(alice_voice) or "{}") if alice_voice else {}
check("alice hears bob left", left.get("voice", {}).get("kind") == "left", left)
s, _, page = call(b, "/", form=None)
check("the overview lists direct voice rooms", "direct voice rooms" in page and "VOX123" in page, page[-500:])
call(anon, "/api/app/voice/peers", data={"room": "vox123", "leaving": True}, headers=auth)
for sock in (alice_voice, bob_voice):
    if sock:
        sock.close()
call(b, "/settings/voice", form={"mode": "livekit", "server": "", "username": ""})

# --- Title requests: friends ask for what isn't in the library, the admin answers on the dashboard
s, _, _ = call(anon, "/api/app/requests")
check("requests need sign-in", s == 401)
s, _, body = call(anon, "/api/app/requests", headers=auth)
check("no requests yet", s == 200 and json.loads(body) == {"requests": []}, body)
MATRIX = {"kind": "movie", "title_id": "tt0133093", "name": " The Matrix ", "year": "1999",
          "poster": "javascript:alert(1)"}
s, _, body = call(anon, "/api/app/requests", data={**MATRIX, "kind": "channel"}, headers=auth)
check("odd requests are refused", s == 400, body)
s, _, body = call(anon, "/api/app/requests", data=MATRIX, headers=auth)
req1 = json.loads(body) if s == 200 else {}
check("alice asks for a title", s == 200 and req1["status"] == "pending" and req1["name"] == "The Matrix"
      and req1["mine"] and req1["requested_by"] == ["Alice B."] and "poster" not in req1, body)
s, _, body = call(anon, "/api/app/requests", data=MATRIX, headers=bob)
req2 = json.loads(body) if s == 200 else {}
check("bob asking for it too joins the same request", s == 200 and req2.get("id") == req1.get("id")
      and req2["requested_by"] == ["Alice B.", "Bob"], body)
s, _, page = call(b, "/requests")
check("the admin sees it waiting, with who asked", s == 200 and "The Matrix" in page and "Alice B., Bob" in page
      and "Mark added" in page, page[:300])
s, _, page = call(b, "/")
check("the overview counts it", s == 200 and "waiting for your answer" in page)
s, hd, _ = call(b, f"/requests/{req1.get('id')}/status", form={"status": "approved", "note": "This weekend", "back": "open"})
check("the admin approves it with a note", s == 303 and "approved" in urllib.parse.unquote_plus(hd.get("location", "")), hd.get("location"))
s, _, page = call(b, hd.get("location", "/"))
check("and lands back on the Requests page, not a 404", s == 200 and "This weekend" in page and "is approved" in page, s)
s, _, _ = call(b, f"/requests/{req1.get('id')}/status", form={"status": "downloading", "note": ""})
s, _, body = call(anon, "/api/app/requests", headers=bob)
mine = json.loads(body)["requests"][0] if s == 200 else {}
check("bob sees the status and note; a made-up status was ignored", mine.get("status") == "approved"
      and mine.get("note") == "This weekend" and mine.get("mine") is True, body)
s, _, body = call(anon, "/api/app/requests/cancel", data={"id": req1.get("id")}, headers=bob)
s, _, body = call(anon, "/api/app/requests", headers=bob)
mine = json.loads(body)["requests"][0] if s == 200 else {}
check("bob withdraws; the request stays for alice", mine.get("mine") is False and mine["requested_by"] == ["Alice B."], body)
call(b, f"/requests/{req1.get('id')}/status", form={"status": "declined", "note": "Not available"})
s, _, body = call(anon, "/api/app/requests", data=MATRIX, headers=bob)
check("asking again for a declined title reopens it", s == 200 and json.loads(body)["status"] == "pending"
      and "note" not in json.loads(body), body)
s, _, body = call(anon, "/api/app/requests", data={"kind": "series", "title_id": "tt0903747", "name": "Breaking Bad"}, headers=bob)
req3 = json.loads(body) if s == 200 else {}
s, _, _ = call(anon, "/api/app/requests/cancel", data={"id": req3.get("id")}, headers=bob)
s, _, body = call(anon, "/api/app/requests", headers=auth)
check("a pending request nobody wants any more goes", [r["name"] for r in json.loads(body)["requests"]] == ["The Matrix"], body)
# --- Requests are marked added once Telegram-Stremio has the title
s, _, body = call(anon, "/api/app/requests", data={"kind": "movie", "title_id": "tt1254207", "name": "Big Buck Bunny"}, headers=auth)
bunny = json.loads(body) if s == 200 else {}
s, _, body = call(anon, "/api/app/requests", data={"kind": "movie", "title_id": "tt0000404", "name": "Not There"}, headers=auth)
missing = json.loads(body) if s == 200 else {}
s, hd, _ = call(b, "/requests/check", form={})
check("Check library now marks the title the server has", "Big Buck Bunny is in the library now" in urllib.parse.unquote_plus(hd.get("location", "")), hd.get("location"))
got = {r["id"]: r for r in json.loads(call(anon, "/api/app/requests", headers=auth)[2])["requests"]}
check("alice sees it added with a note; the other stays pending",
      got.get(bunny.get("id"), {}).get("status") == "added" and got[bunny["id"]].get("note") == "It's in the library now."
      and got.get(missing.get("id"), {}).get("status") == "pending", got)
for r in (bunny, missing):
    call(b, f"/requests/{r.get('id')}/delete", form={})

# --- Shows are asked for one episode at a time; the check marks the episodes the server has
SHOW = {"title_id": "tt9999990", "name": "Blender Shorts", "year": "2008-2010"}
s, _, body = call(anon, "/api/app/requests/episodes", data={**SHOW, "episodes": [
    {"season": 1, "episode": 2, "title": "Sintel"}, {"season": 1, "episode": 3}, {"season": 1, "episode": 2}]}, headers=auth)
eps = json.loads(body)["requests"] if s == 200 else []
check("alice asks for two episodes in one go", [(r.get("season"), r.get("episode"), r.get("episode_title")) for r in eps]
      == [(1, 2, "Sintel"), (1, 3, None)] and all(r["kind"] == "series" and r["mine"] for r in eps), body)
s, _, body = call(anon, "/api/app/requests", data={"kind": "series", **SHOW, "season": 1, "episode": 3}, headers=bob)
check("bob joins one episode's request", s == 200 and json.loads(body)["id"] == (eps[1]["id"] if len(eps) > 1 else None)
      and len(json.loads(body)["requested_by"]) == 2, body)
s, _, body = call(anon, "/api/app/requests", data={"kind": "series", **SHOW, "season": 1}, headers=bob)
check("a season without an episode is refused", s == 400, body)
s, _, body = call(anon, "/api/app/requests/episodes", data={**SHOW, "episodes": [{"season": 1, "episode": e} for e in range(1, 42)]}, headers=bob)
check("more than 40 episodes at once is refused", s == 400, body)
s, _, page = call(b, "/requests")
check("the dashboard shows the episode", "S1 E2 · Sintel" in page and "S1 E3" in page)
s, hd, _ = call(b, "/requests/check", form={})
check("Check library now marks the episode the server has", "Blender Shorts S1 E2 is in the library now" in urllib.parse.unquote_plus(hd.get("location", "")), hd.get("location"))
got = {r["id"]: r for r in json.loads(call(anon, "/api/app/requests", headers=auth)[2])["requests"]}
check("the episode the server lacks stays pending", len(eps) == 2 and got.get(eps[0]["id"], {}).get("status") == "added"
      and got.get(eps[1]["id"], {}).get("status") == "pending", got)
for r in eps:
    call(b, f"/requests/{r.get('id')}/delete", form={})

# --- The bot API: the admin's own program answers requests
FAKE = "http://127.0.0.1:8899"
s, _, body = call(anon, "/api/bot/requests")
check("bot API refuses without a token set up", s == 401, body)
s, _, page = call(b, "/bot/token", form={})
m = re.search(r"(cmb_[A-Za-z0-9_-]{20,})", page)
check("the admin makes a bot token, shown once", s == 200 and m is not None)
bot_tok = m.group(1) if m else ""
botauth = {"authorization": "Bearer " + bot_tok}
check("the token isn't shown again", bot_tok not in call(b, "/requests")[2])
s, _, _ = call(anon, "/api/bot/requests", headers={"authorization": "Bearer cmb_wrong"})
check("a wrong bot token is refused", s == 401)
s, _, _ = call(anon, "/api/bot/requests", headers=auth)
check("an app token isn't a bot token", s == 401)
s, hd, _ = call(b, "/bot/webhook", form={"url": FAKE + "/bot-hook"})
check("the admin saves a webhook", "Webhook saved" in urllib.parse.unquote_plus(hd.get("location", "")), hd.get("location"))
s, _, body = call(anon, "/api/app/requests", data={"kind": "movie", "title_id": "tt0816692", "name": "Interstellar"}, headers=bob)
req4 = json.loads(body) if s == 200 else {}
hook = json.loads(urllib.request.urlopen(FAKE + "/bot-hook/last").read() or "null") or {}
sig = "sha256=" + hmac.new(hashlib.sha256(bot_tok.encode()).hexdigest().encode(), hook.get("body", "").encode(), hashlib.sha256).hexdigest()
check("a new request reaches the bot's webhook, signed", hook.get("event") == "request.created"
      and json.loads(hook["body"])["request"]["id"] == req4.get("id") and hook.get("signature") == sig, hook)
before = len(json.loads(urllib.request.urlopen(FAKE + "/bot-hook/all").read()))
s, _, body = call(anon, "/api/app/requests/episodes", data={"title_id": "tt0903747", "name": "Breaking Bad",
    "episodes": [{"season": 2, "episode": 1}, {"season": 2, "episode": 2}]}, headers=bob)
ep_ids = [r["id"] for r in json.loads(body)["requests"]] if s == 200 else []
hooks = json.loads(urllib.request.urlopen(FAKE + "/bot-hook/all").read())[before:]
sent = sorted((json.loads(h["body"])["request"]["season"], json.loads(h["body"])["request"]["episode"]) for h in hooks)
check("each new episode reaches the webhook with its numbers", sent == [(2, 1), (2, 2)], hooks)
s, _, body = call(anon, "/api/bot/requests", headers=botauth)
check("the bot lists episode requests with their numbers",
      any(r["id"] in ep_ids and r.get("season") == 2 and r.get("episode") == 1 for r in json.loads(body)["requests"]), body)
for i in ep_ids:
    call(b, f"/requests/{i}/delete", form={})
s, _, body = call(anon, "/api/bot/requests?status=pending", headers=botauth)
check("the bot lists pending requests", s == 200 and req4.get("id") in [r["id"] for r in json.loads(body)["requests"]], body)
s, _, body = call(anon, "/api/bot/requests?status=downloading", headers=botauth)
check("an unknown filter is refused", s == 400, body)
s, _, body = call(anon, "/api/bot/requests/update", data={"id": req4.get("id"), "status": "approved", "note": "On it"}, headers=botauth)
check("the bot approves with a note", s == 200 and json.loads(body)["status"] == "approved" and json.loads(body)["note"] == "On it", body)
s, _, body = call(anon, "/api/bot/requests/update", data={"id": req4.get("id"), "status": "added"}, headers=botauth)
check("the bot marks it added; the note stays", s == 200 and json.loads(body)["status"] == "added" and json.loads(body)["note"] == "On it", body)
s, _, body = call(anon, "/api/bot/requests/update", data={"id": req4.get("id"), "status": "lost"}, headers=botauth)
check("a made-up status is refused", s == 400, body)
s, _, body = call(anon, "/api/app/requests", headers=bob)
check("bob sees it added", any(r["id"] == req4.get("id") and r["status"] == "added" for r in json.loads(body)["requests"]), body)
s, _, _ = call(anon, "/api/bot/status", data={"state": "idle"})
check("the bot's status needs its token", s == 401)
s, _, body = call(anon, "/api/bot/status", data={"state": "sleeping"}, headers=botauth)
check("a made-up bot state is refused", s == 400, body)
s, _, body = call(anon, "/api/bot/status", data={
    "state": "working", "activity": "Adding Dune", "version": "9.9",
    "events": [{"at": 1, "level": "error", "message": "Search bot <b>timed out</b>"}],
}, headers=botauth)
check("the bot reports its status", s == 200 and json.loads(body) == {"ok": True}, body)
s, _, page = call(b, "/")
check("the overview shows the bot and its events, escaped",
      "Request bot" in page and "Adding Dune" in page and "Online" not in page.split("Request bot")[1].split("</div>")[0]
      and "Search bot &lt;b&gt;timed out&lt;/b&gt;" in page, page[:300])
s, hd, _ = call(b, "/bot/clear-log", form={})
s, _, page = call(b, "/")
check("the bot log can be cleared", "timed out" not in page and "Adding Dune" in page, page[:300])
s, hd, _ = call(b, "/requests/clear", form={})
check("clear answered says how many", "Cleared" in urllib.parse.unquote_plus(hd.get("location", "")), hd)
s, _, body = call(anon, "/api/app/requests", headers=bob)
check("an answered request is gone after clearing", all(r["id"] != req4.get("id") for r in json.loads(body)["requests"]), body)
call(b, f"/requests/{req4.get('id')}/delete", form={})
call(b, "/bot/webhook", form={"url": "remove"})
s, _, _ = call(b, "/bot/revoke", form={})
s, _, _ = call(anon, "/api/bot/requests", headers=botauth)
check("turning bot access off stops the token", s == 401)

s, hd, _ = call(b, f"/requests/{req1.get('id')}/delete", form={"back": "all"})
s, _, body = call(anon, "/api/app/requests", headers=auth)
check("the admin can delete a request", json.loads(body) == {"requests": []}, body)

# --- Admin resets a password: everyone signed out
uid = re.search(r'href="/users/([0-9a-f]{16})">Alice B\.<', call(b, "/users")[2]).group(1)
s, _, page = call(b, f"/users/{uid}/password", form={"password": ""})
check("admin generates a new password", s == 200 and '<span class="code">' in page)
s, _, _ = call(anon, "/api/app/config", headers=auth)
check("admin reset signs the user out", s == 401)

# --- 2FA reset needs a current code
s, hd, _ = call(b, "/settings/2fa/reset", form={"code": "000000"})
check("2FA reset refuses a wrong code", "didn" in urllib.parse.unquote_plus(hd.get("location", "")))

# cleanup users so reruns work
for name in ("Alice B\\.", "Bob"):
    m = re.search(rf'href="/users/([0-9a-f]{{16}})">{name}<', call(b, "/users")[2])
    if m:
        call(b, f"/users/{m.group(1)}/delete", form={})
print("ALL PASS" if not check.failed else "SOME FAILED")
