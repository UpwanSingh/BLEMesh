#!/usr/bin/env bash
# Sync the string catalogs with the strings in the last build (run after building both schemes),
# then fill in Hindi. Usage: scripts/sync-strings.sh [derived-data-path]
set -euo pipefail
DD="${1:-.build/dd}"
app=$(find "$DD" -name "*.stringsdata" -path "*/BLEMesh.build/*" | grep -v "/BLEMeshTests.build/\|/BLEMeshUITests.build/\|/BLEMeshWatch" || true)
watch=$(find "$DD" -name "*.stringsdata" -path "*/BLEMeshWatch.build/*" || true)
[ -n "$app" ] && xcrun xcstringstool sync BLEMesh/Resources/Localizable.xcstrings --stringsdata $app
[ -n "$watch" ] && xcrun xcstringstool sync BLEMeshWatch/Localizable.xcstrings --stringsdata $watch
python3 scripts/hindi.py
