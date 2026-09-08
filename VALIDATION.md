# Validation

Checked on this Apple Silicon Mac on 2026-09-07.

- Swift release build succeeded; app bundle and embedded framework passed code-signature verification.
- Framework archive SHA-256 matches the official GitHub release digest.
- Full large-v3-turbo model SHA-256 matches its Hugging Face LFS object hash.
- All 19 executable boundary checks passed: audio decoding, sample-rate validation, silence/short-tap/click rejection, cleanup response rejection, cancellation flag behavior, single-instance exclusion, and restart with a stale lock file.
- The upstream 11-second JFK audio sample transcribed correctly on CPU in 4.86 seconds, with 0.60 seconds to load the model and audio. This is a sample measurement, not a latency guarantee.
- The native app launched through macOS, its setup layout was visually checked, and the model loaded successfully with the default Metal configuration.
- Running Metal from the restricted command sandbox failed to allocate a GPU buffer. The command-line smoke test therefore used `--cpu`; normal app loading succeeded.
- Live Right Option recording and automatic paste still need validation after macOS Accessibility permission is enabled. Microphone permission was shown as enabled in the app.
- Optional Ollama integration is implemented but was not run against Qwen: the local Ollama service was not running, and cleanup remains disabled.

## Version 1.3 follow-up

- The older process was still running version 1.0, launched before the rebuild. It was quit through Activity Monitor, and version 1.3 launched successfully through macOS.
- Exit, Cancel, Open Logs, the progress indicator, and the updated window were verified through the native accessibility tree and a screenshot.
- Clicking **Exit Whisperer** logged normal termination. Reopening produced a new process ID and acquired the instance lock successfully.
- All **25 checks passed**, including forced worker timeout, cancellation of an active child, recovery on the next job, and backwards-compatible configuration defaults.
- The UI's subprocess transcription path correctly transcribed the public 11-second JFK sample in **5.15 seconds** on CPU, reported actual loading/transcription progress, and removed temporary result and progress files.
- Transcription now runs in an isolated worker with a 60-second default timeout. Runtime errors update the visible state rather than leaving a stale Transcribing overlay. CPU is the default; Metal is configurable.
- This rebuilt app is open and producing fresh lifecycle/status logs. macOS reports microphone and Accessibility permissions as missing for the new signature, so live microphone-to-paste verification still requires re-enabling those permissions.
- The earlier SIGABRT report has no usable backtrace; its underlying cause was not established. The timeout and error-state changes address the observed indefinite wait without assuming a confirmed Metal failure.

Re-run `bash Scripts/test.sh` for boundary checks. The sample transcript and timing are in `build/smoke-result.json`; engine diagnostics are in `build/smoke-engine.log`. These files contain only the public test sample, not microphone audio.
