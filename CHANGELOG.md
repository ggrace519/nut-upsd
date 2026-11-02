# Changelog

## [Unreleased]

## [1.1.0] - 2026-11-01
NUT 2.8.3, Alpine 3.23.

### Added
- `NUT_DEVICE_GID`: the numeric ID of the host group that owns the UPS's USB device node. The
  drivers run as `nut`, and a default host node (`root:root 0664`) can't be opened read-write,
  so a real USB UPS failed with `libusb1: Could not open any HID devices: insufficient
  permissions on everything` and the container restarted in a loop. With a host udev rule
  giving the device to a group, and that group's ID in `NUT_DEVICE_GID`, the entrypoint adds
  `nut` to a matching group before the drivers drop privileges (NUT keeps supplementary groups
  via `initgroups()`). An ID that already exists in the image is reused; a non-numeric value
  exits 64. The smoke test checks the running driver's groups in `/proc`, including after a
  restart.

## [1.0.0] - 2026-11-01
NUT 2.8.3, Alpine 3.23.

### Added
- The image: NUT 2.8.3 (UPS drivers + `upsd`) on Alpine 3.23, digest-pinned. It's the first
  NUT with EcoFlow River 3 Plus / Delta 3 Plus USB support.
  - Runs every driver in `ups.conf` and `upsd` in the foreground as `nut` under `tini`. If one
    exits, the container exits, so the restart policy recovers all of them together.
  - Config is mounted read-only at `/config` and copied to `/etc/nut` as `root:nut 0640`, so
    host files can stay root-only. `upsd` re-reads `upsd.users` as `nut`.
  - The healthcheck requires a status from every UPS in `ups.conf`.
- CI: shellcheck, hadolint, and an end-to-end smoke test with `dummy-ups` (two UPSes, values,
  permissions, login, driver death, clean stop, missing config).
- Release workflow: a `vX.Y.Z` tag on `main` publishes `ghcr.io/ggrace519/nut-upsd:X.Y.Z`
  and `:latest` with provenance and SBOM attestations.
- Updates: Dependabot covers the Alpine base and GitHub Actions. A weekly job fails when the
  published image is behind Alpine's security fixes. Promotion PRs come from the shared
  `promote` workflow.
