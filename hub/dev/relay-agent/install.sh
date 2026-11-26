#!/bin/sh
# Installs or updates the Couchmates relay monitor. Run from this folder: sudo sh install.sh
# It doesn't change coturn or its config. Remove with: sudo sh install.sh --remove
set -eu
if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now couchmates-relay.timer 2>/dev/null || true
  rm -f /etc/systemd/system/couchmates-relay.service /etc/systemd/system/couchmates-relay.timer
  rm -rf /usr/local/lib/couchmates-relay /var/lib/couchmates-relay
  nft delete table inet couchmates_relay 2>/dev/null || true
  systemctl daemon-reload
  echo "Removed. /etc/couchmates-relay.conf is left in place."
  exit 0
fi
install -d -m 755 /usr/local/lib/couchmates-relay
install -m 755 agent.py /usr/local/lib/couchmates-relay/agent.py
install -m 644 couchmates-relay.service couchmates-relay.timer /etc/systemd/system/
if [ ! -f /etc/couchmates-relay.conf ]; then
  umask 077
  printf 'hub = https://YOUR-HUB.workers.dev\ntoken = PASTE_THE_TOKEN_FROM_THE_VOICE_PAGE\n' > /etc/couchmates-relay.conf
  echo "Edit /etc/couchmates-relay.conf, then run: sudo systemctl enable --now couchmates-relay.timer"
fi
chmod 600 /etc/couchmates-relay.conf
systemctl daemon-reload
echo "Installed. Test once with: sudo python3 -I /usr/local/lib/couchmates-relay/agent.py --verbose"
