#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Process fixtures create isolated IndexCache files; the app's cache is never used.
swift test -c release --filter EverythingCLITests
