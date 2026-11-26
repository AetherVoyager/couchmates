#!/usr/bin/env python3
"""Couchmates relay monitor: measures a coturn relay from outside coturn and sends the totals to the Hub.

Runs once a minute (couchmates-relay.timer) as root, because it reads every process's sockets and the
firewall counters. It never touches coturn or its config:

- relay sessions: coturn's UDP sockets in its relay port range (`ss`), one per allocation;
- bytes: an nftables table of its own (`inet couchmates_relay`) that only counts packets, with accept
  policies, so it can't block anything. Remove it with `nft delete table inet couchmates_relay`.

Each run adds what changed since the last run to running totals per UTC day (kept in STATE), then POSTs
the last two days and the current state to `<hub>/api/relay/report` with the token from the Hub's Voice
page. Nothing listens for the Hub; a failed POST is caught up by the next one, because the totals are
running totals.

Config, /etc/couchmates-relay.conf (mode 600):
    hub = https://your-hub.workers.dev
    token = cmr_...
"""

import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

VERSION = "1"
CONF = os.environ.get("COUCHMATES_RELAY_CONF", "/etc/couchmates-relay.conf")
STATE = os.environ.get("COUCHMATES_RELAY_STATE", "/var/lib/couchmates-relay/state.json")
TURN_CONF = "/etc/turnserver.conf"
TABLE = "couchmates_relay"
# A relay port that moved at least this much per minute carried audio (Opus voice is ~250 KB a minute).
ACTIVE_BYTES_PER_MIN = 8_000
KEEP_DAYS = 40


def run(*args, stdin=None):
    return subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=30)


