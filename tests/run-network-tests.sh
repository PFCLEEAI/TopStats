#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/topstats-network-tests"

swiftc -O -D NETWORK_TESTS \
  "$ROOT/TopStats.swift" "$ROOT/tests/main.swift" \
  -framework Cocoa -framework SwiftUI -framework IOKit \
  -o "$BIN"

"$BIN" "$@"
