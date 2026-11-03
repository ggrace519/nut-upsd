#!/bin/sh
# Start every UPS driver in ups.conf and upsd, both in the foreground, as the nut user.
# Each driver is restarted on its own when it exits, so one failing UPS doesn't take the
# others offline. If upsd exits, stop everything and exit non-zero so the container restart
# policy brings it back.
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

# The drivers run as nut, so they can open a USB device only if its node is group-accessible
# to nut. NUT_DEVICE_GID names the host group that owns the UPS device nodes (set by a host
# udev rule). nut joins a group with that ID here, and the drivers keep it when they drop
# privileges, because NUT calls initgroups().
if [ -n "${NUT_DEVICE_GID:-}" ]; then
  case "$NUT_DEVICE_GID" in
    *[!0-9]*) log "NUT_DEVICE_GID must be a numeric group ID, got '$NUT_DEVICE_GID'"; exit 64 ;;
  esac
  group=$(awk -F: -v gid="$NUT_DEVICE_GID" '$3 == gid { print $1; exit }' /etc/group)
  if [ -z "$group" ]; then
    group=nut-device
    addgroup -g "$NUT_DEVICE_GID" "$group"
  fi
  # A restarted container keeps its /etc/group, so nut may already be a member.
  id -nG nut | tr " " "\n" | grep -qx "$group" || addgroup nut "$group"
fi

ups_list=$(sed -n 's/^[[:space:]]*\[\([^]]*\)\][[:space:]]*$/\1/p' "$NUT_ETC/ups.conf")
[ -n "$ups_list" ] || { log "no UPS defined in $CONFIG_SRC/ups.conf"; exit 64; }

# Run one UPS's driver in the foreground and restart it whenever it exits, with backoff
# (RETRY_MIN doubling to RETRY_MAX; reset after a run of RETRY_MAX or longer). Each UPS has its
# own loop, so a driver that can't start (device unplugged, passthrough missing) doesn't take
# the other UPSes down. While it's down, upsd reports that UPS as not connected or stale, and
# the healthcheck stays unhealthy.
RETRY_MIN=5
RETRY_MAX=60
supervise() {
  ups=$1
  delay=$RETRY_MIN
  child=
  trap 'kill "$child" 2>/dev/null; exit 0' TERM INT
  while :; do
    started=$(date +%s)
    upsdrvctl -u nut -F start "$ups" &
    child=$!
    rc=0
    wait "$child" || rc=$?
    [ $(( $(date +%s) - started )) -ge "$RETRY_MAX" ] && delay=$RETRY_MIN
    log "driver for $ups exited ($rc); restarting in ${delay}s"
    sleep "$delay" &
    child=$!
    wait "$child" || true
    delay=$(( delay * 2 ))
    [ "$delay" -le "$RETRY_MAX" ] || delay=$RETRY_MAX
  done
}

supervisors=
for ups in $ups_list; do
  supervise "$ups" &
  supervisors="$supervisors $!"
done
upsd -u nut -F &
upsd=$!

stop() {
  # shellcheck disable=SC2086 # word-split the PID list
  kill $supervisors "$upsd" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap 'stop; exit 0' TERM INT

# upsd is the one process every UPS depends on: if it exits, so does the container, and the
# restart policy brings everything back. BusyBox `wait -n` doesn't report which child exited,
# so poll.
while kill -0 "$upsd" 2>/dev/null; do
  sleep 2
done

log "upsd exited"
stop
exit 1
