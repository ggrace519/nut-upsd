# Changelog

## [Unreleased]

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
