#!/usr/bin/env python3
"""Copy the resolved MCP runtime dependencies' own license/notice files."""
import json
import shutil
import sys
from pathlib import Path


def main():
    checkout_root, destination = map(Path, sys.argv[1:])
    project_root = Path(__file__).resolve().parent.parent
    resolved = json.loads((project_root / "Package.resolved").read_text())
    pins = {pin["identity"]: pin for pin in resolved["pins"]}
    # Source: the pinned Swift SDK's MCP target dependencies in Package.swift.
    dependencies = ["swift-sdk", "swift-system", "swift-log", "eventsource"]
    sources = []
    for name in dependencies:
        source = checkout_root / name
        files = sorted(path for path in source.iterdir()
                       if path.is_file() and path.name.upper().startswith(("LICENSE", "NOTICE", "COPYING")))
        if not any(path.name.upper().startswith("LICENSE") for path in files):
            raise SystemExit(f"No dependency license found in {source}")
        target = destination / name
        target.mkdir(parents=True, exist_ok=True)
        for path in files:
            shutil.copy2(path, target / path.name)
        pin = pins[name]
        sources.append({"package": name, "repository": pin["location"], **pin["state"]})
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "sources.json").write_text(json.dumps(sources, indent=2) + "\n")


if __name__ == "__main__":
    main()
