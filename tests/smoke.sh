#!/usr/bin/env bash
# End-to-end smoke test with NUT's dummy-ups driver (no hardware needed).
#   tests/smoke.sh <image>
# Checks: healthy with two UPSes, values served over the NUT protocol, the config copy is
# root:nut 0640, a login checks the password, a dead driver stops the container (exit 1), and a missing
# config refuses to start (exit 64).
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

echo "== a dead driver stops the container"
# shellcheck disable=SC2016 # expands inside the container, not here
in_ctr sh -c 'kill "$(pgrep -f "^/usr/lib/nut/dummy-ups .*-a dummy2")"'
for _ in $(seq 1 15); do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = false ] || fail "still running after a driver died"
code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
[ "$code" = 1 ] || fail "exit code $code after driver death, want 1"
echo "exited 1"
cleanup

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

echo "== missing config refuses to start"
set +e
docker run --name "$NAME" "$IMAGE" >/dev/null 2>&1
code=$?
set -e
[ "$code" = 64 ] || fail "exit code $code without config, want 64"
echo "exited 64"

rm -rf "$CFG"
echo "PASS"
