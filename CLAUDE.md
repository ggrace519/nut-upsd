# nut-upsd

Network UPS Tools (drivers + upsd) in an Alpine image, published to GHCR. See README.md.

## Branch model
- `develop` is the default branch and the target of every PR. `main` is what's released. It
  only receives promotion PRs from `develop` (opened by `.github/workflows/promote.yml`), merged
  as a merge commit or fast-forward, never squashed.
- Branch from `develop` as `<type>/<kebab-summary>`. Never commit to `main` or `develop`.
- Release: a release PR to `develop` rolls `[Unreleased]` into a `## [X.Y.Z] - YYYY-MM-DD`
  heading (state the NUT and Alpine versions); merging the promotion PR into `main` releases it.
  `release.yml` (the shared `ggrace519/.github` release workflow) tags `vX.Y.Z` and publishes the
  GitHub release from that section, then rebuilds, smoke-tests and pushes the image to GHCR. On
  the promotion PR it is a dry run that fails while `[Unreleased]` has entries or the top
  version is already tagged. Never tag by hand.

## Checks (CI runs these; run them before pushing)
- `docker build -t nut-upsd:test . && tests/smoke.sh nut-upsd:test` must print `PASS`.
- `shellcheck entrypoint.sh healthcheck.sh tests/smoke.sh` and `hadolint Dockerfile` are clean.
  `noqa`-style disables only with a reason on the same or the previous line.

## Rules
- The image stays generic: no configuration, secrets, hostnames or addresses in it, or in this
  repo's docs.
- Bumping the Alpine branch (e.g. 3.23 → 3.24) changes the NUT version. Note it in the
  CHANGELOG, and check NUT's release notes for driver changes before releasing.
