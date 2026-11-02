# Changelog

## [Unreleased]

### Fixed
- One UPS driver that can't start no longer takes every UPS offline (#11). All drivers ran
  under a single `upsdrvctl -F`, and the container exited when any one of them did. So with
  two or more UPSes, a UPS whose device was missing at start (unplugged, or USB passthrough
  not back after a host reboot) put the container in a restart loop that served none of
  them. A monitor-only UPS could black out the one a shutdown depends on. Each driver now
  runs in its own loop and is restarted with backoff (5 s doubling to 60 s, reset after a
  minute of running). The container exits only when `upsd` does. A down UPS is still visible:
  `upsd` reports it as not connected or stale, and the healthcheck stays unhealthy until it
  recovers. A `ups.conf` with no UPS now exits 64 at start, like missing config. The smoke
  test covers a restarted driver, a driver that can't start (and recovers when its device
  appears), and `upsd` exiting.

## [1.1.1] - 2026-11-01
NUT 2.8.3 (Alpine package `nut-2.8.3-r5`), Alpine 3.24. The release that 1.1.0 should have been.

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

### Changed
- Base image Alpine 3.23 → 3.24 (#4). NUT stays at 2.8.3 (package `-r4` → `-r5`), so driver
  support is unchanged; the smoke test passes on it.

### Fixed
- Releases: the release workflow now refuses a tag whose commit has no `## [X.Y.Z] - <date>`
  heading in `CHANGELOG.md`. `v1.1.0` was tagged on `main` before the promotion PR merged; the
  "tag is on main" check passed for that old commit, and `:1.1.0` published 1.0.0's code. The
  new check fails for exactly that case and passes for every real release.

## [1.1.0] - 2026-11-01
**Don't use.** Tagged on `main` before the promotion PR merged, so the image is 1.0.0's code
rebuilt (NUT 2.8.3, Alpine 3.23) **without `NUT_DEVICE_GID`**. Use 1.1.1.

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
