# Whisperer

Local push-to-talk dictation for Apple Silicon Macs running macOS 14 or later.

**Hold Right Option → speak → release → Whisper → optional Ollama cleanup → paste.**

## Launch

The app and full `large-v3-turbo` model are built locally in this project. Run:

```sh
cd /Users/pratik/dev/whisperer
bash Scripts/run.sh
```

On first launch, use **Enable Microphone** and **Enable Accessibility** in the setup window. Enable **Whisperer** in the corresponding macOS Privacy & Security settings. If the shortcut still reports missing permission, enable Whisperer under **Input Monitoring** and relaunch. These permissions must be granted by you in macOS.

Wait for the waveform menu to say **Ready**, focus a text field, and hold **Right Option**. Speak once the **Listening** indicator appears. Release to transcribe and paste. **Escape** cancels recording or processing. Right Option is reserved for dictation; use Left Option for normal Option typing. Recordings stop automatically after 120 seconds by default.

The main window includes **Exit Whisperer**, **Cancel**, and **Open Logs**. It shows the current stage, elapsed time, and a progress bar. Transcription percentage comes directly from Whisper and can advance in large steps for short recordings; loading and cleanup use an activity indicator. Cancel stops the active dictation, and Exit terminates the app and its active speech worker. Closing the window keeps the app in the menu bar.

The waveform menu provides status, permission setup, optional cleanup, copying the last transcript, opening this folder, logs, and quitting. Launching or reopening the app shows its status window even after permissions are granted. It does not add itself to login items.

## What is local

- Native `AVAudioRecorder` records the default macOS input as 16 kHz mono PCM.
- The bundled **whisper.cpp b4938 Apple framework** runs **Whisper large-v3-turbo** in a separate worker process for each dictation. **CPU is the default**; set `useGPU` to `true` for Metal. Loading the model for each job adds some latency but lets a stalled worker be terminated without freezing the app.
- Cleanup is **off by default**. If enabled, requests go only to `http://127.0.0.1:11434/api/chat`; HTTP redirects are refused.
- Audio is temporarily written under `build/runtime/` with owner-only permissions and removed after processing or cancellation. On the next launch, stale recordings from an interrupted run are removed.
- The last transcript stays in memory until you quit. Dictated text replaces your clipboard; clipboard history tools or Universal Clipboard may retain/sync it according to your macOS setup. Whisperer itself has no telemetry or remote transcription requests.

If the original app, field, or reported text selection changes while processing, Whisperer copies the transcript instead of automatically pasting. Apps that do not expose an accessible text field also use the clipboard fallback. Paste manually with **⌘V**. Automatic paste sends **⌘V** only; it does not press Return or send a message. Visible status reports “Paste sent” because destination apps do not provide a universal acknowledgement.

## Optional Ollama cleanup

```sh
cd /Users/pratik/dev/whisperer
bash Scripts/setup-cleanup.sh
```

This starts an installed Ollama app if needed and downloads `qwen3:4b`. Then enable **Clean up with Ollama** in the Whisperer menu. The menu toggle applies to this session. Set `cleanupEnabled` in `config.json` to persist it.

The cleanup prompt preserves meaning, tone, language, and uncertainty, with thinking disabled. Timeout, HTTP errors, empty responses, obvious reasoning leakage, excessive expansion, and truncated responses fall back to the raw Whisper transcript. This is still a generative editor and can change wording incorrectly; leave it off when exact wording matters. No Qwen download is required for normal dictation.

## Configuration

Edit `config.json` and relaunch:

| Setting | Default | Meaning |
| --- | --- | --- |
| `modelPath` | `Models/ggml-large-v3-turbo.bin` | Relative to this project, or an absolute model path |
| `language` | `auto` | Auto detection or a Whisper code such as `en` or `hi`; text is not translated |
| `cleanupEnabled` | `false` | Enable local Ollama cleanup at startup |
| `cleanupModel` | `qwen3:4b` | `qwen3:4b` or `qwen3:8b`; install the chosen model in Ollama |
| `maxRecordingSeconds` | `120` | Recording limit, from 1 to 300 seconds |
| `silenceThreshold` | `0.003` | Energy gate; lower for very quiet microphones |
| `useGPU` | `false` | CPU by default; `true` enables Metal inside the isolated worker |
| `transcriptionTimeoutSeconds` | `60` | Maximum worker time, including model loading; 10–300 seconds |

The energy gate rejects short taps, clicks, and near-silence. It is not a speech classifier: background audio can still be transcribed. Set the default input device in macOS Sound settings. If very short utterances are misidentified as another language, set a fixed language.

## Build and tests

Xcode Command Line Tools are the only build prerequisite. Homebrew, Python packages, ffmpeg, and cliclick are not required.

```sh
bash Scripts/setup.sh  # Pinned framework + 1.62 GB model, SHA-256 verification, build
bash Scripts/build.sh # Rebuild Swift app only
bash Scripts/test.sh  # Audio and cleanup failure-boundary checks
```

Keep `build/Whisperer.app` in the project: it resolves `config.json` and `Models/` relative to the project root. Quit before rebuilding. Locally ad-hoc signed app updates may require removing and re-adding Whisperer in macOS Accessibility settings.

For a 16 kHz mono WAV smoke test:

```sh
build/Whisperer.app/Contents/MacOS/Whisperer \
  --root /Users/pratik/dev/whisperer --transcribe /absolute/path/sample.wav
```

Use `--cpu` for headless environments where Metal is unavailable. `--result /absolute/path/result.json` also saves the transcript and timing as JSON. These debug commands intentionally output transcript text; normal dictation does not log transcripts.

## Source layout

- `Sources/Core.swift`: configuration, audio decoding/gating, Whisper inference, local Ollama client.
- `Sources/SpeechProcess.swift`: isolated speech worker, actual progress reporting, cancellation, timeout, and exit cleanup.
- `Sources/MacIntegration.swift`: recording, global shortcut, focus checks, clipboard/paste, status overlay.
- `Sources/App.swift`: menu bar, onboarding, permissions, recording/processing/cancellation state.
- `Sources/main.swift`: app and command-line entry points.
- `Sources/Diagnostics.swift`: local operational diagnostics and an exclusive instance lock that releases automatically after exit or a crash.
- `Scripts/`: dependency setup, app build, launch, optional cleanup setup, tests.
- `Tests/`: executable boundary checks.
- `Vendor/WHISPER-LICENSE`: whisper.cpp license. Large generated dependencies, models, and build outputs are gitignored.

For startup problems, inspect `build/runtime/app.log` and `build/runtime/status.json`. The latest worker's engine diagnostics are in `build/runtime/engine.log`. Logs contain lifecycle events, inference diagnostics, and uncaught exception details, never transcript or audio content. The status file includes a timestamp, process ID, model state, and permission state; an old timestamp is not evidence that the app is still running. These files stay local. A leftover `instance.lock` file is normal and does not prevent restarting. Temporary result/progress JSON files are removed after a job, or on the next launch after an interrupted exit.

The same subprocess integration used by the UI can be checked with `build/Whisperer.app/Contents/MacOS/Whisperer --root /Users/pratik/dev/whisperer --test-worker build/jfk.wav`. This debug command intentionally prints the sample transcript and progress to the terminal.

## Upstream references

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [pinned Apple framework release](https://github.com/ggml-org/whisper.cpp/releases/tag/b4938)
- [Whisper model conversion/downloads](https://huggingface.co/ggerganov/whisper.cpp)
- [Ollama chat API](https://docs.ollama.com/api/chat), [disabling thinking](https://docs.ollama.com/capabilities/thinking)
