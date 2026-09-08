import Foundation
import Darwin

enum Diagnostics {
    private static var directory: URL?
    private static let lock = NSLock()

    static func configure(root: URL) {
        let url = root.appendingPathComponent("build/runtime")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        directory = url
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.event("Uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "unknown")\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }
        event("Starting pid=\(getpid()) bundle=\(Bundle.main.bundleURL.path)")
    }

    // Operational events only. Never log audio, transcripts, or focused field contents.
    static func event(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let directory else { return }
        let url = directory.appendingPathComponent("app.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            try? Data().write(to: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
        }
    }

    static func status(microphone: Bool, accessibility: Bool, hotkey: Bool, model: String, activity: String) {
        guard let directory else { return }
        let values: [String: Any] = ["pid": getpid(), "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "microphone": microphone, "accessibility": accessibility, "hotkey": hotkey,
            "model": model, "activity": activity]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}

final class InstanceLock {
    private var descriptor: Int32 = -1

    func acquire(root: URL) throws -> Bool {
        let directory = root.appendingPathComponent("build/runtime")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WhispererError.message("Cannot open Whisperer's instance lock.") }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        let code = errno
        close(descriptor); descriptor = -1
        if code == EWOULDBLOCK { return false }
        throw WhispererError.message("Cannot acquire Whisperer's instance lock (\(code)).")
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
