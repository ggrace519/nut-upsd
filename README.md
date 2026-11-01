# nut-upsd

[Network UPS Tools](https://networkupstools.org/) (the UPS drivers plus `upsd`) in a small
Alpine image, so a host whose distribution ships an older NUT can still run a current one.

- **NUT 2.8.3** from Alpine 3.23. That's the first release that supports EcoFlow's River 3
  Plus and Delta 3 Plus over USB (`usbhid-ups`, USB ID `3746:ffff`).
- Runs the drivers from `ups.conf` and `upsd`, both as the `nut` user. If any of them exits,
  the container exits, so your restart policy brings the whole set back. A dead driver can't
  hide behind a running `upsd`.
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
  ghcr.io/ggrace519/nut-upsd:1.0.0
```

- **`/config`** must contain `ups.conf`, `upsd.conf` and `upsd.users`. `nut.conf` and anything
  your drivers reference, such as `dummy-ups` `.dev` files, are copied too. The files can stay
  root-only (`0600`) on the host: at start the entrypoint copies them to `/etc/nut` as
  `root:nut 0640`, because `upsd` re-reads `upsd.users` after dropping to `nut`. **Restart the
  container to apply config changes.**
- **USB:** bind-mount `/dev/bus/usb` and allow USB character devices (major 189) with the
  cgroup rule. This survives the device re-enumerating after a replug or reboot. `--device`
  only snapshots the device node that exists when the container is created.
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

- `ghcr.io/ggrace519/nut-upsd:<version>` and `:latest` are published for each `vX.Y.Z` tag on
  `main`, with provenance and SBOM attestations. The image version is independent of the NUT
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
- the config copy's permissions and a login;
- that a dead driver stops the container;
- a clean `docker stop`;
- refusal to start without config.

CI runs it on every push and PR, along with shellcheck and hadolint.
