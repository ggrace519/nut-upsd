#!/bin/sh
# Start every UPS driver in ups.conf and upsd, both in the foreground, as the nut user.
# If any of them exits, stop the rest and exit non-zero so the container restart policy
# brings the whole bundle back (upsdrvctl -F already stops all drivers when one dies).
set -eu

CONFIG_SRC="${NUT_CONFIG_SRC:-/config}"
NUT_ETC=/etc/nut
STATE_DIR=/var/run/nut

log() { echo "nut-entrypoint: $*" >&2; }

for f in ups.conf upsd.conf upsd.users; do
  [ -r "$CONFIG_SRC/$f" ] || { log "missing $CONFIG_SRC/$f (mount your NUT config at $CONFIG_SRC)"; exit 64; }
done

# The mounted config can stay root-only on the host: upsd re-reads upsd.users as the nut
# user, so the copy it reads must be group-readable by nut, and nothing else.
rm -rf "${NUT_ETC:?}"/*
cp -R "$CONFIG_SRC"/. "$NUT_ETC"/
chown -R root:nut "$NUT_ETC"
find "$NUT_ETC" -type d -exec chmod 0750 {} +
find "$NUT_ETC" -type f -exec chmod 0640 {} +

install -d -o nut -g nut -m 0770 "$STATE_DIR"

upsdrvctl -u nut -F start &
drivers=$!
upsd -u nut -F &
upsd=$!

stop() {
  kill "$drivers" "$upsd" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap 'stop; exit 0' TERM INT

# BusyBox `wait -n` doesn't report which child exited, so poll.
while kill -0 "$drivers" 2>/dev/null && kill -0 "$upsd" 2>/dev/null; do
  sleep 2
done

if kill -0 "$drivers" 2>/dev/null; then log "upsd exited"; else log "a UPS driver exited"; fi
stop
exit 1
