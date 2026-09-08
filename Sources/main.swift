import AppKit
import Foundation

let arguments = CommandLine.arguments
let root: URL
if let index = arguments.firstIndex(of: "--root"), arguments.count > index + 1 {
    root = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
} else {
    root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
}

do {
    if !arguments.contains("--transcribe") { Diagnostics.configure(root: root) }
    let config = try Configuration.load(root: root)
    if let index = arguments.firstIndex(of: "--test-worker"), arguments.count > index + 1 {
        let text = try SpeechProcess.transcribe(URL(fileURLWithPath: arguments[index + 1]), root: root,
            config: config, cancellation: CancellationFlag()) { stage, percent in
                fputs("\(stage) \(percent.map(String.init) ?? "…")\n", stderr)
            }
        print(text)
    } else if let index = arguments.firstIndex(of: "--transcribe"), arguments.count > index + 1 {
        let progressURL = arguments.firstIndex(of: "--progress").flatMap {
            arguments.count > $0 + 1 ? URL(fileURLWithPath: arguments[$0 + 1]) : nil
        }
        func report(_ stage: String, _ percent: Int?) {
            guard let progressURL else { return }
            var values: [String: Any] = ["stage": stage]
            if let percent { values["percent"] = max(0, min(100, percent)) }
            if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: progressURL, options: .atomic) }
        }
        report("Loading speech model", nil)
        let engine = SpeechEngine()
        let loaded = Date()
        try engine.load(model: config.modelURL(root: root), useGPU: !arguments.contains("--cpu"))
        let samples = try AudioSamples.read(URL(fileURLWithPath: arguments[index + 1]))
        let begin = Date()
        report("Transcribing", 0)
        let text = AudioSamples.hasSignal(samples, threshold: config.silenceThreshold) ?
            try engine.transcribe(samples, language: config.language, cancellation: CancellationFlag(),
                                  progress: { report("Transcribing", $0) }) : ""
        report("Transcribing", 100)
        let result: [String: Any] = ["text": text, "audio_seconds": Double(samples.count) / 16_000,
                                     "load_seconds": begin.timeIntervalSince(loaded),
                                     "transcribe_seconds": Date().timeIntervalSince(begin)]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let outputIndex = arguments.firstIndex(of: "--result"), arguments.count > outputIndex + 1 {
            try data.write(to: URL(fileURLWithPath: arguments[outputIndex + 1]), options: .atomic)
        }
        print(String(data: data, encoding: .utf8)!)
    } else {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(root: root, config: config)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
} catch {
    if arguments.contains("--transcribe") || arguments.contains("--test-worker") {
        fputs("Whisperer: \(error.localizedDescription)\n", stderr)
    } else {
        let app = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "Whisperer could not start"
        alert.informativeText = error.localizedDescription
        app.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    exit(1)
}
