#!/usr/bin/env bash
# Runs the MeshCore package tests. Works with full Xcode or with only the Command Line Tools
# (CLT ships Swift Testing outside the default search path, so we add it explicitly).
set -euo pipefail
cd "$(dirname "$0")/../Packages/MeshCore"
EXTRA=()
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.*\.app"; then
  FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  EXTRA=(-Xswiftc -F"$FW" -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB")
fi
swift test "${EXTRA[@]}" "$@"
