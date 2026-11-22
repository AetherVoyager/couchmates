"""Sets up a fresh local Hub for trying the app: turns on 2FA, connects the
stand-in servers from fake_servers.py and adds an app user.

    npx wrangler d1 execute couchmates-hub --local --command "DELETE FROM settings; DELETE FROM admin_sessions; DELETE FROM users; DELETE FROM devices; DELETE FROM login_attempts;"
    python dev/seed_local.py              # Hub on :8787, fake servers on :8899

Prints the app sign-in details. Local test values only.
"""
import base64
import hashlib
import hmac
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HUB = "http://127.0.0.1:8787"
ADMIN_PASSWORD = sys.argv[1] if len(sys.argv) > 1 else "local-admin-pass"
APP_USER, APP_PASSWORD = "alice", "local-app-pass"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect)
cookie = None


def post(path, form):
    global cookie
    req = urllib.request.Request(HUB + path, data=urllib.parse.urlencode(form).encode(), method="POST")
    if cookie:
        req.add_header("cookie", cookie)
    try:
        r = opener.open(req)
        status, headers, text = r.status, r.headers, r.read().decode()
    except urllib.error.HTTPError as e:
        status, headers, text = e.code, e.headers, e.read().decode()
    if headers.get("set-cookie"):
        cookie = headers["set-cookie"].split(";")[0]
    return status, headers, text


def get(path):
    req = urllib.request.Request(HUB + path, headers={"cookie": cookie or ""})
    return opener.open(req).read().decode()


def totp(secret, offset=0):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    mac = hmac.new(key, struct.pack(">Q", int(time.time() // 30) + offset), hashlib.sha1).digest()
    o = mac[-1] & 15
    return "%06d" % ((struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


status, headers, _ = post("/login", {"password": ADMIN_PASSWORD, "code": ""})
if headers.get("location") != "/setup-2fa":
    sys.exit("The local Hub already has 2FA or the password is wrong. Clear it first (see the top of this file).")
secret = re.search(r"Enter this key by hand: <code>([A-Z2-7 ]+)</code>", get("/setup-2fa")).group(1).replace(" ", "")
post("/setup-2fa", {"code": totp(secret)})
post("/settings/tgs", {"url": "http://127.0.0.1:8899", "username": "admin", "password": "admin-pass"})
post("/settings/livekit", {"url": "ws://127.0.0.1:8899", "key": "devkey", "secret": "devsecret"})
post("/users", {"name": "Alice", "username": APP_USER, "password": APP_PASSWORD, "daily_limit_gb": "0",
                "monthly_limit_gb": "0"})
print(f"App sign-in: Hub {HUB}, username {APP_USER}, password {APP_PASSWORD}")
print(f"Admin authenticator key (local only): {secret}")
