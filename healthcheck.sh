#!/bin/sh
# Healthy only if upsd answers for every UPS defined in ups.conf with a status, i.e. each
# driver is connected and reporting.
set -eu

ups_list=$(sed -n 's/^[[:space:]]*\[\([^]]*\)\][[:space:]]*$/\1/p' /etc/nut/ups.conf)
[ -n "$ups_list" ] || exit 1

for ups in $ups_list; do
  status=$(upsc "$ups@127.0.0.1" ups.status 2>/dev/null) || exit 1
  [ -n "$status" ] || exit 1
done
