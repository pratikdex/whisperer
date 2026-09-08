import Foundation
import AVFoundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}

let silence = [Float](repeating: 0, count: 16_000)
expect(!AudioSamples.hasSignal(silence, threshold: 0.003), "silence must not reach Whisper")
let quiet = [Float](repeating: 0.0001, count: 16_000)
expect(!AudioSamples.hasSignal(quiet, threshold: 0.003), "quiet input must be gated")
expect(!AudioSamples.hasSignal([Float](repeating: 0.2, count: 1000), threshold: 0.003), "brief hotkey taps must be gated")
var impulse = silence
impulse[4000] = 1
expect(!AudioSamples.hasSignal(impulse, threshold: 0.003), "one click must not be speech")
let step: Double = 440.0 * 2.0 * Double.pi / 16_000.0
let tone: [Float] = (0..<16_000).map { index in Float(sin(Double(index) * step) * 0.1) }
expect(AudioSamples.hasSignal(tone, threshold: 0.003), "audible input must pass energy gate")

let raw = "uh I will probably reach around seven but traffic might make me late"
expect(TextCleanup.accepted("I’ll probably reach around seven, but traffic might make me late.", original: raw) != nil, "normal cleanup accepted")
expect(TextCleanup.accepted("", original: raw) == nil, "empty response rejected")
expect(TextCleanup.accepted("<think>reasoning</think> Sure!", original: raw) == nil, "reasoning leakage rejected")
expect(TextCleanup.accepted("```text\nHello\n```", original: raw) == nil, "markdown answer rejected")
expect(TextCleanup.accepted(String(repeating: "added information ", count: 40), original: raw) == nil, "excessive expansion rejected")
expect(TextCleanup.accepted("Ok.", original: raw) == nil, "severe truncation rejected")
let flag = CancellationFlag()
expect(!flag.isCancelled, "initial cancellation state")
flag.cancel()
expect(flag.isCancelled, "cancellation state set")

let temp = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("test-audio.wav")
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
do {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
    buffer.frameLength = 16_000
    tone.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    do {
        let file = try AVAudioFile(forWriting: temp, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try file.write(from: buffer)
    }
    let decoded = try AudioSamples.read(temp)
    expect(decoded.count == 16_000, "16k PCM duration preserved")
    expect(abs(decoded[100] - tone[100]) < 0.0001, "PCM samples preserved")
    try FileManager.default.removeItem(at: temp)
    let wrongFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    do {
        let file = try AVAudioFile(forWriting: temp, settings: wrongFormat.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: wrongFormat, frameCapacity: 4410)!
        buffer.frameLength = 4410
        try file.write(from: buffer)
    }
    var rejected = false
    do { _ = try AudioSamples.read(temp) } catch { rejected = true }
    expect(rejected, "wrong sample rate rejected rather than silently distorted")
    try FileManager.default.removeItem(at: temp)
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
// A stale lock file must not prevent reopening after a crash, and a live instance must be exclusive.
let lockRoot = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("lock-test-\(UUID().uuidString)")
do {
    do {
        let first = InstanceLock()
        let second = InstanceLock()
        let acquiredFirst = try first.acquire(root: lockRoot)
        let acquiredSecond = try second.acquire(root: lockRoot)
        expect(acquiredFirst, "first instance owns the lock")
        expect(!acquiredSecond, "second instance is rejected")
        withExtendedLifetime(first) {}
    }
    let replacement = InstanceLock()
    let acquiredReplacement = try replacement.acquire(root: lockRoot)
    expect(acquiredReplacement, "a remaining lock file does not block restart")
    withExtendedLifetime(replacement) {}
    try FileManager.default.removeItem(at: lockRoot)
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
func sleeper() -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["5"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return process
}
let stalled = sleeper()
let start = ProcessInfo.processInfo.systemUptime
var timedOut = false
do { try ProcessRunner.run(stalled, timeout: 0.15, cancellation: CancellationFlag()) }
catch { timedOut = error.localizedDescription.contains("timed out") }
expect(timedOut, "unresponsive worker reports timeout")
expect(!stalled.isRunning, "timed-out worker is terminated")
expect(ProcessInfo.processInfo.systemUptime - start < 3, "timeout does not block indefinitely")
let cancelledWorker = sleeper()
let cancelFlag = CancellationFlag()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { cancelFlag.cancel() }
var cancelled = false
do { try ProcessRunner.run(cancelledWorker, timeout: 5, cancellation: cancelFlag) }
catch WhispererError.cancelled { cancelled = true }
catch {}
expect(cancelled && !cancelledWorker.isRunning, "cancellation stops an active worker")
let succeeds = Process()
succeeds.executableURL = URL(fileURLWithPath: "/usr/bin/true")
do {
    try ProcessRunner.run(succeeds, timeout: 2, cancellation: CancellationFlag())
    expect(succeeds.terminationStatus == 0, "a new job works after timeout and cancellation")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
let legacyConfig = try! JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
expect(!legacyConfig.useGPU && legacyConfig.transcriptionTimeoutSeconds == 60, "older configs default to CPU and bounded inference")
print("Passed \(checks) checks.")