def read_conf():
    conf = {}
    with open(CONF, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                conf[key.strip()] = value.strip()
    if not conf.get("hub") or not conf.get("token"):
        sys.exit(f"{CONF} needs hub = ... and token = ...")
    return conf


def relay_range():
    """coturn's min-port/max-port, read-only."""
    lo, hi = 49152, 65535
    try:
        with open(TURN_CONF, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*(min|max)-port\s*=?\s*(\d+)", line)
                if m:
                    if m.group(1) == "min":
                        lo = int(m.group(2))
                    else:
                        hi = int(m.group(2))
    except OSError:
        pass
    return lo, hi


def listen_port():
    try:
        with open(TURN_CONF, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*listening-port\s*=?\s*(\d+)", line)
                if m:
                    return int(m.group(1))
    except OSError:
        pass
    return 3478


def ensure_table(port, lo, hi):
    if run("nft", "list", "table", "inet", TABLE).returncode == 0:
        return
    rules = f"""
table inet {TABLE} {{
  set relay_in {{ type inet_service; flags dynamic,timeout; timeout 3h; size 65535; counter; }}
  set relay_out {{ type inet_service; flags dynamic,timeout; timeout 3h; size 65535; counter; }}
  chain input {{ type filter hook input priority -300; policy accept;
    iifname "lo" return
    udp dport {port} counter comment "ctl_in"
    tcp dport {port} counter comment "ctl_in_tcp"
    udp dport {lo}-{hi} update @relay_in {{ udp dport }}
  }}
  chain output {{ type filter hook output priority -300; policy accept;
    oifname "lo" return
    udp sport {port} counter comment "ctl_out"
    tcp sport {port} counter comment "ctl_out_tcp"
    udp sport {lo}-{hi} update @relay_out {{ udp sport }}
  }}
}}
"""
    result = run("nft", "-f", "-", stdin=rules)
    if result.returncode != 0:
        sys.exit(f"couldn't add the counting table: {result.stderr.strip()}")


def counters():
    """({comment: bytes}, {"in": {port: bytes}, "out": {port: bytes}}) from our nftables table."""
    out = json.loads(run("nft", "-j", "list", "table", "inet", TABLE).stdout or "{}")
    control, ports = {}, {"in": {}, "out": {}}
    for item in out.get("nftables", []):
        rule = item.get("rule")
        if rule and rule.get("comment"):
            for expr in rule.get("expr", []):
                if "counter" in expr:
                    control[rule["comment"]] = expr["counter"].get("bytes", 0)
        s = item.get("set")
        if s and s.get("name") in ("relay_in", "relay_out"):
            side = "in" if s["name"] == "relay_in" else "out"
            for e in s.get("elem", []):
                e = e.get("elem", e)
                if isinstance(e, dict) and "val" in e:
                    ports[side][str(e["val"])] = e.get("counter", {}).get("bytes", 0)
    return control, ports


def turn_ports(lo, hi):
    """coturn's UDP relay sockets: one per allocation."""
    ports = set()
    for line in run("ss", "-uanpH").stdout.splitlines():
        if "turnserver" not in line:
            continue
        fields = line.split()
        if len(fields) < 4:
            continue
        port = fields[3].rsplit(":", 1)[-1]
        if port.isdigit() and lo <= int(port) <= hi:
            ports.add(port)
    return ports


def grew(now, before):
    """How much a counter grew; a counter that went down started over."""
    return now - before if now >= before else now


def coturn_active():
    return run("systemctl", "is-active", "coturn").stdout.strip() == "active"


def uptime():
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except OSError:
        return 0


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def step(state, now, control, ports, open_ports):
    """Adds what changed since the last run to today's totals. Returns how many relay ports carried audio."""
    day = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%d")
    days = state.setdefault("days", {})
    today = days.setdefault(day, {"sessions": 0, "minutes": 0.0, "bytes_in": 0.0, "bytes_out": 0.0})
    first = "last_run" not in state
    elapsed = min(max(now - state.get("last_run", now), 0), 300)

    prev_control = state.get("control", {})
    prev_ports = state.get("ports", {"in": {}, "out": {}})
    # Ports that were coturn's last time count too: an allocation that just closed still moved data.
    watched = open_ports | set(state.get("open_ports", []))
    relaying = 0
    if not first:
        for name, total in control.items():
            moved = grew(total, prev_control.get(name, 0))
            today["bytes_in" if "_in" in name else "bytes_out"] += moved
        for port in watched:
            moved_in = grew(ports["in"].get(port, 0), prev_ports["in"].get(port, 0))
            moved_out = grew(ports["out"].get(port, 0), prev_ports["out"].get(port, 0))
            today["bytes_in"] += moved_in
            today["bytes_out"] += moved_out
            if elapsed and moved_in + moved_out >= ACTIVE_BYTES_PER_MIN * elapsed / 60:
                relaying += 1
        today["minutes"] += relaying * elapsed / 60
        today["sessions"] += len(open_ports - set(state.get("open_ports", [])))

    state["control"] = control
    state["ports"] = ports
    state["open_ports"] = sorted(open_ports)
    state["last_run"] = now
    for old in sorted(days)[:-KEEP_DAYS]:
        del days[old]
    return relaying


def report(state, relaying, open_ports):
    recent = sorted(state["days"])[-2:]
    return {
        "coturn_active": coturn_active(),
        "allocations": len(open_ports),
        "relaying": relaying,
        "uptime_secs": uptime(),
        "agent_version": VERSION,
        "days": [
            {
                "day": d,
                "sessions": int(state["days"][d]["sessions"]),
                "minutes": round(state["days"][d]["minutes"], 2),
                "bytes_in": state["days"][d]["bytes_in"],
                "bytes_out": state["days"][d]["bytes_out"],
            }
            for d in recent
        ],
    }


def send(conf, body):
    request = urllib.request.Request(
        conf["hub"].rstrip("/") + "/api/relay/report",
        data=json.dumps(body).encode(),
        headers={
            "content-type": "application/json",
            "authorization": "Bearer " + conf["token"],
            "user-agent": "couchmates-relay/" + VERSION,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status
    except urllib.error.HTTPError as e:
        return f"{e.code} {e.read(200).decode(errors='replace')}"
    except (urllib.error.URLError, OSError) as e:
        return f"couldn't reach the Hub: {e}"


def main():
    conf = read_conf()
    lo, hi = relay_range()
    ensure_table(listen_port(), lo, hi)
    state = load_state()
    control, ports = counters()
    open_ports = turn_ports(lo, hi)
    relaying = step(state, int(time.time()), control, ports, open_ports)
    save_state(state)
    body = report(state, relaying, open_ports)
    result = send(conf, body)
    if result != 200:
        print(f"report not accepted: {result}", file=sys.stderr)
        sys.exit(1)
    if "--verbose" in sys.argv:
        print(json.dumps(body))


if __name__ == "__main__":
    main()
