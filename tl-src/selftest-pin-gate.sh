#!/usr/bin/env bash
# Boot-PIN gate selftest (hash/verify, unset=open, locked/unlocked, /run reset, backoff, wiring).
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/selftest-pin-gate.py"
