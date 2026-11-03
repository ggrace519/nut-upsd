#!/usr/bin/env bash
# End-to-end smoke test with NUT's dummy-ups driver (no hardware needed).
#   tests/smoke.sh <image>
# Checks: healthy with two UPSes, values served over the NUT protocol, the config copy is
# root:nut 0640, a login checks the password, a dead driver is restarted while the other UPS
# stays up, a driver that can't start doesn't take the others down (and recovers when its
# device appears), upsd exiting stops the container (exit 1), and a missing config refuses
# to start (exit 64).
set -euo pipefail

IMAGE="${1:?usage: tests/smoke.sh <image>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="nut-smoke-$$"
fail() { echo "FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -20 >&2 || true; exit 1; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Host-side copy is root-only, like a real deployment.
CFG="$(mktemp -d)"
cp "$HERE"/config/* "$CFG"/
chmod 0600 "$CFG"/upsd.users
chmod 0755 "$CFG"

in_ctr() { docker exec "$NAME" "$@"; }

wait_healthy() {
  local state
  for _ in $(seq 1 45); do
    state=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo gone)
    [ "$state" = healthy ] && return 0
    [ "$state" = gone ] && fail "container exited during start"
    sleep 2
  done
  fail "not healthy after 90 s (state: $state)"
}

# Supplementary groups of the running dummy2 driver, as the kernel sees them.
# shellcheck disable=SC2016 # expands inside the container, not here
driver_groups() { in_ctr sh -c 'grep "^Groups:" "/proc/$(pgrep -f "^/usr/lib/nut/dummy-ups .*-a dummy2")/status"'; }

echo "== start"
docker run -d --name "$NAME" -v "$CFG":/config:ro "$IMAGE" >/dev/null
wait_healthy
echo "healthy"

echo "== values"
v=$(in_ctr upsc dummy@127.0.0.1 battery.charge 2>/dev/null); [ "$v" = 87 ] || fail "dummy battery.charge=$v"
v=$(in_ctr upsc dummy@127.0.0.1 ups.status 2>/dev/null); [ "$v" = OL ] || fail "dummy ups.status=$v"
v=$(in_ctr upsc dummy2@127.0.0.1 ups.status 2>/dev/null); [ "$v" = "OB DISCHRG" ] || fail "dummy2 ups.status=$v"
in_ctr upsd -V 2>&1 | grep -Eq 'upsd 2\.8\.([3-9]|[1-9][0-9])' || fail "NUT older than 2.8.3"
echo "values ok, $(in_ctr upsd -V 2>&1 | head -1)"

echo "== config copy permissions"
perms=$(in_ctr stat -c '%U:%G %a' /etc/nut/upsd.users)
[ "$perms" = "root:nut 640" ] || fail "upsd.users is $perms"
echo "$perms"

echo "== login (upsd reads upsd.users as nut and checks the password)"
# upsd answers OK to USERNAME/PASSWORD whatever they are; LOGIN (upsmon users) checks them.
login() { in_ctr sh -c "printf 'USERNAME smoke\nPASSWORD %s\nLOGIN dummy\nLOGOUT\n' '$1' | nc -w3 127.0.0.1 3493" | sed -n 3p; }
good=$(login smoke-test-only)
[ "${good%$'\r'}" = "OK" ] || fail "LOGIN with the right password: $good"
bad=$(login wrong-password)
[ "${bad%$'\r'}" = "ERR ACCESS-DENIED" ] || fail "LOGIN with a wrong password: $bad"
docker logs "$NAME" 2>&1 | grep -q "Permission denied" && fail "upsd logged a permission error"
echo "login ok, wrong password refused"

# PID of the running dummy2 driver, or nothing.
# shellcheck disable=SC2016 # expands inside the container, not here
dummy2_pid() { in_ctr sh -c 'pgrep -f "^/usr/lib/nut/dummy-ups .*-a dummy2" || true'; }

# Wait up to $2 seconds for `upsc $1` to report a status.
wait_served() {
  for _ in $(seq 1 "$2"); do
    in_ctr upsc "$1@127.0.0.1" ups.status >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

echo "== a dead driver is restarted; the other UPS stays up"
old=$(dummy2_pid)
in_ctr kill "$old"
sleep 2
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || fail "container exited after a driver died"
v=$(in_ctr upsc dummy@127.0.0.1 ups.status 2>/dev/null); [ "$v" = OL ] || fail "dummy not served while dummy2 was down: $v"
wait_served dummy2 30 || fail "dummy2 not back within 30 s"
new=$(dummy2_pid)
[ -n "$new" ] && [ "$new" != "$old" ] || fail "dummy2 driver not restarted (old $old, new $new)"
in_ctr nut-healthcheck || fail "healthcheck fails after dummy2 recovered"
echo "dummy2 restarted (pid $old -> $new), dummy served throughout"

echo "== upsd exiting stops the container (exit 1)"
# shellcheck disable=SC2016 # expands inside the container, not here
in_ctr sh -c 'kill "$(pgrep -x upsd)"'
for _ in $(seq 1 15); do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ] || fail "still running after upsd died"
code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
[ "$code" = 1 ] || fail "exit code $code after upsd died, want 1"
echo "exited 1"
cleanup

echo "== a driver that can't start doesn't take the others down"
# Third UPS whose device (dummy-ups file) doesn't exist yet, like an unplugged USB UPS.
BROKEN="$(mktemp -d)"
cp "$CFG"/* "$BROKEN"/
chmod 0755 "$BROKEN"
printf '\n[broken]\n  driver = dummy-ups\n  port = broken.dev\n' >> "$BROKEN"/ups.conf
docker run -d --name "$NAME" -v "$BROKEN":/config:ro "$IMAGE" >/dev/null
wait_served dummy 30 || fail "dummy not served next to a broken UPS"
wait_served dummy2 30 || fail "dummy2 not served next to a broken UPS"
sleep 8
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || fail "container exited because one driver can't start"
in_ctr upsc broken@127.0.0.1 ups.status >/dev/null 2>&1 && fail "broken UPS reports a status"
in_ctr nut-healthcheck && fail "healthcheck passes with a UPS down"
docker logs "$NAME" 2>&1 | grep -q "driver for broken exited" || fail "no restart logged for broken"
echo "dummy and dummy2 served, broken down, healthcheck failing"
# The device appears (UPS plugged back in): the retry picks it up without a restart.
in_ctr install -o root -g nut -m 0640 /etc/nut/dummy.dev /etc/nut/broken.dev
wait_served broken 90 || fail "broken not served within 90 s of its device appearing"
in_ctr nut-healthcheck || fail "healthcheck still failing after broken recovered"
echo "broken recovered on its own; healthcheck passes"
cleanup
rm -rf "$BROKEN"

echo "== docker stop is clean and quick (signals reach the daemons)"
docker run -d --name "$NAME" -v "$CFG":/config:ro "$IMAGE" >/dev/null
sleep 5
start=$(date +%s)
docker stop -t 10 "$NAME" >/dev/null
took=$(( $(date +%s) - start ))
code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
[ "$code" = 0 ] || fail "exit code $code after docker stop, want 0"
[ "$took" -lt 8 ] || fail "docker stop took ${took}s (SIGTERM not handled?)"
echo "stopped in ${took}s, exit 0"
cleanup

echo "== NUT_DEVICE_GID puts the drivers in the device group, also after a restart"
docker run -d --name "$NAME" -e NUT_DEVICE_GID=4242 -v "$CFG":/config:ro "$IMAGE" >/dev/null
wait_healthy
driver_groups | grep -qw 4242 || fail "driver lacks group 4242: $(driver_groups)"
docker restart -t 10 "$NAME" >/dev/null
wait_healthy
driver_groups | grep -qw 4242 || fail "driver lacks group 4242 after a restart: $(driver_groups)"
echo "driver has 4242, before and after a restart"
cleanup

echo "== an ID the image already has is reused, not duplicated"
docker run -d --name "$NAME" -e NUT_DEVICE_GID=20 -v "$CFG":/config:ro "$IMAGE" >/dev/null
wait_healthy
driver_groups | grep -qw 20 || fail "driver lacks group 20: $(driver_groups)"
in_ctr grep -q '^nut-device:' /etc/group && fail "created nut-device for an existing ID"
echo "driver has 20 (existing group reused)"
cleanup

echo "== a non-numeric NUT_DEVICE_GID refuses to start"
set +e
docker run --name "$NAME" -e NUT_DEVICE_GID=plugdev -v "$CFG":/config:ro "$IMAGE" >/dev/null 2>&1
code=$?
set -e
[ "$code" = 64 ] || fail "exit code $code for NUT_DEVICE_GID=plugdev, want 64"
echo "exited 64"
cleanup

echo "== a ups.conf with no UPS refuses to start"
EMPTY="$(mktemp -d)"
cp "$CFG"/* "$EMPTY"/
chmod 0755 "$EMPTY"
echo "# no UPS" > "$EMPTY"/ups.conf
set +e
docker run --name "$NAME" -v "$EMPTY":/config:ro "$IMAGE" >/dev/null 2>&1
code=$?
set -e
[ "$code" = 64 ] || fail "exit code $code with no UPS defined, want 64"
echo "exited 64"
cleanup
rm -rf "$EMPTY"

echo "== missing config refuses to start"
set +e
docker run --name "$NAME" "$IMAGE" >/dev/null 2>&1
code=$?
set -e
[ "$code" = 64 ] || fail "exit code $code without config, want 64"
echo "exited 64"

rm -rf "$CFG"
echo "PASS"
