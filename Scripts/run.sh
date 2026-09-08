#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -x "$PROJECT_ROOT/build/Whisperer.app/Contents/MacOS/Whisperer" ]]; then
  bash "$PROJECT_ROOT/Scripts/build.sh"
fi
if ! open "$PROJECT_ROOT/build/Whisperer.app"; then
  echo "macOS Launch Services could not open Whisperer. The app is at:" >&2
  echo "$PROJECT_ROOT/build/Whisperer.app" >&2
  echo 'Try opening it in Finder from your regular desktop session. A restricted command sandbox may report a misleading missing-executable error.' >&2
  exit 1
fi
