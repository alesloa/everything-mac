#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# JSON-RPC process fixtures use temporary caches, never the app's saved index.
swift test -c release --filter EverythingMCPTests
