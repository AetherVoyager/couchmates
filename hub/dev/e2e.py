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
s, _, body = call(anon, "/api/app/voice-token", data={"room": "abc123"}, headers=auth)
check("voice token", s == 200 and json.loads(body)["room"] == "couchmates-ABC123")
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
