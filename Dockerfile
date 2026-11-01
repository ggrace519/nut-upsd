# Network UPS Tools (driver + upsd) from Alpine's package.
# Generic: no configuration or secrets are baked in. Mount a NUT config directory at /config
# (read-only); the entrypoint copies it to /etc/nut with ownership NUT can read.
FROM alpine:3.23@sha256:ff7f0c727dd796aa36787bfcd9a64bf35a6ce72a73451b3359fde849b6703d63

# Alpine 3.23 ships NUT 2.8.3, the first release with EcoFlow River 3 Plus / Delta 3 Plus
# support (usbhid-ups, USB ID 3746:ffff).
# Packages are deliberately unpinned: the base image is digest-pinned, and within the 3.23
# branch an unpinned add is what picks up Alpine's security fixes on rebuild.
# hadolint ignore=DL3018
RUN apk add --no-cache nut tini \
 && rm -f /etc/nut/*

COPY --chmod=0755 entrypoint.sh /usr/local/bin/nut-entrypoint
COPY --chmod=0755 healthcheck.sh /usr/local/bin/nut-healthcheck

ARG VERSION=dev
LABEL org.opencontainers.image.title="nut-upsd" \
      org.opencontainers.image.description="Network UPS Tools driver + upsd on Alpine" \
      org.opencontainers.image.source="https://github.com/ggrace519/nut-upsd" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.23"

EXPOSE 3493
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/nut-healthcheck"]

# tini -g forwards signals to the whole process group, so docker stop reaches the drivers
# and upsd directly.
ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/nut-entrypoint"]
