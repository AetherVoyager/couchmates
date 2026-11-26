# Relay monitor

Shows the TURN relay's use on the Hub's **Voice** page: whether coturn is running, relay sessions open now, how
many carry audio, and minutes and data per day.

coturn 4.5.2 (Ubuntu 22.04's package) has no Prometheus or stats feed, and turning on its Redis stats or verbose
logs means changing its config and restarting it. This monitor measures it from outside instead:

- **Relay sessions**: coturn's UDP sockets in its relay port range (`ss`), one per allocation.
- **Data**: an nftables table of its own, `inet couchmates_relay`, that only counts bytes on the listening port and
  on each relay port. Its chains accept everything, so it can't block traffic, and it sits apart from ufw.
- **Minutes**: each minute, each relay port that moved at least 8 KB (a voice stream moves ~250 KB) adds a minute.

Every minute it POSTs running totals to `<hub>/api/relay/report` with a token made on the Voice page (the Hub keeps
only its SHA-256). It only sends; nothing new listens on the server. Other apps on the same relay are counted too.

## Install (on the relay server)

```sh
scp -r hub/dev/relay-agent ubuntu@RELAY:/tmp/
ssh ubuntu@RELAY 'cd /tmp/relay-agent && sudo sh install.sh'
# put hub = ... and token = ... in /etc/couchmates-relay.conf, then:
sudo python3 -I /usr/local/lib/couchmates-relay/agent.py --verbose
sudo systemctl enable --now couchmates-relay.timer
```

Remove: `sudo sh install.sh --remove`. Logs: `journalctl -u couchmates-relay`. Tests: `python -I test_agent.py`.
