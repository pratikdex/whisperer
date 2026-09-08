#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
FRAMEWORK_DIR="$PROJECT_ROOT/Vendor/build-apple/whisper.xcframework/macos-arm64_x86_64"
APP="$PROJECT_ROOT/build/Whisperer.app"
if [[ ! -d "$FRAMEWORK_DIR/whisper.framework" ]]; then
  echo 'Missing whisper framework. Run Scripts/setup.sh first.' >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" build/module-cache
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Whisperer</string>
<key>CFBundleIdentifier</key><string>local.whisperer.app</string>
<key>CFBundleName</key><string>Whisperer</string>
<key>CFBundleDisplayName</key><string>Whisperer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Whisperer records while you hold Right Option to transcribe speech locally on your Mac.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
ditto "$FRAMEWORK_DIR/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$PROJECT_ROOT/build/module-cache" \
  -F "$FRAMEWORK_DIR" -framework whisper -framework AppKit -framework AVFoundation \
  -framework ApplicationServices -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/Core.swift Sources/Diagnostics.swift Sources/SpeechProcess.swift Sources/MacIntegration.swift Sources/App.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/Whisperer"
codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign - --identifier local.whisperer.app "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
