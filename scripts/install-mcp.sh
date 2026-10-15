#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product everything-mcp
destination="${1:-$HOME/.local/bin}"
mkdir -p "$destination"
install -m 755 .build/release/everything-mcp "$destination/everything-mcp"
printf 'Installed %s/everything-mcp\n' "$destination"
