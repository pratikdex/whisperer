import AppKit
import AVFoundation
import ApplicationServices

final class Recorder {
    private var recorder: AVAudioRecorder?
    private var file: URL?

    func start(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("recording-\(UUID().uuidString).wav")
        let recording = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard recording.prepareToRecord(), recording.record() else {
            try? FileManager.default.removeItem(at: url)
            throw WhispererError.message("Could not start the microphone. Check microphone permission and the selected input device.")
        }
        recorder = recording
        file = url
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func stop() -> URL? {
        recorder?.stop(); recorder = nil
        let result = file; file = nil
        return result
    }

    func cancel() { if let url = stop() { try? FileManager.default.removeItem(at: url) } }
}

struct FocusTarget {
    let pid: pid_t
    let element: AXUIElement?
    let selection: CFTypeRef?
    let secure: Bool

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func current() -> FocusTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let value = attribute(application, kAXFocusedUIElementAttribute)
        let element = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        let subrole = element.flatMap { attribute($0, kAXSubroleAttribute) as? String }
        return FocusTarget(pid: app.processIdentifier, element: element,
                           selection: element.flatMap { attribute($0, kAXSelectedTextRangeAttribute) },
                           secure: subrole == kAXSecureTextFieldSubrole)
    }

    func stillFocused() -> Bool {
        guard let current = Self.current(), current.pid == pid, !current.secure,
              let element, let currentElement = current.element, CFEqual(element, currentElement) else { return false }
        if let selection {
            guard let currentSelection = current.selection, CFEqual(selection, currentSelection) else { return false }
        }
        return true
    }
}

enum PasteOutput {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var modifiersHeld: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]).isEmpty
    }

    static func paste() -> Bool {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

final class Hotkey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var busy = false
    var installed: Bool { tap != nil }

    func install() -> Bool {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        uninstall()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userInfo).takeUnretainedValue()
            return hotkey.handle(type, event)
        }, userInfo: pointer) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            held = false
            DispatchQueue.main.async { self.onCancel?() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged && key == 61 {
            // Device-specific right Option flag avoids confusing left Option with right Option.
            let down = event.flags.rawValue & 0x40 != 0
            if down && !held {
                guard event.flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty else {
                    return Unmanaged.passUnretained(event)
                }
                held = true
                DispatchQueue.main.async { self.onPress?() }
                return nil
            }
            if !down && held {
                held = false
                DispatchQueue.main.async { self.onRelease?() }
                return nil
            }
        }
        if type == .keyDown && key == 53 && busy {
            DispatchQueue.main.async { self.onCancel?() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func uninstall() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil; held = false
    }
    deinit { uninstall() }
}

final class RecordingHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var dismissWork: DispatchWorkItem?

    func dismiss() {
        dismissWork?.cancel()
        panel.orderOut(nil)
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 82),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 43, width: 340, height: 22)
        detail.frame = NSRect(x: 20, y: 19, width: 340, height: 18)
        background.addSubview(label); background.addSubview(detail)
        panel.contentView = background
    }

    func show(_ title: String, detail subtitle: String, dismissAfter: Double? = nil) {
        dismissWork?.cancel()
        label.stringValue = title; detail.stringValue = subtitle
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 190, y: screen.visibleFrame.minY + 52))
        }
        panel.orderFrontRegardless()
        if let dismissAfter {
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
        }
    }
}
