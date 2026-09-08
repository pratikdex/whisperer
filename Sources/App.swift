import AppKit
import AVFoundation
import ApplicationServices

final class AppController: NSObject, NSApplicationDelegate {
    let root: URL
    let config: Configuration
    private let worker = DispatchQueue(label: "local.whisperer.speech", qos: .userInitiated)
    private let recorder = Recorder()
    private let hotkey = Hotkey()
    private let hud = RecordingHUD()
    private var status: NSStatusItem!
    private var statusLine = NSMenuItem(title: "Loading speech model…", action: nil, keyEquivalent: "")
    private var cleanupItem: NSMenuItem!
    private var setupWindow: NSWindow?
    private var permissionLabel: NSTextField?
    private var poll: Timer?
    private var limitTimer: Timer?
    private var modelReady = false
    private var modelFailed = false
    private var recording = false
    private var processing = false
    private var target: FocusTarget?
    private var cancellation: CancellationFlag?
    private var job = UUID()
    private var cleanupEnabled: Bool
    private var lastText = ""
    private let instanceLock = InstanceLock()
    private var lastPermissionState = ""
    private let progressHeading = NSTextField(labelWithString: "Ready")
    private let progressDescription = NSTextField(labelWithString: "Hold Right Option to start dictating.")
    private let progressBar = NSProgressIndicator()
    private var cancelButton: NSButton?
    private var stage = "Ready"
    private var stageDetail = "Hold Right Option to start dictating."
    private var stagePercent: Double?
    private var operationStarted: TimeInterval?

