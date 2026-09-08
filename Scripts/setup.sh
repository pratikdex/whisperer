#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p Vendor Models build
VERSION=b4938
ARCHIVE="Vendor/whisper-${VERSION}-xcframework.zip"
FRAMEWORK_SHA=dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd
MODEL_SHA=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
if [[ ! -f "$ARCHIVE" ]]; then
  curl -fL --retry 3 "https://github.com/ggml-org/whisper.cpp/releases/download/${VERSION}/whisper-${VERSION}-xcframework.zip" -o "$ARCHIVE.part"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
echo "$FRAMEWORK_SHA  $ARCHIVE" | shasum -a 256 -c -
if [[ ! -d Vendor/build-apple/whisper.xcframework ]]; then ditto -x -k "$ARCHIVE" Vendor; fi
MODEL=Models/ggml-large-v3-turbo.bin
if [[ ! -f "$MODEL" ]]; then
  curl -fL --retry 3 -C - https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin -o "$MODEL.part"
  echo "$MODEL_SHA  $MODEL.part" | shasum -a 256 -c -
  mv "$MODEL.part" "$MODEL"
else
  echo "$MODEL_SHA  $MODEL" | shasum -a 256 -c -
fi
bash Scripts/build.sh
