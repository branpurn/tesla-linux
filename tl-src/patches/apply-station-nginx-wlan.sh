#!/usr/bin/env bash
# Apply station nginx-bind IPv4 wait into tl-src/tesla-linux-wlan.sh
# Usage (from repo root):
#   bash tl-src/patches/apply-station-nginx-wlan.sh
#   bash -n tl-src/tesla-linux-wlan.sh
#   git add tl-src/tesla-linux-wlan.sh && git commit -m 'fix(wlan): wait for station DHCP IPv4 before nginx-bind'
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
PATCH="$ROOT/tl-src/patches/station-nginx-bind-ipv4.patch"
if [ ! -f "$PATCH" ]; then
  PATCH="$ROOT/tl-src/patches/station-nginx-bind.patch"
fi
if [ ! -f "$PATCH" ]; then
  echo "missing patch under tl-src/patches/" >&2
  exit 1
fi
# Idempotent: skip if already applied
if grep -q '^wait_station_ipv4()' tl-src/tesla-linux-wlan.sh; then
  echo "wait_station_ipv4 already present; nothing to do"
  bash -n tl-src/tesla-linux-wlan.sh
  exit 0
fi
patch -p1 < "$PATCH"
bash -n tl-src/tesla-linux-wlan.sh
echo "applied $PATCH; bash -n OK — commit tl-src/tesla-linux-wlan.sh and push"