    init(root: URL, config: Configuration) {
        self.root = root; self.config = config; self.cleanupEnabled = config.cleanupEnabled
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard try instanceLock.acquire(root: root) else {
                Diagnostics.event("Another instance owns the project lock; exiting.")
                NSApp.terminate(nil); return
            }
        } catch {
            showError(error.localizedDescription)
            NSApp.terminate(nil); return
        }
        Diagnostics.event("Application launched; instance lock acquired.")
        // Remove only this app's stale recordings after an interrupted previous run.
        let runtime = root.appendingPathComponent("build/runtime")
        if let files = try? FileManager.default.contentsOfDirectory(at: runtime, includingPropertiesForKeys: nil) {
            for file in files where (file.lastPathComponent.hasPrefix("recording-") && file.pathExtension == "wav") ||
                ((file.lastPathComponent.hasPrefix("result-") || file.lastPathComponent.hasPrefix("progress-")) && file.pathExtension == "json") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        add("Setup & Permissions…", #selector(showSetup), to: menu)
        cleanupItem = add("Clean up with Ollama", #selector(toggleCleanup), to: menu)
        cleanupItem.state = cleanupEnabled ? .on : .off
        add("Copy Last Transcript", #selector(copyLast), to: menu)
        add("Open Project Folder", #selector(openProject), to: menu)
        add("Open Logs", #selector(openLogs), to: menu)
        menu.addItem(.separator())
        add("Quit Whisperer", #selector(quit), to: menu, key: "q")
        status.menu = menu
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancel), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancel), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        refreshPermissions()
        // Opening an accessory app must present a window even after permissions are granted.
        showSetup()
        worker.async {
            do {
                let model = self.config.modelURL(root: self.root)
                guard FileManager.default.isReadableFile(atPath: model.path),
                      (try model.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1_000_000 else {
                    throw WhispererError.message("Speech model is missing or incomplete. Run Scripts/setup.sh.")
                }
                DispatchQueue.main.async {
                    Diagnostics.event("Speech model file ready; isolated worker backend=\(self.config.useGPU ? "Metal" : "CPU").")
                    self.modelReady = true; self.refreshPermissions()
                }
            } catch {
                DispatchQueue.main.async {
                    self.modelFailed = true
                    Diagnostics.event("Speech model failed to load.")
                    self.statusLine.title = error.localizedDescription
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    @discardableResult private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item); return item
    }

    private func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if ax { _ = hotkey.install() } else { hotkey.uninstall() }
        if (!ax || !mic) && (recording || processing) { cancel() }
        let permissions = "microphone=\(mic) accessibility=\(ax) hotkey=\(hotkey.installed)"
        if permissions != lastPermissionState { Diagnostics.event(permissions); lastPermissionState = permissions }
        Diagnostics.status(microphone: mic, accessibility: ax, hotkey: hotkey.installed,
                           model: modelReady ? "ready" : (modelFailed ? "failed" : "checking"),
                           activity: recording ? "recording" : (processing ? "processing" : "idle"))
        permissionLabel?.stringValue = "Microphone: \(mic ? "enabled" : "permission needed")\nAccessibility: \(ax ? "enabled" : "permission needed")\nShortcut: \(hotkey.installed ? "ready" : "permission needed")\nSpeech model: \(modelReady ? "ready (\(config.useGPU ? "Metal" : "CPU"))" : (modelFailed ? "unavailable" : "checking…"))"
        if !recording && !processing && !modelFailed {
            status.button?.title = ""
            status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisperer")
            statusLine.title = !modelReady ? "Loading speech model…" : (ax && mic && hotkey.installed ? "Ready — hold Right Option to talk" : "Setup needed — open permissions")
            status.button?.toolTip = statusLine.title
        }
        renderProgress()
    }

    private func setProgress(_ title: String, detail: String, percent: Double? = nil) {
        stage = title; stageDetail = detail; stagePercent = percent
        renderProgress()
    }

    private func renderProgress() {
        let busy = recording || processing
        let elapsed = operationStarted.map { max(0, Int(ProcessInfo.processInfo.systemUptime - $0)) } ?? 0
        let percent = recording ? min(100, Double(elapsed) / config.maxRecordingSeconds * 100) : stagePercent
        progressHeading.stringValue = stage + ((processing && percent != nil) ? " · \(Int(percent!))%" : "")
        progressDescription.stringValue = stageDetail + (busy ? " · \(elapsed)s elapsed" : "")
        progressDescription.toolTip = progressDescription.stringValue
        progressBar.isIndeterminate = busy && percent == nil
        if progressBar.isIndeterminate { progressBar.startAnimation(nil) }
        else { progressBar.stopAnimation(nil); progressBar.doubleValue = percent ?? 0 }
        cancelButton?.isEnabled = busy
        if processing { statusLine.title = progressHeading.stringValue + " · \(elapsed)s" }
    }

    @objc func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 590),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Whisperer 1.3"
            window.isReleasedWhenClosed = false
            window.center()
            let view = window.contentView!
            let title = NSTextField(labelWithString: "Speak. Release. Keep writing.")
            title.font = .systemFont(ofSize: 25, weight: .semibold)
            title.frame = NSRect(x: 28, y: 524, width: 504, height: 34)
            view.addSubview(title)
            let intro = NSTextField(wrappingLabelWithString: "Hold Right Option in any text field, speak, then release. Whisper transcribes on your Mac. Press Escape to cancel. The waveform icon in the menu bar shows status.")
            intro.frame = NSRect(x: 28, y: 443, width: 504, height: 66)
            intro.font = .systemFont(ofSize: 14)
            view.addSubview(intro)
            let permissions = NSTextField(wrappingLabelWithString: "")
            permissions.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            permissions.frame = NSRect(x: 28, y: 347, width: 504, height: 85)
            view.addSubview(permissions); permissionLabel = permissions
            let mic = NSButton(title: "Enable Microphone", target: self, action: #selector(requestMic))
            mic.frame = NSRect(x: 24, y: 296, width: 242, height: 34)
            let access = NSButton(title: "Enable Accessibility", target: self, action: #selector(requestAccessibility))
            access.frame = NSRect(x: 282, y: 296, width: 252, height: 34)
            view.addSubview(mic); view.addSubview(access)
            let note = NSTextField(wrappingLabelWithString: "Enable Whisperer in macOS Privacy & Security. If the shortcut still needs permission, enable Whisperer under Input Monitoring and relaunch. Text replaces the clipboard; if focus changes, paste it yourself with ⌘V.")
            note.font = .systemFont(ofSize: 12)
            note.textColor = .secondaryLabelColor
            note.frame = NSRect(x: 28, y: 212, width: 504, height: 68)
            view.addSubview(note)
            let separator = NSBox(frame: NSRect(x: 28, y: 200, width: 504, height: 1))
            separator.boxType = .separator
            view.addSubview(separator)
            progressHeading.font = .systemFont(ofSize: 17, weight: .semibold)
            progressHeading.frame = NSRect(x: 28, y: 161, width: 504, height: 25)
            progressDescription.font = .systemFont(ofSize: 12)
            progressDescription.textColor = .secondaryLabelColor
            progressDescription.frame = NSRect(x: 28, y: 136, width: 504, height: 20)
            progressBar.style = .bar
            progressBar.minValue = 0; progressBar.maxValue = 100
            progressBar.frame = NSRect(x: 28, y: 109, width: 504, height: 16)
            progressBar.setAccessibilityLabel("Dictation progress")
            view.addSubview(progressHeading); view.addSubview(progressDescription); view.addSubview(progressBar)
            let logs = NSButton(title: "Open Logs", target: self, action: #selector(openLogs))
            logs.frame = NSRect(x: 24, y: 27, width: 120, height: 34)
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
            cancel.frame = NSRect(x: 286, y: 27, width: 116, height: 34)
            cancel.isEnabled = false; cancelButton = cancel
            let exit = NSButton(title: "Exit Whisperer", target: self, action: #selector(quit))
            exit.frame = NSRect(x: 406, y: 27, width: 130, height: 34)
            view.addSubview(logs); view.addSubview(cancel); view.addSubview(exit)
            setupWindow = window
        }
        refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func requestMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refreshPermissions() } }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func startRecording() {
        guard !recording && !processing else { return }
        guard modelReady else { hud.show("Speech model is loading", detail: "Try again when the menu says Ready.", dismissAfter: 3); return }
        guard AXIsProcessTrusted(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.show("Permission needed", detail: "Open Setup & Permissions from the menu bar.", dismissAfter: 4); return
        }
        target = FocusTarget.current()
        guard target?.secure != true else {
            hud.show("Password field", detail: "Choose a regular text field to dictate.", dismissAfter: 3); return
        }
        do {
            try recorder.start(in: root.appendingPathComponent("build/runtime"))
            Diagnostics.event("Recording started.")
            recording = true; hotkey.busy = true
            operationStarted = ProcessInfo.processInfo.systemUptime
            setProgress("Listening", detail: "Release Right Option to transcribe")
            job = UUID(); cancellation = CancellationFlag()
            status.button?.image = nil; status.button?.title = "● REC"
            statusLine.title = "Recording — release Right Option to finish"
            hud.show("● Listening", detail: "Release Right Option to finish · Esc to cancel")
            limitTimer = Timer.scheduledTimer(withTimeInterval: config.maxRecordingSeconds, repeats: false) { [weak self] _ in self?.finishRecording() }
        } catch { showError(error.localizedDescription) }
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false; processing = true
        Diagnostics.event("Recording stopped; processing started.")
        limitTimer?.invalidate(); limitTimer = nil
        guard let url = recorder.stop(), let flag = cancellation else { processing = false; hotkey.busy = false; return }
        let currentJob = job
        let shouldClean = cleanupEnabled
        status.button?.title = "…"
        statusLine.title = "Transcribing locally…"
        hud.show("Transcribing…", detail: "Whisper on your Mac · Esc to cancel")
        operationStarted = ProcessInfo.processInfo.systemUptime
        setProgress("Preparing audio", detail: "Local transcription · Cancel or Exit at any time")
        worker.async {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let samples = try AudioSamples.read(url)
                guard AudioSamples.hasSignal(samples, threshold: self.config.silenceThreshold) else {
                    DispatchQueue.main.async { self.completeEmpty(currentJob) }; return
                }
                let raw = try SpeechProcess.transcribe(url, root: self.root, config: self.config, cancellation: flag) { stage, percent in
                    DispatchQueue.main.async {
                        guard self.job == currentJob, self.processing else { return }
                        self.setProgress(stage, detail: "\(self.config.useGPU ? "Metal" : "CPU") · \(Int(self.config.transcriptionTimeoutSeconds))s timeout", percent: percent.map(Double.init))
                        self.hud.show(stage + (percent.map { " · \($0)%" } ?? "…"), detail: "Whisper on your Mac · Esc to cancel")
                    }
                }
                guard !raw.isEmpty else { DispatchQueue.main.async { self.completeEmpty(currentJob) }; return }
                var text = raw
                var cleanupFailed = false
                if shouldClean && !flag.isCancelled {
                    DispatchQueue.main.async {
                        guard self.job == currentJob else { return }
                        self.statusLine.title = "Cleaning up locally…"
                        self.setProgress("Cleaning up", detail: "Ollama on your Mac")
                        self.hud.show("Cleaning up…", detail: "Ollama on your Mac · Esc to cancel")
                    }
                    do { text = try TextCleanup.run(raw, model: self.config.cleanupModel, cancellation: flag) }
                    catch { cleanupFailed = true }
                }
                guard !flag.isCancelled else { return }
                let result = text
                let fallback = cleanupFailed
                DispatchQueue.main.async { self.deliver(result, job: currentJob, cleanupFailed: fallback) }
            } catch {
                DispatchQueue.main.async {
                    guard self.job == currentJob else { return }
                    self.processing = false; self.hotkey.busy = false
                    self.cancellation = nil
                    Diagnostics.event("Transcription failed: \(error.localizedDescription)")
                    self.setProgress("Transcription stopped", detail: error.localizedDescription)
                    self.refreshPermissions()
                    self.hud.show("Transcription stopped", detail: error.localizedDescription, dismissAfter: 8)
                }
            }
        }
    }

    private func completeEmpty(_ id: UUID) {
        guard job == id else { return }
        processing = false; hotkey.busy = false
        setProgress("No speech detected", detail: "Hold Right Option and speak a little longer.")
        hud.show("No speech detected", detail: "Hold Right Option and speak a little longer.", dismissAfter: 3)
        refreshPermissions()
    }

    private func deliver(_ text: String, job id: UUID, cleanupFailed: Bool, attempt: Int = 0) {
        guard job == id, processing else { return }
        if PasteOutput.modifiersHeld && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.deliver(text, job: id, cleanupFailed: cleanupFailed, attempt: attempt + 1)
            }
            return
        }
        lastText = text
        setProgress("Pasting", detail: "Checking the original text field", percent: 100)
        PasteOutput.copy(text)
        let canPaste = !PasteOutput.modifiersHeld && target?.stillFocused() == true
        let pasted = canPaste && PasteOutput.paste()
        Diagnostics.event(pasted ? "Paste event sent." : "Clipboard fallback used.")
        processing = false; hotkey.busy = false; cancellation = nil
        setProgress(pasted ? "Paste sent" : "Transcript copied", detail: pasted ? "Ready for your next thought." : "Choose a text field and press ⌘V.", percent: 100)
        hud.show(pasted ? "Paste sent" : "Transcript copied", detail: pasted ?
                 (cleanupFailed ? "Used Whisper text — Ollama unavailable." : "Ready for your next thought.") :
                 "Focus changed or couldn't be verified. Press ⌘V.", dismissAfter: 3)
        refreshPermissions()
    }

    @objc private func cancel() {
        guard recording || processing else { return }
        cancellation?.cancel(); cancellation = nil; job = UUID()
        recorder.cancel()
        limitTimer?.invalidate(); limitTimer = nil
        recording = false; processing = false; hotkey.busy = false
        setProgress("Cancelled", detail: "Nothing was pasted. Ready to try again.")
        hud.show("Cancelled", detail: "Nothing was pasted.", dismissAfter: 2)
        refreshPermissions()
    }

    private func showError(_ message: String) {
        Diagnostics.event("App reported an error; see the displayed alert.")
        hud.dismiss()
        let alert = NSAlert()
        alert.messageText = "Whisperer"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle(); cleanupItem.state = cleanupEnabled ? .on : .off
    }
    @objc private func copyLast() { if !lastText.isEmpty { PasteOutput.copy(lastText) } }
    @objc private func openProject() { NSWorkspace.shared.open(root) }
    @objc private func openLogs() { NSWorkspace.shared.open(root.appendingPathComponent("build/runtime")) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.event("Application terminating normally.")
        ProcessRunner.shutdown()
        cancellation?.cancel(); recorder.cancel(); hotkey.uninstall(); poll?.invalidate(); limitTimer?.invalidate()
    }
}
