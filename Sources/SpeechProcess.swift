import Foundation
import Darwin

enum ProcessRunner {
    private static let lock = NSLock()
    private static var active: Process?
    private static var shuttingDown = false

    static func shutdown() {
        lock.lock(); defer { lock.unlock() }
        shuttingDown = true
        if let active, active.isRunning { _ = kill(active.processIdentifier, SIGKILL) }
    }

    // Run on the worker queue. Deadline and cancellation do not depend on Whisper/Metal callbacks.
    static func run(_ process: Process, timeout: TimeInterval, cancellation: CancellationFlag, onPoll: () -> Void = {}) throws {
        if cancellation.isCancelled { throw WhispererError.cancelled }
        lock.lock()
        if shuttingDown { lock.unlock(); throw WhispererError.cancelled }
        do { try process.run(); active = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer {
            lock.lock()
            if active === process { active = nil }
            lock.unlock()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            onPoll()
            if cancellation.isCancelled {
                stop(process)
                throw WhispererError.cancelled
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop(process)
                throw WhispererError.message("Transcription timed out. Try a shorter recording or CPU mode.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        onPoll()
        if cancellation.isCancelled { throw WhispererError.cancelled }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw WhispererError.message("Speech worker stopped unexpectedly (\(process.terminationStatus)). See build/runtime/engine.log.")
        }
    }

    private static func stop(_ process: Process) {
        // Only signal this child process, never an unrelated app or a process found by name.
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

enum SpeechProcess {
    static func transcribe(_ audio: URL, root: URL, config: Configuration, cancellation: CancellationFlag,
                           progress: @escaping (String, Int?) -> Void = { _, _ in }) throws -> String {
        guard let executable = Bundle.main.executableURL else { throw WhispererError.message("Cannot locate the speech worker.") }
        let runtime = root.appendingPathComponent("build/runtime")
        let result = runtime.appendingPathComponent("result-\(UUID().uuidString).json")
        let progressURL = runtime.appendingPathComponent("progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: result); try? FileManager.default.removeItem(at: progressURL) }
        let log = runtime.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let diagnostics = try FileHandle(forWritingTo: log)
        defer { try? diagnostics.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--root", root.path, "--transcribe", audio.path, "--result", result.path, "--progress", progressURL.path]
        if !config.useGPU { process.arguments?.append("--cpu") }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics
        process.standardInput = FileHandle.nullDevice
        Diagnostics.event("Speech worker starting backend=\(config.useGPU ? "Metal" : "CPU") timeout=\(Int(config.transcriptionTimeoutSeconds))s.")
        let started = ProcessInfo.processInfo.systemUptime
        progress("Starting speech worker", nil)
        var previous: Data?
        try ProcessRunner.run(process, timeout: config.transcriptionTimeoutSeconds, cancellation: cancellation) {
            guard let data = try? Data(contentsOf: progressURL), data != previous,
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stage = values["stage"] as? String else { return }
            previous = data
            progress(stage, values["percent"] as? Int)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any]
        guard let text = object?["text"] as? String else { throw WhispererError.message("Speech worker returned an invalid result.") }
        Diagnostics.event("Speech worker finished in \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s.")
        return text
    }
}
