#!/bin/bash
set -euo pipefail
OLLAMA_BIN="$(command -v ollama || true)"
if [[ -z "$OLLAMA_BIN" ]]; then
  echo 'Install Ollama for macOS from https://ollama.com/download, then run this again.' >&2
  exit 1
fi
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null; then
  open -a Ollama
  for ((attempt=0; attempt<30; attempt++)); do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then break; fi
    sleep 1
  done
fi
"$OLLAMA_BIN" pull qwen3:4b
echo 'Ready. Enable “Clean up with Ollama” in the Whisperer menu.'
