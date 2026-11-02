# nut-upsd

Network UPS Tools (drivers + upsd) in an Alpine image, published to GHCR. See README.md.

## Branch model
- `develop` is the default branch and the target of every PR. `main` is what's released. It
  only receives promotion PRs from `develop` (opened by `.github/workflows/promote.yml`), merged
  as a merge commit or fast-forward, never squashed.
- Branch from `develop` as `<type>/<kebab-summary>`. Never commit to `main` or `develop`.
- Release, in this order: a release PR to `develop` rolls `[Unreleased]` into a
  `## [X.Y.Z] - YYYY-MM-DD` heading (state the NUT and Alpine versions); the promotion PR
  merges into `main`; **then** tag `vX.Y.Z` on `main`. `release.yml` refuses a tag whose commit
  lacks that heading (v1.1.0 was tagged before the promotion and shipped 1.0.0's code), then
  rebuilds, smoke-tests and pushes to GHCR.

## Checks (CI runs these; run them before pushing)
- `docker build -t nut-upsd:test . && tests/smoke.sh nut-upsd:test` must print `PASS`.
- `shellcheck entrypoint.sh healthcheck.sh tests/smoke.sh` and `hadolint Dockerfile` are clean.
  `noqa`-style disables only with a reason on the same or the previous line.

## Rules
- The image stays generic: no configuration, secrets, hostnames or addresses in it, or in this
  repo's docs.
- Bumping the Alpine branch (e.g. 3.23 → 3.24) changes the NUT version. Note it in the
  CHANGELOG, and check NUT's release notes for driver changes before releasing.
