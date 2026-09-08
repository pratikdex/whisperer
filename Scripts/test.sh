#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
FRAMEWORK_DIR="$PROJECT_ROOT/Vendor/build-apple/whisper.xcframework/macos-arm64_x86_64"
mkdir -p build/module-cache
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  -F "$FRAMEWORK_DIR" -framework whisper -framework AVFoundation \
  -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" Sources/Core.swift Sources/Diagnostics.swift Sources/SpeechProcess.swift Tests/main.swift -o build/core-tests
build/core-tests "$PROJECT_ROOT/build"
