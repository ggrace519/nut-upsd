# nut-upsd

[Network UPS Tools](https://networkupstools.org/) (the UPS drivers plus `upsd`) in a small
Alpine image, so a host whose distribution ships an older NUT can still run a current one.

- **NUT 2.8.3** from Alpine 3.24. That's the first release that supports EcoFlow's River 3
  Plus and Delta 3 Plus over USB (`usbhid-ups`, USB ID `3746:ffff`).
- Runs the drivers from `ups.conf` and `upsd`, both as the `nut` user. Each driver is restarted
  on its own when it exits (backoff 5 s doubling to 60 s), so one UPS that's unplugged or
  failing doesn't take the others offline. If `upsd` exits, the container exits and your
  restart policy brings it back. A dead driver still can't hide: `upsd` reports its UPS as not
  connected or stale, and the healthcheck stays unhealthy until it recovers.
- Has no configuration or secrets of its own. You mount yours.
- Its healthcheck is healthy only while every UPS in `ups.conf` reports a status.

`upsmon` isn't included. Run it on the machines that should shut down, pointed at this
container's `upsd`.

## Run

```bash
docker run -d --name nut-upsd \
  --restart unless-stopped \
  --network host \
  -v /etc/nut-upsd:/config:ro \
  -v /dev/bus/usb:/dev/bus/usb \
  --device-cgroup-rule 'c 189:* rmw' \
  -e NUT_DEVICE_GID="$(getent group nut-ups | cut -d: -f3)" \
  ghcr.io/ggrace519/nut-upsd:1.2.0
```

- **`/config`** must contain `ups.conf`, `upsd.conf` and `upsd.users`. `nut.conf` and anything
  your drivers reference, such as `dummy-ups` `.dev` files, are copied too. The files can stay
  root-only (`0600`) on the host: at start the entrypoint copies them to `/etc/nut` as
  `root:nut 0640`, because `upsd` re-reads `upsd.users` after dropping to `nut`. **Restart the
  container to apply config changes.**
- **USB:** bind-mount `/dev/bus/usb` and allow USB character devices (major 189) with the
  cgroup rule. This survives the device re-enumerating after a replug or reboot. `--device`
  only snapshots the device node that exists when the container is created.
- **USB permissions (`NUT_DEVICE_GID`):** the drivers run as `nut`, and a host device node is
  `root:root 0664` by default, so they fail with `libusb1: Could not open any HID devices:
  insufficient permissions on everything`. Give the UPS to a host group with a udev rule, and
  pass that group's numeric ID:
  ```
  # /etc/udev/rules.d/62-nut-upsd.rules (host)
  SUBSYSTEM=="usb", ATTR{idVendor}=="3746", ATTR{idProduct}=="ffff", MODE="0660", GROUP="nut-ups"
  ```
  At start the entrypoint adds `nut` to a group with that ID (reusing one the image already
  has), and the drivers keep it when they drop privileges. udev applies the rule on every plug,
  so replugs keep working.
- **`--network host`:** `upsd` binds on the host itself, so the host firewall decides who can
  reach port 3493. Docker's published ports (`-p`) bypass host firewall rules.
- **`upsd.conf` must listen on `127.0.0.1`** (or `0.0.0.0`) for the healthcheck to work.

Minimal config for one USB HID UPS:

```ini
# ups.conf
[myups]
  driver = usbhid-ups
  port = auto
  vendorid = 3746
  productid = ffff

# upsd.conf
LISTEN 0.0.0.0 3493

# upsd.users
[monitor]
  password = change-me
  upsmon secondary
```

Check it: `docker exec nut-upsd upsc myups@127.0.0.1`.

## Images and updates

- `ghcr.io/ggrace519/nut-upsd:<version>` and `:latest` are published for each release, with
  provenance and SBOM attestations. A release is tagged `vX.Y.Z` on `main` from the top version
  in `CHANGELOG.md` when the promotion merges. The image version is independent of the NUT
  version: the release notes in `CHANGELOG.md` give the NUT version.
- The Alpine base is pinned by digest. Dependabot opens a PR when Alpine moves.
- A weekly CI job checks whether `:latest` has outdated Alpine packages (security fixes
  between Alpine point releases). It fails when a patch release is due.

## Development

```bash
docker build -t nut-upsd:test .
tests/smoke.sh nut-upsd:test
```

The smoke test needs no hardware. It uses NUT's `dummy-ups` driver to check:
- start-up with two UPSes and the healthcheck;
- values served over the NUT protocol;
- the config copy's permissions, and that `LOGIN` takes the right password and refuses a wrong one;
- that a dead driver is restarted while the other UPS stays served, that a driver that can't
  start (missing device) leaves the others up and recovers once its device appears, and that
  `upsd` exiting stops the container (exit 1);
- a clean `docker stop`;
- that `NUT_DEVICE_GID` reaches the running drivers' groups, also after a restart, reusing a
  group ID the image already has, and that a non-numeric value exits 64;
- refusal to start without config, or with no UPS in `ups.conf` (exit 64).

CI runs it on every push and PR, along with shellcheck and hadolint.
